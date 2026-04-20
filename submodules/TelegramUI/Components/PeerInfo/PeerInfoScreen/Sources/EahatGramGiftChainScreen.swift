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
let eahatGramGiftChainDefaultConcurrentPeers = 4
private let eahatGramGiftChainCacheLock = NSLock()
private let eahatGramGiftChainBranchTimeout = 4.0
private let eahatGramGiftChainFinalizeTimeout = 5.0

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
    let isMutual: Bool
}

struct EahatGramGiftChainGraph: Equatable {
    let rootPeerId: EnginePeer.Id
    let nodes: [EahatGramGiftChainNode]
    let edges: [EahatGramGiftChainEdge]
    let highlightEdges: [EahatGramGiftChainEdge]
    let isTruncated: Bool
}

struct EahatGramGiftChainVisualizationState: Equatable {
    var graph: EahatGramGiftChainGraph
    var focusedPeerId: EnginePeer.Id?
    var manualOrigins: [EnginePeer.Id: CGPoint]
    var selectedEdges: [EahatGramGiftChainEdge]
    var isVisualLineMode: Bool
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

private func eahatGramGiftChainFetchResult(
    state: ProfileGiftsContext.State,
    trackedPeerId: EnginePeer.Id?,
    peerId: EnginePeer.Id,
    peerLimit: Int
) -> EahatGramGiftChainFetchResult {
    let senders = eahatGramGiftChainSenderSummaries(gifts: state.gifts, peerLimit: peerLimit)
    let giftCountsByPeerId = eahatGramGiftChainGiftCountsByPeerId(gifts: state.gifts)
    let cacheEntry = EahatGramGiftChainCacheEntry(
        targetPeer: nil,
        senders: senders,
        totalGiftCount: state.gifts.count,
        giftCountsByPeerId: giftCountsByPeerId
    )
    eahatGramGiftChainStoreFetchResult(
        peerId: peerId,
        peerLimit: peerLimit,
        entry: cacheEntry
    )
    return EahatGramGiftChainFetchResult(
        targetPeer: cacheEntry.targetPeer,
        senders: cacheEntry.senders,
        totalGiftCount: cacheEntry.totalGiftCount,
        trackedPeerGiftCount: trackedPeerId.flatMap { cacheEntry.giftCountsByPeerId[$0] } ?? 0
    )
}

private func eahatGramGiftChainPathPeerIds(
    graph: EahatGramGiftChainGraph,
    targetPeerId: EnginePeer.Id
) -> [EnginePeer.Id] {
    let nodesByPeerId = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.peerId, $0) })
    guard nodesByPeerId[targetPeerId] != nil else {
        return []
    }

    var result: [EnginePeer.Id] = [targetPeerId]
    var currentPeerId = targetPeerId
    var visited = Set<EnginePeer.Id>([targetPeerId])

    while currentPeerId != graph.rootPeerId {
        guard let currentNode = nodesByPeerId[currentPeerId], let parentPeerId = currentNode.parentPeerId else {
            return []
        }
        if !visited.insert(parentPeerId).inserted {
            return []
        }
        result.append(parentPeerId)
        currentPeerId = parentPeerId
    }

    return result
}

private func eahatGramGiftChainPathText(
    graph: EahatGramGiftChainGraph,
    targetPeerId: EnginePeer.Id
) -> String {
    let pathPeerIds = eahatGramGiftChainPathPeerIds(graph: graph, targetPeerId: targetPeerId)
    guard !pathPeerIds.isEmpty else {
        return "Path not found"
    }
    return pathPeerIds.map { "\($0.id._internalGetInt64Value())" }.joined(separator: " -> ")
}

private func eahatGramGiftChainPathEdges(
    graph: EahatGramGiftChainGraph,
    targetPeerId: EnginePeer.Id
) -> [EahatGramGiftChainEdge] {
    let pathPeerIds = eahatGramGiftChainPathPeerIds(graph: graph, targetPeerId: targetPeerId)
    guard pathPeerIds.count >= 2 else {
        return []
    }

    var edges: [EahatGramGiftChainEdge] = []
    for index in 0 ..< (pathPeerIds.count - 1) {
        let fromPeerId = pathPeerIds[index]
        let toPeerId = pathPeerIds[index + 1]
        if let edge = graph.edges.first(where: { $0.fromPeerId == fromPeerId && $0.toPeerId == toPeerId }) {
            edges.append(edge)
        } else if let edge = graph.highlightEdges.first(where: { $0.fromPeerId == fromPeerId && $0.toPeerId == toPeerId }) {
            edges.append(edge)
        } else {
            edges.append(EahatGramGiftChainEdge(
                fromPeerId: fromPeerId,
                toPeerId: toPeerId,
                giftCount: 0,
                isMutual: false
            ))
        }
    }
    return edges
}

private func eahatGramGiftChainPathPeerIds(
    graph: EahatGramGiftChainGraph,
    edge: EahatGramGiftChainEdge
) -> [EnginePeer.Id] {
    if graph.highlightEdges.contains(edge) && edge.fromPeerId == graph.rootPeerId {
        return [graph.rootPeerId, edge.toPeerId]
    }
    return eahatGramGiftChainPathPeerIds(graph: graph, targetPeerId: edge.fromPeerId)
}

private func eahatGramGiftChainPathEdges(
    graph: EahatGramGiftChainGraph,
    edge: EahatGramGiftChainEdge
) -> [EahatGramGiftChainEdge] {
    if graph.highlightEdges.contains(edge) && edge.fromPeerId == graph.rootPeerId {
        return [edge]
    }
    return eahatGramGiftChainPathEdges(graph: graph, targetPeerId: edge.fromPeerId)
}

private func eahatGramGiftChainPathText(
    graph: EahatGramGiftChainGraph,
    edge: EahatGramGiftChainEdge
) -> String {
    let pathPeerIds = eahatGramGiftChainPathPeerIds(graph: graph, edge: edge)
    guard !pathPeerIds.isEmpty else {
        return "Path not found"
    }
    return pathPeerIds.map { "\($0.id._internalGetInt64Value())" }.joined(separator: " -> ")
}

private func eahatGramGiftChainPathText(
    graph: EahatGramGiftChainGraph,
    edges: [EahatGramGiftChainEdge]
) -> String {
    guard !edges.isEmpty else {
        return "Path not found"
    }
    return edges.map { eahatGramGiftChainPathText(graph: graph, edge: $0) }.joined(separator: "\n\n")
}

private func eahatGramGiftChainPathCopyComponent(
    graph: EahatGramGiftChainGraph,
    peerId: EnginePeer.Id
) -> String {
    if let node = graph.nodes.first(where: { $0.peerId == peerId }), let addressName = node.peer.addressName, !addressName.isEmpty {
        return "@\(addressName)"
    }
    return "\(peerId.id._internalGetInt64Value())"
}

private func eahatGramGiftChainPathCopyText(
    graph: EahatGramGiftChainGraph,
    targetPeerId: EnginePeer.Id
) -> String {
    let pathPeerIds = eahatGramGiftChainPathPeerIds(graph: graph, targetPeerId: targetPeerId)
    guard !pathPeerIds.isEmpty else {
        return "Path not found"
    }
    return pathPeerIds.map { eahatGramGiftChainPathCopyComponent(graph: graph, peerId: $0) }.joined(separator: " -> ")
}

private func eahatGramGiftChainHTMLEscape(_ value: String) -> String {
    return value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private let eahatGramGiftChainExportCardSize = CGSize(width: 220.0, height: 96.0)
private let eahatGramGiftChainExportContentInset: CGFloat = 72.0
private let eahatGramGiftChainExportHorizontalSpacing: CGFloat = 180.0
private let eahatGramGiftChainExportVerticalSpacing: CGFloat = 240.0

private struct EahatGramGiftChainExportLayout {
    let graph: EahatGramGiftChainGraph
    let frames: [EnginePeer.Id: CGRect]
    let contentSize: CGSize
}

private struct EahatGramGiftChainExportEdgeGeometry {
    let startPoint: CGPoint
    let endPoint: CGPoint
    let controlPoint1: CGPoint
    let controlPoint2: CGPoint
}

private let eahatGramGiftChainSVGNumberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.decimalSeparator = "."
    return formatter
}()

private func eahatGramGiftChainSVGNumber(_ value: CGFloat) -> String {
    return eahatGramGiftChainSVGNumberFormatter.string(from: NSNumber(value: Double(value))) ?? "0.00"
}

private func eahatGramGiftChainSVGLabel(_ value: String, maxLength: Int) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maxLength else {
        return trimmed
    }
    return String(trimmed.prefix(max(0, maxLength - 3))) + "..."
}

private func eahatGramGiftChainSVGInitials(_ value: String) -> String {
    let parts = value
        .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        .prefix(2)
    let initials = parts.compactMap { part -> String? in
        guard let scalar = part.first else {
            return nil
        }
        return String(scalar).uppercased()
    }.joined()
    if !initials.isEmpty {
        return initials
    }
    if let scalar = value.trimmingCharacters(in: .whitespacesAndNewlines).first {
        return String(scalar).uppercased()
    }
    return "?"
}

