import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import AvatarNode
import Postbox

private let eahatGramGiftChainQueue = Queue(name: "EahatGramGiftChain", qos: .userInitiated)
private let eahatGramGiftChainMaximumNodes = 180
private let eahatGramGiftChainMaximumConcurrentPeers = 4
private let eahatGramGiftChainCacheLock = NSLock()

private struct EahatGramGiftChainCacheKey: Hashable {
    let peerId: EnginePeer.Id
    let peerLimit: Int
}

private struct EahatGramGiftChainCacheEntry {
    let targetPeer: EnginePeer?
    let senders: [EahatGramGiftChainSenderSummary]
    let totalGiftCount: Int
    let giftCountsByPeerId: [EnginePeer.Id: Int]
}

private var eahatGramGiftChainCache: [EahatGramGiftChainCacheKey: EahatGramGiftChainCacheEntry] = [:]

private func eahatGramRawPeerId(_ peerId: EnginePeer.Id) -> Int64 {
    return peerId.id._internalGetInt64Value()
}

private func eahatGramGiftChainEdgeKey(fromPeerId: EnginePeer.Id, toPeerId: EnginePeer.Id) -> String {
    return "\(fromPeerId.toInt64()):\(toPeerId.toInt64())"
}

struct EahatGramGiftChainNode: Equatable {
    let peerId: EnginePeer.Id
    let peer: EnginePeer
    let depth: Int
    let parentPeerId: EnginePeer.Id?
    let incomingGiftCount: Int
    let mutualGiftCount: Int
}

struct EahatGramGiftChainEdge: Equatable {
    let fromPeerId: EnginePeer.Id
    let toPeerId: EnginePeer.Id
    let giftCount: Int
}

struct EahatGramGiftChainGraph: Equatable {
    let rootPeerId: EnginePeer.Id
    let nodes: [EahatGramGiftChainNode]
    let edges: [EahatGramGiftChainEdge]
    let highlightEdges: [EahatGramGiftChainEdge]
    let isTruncated: Bool
}

enum EahatGramGiftChainBuildEvent: Equatable {
    case progress(String)
    case completed(EahatGramGiftChainGraph)
}

private struct EahatGramGiftChainSenderSummary: Equatable {
    let peer: EnginePeer
    let giftCount: Int
}

private struct EahatGramGiftChainFetchResult: Equatable {
    let targetPeer: EnginePeer?
    let senders: [EahatGramGiftChainSenderSummary]
    let totalGiftCount: Int
    let trackedPeerGiftCount: Int
}

private func eahatGramGiftChainGiftCountsByPeerId(
    gifts: [ProfileGiftsContext.State.StarGift]
) -> [EnginePeer.Id: Int] {
    var counts: [EnginePeer.Id: Int] = [:]
    for gift in gifts {
        guard let fromPeerId = gift.fromPeer?.id else {
            continue
        }
        counts[fromPeerId, default: 0] += 1
    }
    return counts
}

private func eahatGramGiftChainCachedFetchResult(
    peerId: EnginePeer.Id,
    trackedPeerId: EnginePeer.Id?,
    peerLimit: Int
) -> EahatGramGiftChainFetchResult? {
    let key = EahatGramGiftChainCacheKey(peerId: peerId, peerLimit: peerLimit)
    eahatGramGiftChainCacheLock.lock()
    let entry = eahatGramGiftChainCache[key]
    eahatGramGiftChainCacheLock.unlock()
    guard let entry else {
        return nil
    }
    return EahatGramGiftChainFetchResult(
        targetPeer: entry.targetPeer,
        senders: entry.senders,
        totalGiftCount: entry.totalGiftCount,
        trackedPeerGiftCount: trackedPeerId.flatMap { entry.giftCountsByPeerId[$0] } ?? 0
    )
}

private func eahatGramGiftChainStoreFetchResult(
    peerId: EnginePeer.Id,
    peerLimit: Int,
    entry: EahatGramGiftChainCacheEntry
) {
    let key = EahatGramGiftChainCacheKey(peerId: peerId, peerLimit: peerLimit)
    eahatGramGiftChainCacheLock.lock()
    eahatGramGiftChainCache[key] = entry
    eahatGramGiftChainCacheLock.unlock()
}

