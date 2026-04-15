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

struct EahatGramGiftChainNode: Equatable {
    let peerId: EnginePeer.Id
    let peer: EnginePeer
    let depth: Int
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
}

private func eahatGramGiftChainPlaceholderPeer(peerId: EnginePeer.Id) -> EnginePeer {
    return .user(TelegramUser(
        id: peerId,
        accessHash: nil,
        firstName: "User \(peerId.id._internalGetInt64Value())",
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
    peerLimit: Int
) -> Signal<EahatGramGiftChainFetchResult, NoError> {
    return Signal { subscriber in
        let giftsContext = ProfileGiftsContext(account: context.account, peerId: peerId, filter: .All, limit: 200)
        let stateDisposable = MetaDisposable()
        let peerDisposable = MetaDisposable()

        var completed = false

        let completeWithState: (ProfileGiftsContext.State) -> Void = { state in
            guard !completed else {
                return
            }
            completed = true

            var senders: [EahatGramGiftChainSenderSummary] = []
            var senderIndices: [EnginePeer.Id: Int] = [:]
            for gift in state.gifts {
                guard let fromPeer = gift.fromPeer else {
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

            peerDisposable.set((context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> take(1)
            |> deliverOnMainQueue).start(next: { peer in
                subscriber.putNext(EahatGramGiftChainFetchResult(
                    targetPeer: peer,
                    senders: senders,
                    totalGiftCount: state.gifts.count
                ))
                subscriber.putCompletion()
            }))
        }

        stateDisposable.set((giftsContext.state
        |> deliverOnMainQueue).start(next: { state in
            guard !completed else {
                return
            }
            switch state.dataState {
            case let .ready(canLoadMore, _):
                if canLoadMore {
                    giftsContext.loadMore()
                } else {
                    completeWithState(state)
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
        let operationDisposable = MetaDisposable()

        var pending: [(peerId: EnginePeer.Id, depth: Int)] = [(rootPeerId, 0)]
        var visited = Set<EnginePeer.Id>([rootPeerId])
        var nodes: [EnginePeer.Id: EahatGramGiftChainNode] = [
            rootPeerId: EahatGramGiftChainNode(
                peerId: rootPeerId,
                peer: eahatGramGiftChainPlaceholderPeer(peerId: rootPeerId),
                depth: 0
            )
        ]
        var edges: [EahatGramGiftChainEdge] = []
        var isDisposed = false

        let finish: () -> Void = {
            let sortedNodes = nodes.values.sorted { lhs, rhs in
                if lhs.depth != rhs.depth {
                    return lhs.depth < rhs.depth
                }
                return lhs.peerId.toInt64() < rhs.peerId.toInt64()
            }
            let sortedEdges = edges.sorted { lhs, rhs in
                if lhs.fromPeerId != rhs.fromPeerId {
                    return lhs.fromPeerId.toInt64() < rhs.fromPeerId.toInt64()
                }
                return lhs.toPeerId.toInt64() < rhs.toPeerId.toInt64()
            }
            subscriber.putNext(.completed(EahatGramGiftChainGraph(
                rootPeerId: rootPeerId,
                nodes: sortedNodes,
                edges: sortedEdges
            )))
            subscriber.putCompletion()
        }

        func processNext() {
            guard !isDisposed else {
                return
            }
            guard !pending.isEmpty else {
                finish()
                return
            }

            let current = pending.removeFirst()
            subscriber.putNext(.progress("giftChain scan peerId=\(current.peerId.toInt64()) depth=\(current.depth) pending=\(pending.count)"))

            operationDisposable.set((eahatGramLoadGiftChainBranch(
                context: context,
                peerId: current.peerId,
                peerLimit: peerLimit
            )
            |> deliverOnMainQueue).start(next: { result in
                guard !isDisposed else {
                    return
                }

                let resolvedPeer = result.targetPeer ?? nodes[current.peerId]?.peer ?? eahatGramGiftChainPlaceholderPeer(peerId: current.peerId)
                nodes[current.peerId] = EahatGramGiftChainNode(
                    peerId: current.peerId,
                    peer: resolvedPeer,
                    depth: current.depth
                )

                subscriber.putNext(.progress("giftChain loaded peerId=\(current.peerId.toInt64()) depth=\(current.depth) gifts=\(result.totalGiftCount) uniquePeople=\(result.senders.count)"))

                guard current.depth < maxDepth else {
                    processNext()
                    return
                }

                for sender in result.senders {
                    if nodes[sender.peer.id] == nil {
                        nodes[sender.peer.id] = EahatGramGiftChainNode(
                            peerId: sender.peer.id,
                            peer: sender.peer,
                            depth: current.depth + 1
                        )
                    }
                    if !edges.contains(where: { $0.fromPeerId == current.peerId && $0.toPeerId == sender.peer.id }) {
                        edges.append(EahatGramGiftChainEdge(
                            fromPeerId: current.peerId,
                            toPeerId: sender.peer.id,
                            giftCount: sender.giftCount
                        ))
                    }
                    if visited.insert(sender.peer.id).inserted {
                        pending.append((sender.peer.id, current.depth + 1))
                    }
                }

                processNext()
            }))
        }

        processNext()

        return ActionDisposable {
            isDisposed = true
            operationDisposable.dispose()
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

    static let size = CGSize(width: 220.0, height: 82.0)

    init(
        context: AccountContext,
        theme: PresentationTheme,
        node: EahatGramGiftChainNode,
        isRoot: Bool
    ) {
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

        self.nameNode.attributedText = NSAttributedString(
            string: node.peer.compactDisplayTitle,
            font: Font.semibold(14.0),
            textColor: .white
        )
        self.tagNode.attributedText = NSAttributedString(
            string: node.peer.addressName.flatMap { "@\($0)" } ?? "@-",
            font: Font.regular(11.0),
            textColor: UIColor(red: 0.80, green: 0.82, blue: 0.88, alpha: 1.0)
        )
        self.idNode.attributedText = NSAttributedString(
            string: "id \(node.peerId.toInt64())",
            font: Font.with(size: 11.0, weight: .medium, traits: .monospacedNumbers),
            textColor: UIColor(red: 0.86, green: 0.88, blue: 0.92, alpha: 1.0)
        )
        self.depthNode.attributedText = NSAttributedString(
            string: "chain \(node.depth)",
            font: Font.with(size: 11.0, weight: .semibold, traits: .monospacedNumbers),
            textColor: isRoot ? UIColor(red: 0.67, green: 0.84, blue: 1.0, alpha: 1.0) : UIColor(red: 0.70, green: 0.74, blue: 0.86, alpha: 1.0)
        )

        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.avatarNode)
        self.addSubnode(self.nameNode)
        self.addSubnode(self.tagNode)
        self.addSubnode(self.idNode)
        self.addSubnode(self.depthNode)

        self.avatarNode.setPeer(
            context: context,
            theme: theme,
            peer: node.peer,
            clipStyle: .round,
            synchronousLoad: false,
            displayDimensions: CGSize(width: 42.0, height: 42.0)
        )
    }

    override func layout() {
        super.layout()

        self.backgroundNode.frame = self.bounds
        self.avatarNode.frame = CGRect(x: 12.0, y: 20.0, width: 42.0, height: 42.0)

        let textOriginX: CGFloat = 66.0
        let textWidth = self.bounds.width - textOriginX - 12.0

        let nameSize = self.nameNode.updateLayout(CGSize(width: textWidth, height: 18.0))
        self.nameNode.frame = CGRect(x: textOriginX, y: 12.0, width: textWidth, height: nameSize.height)

        let tagSize = self.tagNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.tagNode.frame = CGRect(x: textOriginX, y: 31.0, width: textWidth, height: tagSize.height)

        let idSize = self.idNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.idNode.frame = CGRect(x: textOriginX, y: 48.0, width: textWidth, height: idSize.height)

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

    private let backgroundNode = ASDisplayNode()
    private let scrollView = UIScrollView()
    private let contentNode = ASDisplayNode()
    private let emptyNode = ImmediateTextNode()
    private let linksLayer = CAShapeLayer()

    private var cardNodes: [EnginePeer.Id: EahatGramGiftChainCardNode] = [:]
    private var didSetInitialZoom = false

    init(
        context: AccountContext,
        theme: PresentationTheme,
        graph: EahatGramGiftChainGraph
    ) {
        self.context = context
        self.theme = theme
        self.graph = graph

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
        self.scrollView.minimumZoomScale = 0.25
        self.scrollView.maximumZoomScale = 2.5
        self.scrollView.showsHorizontalScrollIndicator = true
        self.scrollView.showsVerticalScrollIndicator = true
        self.scrollView.bouncesZoom = true
        self.scrollView.backgroundColor = .clear
        self.scrollView.delaysContentTouches = false

        self.view.addSubview(self.scrollView)
        self.scrollView.addSubview(self.contentNode.view)
        self.contentNode.view.layer.addSublayer(self.linksLayer)
        self.linksLayer.fillColor = UIColor.clear.cgColor
        self.linksLayer.strokeColor = UIColor(red: 0.41, green: 0.58, blue: 0.93, alpha: 0.45).cgColor
        self.linksLayer.lineWidth = 2.0
        self.linksLayer.lineCap = .round
        self.linksLayer.lineJoin = .round

        for node in self.graph.nodes {
            let cardNode = EahatGramGiftChainCardNode(
                context: self.context,
                theme: self.theme,
                node: node,
                isRoot: node.peerId == self.graph.rootPeerId
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
        let horizontalSpacing: CGFloat = 28.0
        let verticalSpacing: CGFloat = 70.0
        let contentInset: CGFloat = 36.0

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

        var frames: [EnginePeer.Id: CGRect] = [:]
        for depth in 0 ... maxDepth {
            let rowNodes = (groupedLevels[depth] ?? []).sorted { lhs, rhs in
                lhs.peerId.toInt64() < rhs.peerId.toInt64()
            }
            let rowWidth = CGFloat(rowNodes.count) * cardSize.width + CGFloat(max(0, rowNodes.count - 1)) * horizontalSpacing
            let startX = max(contentInset, floor((contentWidth - rowWidth) * 0.5))
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
            let controlPoint = CGPoint(x: startPoint.x, y: startPoint.y + (endPoint.y - startPoint.y) * 0.55)
            path.move(to: startPoint)
            path.addCurve(to: endPoint, controlPoint1: controlPoint, controlPoint2: CGPoint(x: endPoint.x, y: controlPoint.y))
        }
        self.linksLayer.path = path.cgPath

        if !self.didSetInitialZoom {
            self.didSetInitialZoom = true
            let fitWidthScale = min(1.0, max(0.25, self.scrollView.bounds.width / max(contentWidth, 1.0)))
            self.scrollView.setZoomScale(fitWidthScale, animated: false)
            let visibleWidth = self.scrollView.bounds.width / fitWidthScale
            let centeredOffsetX = max(0.0, (contentWidth - visibleWidth) * 0.5)
            self.scrollView.contentOffset = CGPoint(x: centeredOffsetX, y: 0.0)
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
            graph: self.graph
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