private func eahatGramGiftChainExportLayout(
    visualizationState: EahatGramGiftChainVisualizationState
) -> EahatGramGiftChainExportLayout {
    let graph = eahatGramGiftChainDisplayGraph(visualizationState: visualizationState)
    let nodesByPeerId = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.peerId, $0) })
    let cardSize = eahatGramGiftChainExportCardSize

    var childrenByParentPeerId: [EnginePeer.Id: [EnginePeer.Id]] = [:]
    for node in graph.nodes {
        if let parentPeerId = node.parentPeerId, nodesByPeerId[parentPeerId] != nil {
            childrenByParentPeerId[parentPeerId, default: []].append(node.peerId)
        }
    }
    for (parentPeerId, childPeerIds) in childrenByParentPeerId {
        childrenByParentPeerId[parentPeerId] = childPeerIds.sorted(by: { lhs, rhs in
            let lhsNode = nodesByPeerId[lhs]
            let rhsNode = nodesByPeerId[rhs]
            if lhsNode?.incomingGiftCount != rhsNode?.incomingGiftCount {
                return (lhsNode?.incomingGiftCount ?? 0) > (rhsNode?.incomingGiftCount ?? 0)
            }
            return eahatGramRawPeerId(lhs) < eahatGramRawPeerId(rhs)
        })
    }

    var subtreeWidths: [EnginePeer.Id: CGFloat] = [:]
    func subtreeWidth(peerId: EnginePeer.Id) -> CGFloat {
        if let current = subtreeWidths[peerId] {
            return current
        }
        let childPeerIds = childrenByParentPeerId[peerId] ?? []
        if childPeerIds.isEmpty {
            subtreeWidths[peerId] = cardSize.width
            return cardSize.width
        }
        let childWidths = childPeerIds.map { subtreeWidth(peerId: $0) }
        let totalChildWidth = childWidths.reduce(0.0, +) + CGFloat(max(0, childPeerIds.count - 1)) * eahatGramGiftChainExportHorizontalSpacing
        let result = max(cardSize.width, totalChildWidth)
        subtreeWidths[peerId] = result
        return result
    }

    var baseFrames: [EnginePeer.Id: CGRect] = [:]
    func place(peerId: EnginePeer.Id, leftX: CGFloat) -> CGFloat {
        guard let currentNode = nodesByPeerId[peerId] else {
            return leftX + cardSize.width / 2.0
        }
        let childPeerIds = childrenByParentPeerId[peerId] ?? []
        let currentSubtreeWidth = subtreeWidth(peerId: peerId)
        let originY = eahatGramGiftChainExportContentInset + CGFloat(currentNode.depth) * (cardSize.height + eahatGramGiftChainExportVerticalSpacing)

        let centerX: CGFloat
        if childPeerIds.isEmpty {
            centerX = leftX + cardSize.width / 2.0
        } else {
            let childWidths = childPeerIds.map { subtreeWidth(peerId: $0) }
            let totalChildWidth = childWidths.reduce(0.0, +) + CGFloat(max(0, childPeerIds.count - 1)) * eahatGramGiftChainExportHorizontalSpacing
            var nextChildLeftX = leftX + (currentSubtreeWidth - totalChildWidth) / 2.0
            var firstChildCenterX: CGFloat?
            var lastChildCenterX: CGFloat = leftX
            for childPeerId in childPeerIds {
                let childCenterX = place(peerId: childPeerId, leftX: nextChildLeftX)
                if firstChildCenterX == nil {
                    firstChildCenterX = childCenterX
                }
                lastChildCenterX = childCenterX
                nextChildLeftX += subtreeWidth(peerId: childPeerId) + eahatGramGiftChainExportHorizontalSpacing
            }
            centerX = ((firstChildCenterX ?? leftX) + lastChildCenterX) / 2.0
        }

        baseFrames[peerId] = CGRect(
            x: centerX - cardSize.width / 2.0,
            y: originY,
            width: cardSize.width,
            height: cardSize.height
        )
        return centerX
    }

    _ = place(peerId: graph.rootPeerId, leftX: eahatGramGiftChainExportContentInset)

    var frames: [EnginePeer.Id: CGRect] = [:]
    for node in graph.nodes {
        let baseFrame = baseFrames[node.peerId] ?? CGRect(origin: CGPoint(x: eahatGramGiftChainExportContentInset, y: eahatGramGiftChainExportContentInset), size: cardSize)
        if let manualOrigin = visualizationState.manualOrigins[node.peerId] {
            frames[node.peerId] = CGRect(
                origin: CGPoint(
                    x: max(eahatGramGiftChainExportContentInset, manualOrigin.x),
                    y: max(eahatGramGiftChainExportContentInset, manualOrigin.y)
                ),
                size: cardSize
            )
        } else {
            frames[node.peerId] = baseFrame
        }
    }

    let maxX = frames.values.map(\.maxX).max() ?? eahatGramGiftChainExportContentInset
    let maxY = frames.values.map(\.maxY).max() ?? eahatGramGiftChainExportContentInset
    let contentSize = CGSize(
        width: maxX + eahatGramGiftChainExportContentInset,
        height: maxY + eahatGramGiftChainExportContentInset
    )

    return EahatGramGiftChainExportLayout(
        graph: graph,
        frames: frames,
        contentSize: contentSize
    )
}

private func eahatGramGiftChainExportEdgeGeometry(
    edge: EahatGramGiftChainEdge,
    frames: [EnginePeer.Id: CGRect]
) -> EahatGramGiftChainExportEdgeGeometry? {
    guard let fromFrame = frames[edge.fromPeerId], let toFrame = frames[edge.toPeerId] else {
        return nil
    }
    let startPoint = CGPoint(x: fromFrame.midX, y: fromFrame.minY)
    let endPoint = CGPoint(x: toFrame.midX, y: toFrame.maxY)
    let controlOffset = max(120.0, abs(startPoint.y - endPoint.y) * 0.62)
    return EahatGramGiftChainExportEdgeGeometry(
        startPoint: startPoint,
        endPoint: endPoint,
        controlPoint1: CGPoint(x: startPoint.x, y: startPoint.y - controlOffset),
        controlPoint2: CGPoint(x: endPoint.x, y: endPoint.y + controlOffset)
    )
}

private func eahatGramGiftChainSVGPath(
    geometry: EahatGramGiftChainExportEdgeGeometry
) -> String {
    return "M \(eahatGramGiftChainSVGNumber(geometry.startPoint.x)) \(eahatGramGiftChainSVGNumber(geometry.startPoint.y)) C \(eahatGramGiftChainSVGNumber(geometry.controlPoint1.x)) \(eahatGramGiftChainSVGNumber(geometry.controlPoint1.y)), \(eahatGramGiftChainSVGNumber(geometry.controlPoint2.x)) \(eahatGramGiftChainSVGNumber(geometry.controlPoint2.y)), \(eahatGramGiftChainSVGNumber(geometry.endPoint.x)) \(eahatGramGiftChainSVGNumber(geometry.endPoint.y))"
}

private func eahatGramGiftChainSVGArrowPolygon(
    tip: CGPoint,
    referencePoint: CGPoint
) -> String {
    let dx = tip.x - referencePoint.x
    let dy = tip.y - referencePoint.y
    let length = max(1.0, sqrt(dx * dx + dy * dy))
    let unitX = dx / length
    let unitY = dy / length
    let perpendicularX = -unitY
    let perpendicularY = unitX
    let arrowLength: CGFloat = 11.0
    let arrowWidth: CGFloat = 5.5
    let basePoint = CGPoint(x: tip.x - unitX * arrowLength, y: tip.y - unitY * arrowLength)
    let point1 = CGPoint(x: basePoint.x + perpendicularX * arrowWidth, y: basePoint.y + perpendicularY * arrowWidth)
    let point2 = CGPoint(x: basePoint.x - perpendicularX * arrowWidth, y: basePoint.y - perpendicularY * arrowWidth)
    return "\(eahatGramGiftChainSVGNumber(point1.x)),\(eahatGramGiftChainSVGNumber(point1.y)) \(eahatGramGiftChainSVGNumber(tip.x)),\(eahatGramGiftChainSVGNumber(tip.y)) \(eahatGramGiftChainSVGNumber(point2.x)),\(eahatGramGiftChainSVGNumber(point2.y))"
}