private func eahatGramGiftChainSenderSummaries(
    gifts: [ProfileGiftsContext.State.StarGift],
    peerLimit: Int
) -> [EahatGramGiftChainSenderSummary] {
    guard peerLimit > 0 else {
        return []
    }

    var senders: [EahatGramGiftChainSenderSummary] = []
    var senderIndices: [EnginePeer.Id: Int] = [:]
    for gift in gifts {
        guard let fromPeer = gift.fromPeer else {
            continue
        }
        guard fromPeer.id.namespace == Namespaces.Peer.CloudUser else {
            continue
        }
        if let existingIndex = senderIndices[fromPeer.id] {
            let existing = senders[existingIndex]
            senders[existingIndex] = EahatGramGiftChainSenderSummary(peer: existing.peer, giftCount: existing.giftCount + 1)
        } else if senders.count < peerLimit {
            senderIndices[fromPeer.id] = senders.count
            senders.append(EahatGramGiftChainSenderSummary(peer: fromPeer, giftCount: 1))
        }
    }
    return senders
}

private func eahatGramGiftChainGiftCount(
    gifts: [ProfileGiftsContext.State.StarGift],
    fromPeerId: EnginePeer.Id?
) -> Int {
    guard let fromPeerId else {
        return 0
    }
    var count = 0
    for gift in gifts {
        if gift.fromPeer?.id == fromPeerId {
            count += 1
        }
    }
    return count
}

private func eahatGramGiftChainPlaceholderPeer(peerId: EnginePeer.Id) -> EnginePeer {
    return .user(TelegramUser(
        id: peerId,
        accessHash: nil,
        firstName: "User \(eahatGramRawPeerId(peerId))",
        lastName: nil,
        username: nil,
        phone: nil,
        photo: [],
        botInfo: nil,
        restrictionInfo: nil,
        flags: [],
        emojiStatus: nil,
        usernames: [],
        storiesHidden: nil,
        nameColor: nil,
        backgroundEmojiId: nil,
        profileColor: nil,
        profileBackgroundEmojiId: nil,
        subscriberCount: nil,
        verificationIconFileId: nil
    ))
}

private func eahatGramLoadGiftChainBranch(
    context: AccountContext,
    peerId: EnginePeer.Id,
    trackedPeerId: EnginePeer.Id?,
    peerLimit: Int
) -> Signal<EahatGramGiftChainFetchResult, NoError> {
    return Signal { subscriber in
        if let cachedResult = eahatGramGiftChainCachedFetchResult(
            peerId: peerId,
            trackedPeerId: trackedPeerId,
            peerLimit: peerLimit
        ) {
            subscriber.putNext(cachedResult)
            subscriber.putCompletion()
            return ActionDisposable {}
        }

        let giftsContext = ProfileGiftsContext(account: context.account, peerId: peerId, filter: .All, limit: 200)
        let stateDisposable = MetaDisposable()
        let peerDisposable = MetaDisposable()

        var completed = false

        let completeWithState: (ProfileGiftsContext.State) -> Void = { state in
            guard !completed else {
                return
            }
            completed = true

            let senders = eahatGramGiftChainSenderSummaries(gifts: state.gifts, peerLimit: peerLimit)
            let giftCountsByPeerId = eahatGramGiftChainGiftCountsByPeerId(gifts: state.gifts)

            peerDisposable.set((context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> take(1)
            |> deliverOn(eahatGramGiftChainQueue)).start(next: { peer in
                let cacheEntry = EahatGramGiftChainCacheEntry(
                    targetPeer: peer,
                    senders: senders,
                    totalGiftCount: state.gifts.count,
                    giftCountsByPeerId: giftCountsByPeerId
                )
                eahatGramGiftChainStoreFetchResult(
                    peerId: peerId,
                    peerLimit: peerLimit,
                    entry: cacheEntry
                )
                subscriber.putNext(EahatGramGiftChainFetchResult(
                    targetPeer: cacheEntry.targetPeer,
                    senders: cacheEntry.senders,
                    totalGiftCount: cacheEntry.totalGiftCount,
                    trackedPeerGiftCount: trackedPeerId.flatMap { cacheEntry.giftCountsByPeerId[$0] } ?? 0
                ))
                subscriber.putCompletion()
            }))
        }

        stateDisposable.set((giftsContext.state
        |> deliverOn(eahatGramGiftChainQueue)).start(next: { state in
            guard !completed else {
                return
            }
            let senderCount = eahatGramGiftChainSenderSummaries(gifts: state.gifts, peerLimit: peerLimit).count
            switch state.dataState {
            case let .ready(canLoadMore, _):
                if senderCount >= peerLimit || !canLoadMore {
                    completeWithState(state)
                } else {
                    giftsContext.loadMore()
                }
            case .loading:
                break
            }
        }))

        return ActionDisposable {
            stateDisposable.dispose()
            peerDisposable.dispose()
        }
    }
}

func eahatGramBuildGiftChainSignal(
    context: AccountContext,
    rootPeerId: EnginePeer.Id,
    maxDepth: Int,
    peerLimit: Int
) -> Signal<EahatGramGiftChainBuildEvent, NoError> {
    return Signal { subscriber in
        var pending: [(peerId: EnginePeer.Id, depth: Int)] = [(rootPeerId, 0)]
        var pendingIndex = 0
        var visited = Set<EnginePeer.Id>([rootPeerId])
        var nodes: [EnginePeer.Id: EahatGramGiftChainNode] = [
            rootPeerId: EahatGramGiftChainNode(
                peerId: rootPeerId,
                peer: eahatGramGiftChainPlaceholderPeer(peerId: rootPeerId),
                depth: 0,
                parentPeerId: nil,
                incomingGiftCount: 0,
                mutualGiftCount: 0
            )
        ]
        var edges: [EahatGramGiftChainEdge] = []
        var edgeKeys = Set<String>()
        var highlightEdges: [EahatGramGiftChainEdge] = []
        var highlightEdgeKeys = Set<String>()
        var rootDirectGiftCounts: [EnginePeer.Id: Int] = [:]
        var isDisposed = false
        var isTruncated = false
        var activeOperations: [EnginePeer.Id: Disposable] = [:]

        let addHighlightEdge: (EnginePeer.Id) -> Void = { peerId in
            guard peerId != rootPeerId, let giftCount = rootDirectGiftCounts[peerId], nodes[peerId] != nil else {
                return
            }
            let key = eahatGramGiftChainEdgeKey(fromPeerId: peerId, toPeerId: rootPeerId)
            if highlightEdgeKeys.insert(key).inserted {
                highlightEdges.append(EahatGramGiftChainEdge(
                    fromPeerId: peerId,
                    toPeerId: rootPeerId,
                    giftCount: giftCount
                ))
            }
        }

        let finish: () -> Void = {
            let sortedNodes = nodes.values.sorted { lhs, rhs in
                if lhs.depth != rhs.depth {
                    return lhs.depth < rhs.depth
                }
                return eahatGramRawPeerId(lhs.peerId) < eahatGramRawPeerId(rhs.peerId)
            }
            let sortedEdges = edges.sorted { lhs, rhs in
                if lhs.fromPeerId != rhs.fromPeerId {
                    return eahatGramRawPeerId(lhs.fromPeerId) < eahatGramRawPeerId(rhs.fromPeerId)
                }
                return eahatGramRawPeerId(lhs.toPeerId) < eahatGramRawPeerId(rhs.toPeerId)
            }
            let sortedHighlightEdges = highlightEdges.sorted { lhs, rhs in
                if lhs.fromPeerId != rhs.fromPeerId {
                    return eahatGramRawPeerId(lhs.fromPeerId) < eahatGramRawPeerId(rhs.fromPeerId)
                }
                return eahatGramRawPeerId(lhs.toPeerId) < eahatGramRawPeerId(rhs.toPeerId)
            }
            subscriber.putNext(.completed(EahatGramGiftChainGraph(
                rootPeerId: rootPeerId,
                nodes: sortedNodes,
                edges: sortedEdges,
                highlightEdges: sortedHighlightEdges,
                isTruncated: isTruncated
            )))
            subscriber.putCompletion()
        }

        func maybeFinish() {
            guard !isDisposed else {
                return
            }
            if pendingIndex >= pending.count && activeOperations.isEmpty {
                finish()
            }
        }

        func startMoreScans() {
            guard !isDisposed else {
                return
            }

            while activeOperations.count < eahatGramGiftChainMaximumConcurrentPeers && pendingIndex < pending.count {
                let current = pending[pendingIndex]
                pendingIndex += 1
                subscriber.putNext(.progress("giftChain scan peerId=\(eahatGramRawPeerId(current.peerId)) depth=\(current.depth) pending=\(pending.count - pendingIndex) active=\(activeOperations.count + 1)"))

                let operationDisposable = MetaDisposable()
                activeOperations[current.peerId] = operationDisposable

                operationDisposable.set((eahatGramLoadGiftChainBranch(
                    context: context,
                    peerId: current.peerId,
                    trackedPeerId: nodes[current.peerId]?.parentPeerId,
                    peerLimit: peerLimit
                )
                |> deliverOn(eahatGramGiftChainQueue)).start(next: { result in
                    guard !isDisposed else {
                        return
                    }

                    activeOperations[current.peerId] = nil

                    let existingNode = nodes[current.peerId] ?? EahatGramGiftChainNode(
                        peerId: current.peerId,
                        peer: eahatGramGiftChainPlaceholderPeer(peerId: current.peerId),
                        depth: current.depth,
                        parentPeerId: nil,
                        incomingGiftCount: 0,
                        mutualGiftCount: 0
                    )
                    let resolvedPeer = result.targetPeer ?? existingNode.peer
                    nodes[current.peerId] = EahatGramGiftChainNode(
                        peerId: current.peerId,
                        peer: resolvedPeer,
                        depth: existingNode.depth,
                        parentPeerId: existingNode.parentPeerId,
                        incomingGiftCount: existingNode.incomingGiftCount,
                        mutualGiftCount: existingNode.parentPeerId == nil ? 0 : (existingNode.incomingGiftCount + result.trackedPeerGiftCount)
                    )

                    addHighlightEdge(current.peerId)

                    subscriber.putNext(.progress("giftChain loaded peerId=\(eahatGramRawPeerId(current.peerId)) depth=\(current.depth) gifts=\(result.totalGiftCount) uniquePeople=\(result.senders.count) active=\(activeOperations.count)"))

                    if current.depth < maxDepth {
                        for sender in result.senders {
                            if current.peerId == rootPeerId {
                                rootDirectGiftCounts[sender.peer.id] = sender.giftCount
                            }

                            if nodes[sender.peer.id] == nil {
                                if nodes.count >= eahatGramGiftChainMaximumNodes {
                                    isTruncated = true
                                    continue
                                }
                                nodes[sender.peer.id] = EahatGramGiftChainNode(
                                    peerId: sender.peer.id,
                                    peer: sender.peer,
                                    depth: current.depth + 1,
                                    parentPeerId: current.peerId,
                                    incomingGiftCount: sender.giftCount,
                                    mutualGiftCount: sender.giftCount
                                )
                            }

                            let edgeKey = eahatGramGiftChainEdgeKey(fromPeerId: current.peerId, toPeerId: sender.peer.id)
                            if edgeKeys.insert(edgeKey).inserted {
                                edges.append(EahatGramGiftChainEdge(
                                    fromPeerId: current.peerId,
                                    toPeerId: sender.peer.id,
                                    giftCount: sender.giftCount
                                ))
                            }

                            addHighlightEdge(sender.peer.id)

                            if visited.insert(sender.peer.id).inserted {
                                pending.append((sender.peer.id, current.depth + 1))
                            }
                        }
                    }

                    startMoreScans()
                    maybeFinish()
                }))
            }

            maybeFinish()
        }

        eahatGramGiftChainQueue.async {
            startMoreScans()
        }

        return ActionDisposable {
            eahatGramGiftChainQueue.async {
                isDisposed = true
                let disposables = Array(activeOperations.values)
                activeOperations.removeAll()
                for disposable in disposables {
                    disposable.dispose()
                }
            }
        }
    }
}