private func eahatGramGiftChainHTMLDocument(
    visualizationState: EahatGramGiftChainVisualizationState
) -> String {
    let exportLayout = eahatGramGiftChainExportLayout(visualizationState: visualizationState)
    let graph = exportLayout.graph
    let frames = exportLayout.frames
    let contentSize = exportLayout.contentSize
    let generatedAt = ISO8601DateFormatter().string(from: Date())
    let selectedPathText: String
    if !visualizationState.selectedEdges.isEmpty {
        selectedPathText = eahatGramGiftChainPathText(graph: visualizationState.graph, edges: visualizationState.selectedEdges)
    } else if let focusedPeerId = visualizationState.focusedPeerId {
        selectedPathText = eahatGramGiftChainPathCopyText(graph: visualizationState.graph, targetPeerId: focusedPeerId)
    } else {
        selectedPathText = "Path not selected"
    }

    let selectedPathPeerIds: Set<EnginePeer.Id>
    if !visualizationState.selectedEdges.isEmpty {
        selectedPathPeerIds = eahatGramGiftChainPathPeerIds(graph: visualizationState.graph, edges: visualizationState.selectedEdges)
    } else {
        selectedPathPeerIds = Set(eahatGramGiftChainPathPeerIds(
            graph: visualizationState.graph,
            targetPeerId: visualizationState.focusedPeerId ?? visualizationState.graph.rootPeerId
        ))
    }

    let baseEdgesSVG = (!visualizationState.isVisualLineMode ? graph.edges : []).compactMap { edge -> String? in
        guard let geometry = eahatGramGiftChainExportEdgeGeometry(edge: edge, frames: frames) else {
            return nil
        }
        let path = eahatGramGiftChainSVGPath(geometry: geometry)
        let arrow = eahatGramGiftChainSVGArrowPolygon(tip: geometry.endPoint, referencePoint: geometry.controlPoint2)
        return """
        <path class="edge edge-base" d="\(path)" />
        <polygon class="edge-arrow" points="\(arrow)" />
        """
    }.joined(separator: "\n")

    let highlightEdgesSVG = (!visualizationState.isVisualLineMode ? graph.highlightEdges : []).compactMap { edge -> String? in
        guard let geometry = eahatGramGiftChainExportEdgeGeometry(edge: edge, frames: frames) else {
            return nil
        }
        let path = eahatGramGiftChainSVGPath(geometry: geometry)
        var arrowPolygons: [String] = [
            """
            <polygon class="edge-arrow" points="\(eahatGramGiftChainSVGArrowPolygon(tip: geometry.endPoint, referencePoint: geometry.controlPoint2))" />
            """
        ]
        if edge.isMutual {
            arrowPolygons.append(
                """
                <polygon class="edge-arrow" points="\(eahatGramGiftChainSVGArrowPolygon(tip: geometry.startPoint, referencePoint: geometry.controlPoint1))" />
                """
            )
        }
        return """
        <path class="edge \(edge.isMutual ? "edge-mutual" : "edge-outgoing")" d="\(path)" />
        \(arrowPolygons.joined(separator: "\n"))
        """
    }.joined(separator: "\n")

    let focusedEdges: [EahatGramGiftChainEdge]
    if !visualizationState.selectedEdges.isEmpty {
        focusedEdges = eahatGramGiftChainPathEdges(graph: visualizationState.graph, edges: visualizationState.selectedEdges)
    } else if let focusedPeerId = visualizationState.focusedPeerId {
        focusedEdges = eahatGramGiftChainPathEdges(graph: visualizationState.graph, targetPeerId: focusedPeerId)
    } else {
        focusedEdges = []
    }
    let focusedEdgesSVG = focusedEdges.compactMap { edge -> String? in
        guard let geometry = eahatGramGiftChainExportEdgeGeometry(edge: edge, frames: frames) else {
            return nil
        }
        let path = eahatGramGiftChainSVGPath(geometry: geometry)
        var arrowPolygons: [String] = [
            """
            <polygon class="edge-arrow" points="\(eahatGramGiftChainSVGArrowPolygon(tip: geometry.endPoint, referencePoint: geometry.controlPoint2))" />
            """
        ]
        if edge.isMutual {
            arrowPolygons.append(
                """
                <polygon class="edge-arrow" points="\(eahatGramGiftChainSVGArrowPolygon(tip: geometry.startPoint, referencePoint: geometry.controlPoint1))" />
                """
            )
        }
        return """
        <path class="edge edge-focused" d="\(path)" />
        \(arrowPolygons.joined(separator: "\n"))
        """
    }.joined(separator: "\n")

    let nodeCardsSVG = graph.nodes.sorted(by: { lhs, rhs in
        if lhs.depth != rhs.depth {
            return lhs.depth < rhs.depth
        }
        return eahatGramRawPeerId(lhs.peerId) < eahatGramRawPeerId(rhs.peerId)
    }).compactMap { node -> String? in
        guard let frame = frames[node.peerId] else {
            return nil
        }
        let username = node.peer.addressName.flatMap { "@\($0)" } ?? "@-"
        let searchText = "\(node.peer.compactDisplayTitle) \(username) \(eahatGramRawPeerId(node.peerId))".lowercased()
        let cardClass: String
        if node.peerId == visualizationState.focusedPeerId {
            cardClass = "node-card node-card-target"
        } else if selectedPathPeerIds.contains(node.peerId) {
            cardClass = "node-card node-card-path"
        } else {
            cardClass = "node-card"
        }
        let isRoot = node.peerId == graph.rootPeerId
        let mainClass = isRoot ? "node-main node-main-root" : "node-main"
        let glossClass = isRoot ? "node-gloss node-gloss-root" : "node-gloss"
        return """
        <g class="\(cardClass)" data-search="\(eahatGramGiftChainHTMLEscape(searchText))" transform="translate(\(eahatGramGiftChainSVGNumber(frame.minX)) \(eahatGramGiftChainSVGNumber(frame.minY)))">
          <rect class="node-shadow" x="0" y="6" width="220" height="96" rx="16" ry="16" />
          <rect class="\(mainClass)" x="0" y="0" width="220" height="96" rx="16" ry="16" />
          <rect class="\(glossClass)" x="1" y="1" width="218" height="94" rx="15" ry="15" />
          <circle class="node-avatar" cx="33" cy="48" r="21" />
          <text class="node-avatar-text" x="33" y="53">\(eahatGramGiftChainHTMLEscape(eahatGramGiftChainSVGInitials(node.peer.compactDisplayTitle)))</text>
          <text class="node-title" x="66" y="27">\(eahatGramGiftChainHTMLEscape(eahatGramGiftChainSVGLabel(node.peer.compactDisplayTitle, maxLength: 20)))</text>
          <text class="node-subtitle" x="66" y="44">\(eahatGramGiftChainHTMLEscape(eahatGramGiftChainSVGLabel(username, maxLength: 22)))</text>
          <text class="node-meta" x="66" y="61">id \(eahatGramRawPeerId(node.peerId))</text>
          <text class="node-meta" x="66" y="78">mutual \(node.mutualGiftCount)</text>
          <text class="node-depth" x="208" y="28">chain \(node.depth)</text>
          <text class="node-meta node-meta-right" x="208" y="78">gifts \(node.incomingGiftCount)</text>
        </g>
        """
    }.joined(separator: "\n")

    let edgeRows = graph.edges.sorted(by: { lhs, rhs in
        if lhs.giftCount != rhs.giftCount {
            return lhs.giftCount > rhs.giftCount
        }
        if eahatGramRawPeerId(lhs.fromPeerId) != eahatGramRawPeerId(rhs.fromPeerId) {
            return eahatGramRawPeerId(lhs.fromPeerId) < eahatGramRawPeerId(rhs.fromPeerId)
        }
        return eahatGramRawPeerId(lhs.toPeerId) < eahatGramRawPeerId(rhs.toPeerId)
    }).map { edge -> String in
        let fromNode = graph.nodes.first(where: { $0.peerId == edge.fromPeerId })
        let toNode = graph.nodes.first(where: { $0.peerId == edge.toPeerId })
        let fromText = fromNode?.peer.addressName.flatMap { "@\($0)" } ?? "\(eahatGramRawPeerId(edge.fromPeerId))"
        let toText = toNode?.peer.addressName.flatMap { "@\($0)" } ?? "\(eahatGramRawPeerId(edge.toPeerId))"
        let searchText = "\(fromText) \(toText) \(eahatGramRawPeerId(edge.fromPeerId)) \(eahatGramRawPeerId(edge.toPeerId))".lowercased()
        return """
        <tr data-search="\(eahatGramGiftChainHTMLEscape(searchText))">
          <td>\(eahatGramGiftChainHTMLEscape(fromText))</td>
          <td>\(eahatGramGiftChainHTMLEscape(toText))</td>
          <td>\(edge.giftCount)</td>
          <td>\(edge.isMutual ? "yes" : "no")</td>
        </tr>
        """
    }.joined(separator: "\n")

    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Gift Chain Export</title>
        <style>
        :root {
          color-scheme: dark;
          --bg: #0a0b10;
          --panel: rgba(20, 22, 31, 0.92);
          --panel-strong: rgba(30, 34, 48, 0.98);
          --stroke: rgba(255, 255, 255, 0.08);
          --accent: #6db4ff;
          --accent-2: #9d6bff;
          --danger: rgba(242, 66, 77, 0.95);
          --text: #eef2ff;
          --muted: #9aa4c7;
          --good: #67d38f;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          min-height: 100vh;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          background:
            radial-gradient(circle at top left, rgba(109, 180, 255, 0.20), transparent 28%),
            radial-gradient(circle at top right, rgba(157, 107, 255, 0.18), transparent 24%),
            linear-gradient(180deg, #0d1018 0%, #08090d 100%);
          color: var(--text);
        }
        .shell {
          width: min(1440px, calc(100vw - 48px));
          margin: 24px auto 48px;
        }
        .hero, .panel {
          background: var(--panel);
          border: 1px solid var(--stroke);
          border-radius: 22px;
          backdrop-filter: blur(18px);
          box-shadow: 0 22px 60px rgba(0, 0, 0, 0.30);
        }
        .hero {
          padding: 28px;
          margin-bottom: 20px;
        }
        .title {
          font-size: 34px;
          font-weight: 750;
          letter-spacing: -0.04em;
          margin: 0 0 10px;
        }
        .subtitle {
          color: var(--muted);
          font-size: 14px;
          line-height: 1.6;
          margin: 0;
        }
        .badges {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
          gap: 12px;
          margin-top: 22px;
        }
        .badge {
          padding: 16px 18px;
          border-radius: 18px;
          background: var(--panel-strong);
          border: 1px solid var(--stroke);
        }
        .badge-label {
          color: var(--muted);
          font-size: 12px;
          text-transform: uppercase;
          letter-spacing: 0.08em;
        }
        .badge-value {
          margin-top: 8px;
          font-size: 24px;
          font-weight: 700;
        }
        .toolbar {
          display: flex;
          gap: 12px;
          align-items: center;
          margin: 20px 0;
        }
        .search {
          width: min(420px, 100%);
          border: 1px solid var(--stroke);
          border-radius: 16px;
          padding: 14px 16px;
          background: rgba(12, 14, 20, 0.88);
          color: var(--text);
          font-size: 14px;
          outline: none;
        }
        .panel {
          padding: 24px;
          margin-bottom: 20px;
        }
        .panel-title {
          margin: 0 0 14px;
          font-size: 22px;
          letter-spacing: -0.03em;
        }
        .graph-shell {
          overflow: auto;
          border-radius: 22px;
          border: 1px solid var(--stroke);
          background:
            radial-gradient(circle at top left, rgba(109, 180, 255, 0.18), transparent 24%),
            radial-gradient(circle at top right, rgba(242, 66, 77, 0.14), transparent 20%),
            linear-gradient(180deg, rgba(11, 14, 22, 0.98), rgba(7, 9, 14, 0.98));
          padding: 18px;
        }
        .graph-stage {
          display: block;
        }
        .edge {
          fill: none;
          stroke-linecap: round;
          stroke-linejoin: round;
        }
        .edge-base {
          stroke: rgba(145, 156, 179, 0.55);
          stroke-width: 2;
        }
        .edge-outgoing {
          stroke: rgba(82, 143, 250, 0.95);
          stroke-width: 2.4;
        }
        .edge-mutual {
          stroke: rgba(242, 66, 77, 0.95);
          stroke-width: 2.6;
        }
        .edge-focused {
          stroke: rgba(245, 212, 92, 0.98);
          stroke-width: 3;
        }
        .edge-arrow {
          fill: var(--danger);
          opacity: 0.98;
        }
        .node-shadow {
          fill: rgba(0, 0, 0, 0.28);
          filter: blur(6px);
        }
        .node-main {
          fill: rgba(23, 26, 36, 0.96);
          stroke: rgba(64, 71, 87, 1.0);
          stroke-width: 1;
        }
        .node-main-root {
          fill: rgba(41, 46, 61, 0.98);
          stroke: rgba(112, 176, 250, 1.0);
        }
        .node-gloss {
          fill: rgba(255, 255, 255, 0.015);
          stroke: rgba(255, 255, 255, 0.03);
          stroke-width: 0.8;
        }
        .node-gloss-root {
          fill: rgba(255, 255, 255, 0.028);
        }
        .node-card-path .node-main {
          stroke: rgba(227, 189, 69, 1.0);
          stroke-width: 1.8;
        }
        .node-card-target .node-main {
          stroke: rgba(245, 212, 92, 0.98);
          stroke-width: 2.2;
        }
        .node-avatar {
          fill: rgba(255, 255, 255, 0.08);
          stroke: rgba(255, 255, 255, 0.07);
          stroke-width: 1;
        }
        .node-avatar-text {
          font-size: 14px;
          font-weight: 700;
          fill: #f4f7ff;
          text-anchor: middle;
        }
        .node-title {
          font-size: 14px;
          font-weight: 600;
          fill: #f2f5ff;
        }
        .node-subtitle,
        .node-meta {
          font-size: 11px;
          fill: rgba(204, 209, 224, 1.0);
        }
        .node-depth {
          font-size: 11px;
          font-weight: 600;
          text-anchor: end;
          fill: rgba(179, 189, 219, 1.0);
        }
        .node-meta-right {
          text-anchor: end;
        }
        .path-box {
          white-space: pre-wrap;
          line-height: 1.7;
          color: #dbe4ff;
          background: rgba(8, 11, 18, 0.9);
          border: 1px solid var(--stroke);
          border-radius: 18px;
          padding: 18px;
        }
        .depth-grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(270px, 1fr));
          gap: 16px;
        }
        .depth-column {
          border: 1px solid var(--stroke);
          border-radius: 18px;
          background: rgba(11, 13, 20, 0.85);
          padding: 16px;
        }
        .depth-title {
          font-size: 12px;
          color: var(--muted);
          text-transform: uppercase;
          letter-spacing: 0.08em;
          margin-bottom: 14px;
        }
        .depth-cards {
          display: grid;
          gap: 12px;
        }
        .node-card {
          border: 1px solid rgba(255, 255, 255, 0.06);
          border-radius: 16px;
          padding: 14px;
          background: linear-gradient(180deg, rgba(36, 41, 58, 0.95), rgba(17, 20, 31, 0.96));
        }
        .node-title {
          font-size: 17px;
          font-weight: 650;
        }
        .node-subtitle, .node-meta {
          color: var(--muted);
          font-size: 13px;
          margin-top: 4px;
        }
        .node-stats {
          display: flex;
          flex-wrap: wrap;
          gap: 8px;
          margin-top: 12px;
        }
        .node-stats span {
          font-size: 12px;
          padding: 6px 10px;
          border-radius: 999px;
          background: rgba(255, 255, 255, 0.06);
          color: #dfe7ff;
        }
        table {
          width: 100%;
          border-collapse: collapse;
          overflow: hidden;
          border-radius: 18px;
          border: 1px solid var(--stroke);
        }
        th, td {
          text-align: left;
          padding: 14px 16px;
          font-size: 14px;
          border-bottom: 1px solid rgba(255, 255, 255, 0.05);
        }
        th {
          color: var(--muted);
          font-weight: 600;
          background: rgba(255, 255, 255, 0.03);
        }
        tr:last-child td {
          border-bottom: none;
        }
        .status-good {
          color: var(--good);
          font-weight: 700;
        }
        @media (max-width: 768px) {
          .shell {
            width: calc(100vw - 20px);
            margin: 10px auto 24px;
          }
          .hero, .panel {
            padding: 18px;
            border-radius: 18px;
          }
          .title {
            font-size: 28px;
          }
          th, td {
            padding: 12px;
            font-size: 13px;
          }
        }
      </style>
    </head>
    <body>
      <div class="shell">
        <section class="hero">
          <h1 class="title">Gift Chain Export</h1>
          <p class="subtitle">Generated at \(eahatGramGiftChainHTMLEscape(generatedAt)) for root peer id \(eahatGramRawPeerId(graph.rootPeerId)). Current selection and visible graph are embedded below for desktop review.</p>
          <div class="badges">
            <div class="badge"><div class="badge-label">Root Peer</div><div class="badge-value">\(eahatGramRawPeerId(graph.rootPeerId))</div></div>
            <div class="badge"><div class="badge-label">Visible Nodes</div><div class="badge-value">\(graph.nodes.count)</div></div>
            <div class="badge"><div class="badge-label">Visible Edges</div><div class="badge-value">\(graph.edges.count)</div></div>
            <div class="badge"><div class="badge-label">Highlighted Edges</div><div class="badge-value">\(graph.highlightEdges.count)</div></div>
            <div class="badge"><div class="badge-label">Selected Lines</div><div class="badge-value">\(visualizationState.selectedEdges.count)</div></div>
            <div class="badge"><div class="badge-label">Truncated</div><div class="badge-value \(graph.isTruncated ? "" : "status-good")">\(graph.isTruncated ? "YES" : "NO")</div></div>
          </div>
        </section>

        <div class="toolbar">
          <input id="query" class="search" type="search" placeholder="Filter by title, @username or peer id" oninput="filterGiftChain()">
        </div>

        <section class="panel">
          <h2 class="panel-title">Visualization</h2>
          <div class="graph-shell">
            <svg class="graph-stage" width="\(eahatGramGiftChainSVGNumber(contentSize.width))" height="\(eahatGramGiftChainSVGNumber(contentSize.height))" viewBox="0 0 \(eahatGramGiftChainSVGNumber(contentSize.width)) \(eahatGramGiftChainSVGNumber(contentSize.height))" xmlns="http://www.w3.org/2000/svg">
              <g class="edge-layer">
                \(baseEdgesSVG)
                \(highlightEdgesSVG)
                \(focusedEdgesSVG)
              </g>
              <g class="node-layer">
                \(nodeCardsSVG)
              </g>
            </svg>
          </div>
        </section>

        <section class="panel">
          <h2 class="panel-title">Current Path</h2>
          <div class="path-box">\(eahatGramGiftChainHTMLEscape(selectedPathText))</div>
        </section>

        <section class="panel">
          <h2 class="panel-title">Edges</h2>
          <table>
            <thead>
              <tr>
                <th>From</th>
                <th>To</th>
                <th>Gift Count</th>
                <th>Mutual</th>
              </tr>
            </thead>
            <tbody>
              \(edgeRows)
            </tbody>
          </table>
        </section>
      </div>
      <script>
        function filterGiftChain() {
          const query = (document.getElementById('query').value || '').toLowerCase().trim();
          document.querySelectorAll('[data-search]').forEach(function(node) {
            const haystack = node.getAttribute('data-search') || '';
            node.style.display = !query || haystack.indexOf(query) !== -1 ? '' : 'none';
          });
        }
      </script>
    </body>
    </html>
    """
}

private func eahatGramGiftChainSelectedEdgeKeys(
    edges: [EahatGramGiftChainEdge]
) -> Set<String> {
    return Set(edges.map { eahatGramGiftChainEdgeKey(fromPeerId: $0.fromPeerId, toPeerId: $0.toPeerId) })
}

private func eahatGramGiftChainPathPeerIds(
    graph: EahatGramGiftChainGraph,
    edges: [EahatGramGiftChainEdge]
) -> Set<EnginePeer.Id> {
    var result = Set<EnginePeer.Id>()
    for edge in edges {
        for peerId in eahatGramGiftChainPathPeerIds(graph: graph, edge: edge) {
            result.insert(peerId)
        }
    }
    return result
}

private func eahatGramGiftChainPathEdges(
    graph: EahatGramGiftChainGraph,
    edges: [EahatGramGiftChainEdge]
) -> [EahatGramGiftChainEdge] {
    var result: [EahatGramGiftChainEdge] = []
    var resultKeys = Set<String>()
    for edge in edges {
        for pathEdge in eahatGramGiftChainPathEdges(graph: graph, edge: edge) {
            let edgeKey = eahatGramGiftChainEdgeKey(fromPeerId: pathEdge.fromPeerId, toPeerId: pathEdge.toPeerId)
            if resultKeys.insert(edgeKey).inserted {
                result.append(pathEdge)
            }
        }
    }
    return result
}

private func eahatGramGiftChainDisplayGraph(
    visualizationState: EahatGramGiftChainVisualizationState
) -> EahatGramGiftChainGraph {
    let graph = visualizationState.graph
    guard visualizationState.isVisualLineMode, !visualizationState.selectedEdges.isEmpty else {
        return graph
    }

    let pathPeerIds = eahatGramGiftChainPathPeerIds(graph: graph, edges: visualizationState.selectedEdges)
    let pathEdges = eahatGramGiftChainPathEdges(graph: graph, edges: visualizationState.selectedEdges)
    let pathEdgeKeys = Set(pathEdges.map { eahatGramGiftChainEdgeKey(fromPeerId: $0.fromPeerId, toPeerId: $0.toPeerId) })
    let selectedEdgeKeys = eahatGramGiftChainSelectedEdgeKeys(edges: visualizationState.selectedEdges)

    return EahatGramGiftChainGraph(
        rootPeerId: graph.rootPeerId,
        nodes: graph.nodes.filter { pathPeerIds.contains($0.peerId) },
        edges: graph.edges.filter {
            pathEdgeKeys.contains(eahatGramGiftChainEdgeKey(fromPeerId: $0.fromPeerId, toPeerId: $0.toPeerId))
        },
        highlightEdges: graph.highlightEdges.filter {
            let edgeKey = eahatGramGiftChainEdgeKey(fromPeerId: $0.fromPeerId, toPeerId: $0.toPeerId)
            return pathEdgeKeys.contains(edgeKey) || selectedEdgeKeys.contains(edgeKey)
        },
        isTruncated: graph.isTruncated
    )
}

private func eahatGramGiftChainSearchMatches(
    graph: EahatGramGiftChainGraph,
    query: String
) -> [EahatGramGiftChainNode] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedQuery.isEmpty else {
        return []
    }
    let strippedQuery: String
    if normalizedQuery.hasPrefix("@") {
        strippedQuery = String(normalizedQuery.dropFirst())
    } else {
        strippedQuery = normalizedQuery
    }

    return graph.nodes.filter { node in
        let rawPeerId = "\(eahatGramRawPeerId(node.peerId))"
        let title = node.peer.compactDisplayTitle.lowercased()
        let username = node.peer.addressName?.lowercased() ?? ""
        return rawPeerId == strippedQuery || rawPeerId.contains(strippedQuery) || title.contains(strippedQuery) || username.contains(strippedQuery)
    }.sorted { lhs, rhs in
        if lhs.depth != rhs.depth {
            return lhs.depth < rhs.depth
        }
        return eahatGramRawPeerId(lhs.peerId) < eahatGramRawPeerId(rhs.peerId)
    }
}

private func eahatGramGiftChainCopyText(node: EahatGramGiftChainNode) -> String {
    let tagText = node.peer.addressName.flatMap { "@\($0)" } ?? "@-"
    return "\(tagText) \(eahatGramRawPeerId(node.peerId))"
}

private func eahatGramGiftChainNodeSummaryText(node: EahatGramGiftChainNode) -> String {
    let tagText = node.peer.addressName.flatMap { "@\($0)" } ?? "@-"
    return "\(node.peer.compactDisplayTitle)\n\(tagText)\nid \(eahatGramRawPeerId(node.peerId))"
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

        var completed = false
        var lastState: ProfileGiftsContext.State?
        var timeoutTimer: SwiftSignalKit.Timer?

        let completeWithResult: (EahatGramGiftChainFetchResult) -> Void = { result in
            guard !completed else {
                return
            }
            completed = true
            timeoutTimer?.invalidate()
            timeoutTimer = nil
            subscriber.putNext(result)
            subscriber.putCompletion()
        }

        let completeWithState: (ProfileGiftsContext.State) -> Void = { state in
            completeWithResult(eahatGramGiftChainFetchResult(
                state: state,
                trackedPeerId: trackedPeerId,
                peerId: peerId,
                peerLimit: peerLimit
            ))
        }

        let resetTimeout: () -> Void = {
            timeoutTimer?.invalidate()
            timeoutTimer = SwiftSignalKit.Timer(timeout: eahatGramGiftChainBranchTimeout, repeat: false, completion: {
                if let lastState {
                    completeWithState(lastState)
                } else {
                    let emptyEntry = EahatGramGiftChainCacheEntry(
                        targetPeer: nil,
                        senders: [],
                        totalGiftCount: 0,
                        giftCountsByPeerId: [:]
                    )
                    eahatGramGiftChainStoreFetchResult(
                        peerId: peerId,
                        peerLimit: peerLimit,
                        entry: emptyEntry
                    )
                    completeWithResult(EahatGramGiftChainFetchResult(
                        targetPeer: nil,
                        senders: [],
                        totalGiftCount: 0,
                        trackedPeerGiftCount: 0
                    ))
                }
            }, queue: eahatGramGiftChainQueue)
            timeoutTimer?.start()
        }

        resetTimeout()

        stateDisposable.set((giftsContext.state
        |> deliverOn(eahatGramGiftChainQueue)).start(next: { state in
            guard !completed else {
                return
            }

            lastState = state
            resetTimeout()

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
            timeoutTimer?.invalidate()
            stateDisposable.dispose()
        }
    }
}

func eahatGramBuildGiftChainSignal(
    context: AccountContext,
    rootPeerId: EnginePeer.Id,
    maxDepth: Int,
    peerLimit: Int,
    maxConcurrentPeers: Int
) -> Signal<EahatGramGiftChainBuildEvent, NoError> {
    return Signal { subscriber in
        let boundedConcurrentPeers = max(1, maxConcurrentPeers)
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
        var isDisposed = false
        var hasFinished = false
        var isTruncated = false
        var activeOperations: [EnginePeer.Id: Disposable] = [:]
        var finishTimer: SwiftSignalKit.Timer?

        let invalidateFinishTimer: () -> Void = {
            finishTimer?.invalidate()
            finishTimer = nil
        }

        let finish: () -> Void = {
            guard !hasFinished else {
                return
            }
            hasFinished = true
            invalidateFinishTimer()
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
            guard !isDisposed, !hasFinished else {
                return
            }
            if pendingIndex >= pending.count {
                if activeOperations.isEmpty {
                    finish()
                } else if finishTimer == nil {
                    finishTimer = SwiftSignalKit.Timer(timeout: eahatGramGiftChainFinalizeTimeout, repeat: false, completion: {
                        guard !isDisposed, !hasFinished else {
                            return
                        }
                        guard pendingIndex >= pending.count, !activeOperations.isEmpty else {
                            return
                        }
                        let disposables = Array(activeOperations.values)
                        activeOperations.removeAll()
                        for disposable in disposables {
                            disposable.dispose()
                        }
                        finish()
                    }, queue: eahatGramGiftChainQueue)
                    finishTimer?.start()
                }
            } else {
                invalidateFinishTimer()
            }
        }

        func startMoreScans() {
            guard !isDisposed else {
                return
            }

            while activeOperations.count < boundedConcurrentPeers && pendingIndex < pending.count {
                let current = pending[pendingIndex]
                pendingIndex += 1
                subscriber.putNext(.progress("giftChain scan rootPeerId=\(eahatGramRawPeerId(rootPeerId)) currentPeerId=\(eahatGramRawPeerId(current.peerId)) depth=\(current.depth) pending=\(pending.count - pendingIndex) active=\(activeOperations.count + 1)"))

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

                    if existingNode.parentPeerId == rootPeerId && result.trackedPeerGiftCount > 0 {
                        let highlightKey = eahatGramGiftChainEdgeKey(fromPeerId: rootPeerId, toPeerId: current.peerId)
                        if highlightEdgeKeys.insert(highlightKey).inserted {
                            highlightEdges.append(EahatGramGiftChainEdge(
                                fromPeerId: rootPeerId,
                                toPeerId: current.peerId,
                                giftCount: result.trackedPeerGiftCount,
                                isMutual: existingNode.incomingGiftCount > 0
                            ))
                        }
                    }

                    subscriber.putNext(.progress("giftChain loaded rootPeerId=\(eahatGramRawPeerId(rootPeerId)) currentPeerId=\(eahatGramRawPeerId(current.peerId)) depth=\(current.depth) gifts=\(result.totalGiftCount) uniquePeople=\(result.senders.count) pending=\(pending.count - pendingIndex) active=\(activeOperations.count)"))

                    if current.depth < maxDepth {
                        for sender in result.senders {
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

                            let edgeKey = eahatGramGiftChainEdgeKey(fromPeerId: sender.peer.id, toPeerId: current.peerId)
                            if edgeKeys.insert(edgeKey).inserted {
                                edges.append(EahatGramGiftChainEdge(
                                    fromPeerId: sender.peer.id,
                                    toPeerId: current.peerId,
                                    giftCount: sender.giftCount,
                                    isMutual: false
                                ))
                            }

                            if visited.insert(sender.peer.id).inserted {
                                pending.append((sender.peer.id, current.depth + 1))
                            }
                        }
                    }

                    startMoreScans()
                    maybeFinish()
                }, completed: {
                    guard !isDisposed else {
                        return
                    }
                    if activeOperations[current.peerId] != nil {
                        activeOperations[current.peerId] = nil
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
                invalidateFinishTimer()
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
    private let defaultBorderColor: UIColor
    private let defaultBorderWidth: CGFloat
    private let tapPeer: ((EnginePeer.Id) -> Void)?
    private let dragPeer: ((EnginePeer.Id, UIGestureRecognizer.State, CGPoint) -> Void)?

    static let size = CGSize(width: 220.0, height: 96.0)

    init(
        context: AccountContext,
        theme: PresentationTheme,
        node: EahatGramGiftChainNode,
        isRoot: Bool,
        tapPeer: ((EnginePeer.Id) -> Void)?,
        dragPeer: ((EnginePeer.Id, UIGestureRecognizer.State, CGPoint) -> Void)?
    ) {
        self.peerId = node.peerId
        self.tapPeer = tapPeer
        self.dragPeer = dragPeer
        self.defaultBorderColor = isRoot ? UIColor(red: 0.44, green: 0.69, blue: 0.98, alpha: 1.0) : UIColor(red: 0.25, green: 0.28, blue: 0.34, alpha: 1.0)
        self.defaultBorderWidth = UIScreenPixel

        super.init()

        self.backgroundNode.cornerRadius = 16.0
        self.backgroundNode.borderWidth = self.defaultBorderWidth
        self.backgroundNode.backgroundColor = isRoot ? UIColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 0.98) : UIColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 0.96)
        self.backgroundNode.borderColor = self.defaultBorderColor.cgColor

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
            string: node.peer.addressName.flatMap { "@\($0)" } ?? "@-",
            font: Font.regular(11.0),
            textColor: UIColor(red: 0.80, green: 0.82, blue: 0.88, alpha: 1.0)
        )
        self.idNode.attributedText = NSAttributedString(
            string: "id \(eahatGramRawPeerId(node.peerId))",
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

    func updatePathHighlight(isOnPath: Bool, isTarget: Bool) {
        if isTarget {
            self.backgroundNode.borderColor = UIColor(red: 0.96, green: 0.83, blue: 0.36, alpha: 1.0).cgColor
            self.backgroundNode.borderWidth = 2.2
        } else if isOnPath {
            self.backgroundNode.borderColor = UIColor(red: 0.89, green: 0.74, blue: 0.27, alpha: 1.0).cgColor
            self.backgroundNode.borderWidth = 1.8
        } else {
            self.backgroundNode.borderColor = self.defaultBorderColor.cgColor
            self.backgroundNode.borderWidth = self.defaultBorderWidth
        }
    }

    override func didLoad() {
        super.didLoad()

        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTap))
        let longPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.handleLongPress(_:)))
        longPressGestureRecognizer.minimumPressDuration = 0.25
        tapGestureRecognizer.require(toFail: longPressGestureRecognizer)
        self.view.addGestureRecognizer(tapGestureRecognizer)
        self.view.addGestureRecognizer(longPressGestureRecognizer)
    }

    @objc private func handleTap() {
        self.tapPeer?(self.peerId)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let superview = self.supernode?.view else {
            return
        }
        let location = recognizer.location(in: superview)
        self.dragPeer?(self.peerId, recognizer.state, location)
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
    private var visualizationState: EahatGramGiftChainVisualizationState
    private let tapPeer: ((EnginePeer.Id) -> Void)?
    private let tapEdge: ((EahatGramGiftChainEdge) -> Void)?
    private let stateUpdated: ((EahatGramGiftChainVisualizationState) -> Void)?

    private let backgroundNode = ASDisplayNode()
    private let scrollView = UIScrollView()
    private let contentNode = ASDisplayNode()
    private let emptyNode = ImmediateTextNode()
    private let linksLayer = CAShapeLayer()
    private let outgoingLinksLayer = CAShapeLayer()
    private let mutualLinksLayer = CAShapeLayer()
    private let focusedLinksLayer = CAShapeLayer()

    private var cardNodes: [EnginePeer.Id: EahatGramGiftChainCardNode] = [:]
    private var currentFrames: [EnginePeer.Id: CGRect] = [:]
    private var draggingPeerId: EnginePeer.Id?
    private var dragTouchOffset = CGPoint()
    private var didSetInitialZoom = false
    private var lastLayoutSize = CGSize()
    private var lastSafeInsets = UIEdgeInsets()
    private var lastNavigationHeight: CGFloat = 0.0
    private var hasLayout = false
    private var centerFocusedAfterLayout = false
    private var animateFocusCentering = false
    private var edgeHitRegions: [(edge: EahatGramGiftChainEdge, path: CGPath)] = []

    init(
        context: AccountContext,
        theme: PresentationTheme,
        visualizationState: EahatGramGiftChainVisualizationState,
        tapPeer: ((EnginePeer.Id) -> Void)?,
        tapEdge: ((EahatGramGiftChainEdge) -> Void)?,
        stateUpdated: ((EahatGramGiftChainVisualizationState) -> Void)?
    ) {
        var initialVisualizationState = visualizationState
        if initialVisualizationState.focusedPeerId == nil {
            initialVisualizationState.focusedPeerId = initialVisualizationState.graph.rootPeerId
        }
        self.context = context
        self.theme = theme
        self.visualizationState = initialVisualizationState
        self.tapPeer = tapPeer
        self.tapEdge = tapEdge
        self.stateUpdated = stateUpdated
        self.centerFocusedAfterLayout = initialVisualizationState.focusedPeerId != nil

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
        self.scrollView.disablesInteractiveTransitionGestureRecognizer = true
        self.scrollView.disablesInteractiveTransitionGestureRecognizerNow = { true }

        self.view.addSubview(self.scrollView)
        self.scrollView.addSubview(self.contentNode.view)
        self.view.disablesInteractiveTransitionGestureRecognizerNow = { true }
        self.contentNode.view.disablesInteractiveTransitionGestureRecognizerNow = { true }
        let lineTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleLineTap(_:)))
        lineTapGestureRecognizer.cancelsTouchesInView = false
        self.contentNode.view.addGestureRecognizer(lineTapGestureRecognizer)
        self.contentNode.view.layer.addSublayer(self.linksLayer)
        self.contentNode.view.layer.addSublayer(self.outgoingLinksLayer)
        self.contentNode.view.layer.addSublayer(self.mutualLinksLayer)
        self.contentNode.view.layer.addSublayer(self.focusedLinksLayer)

        self.linksLayer.fillColor = UIColor.clear.cgColor
        self.linksLayer.strokeColor = UIColor(red: 0.57, green: 0.61, blue: 0.70, alpha: 0.55).cgColor
        self.linksLayer.lineWidth = 2.0
        self.linksLayer.lineCap = .round
        self.linksLayer.lineJoin = .round

        self.outgoingLinksLayer.fillColor = UIColor.clear.cgColor
        self.outgoingLinksLayer.strokeColor = UIColor(red: 0.32, green: 0.56, blue: 0.98, alpha: 0.95).cgColor
        self.outgoingLinksLayer.lineWidth = 2.4
        self.outgoingLinksLayer.lineCap = .round
        self.outgoingLinksLayer.lineJoin = .round

        self.mutualLinksLayer.fillColor = UIColor.clear.cgColor
        self.mutualLinksLayer.strokeColor = UIColor(red: 0.95, green: 0.26, blue: 0.30, alpha: 0.95).cgColor
        self.mutualLinksLayer.lineWidth = 2.6
        self.mutualLinksLayer.lineCap = .round
        self.mutualLinksLayer.lineJoin = .round

        self.focusedLinksLayer.fillColor = UIColor.clear.cgColor
        self.focusedLinksLayer.strokeColor = UIColor(red: 0.96, green: 0.83, blue: 0.36, alpha: 0.98).cgColor
        self.focusedLinksLayer.lineWidth = 3.0
        self.focusedLinksLayer.lineCap = .round
        self.focusedLinksLayer.lineJoin = .round

        for node in self.visualizationState.graph.nodes {
            let cardNode = EahatGramGiftChainCardNode(
                context: self.context,
                theme: self.theme,
                node: node,
                isRoot: node.peerId == self.visualizationState.graph.rootPeerId,
                tapPeer: self.tapPeer,
                dragPeer: { [weak self] peerId, state, location in
                    self?.updateDrag(peerId: peerId, state: state, location: location)
                }
            )
            self.cardNodes[node.peerId] = cardNode
            self.contentNode.addSubnode(cardNode)
        }
    }

    func setVisualizationState(_ visualizationState: EahatGramGiftChainVisualizationState, centerOnFocusedPeer: Bool) {
        self.visualizationState = visualizationState
        self.centerFocusedAfterLayout = centerOnFocusedPeer
        self.animateFocusCentering = centerOnFocusedPeer
        self.relayout(centerOnFocusedPeer: centerOnFocusedPeer, animatedCentering: true)
    }

    func pathText(for peerId: EnginePeer.Id) -> String {
        return eahatGramGiftChainPathText(graph: self.visualizationState.graph, targetPeerId: peerId)
    }

    func updateLayout(size: CGSize, safeInsets: UIEdgeInsets, navigationHeight: CGFloat) {
        self.lastLayoutSize = size
        self.lastSafeInsets = safeInsets
        self.lastNavigationHeight = navigationHeight
        self.hasLayout = true

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

        guard !self.visualizationState.graph.nodes.isEmpty else {
            self.scrollView.isHidden = true
            self.emptyNode.isHidden = false
            self.currentFrames = [:]
            return
        }

        self.scrollView.isHidden = false
        self.emptyNode.isHidden = true

        let graph = eahatGramGiftChainDisplayGraph(visualizationState: self.visualizationState)
        let nodesByPeerId = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.peerId, $0) })
        let cardSize = EahatGramGiftChainCardNode.size
        let contentInset: CGFloat = 72.0
        let horizontalSpacing: CGFloat = 180.0
        let verticalSpacing: CGFloat = 240.0

        var childrenByParentPeerId: [EnginePeer.Id: [EnginePeer.Id]] = [:]
        for node in graph.nodes {
            if let parentPeerId = node.parentPeerId, nodesByPeerId[parentPeerId] != nil {
                childrenByParentPeerId[parentPeerId, default: []].append(node.peerId)
            }
        }
        for key in childrenByParentPeerId.keys {
            childrenByParentPeerId[key]?.sort { lhs, rhs in
                eahatGramRawPeerId(lhs) < eahatGramRawPeerId(rhs)
            }
        }

        var subtreeWidths: [EnginePeer.Id: CGFloat] = [:]
        func subtreeWidth(peerId: EnginePeer.Id) -> CGFloat {
            if let current = subtreeWidths[peerId] {
                return current
            }
            let childPeerIds = childrenByParentPeerId[peerId] ?? []
            if childPeerIds.isEmpty {
                subtreeWidths[peerId] = cardSize.width
                return cardSize.width
            }
            let childWidths = childPeerIds.map { subtreeWidth(peerId: $0) }
            let totalChildWidth = childWidths.reduce(0.0, +) + CGFloat(max(0, childPeerIds.count - 1)) * horizontalSpacing
            let result = max(cardSize.width, totalChildWidth)
            subtreeWidths[peerId] = result
            return result
        }

        var baseFrames: [EnginePeer.Id: CGRect] = [:]
        @discardableResult
        func place(peerId: EnginePeer.Id, leftX: CGFloat) -> CGFloat {
            let currentNode = nodesByPeerId[peerId]!
            let childPeerIds = childrenByParentPeerId[peerId] ?? []
            let currentSubtreeWidth = subtreeWidth(peerId: peerId)
            let originY = contentInset + CGFloat(currentNode.depth) * (cardSize.height + verticalSpacing)

            let centerX: CGFloat
            if childPeerIds.isEmpty {
                centerX = leftX + cardSize.width / 2.0
            } else {
                let childWidths = childPeerIds.map { subtreeWidth(peerId: $0) }
                let totalChildWidth = childWidths.reduce(0.0, +) + CGFloat(max(0, childPeerIds.count - 1)) * horizontalSpacing
                var nextChildLeftX = leftX + (currentSubtreeWidth - totalChildWidth) / 2.0
                var firstChildCenterX: CGFloat?
                var lastChildCenterX: CGFloat = leftX
                for childPeerId in childPeerIds {
                    let childCenterX = place(peerId: childPeerId, leftX: nextChildLeftX)
                    if firstChildCenterX == nil {
                        firstChildCenterX = childCenterX
                    }
                    lastChildCenterX = childCenterX
                    nextChildLeftX += subtreeWidth(peerId: childPeerId) + horizontalSpacing
                }
                centerX = ((firstChildCenterX ?? leftX) + lastChildCenterX) / 2.0
            }

            baseFrames[peerId] = CGRect(
                x: centerX - cardSize.width / 2.0,
                y: originY,
                width: cardSize.width,
                height: cardSize.height
            )
            return centerX
        }

        _ = place(peerId: graph.rootPeerId, leftX: contentInset)

        var frames: [EnginePeer.Id: CGRect] = [:]
        for node in graph.nodes {
            let baseFrame = baseFrames[node.peerId] ?? CGRect(origin: CGPoint(x: contentInset, y: contentInset), size: cardSize)
            if let manualOrigin = self.visualizationState.manualOrigins[node.peerId] {
                frames[node.peerId] = CGRect(origin: CGPoint(x: max(contentInset, manualOrigin.x), y: max(contentInset, manualOrigin.y)), size: cardSize)
            } else {
                frames[node.peerId] = baseFrame
            }
        }

        let maxX = frames.values.map(\.maxX).max() ?? contentInset
        let maxY = frames.values.map(\.maxY).max() ?? contentInset
        let contentWidth = max(self.scrollView.bounds.width, maxX + contentInset)
        let contentHeight = max(self.scrollView.bounds.height, maxY + contentInset)

        self.contentNode.frame = CGRect(origin: .zero, size: CGSize(width: contentWidth, height: contentHeight))
        self.contentNode.view.frame = self.contentNode.frame
        self.scrollView.contentSize = self.contentNode.bounds.size
        self.linksLayer.frame = self.contentNode.bounds
        self.outgoingLinksLayer.frame = self.contentNode.bounds
        self.mutualLinksLayer.frame = self.contentNode.bounds
        self.focusedLinksLayer.frame = self.contentNode.bounds

        self.currentFrames = frames
        for (peerId, cardNode) in self.cardNodes {
            if let frame = frames[peerId] {
                cardNode.isHidden = false
                cardNode.frame = frame
            } else {
                cardNode.isHidden = true
            }
        }

        let selectedPathPeerIds: Set<EnginePeer.Id>
        if !self.visualizationState.selectedEdges.isEmpty {
            selectedPathPeerIds = eahatGramGiftChainPathPeerIds(graph: self.visualizationState.graph, edges: self.visualizationState.selectedEdges)
        } else {
            selectedPathPeerIds = Set(eahatGramGiftChainPathPeerIds(
                graph: self.visualizationState.graph,
                targetPeerId: self.visualizationState.focusedPeerId ?? self.visualizationState.graph.rootPeerId
            ))
        }
        for node in self.visualizationState.graph.nodes {
            let isTarget = node.peerId == self.visualizationState.focusedPeerId
            let isOnPath = selectedPathPeerIds.contains(node.peerId)
            self.cardNodes[node.peerId]?.updatePathHighlight(isOnPath: isOnPath, isTarget: isTarget)
        }

        func addArrowHead(_ path: UIBezierPath, tip: CGPoint, referencePoint: CGPoint) {
            let dx = tip.x - referencePoint.x
            let dy = tip.y - referencePoint.y
            let length = max(1.0, sqrt(dx * dx + dy * dy))
            let unitX = dx / length
            let unitY = dy / length
            let perpendicularX = -unitY
            let perpendicularY = unitX
            let arrowLength: CGFloat = 11.0
            let arrowWidth: CGFloat = 5.5
            let basePoint = CGPoint(x: tip.x - unitX * arrowLength, y: tip.y - unitY * arrowLength)
            path.move(to: tip)
            path.addLine(to: CGPoint(x: basePoint.x + perpendicularX * arrowWidth, y: basePoint.y + perpendicularY * arrowWidth))
            path.move(to: tip)
            path.addLine(to: CGPoint(x: basePoint.x - perpendicularX * arrowWidth, y: basePoint.y - perpendicularY * arrowWidth))
        }

        self.edgeHitRegions = []

        func appendEdge(_ edge: EahatGramGiftChainEdge, to path: UIBezierPath, arrowAtStart: Bool, arrowAtEnd: Bool, addHitRegion: Bool) {
            guard let fromFrame = frames[edge.fromPeerId], let toFrame = frames[edge.toPeerId] else {
                return
            }
            let startPoint = CGPoint(x: fromFrame.midX, y: fromFrame.minY)
            let endPoint = CGPoint(x: toFrame.midX, y: toFrame.maxY)
            let controlOffset = max(120.0, abs(startPoint.y - endPoint.y) * 0.62)
            let controlPoint1 = CGPoint(x: startPoint.x, y: startPoint.y - controlOffset)
            let controlPoint2 = CGPoint(x: endPoint.x, y: endPoint.y + controlOffset)
            let edgePath = UIBezierPath()
            edgePath.move(to: startPoint)
            edgePath.addCurve(
                to: endPoint,
                controlPoint1: controlPoint1,
                controlPoint2: controlPoint2
            )
            path.append(edgePath)
            if arrowAtEnd {
                addArrowHead(path, tip: endPoint, referencePoint: controlPoint2)
            }
            if arrowAtStart {
                addArrowHead(path, tip: startPoint, referencePoint: controlPoint1)
            }
            if addHitRegion {
                let strokedPath = edgePath.cgPath.copy(strokingWithWidth: 26.0, lineCap: .round, lineJoin: .round, miterLimit: 0.0)
                self.edgeHitRegions.append((edge: edge, path: strokedPath))
            }
        }

        let basePath = UIBezierPath()
        if !self.visualizationState.isVisualLineMode {
            for edge in graph.edges {
                appendEdge(edge, to: basePath, arrowAtStart: false, arrowAtEnd: true, addHitRegion: true)
            }
        }
        self.linksLayer.path = basePath.cgPath

        let outgoingPath = UIBezierPath()
        let mutualPath = UIBezierPath()
        if !self.visualizationState.isVisualLineMode {
            for edge in graph.highlightEdges {
                let targetPath = edge.isMutual ? mutualPath : outgoingPath
                appendEdge(edge, to: targetPath, arrowAtStart: edge.isMutual, arrowAtEnd: true, addHitRegion: true)
            }
        }
        self.outgoingLinksLayer.path = outgoingPath.cgPath
        self.mutualLinksLayer.path = mutualPath.cgPath

        let focusedPath = UIBezierPath()
        if !self.visualizationState.selectedEdges.isEmpty {
            for edge in eahatGramGiftChainPathEdges(graph: self.visualizationState.graph, edges: self.visualizationState.selectedEdges) {
                appendEdge(edge, to: focusedPath, arrowAtStart: edge.isMutual, arrowAtEnd: true, addHitRegion: false)
            }
        } else if let focusedPeerId = self.visualizationState.focusedPeerId {
            for edge in eahatGramGiftChainPathEdges(graph: self.visualizationState.graph, targetPeerId: focusedPeerId) {
                appendEdge(edge, to: focusedPath, arrowAtStart: false, arrowAtEnd: true, addHitRegion: false)
            }
        }
        self.focusedLinksLayer.path = focusedPath.cgPath

        if !self.didSetInitialZoom {
            self.didSetInitialZoom = true
            let fitWidthScale = self.scrollView.bounds.width / max(contentWidth, 1.0)
            let fitHeightScale = self.scrollView.bounds.height / max(contentHeight, 1.0)
            let initialScale = min(1.0, max(self.scrollView.minimumZoomScale, min(fitWidthScale, fitHeightScale)))
            self.scrollView.setZoomScale(initialScale, animated: false)
        }

        if self.centerFocusedAfterLayout {
            let animated = self.animateFocusCentering
            self.centerFocusedAfterLayout = false
            self.animateFocusCentering = false
            self.centerOnFocusedPeer(animated: animated)
        } else if self.scrollView.contentOffset == .zero {
            self.scrollView.contentOffset = .zero
        }
    }

    private func updateDrag(peerId: EnginePeer.Id, state: UIGestureRecognizer.State, location: CGPoint) {
        switch state {
        case .began:
            guard let frame = self.currentFrames[peerId] else {
                return
            }
            self.draggingPeerId = peerId
            self.dragTouchOffset = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        case .changed:
            guard self.draggingPeerId == peerId else {
                return
            }
            var updatedState = self.visualizationState
            updatedState.manualOrigins[peerId] = CGPoint(
                x: max(24.0, location.x - self.dragTouchOffset.x),
                y: max(24.0, location.y - self.dragTouchOffset.y)
            )
            self.visualizationState = updatedState
            self.stateUpdated?(updatedState)
            self.relayout(centerOnFocusedPeer: false, animatedCentering: false)
        default:
            self.draggingPeerId = nil
        }
    }

    private func relayout(centerOnFocusedPeer: Bool, animatedCentering: Bool) {
        guard self.hasLayout else {
            return
        }
        self.centerFocusedAfterLayout = centerOnFocusedPeer
        self.animateFocusCentering = animatedCentering
        self.updateLayout(
            size: self.lastLayoutSize,
            safeInsets: self.lastSafeInsets,
            navigationHeight: self.lastNavigationHeight
        )
    }

    private func centerOnFocusedPeer(animated: Bool) {
        guard let focusedPeerId = self.visualizationState.focusedPeerId, let frame = self.currentFrames[focusedPeerId] else {
            return
        }
        let zoomScale = self.scrollView.zoomScale
        let scaledCenter = CGPoint(x: frame.midX * zoomScale, y: frame.midY * zoomScale)
        let visibleBounds = self.scrollView.bounds
        let maxOffsetX = max(0.0, self.scrollView.contentSize.width - visibleBounds.width)
        let maxOffsetY = max(0.0, self.scrollView.contentSize.height - visibleBounds.height)
        let targetOffset = CGPoint(
            x: min(max(0.0, scaledCenter.x - visibleBounds.width / 2.0), maxOffsetX),
            y: min(max(0.0, scaledCenter.y - visibleBounds.height / 2.0), maxOffsetY)
        )
        self.scrollView.setContentOffset(targetOffset, animated: animated)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return self.contentNode.view
    }

    @objc private func handleLineTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else {
            return
        }
        let location = recognizer.location(in: self.contentNode.view)
        for frame in self.currentFrames.values {
            if frame.insetBy(dx: -6.0, dy: -6.0).contains(location) {
                return
            }
        }
        for region in self.edgeHitRegions.reversed() {
            if region.path.contains(location) {
                self.tapEdge?(region.edge)
                return
            }
        }
    }
}

final class EahatGramGiftChainScreen: ViewController {
    private let context: AccountContext
    private let presentationData: PresentationData
    private let stateUpdated: (EahatGramGiftChainVisualizationState) -> Void

    private var visualizationState: EahatGramGiftChainVisualizationState
    private var previousInteractivePopEnabled: Bool?

    private var controllerNode: EahatGramGiftChainScreenNode {
        return self.displayNode as! EahatGramGiftChainScreenNode
    }

    init(
        context: AccountContext,
        visualizationState: EahatGramGiftChainVisualizationState,
        stateUpdated: @escaping (EahatGramGiftChainVisualizationState) -> Void
    ) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var initialVisualizationState = visualizationState
        if initialVisualizationState.focusedPeerId == nil {
            initialVisualizationState.focusedPeerId = initialVisualizationState.graph.rootPeerId
        }
        self.visualizationState = initialVisualizationState
        self.stateUpdated = stateUpdated

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
        self.navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                title: "Export2HTML",
                style: .plain,
                target: self,
                action: #selector(self.exportHTMLPressed)
            ),
            UIBarButtonItem(
                title: "Search by user",
                style: .plain,
                target: self,
                action: #selector(self.searchPressed)
            )
        ]
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = EahatGramGiftChainScreenNode(
            context: self.context,
            theme: self.presentationData.theme,
            visualizationState: self.visualizationState,
            tapPeer: { [weak self] peerId in
                self?.presentPeerMenu(peerId: peerId)
            },
            tapEdge: { [weak self] edge in
                self?.presentEdgeMenu(edge: edge)
            },
            stateUpdated: { [weak self] updatedState in
                guard let self else {
                    return
                }
                self.visualizationState = updatedState
                self.stateUpdated(updatedState)
            }
        )
        self.view.disablesInteractiveTransitionGestureRecognizer = true
        self.view.disablesInteractiveTransitionGestureRecognizerNow = { true }
        self.displayNode.view.disablesInteractiveTransitionGestureRecognizer = true
        self.displayNode.view.disablesInteractiveTransitionGestureRecognizerNow = { true }
        self.displayNodeDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if let navigationController = self.navigationController {
            self.previousInteractivePopEnabled = navigationController.interactivePopGestureRecognizer?.isEnabled
            navigationController.interactivePopGestureRecognizer?.isEnabled = false
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        if let navigationController = self.navigationController, let previousInteractivePopEnabled = self.previousInteractivePopEnabled {
            navigationController.interactivePopGestureRecognizer?.isEnabled = previousInteractivePopEnabled
        }
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.updateLayout(
            size: layout.size,
            safeInsets: layout.safeInsets,
            navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY
        )
    }

    @objc private func exportHTMLPressed() {
        let html = eahatGramGiftChainHTMLDocument(visualizationState: self.visualizationState)
        let fileName = "gift-chain-\(eahatGramRawPeerId(self.visualizationState.graph.rootPeerId))-\(Int(Date().timeIntervalSince1970))"
        let exportUrl = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName).appendingPathExtension("html")

        do {
            try html.write(to: exportUrl, atomically: true, encoding: .utf8)
        } catch {
            let alertController = UIAlertController(title: "Export failed", message: error.localizedDescription, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alertController, animated: true)
            return
        }

        let activityController = UIActivityViewController(activityItems: [exportUrl], applicationActivities: nil)
        activityController.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItems?.first
        self.present(activityController, animated: true)
    }

    @objc private func searchPressed() {
        let alertController = UIAlertController(title: "Search by user", message: nil, preferredStyle: .alert)
        alertController.addTextField { textField in
            textField.placeholder = "@username or id"
            textField.keyboardType = .default
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alertController.addAction(UIAlertAction(title: "Find", style: .default, handler: { [weak self, weak alertController] _ in
            guard let self, let query = alertController?.textFields?.first?.text else {
                return
            }
            self.performSearch(query: query)
        }))
        self.present(alertController, animated: true)
    }

    private func performSearch(query: String) {
        let matches = eahatGramGiftChainSearchMatches(graph: self.visualizationState.graph, query: query)
        guard !matches.isEmpty else {
            self.presentPathAlert(title: "Not found", text: query.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }

        if matches.count == 1, let match = matches.first {
            self.focusOnPeer(match.peerId, presentPath: true)
            return
        }

        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = [
            ActionSheetTextItem(title: "Matches: \(matches.count)")
        ]
        for match in matches {
            let title = "\(match.peer.compactDisplayTitle) - id \(eahatGramRawPeerId(match.peerId))"
            items.append(ActionSheetButtonItem(title: title, color: .accent, action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                self?.focusOnPeer(match.peerId, presentPath: true)
            }))
        }
        items.append(ActionSheetButtonItem(title: "Cancel", color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        }))
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items)])
        self.present(actionSheet, in: .window(.root))
    }

    private func presentPeerMenu(peerId: EnginePeer.Id) {
        guard let node = self.visualizationState.graph.nodes.first(where: { $0.peerId == peerId }) else {
            return
        }

        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        let pathText = self.controllerNode.pathText(for: peerId)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: "\(eahatGramGiftChainNodeSummaryText(node: node))\n\(pathText)"),
                ActionSheetButtonItem(title: "View visualization", color: .accent, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    self?.focusOnPeer(peerId, presentPath: true)
                }),
                ActionSheetButtonItem(title: "Open profile", color: .accent, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    self?.openProfile(peerId: peerId)
                }),
                ActionSheetButtonItem(title: "Copy @tag + id", color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    UIPasteboard.general.string = eahatGramGiftChainCopyText(node: node)
                }),
                ActionSheetButtonItem(title: "Copy path", color: .accent, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    guard let self else {
                        return
                    }
                    UIPasteboard.general.string = eahatGramGiftChainPathCopyText(graph: self.visualizationState.graph, targetPeerId: peerId)
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: "Cancel", color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        self.present(actionSheet, in: .window(.root))
    }

    private func presentEdgeMenu(edge: EahatGramGiftChainEdge) {
        var updatedState = self.visualizationState
        if !updatedState.selectedEdges.contains(edge) {
            updatedState.selectedEdges.append(edge)
        }
        updatedState.isVisualLineMode = false
        self.visualizationState = updatedState
        self.stateUpdated(updatedState)
        self.controllerNode.setVisualizationState(updatedState, centerOnFocusedPeer: false)

        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: eahatGramGiftChainPathText(graph: self.visualizationState.graph, edges: updatedState.selectedEdges)),
                ActionSheetButtonItem(title: "Remove line from selection", color: .accent, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    guard let self else {
                        return
                    }
                    var selectionState = self.visualizationState
                    if let index = selectionState.selectedEdges.firstIndex(of: edge) {
                        selectionState.selectedEdges.remove(at: index)
                    }
                    selectionState.isVisualLineMode = false
                    self.visualizationState = selectionState
                    self.stateUpdated(selectionState)
                    self.controllerNode.setVisualizationState(selectionState, centerOnFocusedPeer: false)
                }),
                ActionSheetButtonItem(title: "Visual lines", color: .accent, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    guard let self else {
                        return
                    }
                    var visualizedState = self.visualizationState
                    if !visualizedState.selectedEdges.contains(edge) {
                        visualizedState.selectedEdges.append(edge)
                    }
                    visualizedState.isVisualLineMode = true
                    self.visualizationState = visualizedState
                    self.stateUpdated(visualizedState)
                    self.controllerNode.setVisualizationState(visualizedState, centerOnFocusedPeer: false)
                }),
                ActionSheetButtonItem(title: "Clear lines", color: .accent, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    guard let self else {
                        return
                    }
                    var clearedState = self.visualizationState
                    clearedState.selectedEdges.removeAll()
                    clearedState.isVisualLineMode = false
                    self.visualizationState = clearedState
                    self.stateUpdated(clearedState)
                    self.controllerNode.setVisualizationState(clearedState, centerOnFocusedPeer: false)
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: "Cancel", color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        self.present(actionSheet, in: .window(.root))
    }

    private func focusOnPeer(_ peerId: EnginePeer.Id, presentPath: Bool) {
        var updatedState = self.visualizationState
        updatedState.focusedPeerId = peerId
        updatedState.selectedEdges.removeAll()
        updatedState.isVisualLineMode = false
        self.visualizationState = updatedState
        self.stateUpdated(updatedState)
        self.controllerNode.setVisualizationState(updatedState, centerOnFocusedPeer: true)

        if presentPath {
            self.presentPathAlert(title: "Path", text: self.controllerNode.pathText(for: peerId))
        }
    }

    private func presentPathAlert(title: String, text: String) {
        let alertController = UIAlertController(title: title, message: text, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alertController, animated: true)
    }

    private func openProfile(peerId: EnginePeer.Id) {
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
}