private final class EahatGramGiftChainCardNode: ASDisplayNode {
    private let backgroundNode = ASDisplayNode()
    private let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 15.0))
    private let nameNode = ImmediateTextNode()
    private let tagNode = ImmediateTextNode()
    private let idNode = ImmediateTextNode()
    private let depthNode = ImmediateTextNode()
    private let mutualNode = ImmediateTextNode()
    private let peerId: EnginePeer.Id
    private let copyText: String
    private let openPeer: ((EnginePeer.Id) -> Void)?

    static let size = CGSize(width: 220.0, height: 96.0)

    init(
        context: AccountContext,
        theme: PresentationTheme,
        node: EahatGramGiftChainNode,
        isRoot: Bool,
        openPeer: ((EnginePeer.Id) -> Void)?
    ) {
        self.peerId = node.peerId
        let rawPeerId = eahatGramRawPeerId(node.peerId)
        let tagText = node.peer.addressName.flatMap { "@\($0)" } ?? "@-"
        self.copyText = "\(tagText) \(rawPeerId)"
        self.openPeer = openPeer

        super.init()

        self.backgroundNode.cornerRadius = 16.0
        self.backgroundNode.borderWidth = UIScreenPixel
        self.backgroundNode.backgroundColor = isRoot ? UIColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 0.98) : UIColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 0.96)
        self.backgroundNode.borderColor = (isRoot ? UIColor(red: 0.44, green: 0.69, blue: 0.98, alpha: 1.0) : UIColor(red: 0.25, green: 0.28, blue: 0.34, alpha: 1.0)).cgColor

        self.nameNode.displaysAsynchronously = false
        self.nameNode.maximumNumberOfLines = 1
        self.tagNode.displaysAsynchronously = false
        self.tagNode.maximumNumberOfLines = 1
        self.idNode.displaysAsynchronously = false
        self.idNode.maximumNumberOfLines = 1
        self.depthNode.displaysAsynchronously = false
        self.depthNode.maximumNumberOfLines = 1
        self.mutualNode.displaysAsynchronously = false
        self.mutualNode.maximumNumberOfLines = 1

        self.nameNode.attributedText = NSAttributedString(
            string: node.peer.compactDisplayTitle,
            font: Font.semibold(14.0),
            textColor: .white
        )
        self.tagNode.attributedText = NSAttributedString(
            string: tagText,
            font: Font.regular(11.0),
            textColor: UIColor(red: 0.80, green: 0.82, blue: 0.88, alpha: 1.0)
        )
        self.idNode.attributedText = NSAttributedString(
            string: "id \(rawPeerId)",
            font: Font.with(size: 11.0, weight: .medium, traits: .monospacedNumbers),
            textColor: UIColor(red: 0.86, green: 0.88, blue: 0.92, alpha: 1.0)
        )
        self.depthNode.attributedText = NSAttributedString(
            string: "chain \(node.depth)",
            font: Font.with(size: 11.0, weight: .semibold, traits: .monospacedNumbers),
            textColor: isRoot ? UIColor(red: 0.67, green: 0.84, blue: 1.0, alpha: 1.0) : UIColor(red: 0.70, green: 0.74, blue: 0.86, alpha: 1.0)
        )
        self.mutualNode.attributedText = NSAttributedString(
            string: "mutual \(node.mutualGiftCount)",
            font: Font.with(size: 11.0, weight: .semibold, traits: .monospacedNumbers),
            textColor: UIColor(red: 0.98, green: 0.80, blue: 0.54, alpha: 1.0)
        )

        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.avatarNode)
        self.addSubnode(self.nameNode)
        self.addSubnode(self.tagNode)
        self.addSubnode(self.idNode)
        self.addSubnode(self.depthNode)
        self.addSubnode(self.mutualNode)

        self.avatarNode.setPeer(
            context: context,
            theme: theme,
            peer: node.peer,
            clipStyle: .round,
            synchronousLoad: false,
            displayDimensions: CGSize(width: 42.0, height: 42.0)
        )
    }

    override func didLoad() {
        super.didLoad()

        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTap))
        self.view.addGestureRecognizer(tapGestureRecognizer)

        let longPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.handleLongPress(_:)))
        self.view.addGestureRecognizer(longPressGestureRecognizer)
    }

    @objc private func handleTap() {
        self.openPeer?(self.peerId)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else {
            return
        }
        UIPasteboard.general.string = self.copyText
    }

    override func layout() {
        super.layout()

        self.backgroundNode.frame = self.bounds
        self.avatarNode.frame = CGRect(x: 12.0, y: 27.0, width: 42.0, height: 42.0)

        let textOriginX: CGFloat = 66.0
        let textWidth = max(0.0, self.bounds.width - textOriginX - 76.0)

        let nameSize = self.nameNode.updateLayout(CGSize(width: textWidth, height: 18.0))
        self.nameNode.frame = CGRect(x: textOriginX, y: 12.0, width: textWidth, height: nameSize.height)

        let tagSize = self.tagNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.tagNode.frame = CGRect(x: textOriginX, y: 31.0, width: textWidth, height: tagSize.height)

        let idSize = self.idNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.idNode.frame = CGRect(x: textOriginX, y: 48.0, width: textWidth, height: idSize.height)

        let mutualSize = self.mutualNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.mutualNode.frame = CGRect(x: textOriginX, y: 65.0, width: textWidth, height: mutualSize.height)

        let depthSize = self.depthNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.depthNode.frame = CGRect(
            x: self.bounds.width - 12.0 - depthSize.width,
            y: 12.0,
            width: depthSize.width,
            height: depthSize.height
        )
    }
}

private final class EahatGramGiftChainScreenNode: ASDisplayNode, UIScrollViewDelegate {
    private let context: AccountContext
    private let theme: PresentationTheme
    private let graph: EahatGramGiftChainGraph
    private let openPeer: ((EnginePeer.Id) -> Void)?

    private let backgroundNode = ASDisplayNode()
    private let scrollView = UIScrollView()
    private let contentNode = ASDisplayNode()
    private let emptyNode = ImmediateTextNode()
    private let linksLayer = CAShapeLayer()
    private let highlightLinksLayer = CAShapeLayer()

    private var cardNodes: [EnginePeer.Id: EahatGramGiftChainCardNode] = [:]
    private var didSetInitialZoom = false

    init(
        context: AccountContext,
        theme: PresentationTheme,
        graph: EahatGramGiftChainGraph,
        openPeer: ((EnginePeer.Id) -> Void)?
    ) {
        self.context = context
        self.theme = theme
        self.graph = graph
        self.openPeer = openPeer

        super.init()

        self.backgroundNode.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1.0)
        self.addSubnode(self.backgroundNode)

        self.emptyNode.displaysAsynchronously = false
        self.emptyNode.maximumNumberOfLines = 0
        self.emptyNode.textAlignment = .center
        self.emptyNode.attributedText = NSAttributedString(
            string: "No chain data",
            font: Font.regular(16.0),
            textColor: UIColor(red: 0.72, green: 0.74, blue: 0.78, alpha: 1.0)
        )
        self.addSubnode(self.emptyNode)
    }

    override func didLoad() {
        super.didLoad()

        self.scrollView.delegate = self
        self.scrollView.minimumZoomScale = 0.08
        self.scrollView.maximumZoomScale = 2.5
        self.scrollView.showsHorizontalScrollIndicator = true
        self.scrollView.showsVerticalScrollIndicator = true
        self.scrollView.bouncesZoom = true
        self.scrollView.backgroundColor = .clear
        self.scrollView.delaysContentTouches = false

        self.view.addSubview(self.scrollView)
        self.scrollView.addSubview(self.contentNode.view)
        self.contentNode.view.layer.addSublayer(self.linksLayer)
        self.contentNode.view.layer.addSublayer(self.highlightLinksLayer)
        self.linksLayer.fillColor = UIColor.clear.cgColor
        self.linksLayer.strokeColor = UIColor(red: 0.41, green: 0.58, blue: 0.93, alpha: 0.45).cgColor
        self.linksLayer.lineWidth = 2.0
        self.linksLayer.lineCap = .round
        self.linksLayer.lineJoin = .round
        self.highlightLinksLayer.fillColor = UIColor.clear.cgColor
        self.highlightLinksLayer.strokeColor = UIColor(red: 0.95, green: 0.26, blue: 0.30, alpha: 0.92).cgColor
        self.highlightLinksLayer.lineWidth = 2.4
        self.highlightLinksLayer.lineCap = .round
        self.highlightLinksLayer.lineJoin = .round

        for node in self.graph.nodes {
            let cardNode = EahatGramGiftChainCardNode(
                context: self.context,
                theme: self.theme,
                node: node,
                isRoot: node.peerId == self.graph.rootPeerId,
                openPeer: self.openPeer
            )
            self.cardNodes[node.peerId] = cardNode
            self.contentNode.addSubnode(cardNode)
        }
    }

    func updateLayout(size: CGSize, safeInsets: UIEdgeInsets, navigationHeight: CGFloat) {
        self.backgroundNode.frame = CGRect(origin: .zero, size: size)

        let topInset = navigationHeight
        self.scrollView.frame = CGRect(
            x: 0.0,
            y: topInset,
            width: size.width,
            height: max(0.0, size.height - topInset)
        )
        self.emptyNode.frame = CGRect(
            x: 24.0,
            y: topInset + 40.0,
            width: max(0.0, size.width - 48.0),
            height: 40.0
        )

        guard !self.graph.nodes.isEmpty else {
            self.scrollView.isHidden = true
            self.emptyNode.isHidden = false
            return
        }

        self.scrollView.isHidden = false
        self.emptyNode.isHidden = true

        let groupedLevels = Dictionary(grouping: self.graph.nodes, by: { $0.depth })
        let maxDepth = groupedLevels.keys.max() ?? 0
        let cardSize = EahatGramGiftChainCardNode.size
        let horizontalSpacing: CGFloat = 20.0
        let verticalSpacing: CGFloat = 54.0
        let contentInset: CGFloat = 28.0

        var maximumRowWidth: CGFloat = 0.0
        for depth in 0 ... maxDepth {
            let rowCount = CGFloat(groupedLevels[depth]?.count ?? 0)
            if rowCount > 0.0 {
                let rowWidth = rowCount * cardSize.width + max(0.0, rowCount - 1.0) * horizontalSpacing
                maximumRowWidth = max(maximumRowWidth, rowWidth)
            }
        }

        let availableWidth = max(size.width, self.scrollView.bounds.width)
        let contentWidth = max(availableWidth - 24.0, maximumRowWidth + contentInset * 2.0)
        let contentHeight = contentInset * 2.0 + CGFloat(maxDepth + 1) * cardSize.height + CGFloat(maxDepth) * verticalSpacing

        self.contentNode.frame = CGRect(origin: .zero, size: CGSize(width: contentWidth, height: contentHeight))
        self.contentNode.view.frame = self.contentNode.frame
        self.scrollView.contentSize = self.contentNode.bounds.size
        self.linksLayer.frame = self.contentNode.bounds
        self.highlightLinksLayer.frame = self.contentNode.bounds

        var frames: [EnginePeer.Id: CGRect] = [:]
        for depth in 0 ... maxDepth {
            let rowNodes = (groupedLevels[depth] ?? []).sorted { lhs, rhs in
                eahatGramRawPeerId(lhs.peerId) < eahatGramRawPeerId(rhs.peerId)
            }
            let startX = contentInset
            let originY = contentInset + CGFloat(depth) * (cardSize.height + verticalSpacing)

            for index in 0 ..< rowNodes.count {
                let node = rowNodes[index]
                let frame = CGRect(
                    x: startX + CGFloat(index) * (cardSize.width + horizontalSpacing),
                    y: originY,
                    width: cardSize.width,
                    height: cardSize.height
                )
                frames[node.peerId] = frame
                self.cardNodes[node.peerId]?.frame = frame
            }
        }

        let path = UIBezierPath()
        for edge in self.graph.edges {
            guard let fromFrame = frames[edge.fromPeerId], let toFrame = frames[edge.toPeerId] else {
                continue
            }
            let startPoint = CGPoint(x: fromFrame.midX, y: fromFrame.maxY)
            let endPoint = CGPoint(x: toFrame.midX, y: toFrame.minY)
            let controlOffset = max(24.0, (endPoint.y - startPoint.y) * 0.55)
            path.move(to: startPoint)
            path.addCurve(
                to: endPoint,
                controlPoint1: CGPoint(x: startPoint.x, y: startPoint.y + controlOffset),
                controlPoint2: CGPoint(x: endPoint.x, y: endPoint.y - controlOffset)
            )
        }
        self.linksLayer.path = path.cgPath

        let highlightPath = UIBezierPath()
        for edge in self.graph.highlightEdges {
            guard let fromFrame = frames[edge.fromPeerId], let toFrame = frames[edge.toPeerId] else {
                continue
            }
            let startPoint = CGPoint(x: fromFrame.midX, y: fromFrame.minY)
            let endPoint = CGPoint(x: toFrame.midX, y: toFrame.maxY)
            let controlOffset = max(24.0, (startPoint.y - endPoint.y) * 0.55)
            highlightPath.move(to: startPoint)
            highlightPath.addCurve(
                to: endPoint,
                controlPoint1: CGPoint(x: startPoint.x, y: startPoint.y - controlOffset),
                controlPoint2: CGPoint(x: endPoint.x, y: endPoint.y + controlOffset)
            )

            let arrowLength: CGFloat = 10.0
            let arrowWidth: CGFloat = 5.0
            let basePoint = CGPoint(x: endPoint.x, y: endPoint.y + arrowLength)
            highlightPath.move(to: endPoint)
            highlightPath.addLine(to: CGPoint(x: basePoint.x - arrowWidth, y: basePoint.y))
            highlightPath.move(to: endPoint)
            highlightPath.addLine(to: CGPoint(x: basePoint.x + arrowWidth, y: basePoint.y))
        }
        self.highlightLinksLayer.path = highlightPath.cgPath

        if !self.didSetInitialZoom {
            self.didSetInitialZoom = true
            let fitWidthScale = self.scrollView.bounds.width / max(contentWidth, 1.0)
            let fitHeightScale = self.scrollView.bounds.height / max(contentHeight, 1.0)
            let initialScale = min(1.0, max(self.scrollView.minimumZoomScale, min(fitWidthScale, fitHeightScale)))
            self.scrollView.setZoomScale(initialScale, animated: false)
            self.scrollView.contentOffset = .zero
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return self.contentNode.view
    }
}

final class EahatGramGiftChainScreen: ViewController {
    private let context: AccountContext
    private let graph: EahatGramGiftChainGraph
    private let presentationData: PresentationData

    private var controllerNode: EahatGramGiftChainScreenNode {
        return self.displayNode as! EahatGramGiftChainScreenNode
    }

    init(
        context: AccountContext,
        graph: EahatGramGiftChainGraph
    ) {
        self.context = context
        self.graph = graph
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(
            theme: NavigationBarTheme(
                rootControllerTheme: self.presentationData.theme,
                hideBackground: false,
                hideSeparator: false,
                style: .glass
            ),
            strings: NavigationBarStrings(presentationStrings: self.presentationData.strings)
        ))

        self.title = "Gift Chain"
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = EahatGramGiftChainScreenNode(
            context: self.context,
            theme: self.presentationData.theme,
            graph: self.graph,
            openPeer: { [weak self] peerId in
                guard let self else {
                    return
                }
                let controller = PeerInfoScreenImpl(
                    context: self.context,
                    updatedPresentationData: nil,
                    peerId: peerId,
                    avatarInitiallyExpanded: false,
                    isOpenedFromChat: false,
                    nearbyPeerDistance: nil,
                    reactionSourceMessageId: nil,
                    callMessages: [],
                    isMyProfile: peerId == self.context.account.peerId,
                    profileGiftsContext: nil
                )
                (self.navigationController as? NavigationController)?.pushViewController(controller)
            }
        )
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.updateLayout(
            size: layout.size,
            safeInsets: layout.safeInsets,
            navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY
        )
    }
}
