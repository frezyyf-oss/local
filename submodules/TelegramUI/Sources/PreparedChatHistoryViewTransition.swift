import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import Display
import MergeLists
import AccountContext
import ChatControllerInteraction
import ChatHistoryEntry
import ChatMessageBubbleItemNode
import TelegramPresentationData

private struct EahatGramPreviousMessageEntryData {
    let message: Message
    let presentationData: ChatPresentationData
    let read: Bool
    let attributes: ChatMessageEntryAttributes
}

private struct EahatGramDeletedMessageSnapshot {
    let sourceMessageId: MessageId
    let displayId: Int32
    let threadId: Int64?
    let timestamp: Int32
    let isIncoming: Bool
    let text: String
    let read: Bool
    let isContact: Bool
}

private struct EahatGramSavedChatState {
    var deletedEntries: [MessageId: EahatGramDeletedMessageSnapshot]
    var editedTexts: [MessageId: String]

    init(
        deletedEntries: [MessageId: EahatGramDeletedMessageSnapshot] = [:],
        editedTexts: [MessageId: String] = [:]
    ) {
        self.deletedEntries = deletedEntries
        self.editedTexts = editedTexts
    }
}

private struct EahatGramPersistedDeletedEntry: Codable {
    let messageId: MessageId
    let displayId: Int32
    let threadId: Int64?
    let timestamp: Int32
    let isIncoming: Bool
    let text: String
    let read: Bool
    let isContact: Bool
}

private let eahatGramSavedChatStateCache = Atomic<[String: EahatGramSavedChatState]>(value: [:])
private let eahatGramSavedEditedTextsDefaultsKey = "eahatGram.savedEditedTexts"
private let eahatGramSavedDeletedEntriesDefaultsKey = "eahatGram.savedDeletedEntries.v8"
private let eahatGramDeletedDisplayIdSeed: Int32 = Int32.min + 1048576

private func eahatGramSavedChatStateKey(chatLocation: ChatLocation) -> String {
    switch chatLocation {
    case let .peer(peerId):
        return "peer:\(peerId.toInt64())"
    case let .replyThread(message):
        return "thread:\(message.peerId.toInt64()):\(message.threadId)"
    case .customChatContents:
        return "custom"
    }
}

private func eahatGramSavedEditedTextKey(messageId: MessageId) -> String {
    return "\(messageId.peerId.toInt64()):\(messageId.namespace):\(messageId.id)"
}

private func eahatGramParsedSavedEditedTextKey(_ key: String) -> MessageId? {
    let components = key.split(separator: ":", omittingEmptySubsequences: false)
    guard components.count == 3 else {
        return nil
    }
    guard let peerIdValue = Int64(components[0]), let namespaceValue = Int32(components[1]), let idValue = Int32(components[2]) else {
        return nil
    }
    return MessageId(peerId: PeerId(peerIdValue), namespace: namespaceValue, id: idValue)
}

private func eahatGramLoadPersistedEditedTexts(cacheKey: String) -> [MessageId: String] {
    guard let rawRoot = UserDefaults.standard.dictionary(forKey: eahatGramSavedEditedTextsDefaultsKey),
          let rawChatValues = rawRoot[cacheKey] as? [String: String] else {
        return [:]
    }
    var result: [MessageId: String] = [:]
    for (messageKey, text) in rawChatValues {
        guard let messageId = eahatGramParsedSavedEditedTextKey(messageKey), !text.isEmpty else {
            continue
        }
        result[messageId] = text
    }
    return result
}

private func eahatGramStorePersistedEditedTexts(cacheKey: String, editedTexts: [MessageId: String]) {
    var rawRoot = UserDefaults.standard.dictionary(forKey: eahatGramSavedEditedTextsDefaultsKey) ?? [:]
    if editedTexts.isEmpty {
        rawRoot.removeValue(forKey: cacheKey)
    } else {
        var rawChatValues: [String: String] = [:]
        rawChatValues.reserveCapacity(editedTexts.count)
        for (messageId, text) in editedTexts {
            guard !text.isEmpty else {
                continue
            }
            rawChatValues[eahatGramSavedEditedTextKey(messageId: messageId)] = text
        }
        if rawChatValues.isEmpty {
            rawRoot.removeValue(forKey: cacheKey)
        } else {
            rawRoot[cacheKey] = rawChatValues
        }
    }
    UserDefaults.standard.set(rawRoot, forKey: eahatGramSavedEditedTextsDefaultsKey)
}

private func eahatGramDeletedDisplayMessageId(sourceMessageId: MessageId, displayId: Int32) -> MessageId {
    return MessageId(peerId: sourceMessageId.peerId, namespace: Namespaces.Message.Cloud, id: displayId)
}

private func eahatGramDeletedStableId(sourceMessageId: MessageId, displayId: Int32) -> UInt32 {
    var hasher = Hasher()
    hasher.combine(sourceMessageId.peerId.toInt64())
    hasher.combine(sourceMessageId.namespace)
    hasher.combine(sourceMessageId.id)
    hasher.combine(displayId)
    hasher.combine("eahatGramDeleted")

    let hashValue = Int64(hasher.finalize())
    let first = UInt32((hashValue >> 32) & 0xffffffff)
    let second = UInt32(hashValue & 0xffffffff)
    return first &+ second
}

private func eahatGramDeletedMessage(snapshot: EahatGramDeletedMessageSnapshot) -> Message {
    let syntheticFlags: MessageFlags = snapshot.isIncoming ? MessageFlags.IsIncomingMask : MessageFlags()
    return Message(
        stableId: eahatGramDeletedStableId(sourceMessageId: snapshot.sourceMessageId, displayId: snapshot.displayId),
        stableVersion: 0,
        id: eahatGramDeletedDisplayMessageId(sourceMessageId: snapshot.sourceMessageId, displayId: snapshot.displayId),
        globallyUniqueId: nil,
        groupingKey: nil,
        groupInfo: nil,
        threadId: snapshot.threadId,
        timestamp: snapshot.timestamp,
        flags: syntheticFlags,
        tags: MessageTags(rawValue: 0),
        globalTags: GlobalMessageTags(rawValue: 0),
        localTags: LocalMessageTags(rawValue: 0),
        customTags: [],
        forwardInfo: nil,
        author: nil,
        text: snapshot.text,
        attributes: [],
        media: [],
        peers: SimpleDictionary<PeerId, Peer>(),
        associatedMessages: SimpleDictionary<MessageId, Message>(),
        associatedMessageIds: [],
        associatedMedia: [:],
        associatedThreadInfo: nil,
        associatedStories: [:]
    )
}

private func eahatGramNextDeletedDisplayId(existingEntries: [MessageId: EahatGramDeletedMessageSnapshot]) -> Int32 {
    var result: Int32 = eahatGramDeletedDisplayIdSeed
    for entry in existingEntries.values {
        if entry.displayId <= result {
            if entry.displayId == Int32.min {
                return Int32.min
            }
            result = entry.displayId - 1
        }
    }
    return result
}

private func eahatGramDeletedMessageSnapshot(
    message: Message,
    read: Bool,
    attributes: ChatMessageEntryAttributes,
    displayId: Int32
) -> EahatGramDeletedMessageSnapshot {
    return EahatGramDeletedMessageSnapshot(
        sourceMessageId: message.id,
        displayId: displayId,
        threadId: message.threadId,
        timestamp: message.timestamp,
        isIncoming: message.flags.contains(.Incoming),
        text: message.text,
        read: read,
        isContact: attributes.isContact
    )
}

private func eahatGramPersistedDeletedEntry(_ snapshot: EahatGramDeletedMessageSnapshot) -> EahatGramPersistedDeletedEntry {
    return EahatGramPersistedDeletedEntry(
        messageId: snapshot.sourceMessageId,
        displayId: snapshot.displayId,
        threadId: snapshot.threadId,
        timestamp: snapshot.timestamp,
        isIncoming: snapshot.isIncoming,
        text: snapshot.text,
        read: snapshot.read,
        isContact: snapshot.isContact
    )
}

private func eahatGramRestoredDeletedEntry(_ entry: EahatGramPersistedDeletedEntry) -> EahatGramDeletedMessageSnapshot? {
    guard !entry.text.isEmpty else {
        return nil
    }
    return EahatGramDeletedMessageSnapshot(
        sourceMessageId: entry.messageId,
        displayId: entry.displayId,
        threadId: entry.threadId,
        timestamp: entry.timestamp,
        isIncoming: entry.isIncoming,
        text: entry.text,
        read: entry.read,
        isContact: entry.isContact
    )
}

private func eahatGramResolvedPresentationData(entries: [ChatHistoryEntry]) -> ChatPresentationData? {
    for entry in entries {
        switch entry {
        case let .MessageEntry(_, presentationData, _, _, _, _):
            return presentationData
        case let .MessageGroupEntry(_, _, presentationData):
            return presentationData
        case let .UnreadEntry(_, presentationData):
            return presentationData
        case let .ReplyCountEntry(_, _, _, presentationData):
            return presentationData
        case let .ChatInfoEntry(_, presentationData):
            return presentationData
        }
    }
    return nil
}

private func eahatGramLoadPersistedDeletedEntries(cacheKey: String) -> [MessageId: EahatGramDeletedMessageSnapshot] {
    guard let rawRoot = UserDefaults.standard.dictionary(forKey: eahatGramSavedDeletedEntriesDefaultsKey),
          let rawChatValue = rawRoot[cacheKey] as? Data,
          let decoded = try? AdaptedPostboxDecoder().decode([EahatGramPersistedDeletedEntry].self, from: rawChatValue) else {
        return [:]
    }
    var result: [MessageId: EahatGramDeletedMessageSnapshot] = [:]
    for entry in decoded {
        if let restored = eahatGramRestoredDeletedEntry(entry) {
            result[entry.messageId] = restored
        }
    }
    return result
}

private func eahatGramStorePersistedDeletedEntries(cacheKey: String, deletedEntries: [MessageId: EahatGramDeletedMessageSnapshot]) {
    var rawRoot = UserDefaults.standard.dictionary(forKey: eahatGramSavedDeletedEntriesDefaultsKey) ?? [:]
    if deletedEntries.isEmpty {
        rawRoot.removeValue(forKey: cacheKey)
    } else {
        let encodedEntries = deletedEntries
            .sorted(by: { lhs, rhs in lhs.key < rhs.key })
            .map { _, entry in
                eahatGramPersistedDeletedEntry(entry)
            }
        if let rawChatValue = try? AdaptedPostboxEncoder().encode(encodedEntries) {
            rawRoot[cacheKey] = rawChatValue
        } else {
            rawRoot.removeValue(forKey: cacheKey)
        }
    }
    UserDefaults.standard.set(rawRoot, forKey: eahatGramSavedDeletedEntriesDefaultsKey)
}

private func eahatGramPreviousMessageEntryDataMap(
    entries: [ChatHistoryEntry]
) -> [MessageId: EahatGramPreviousMessageEntryData] {
    var result: [MessageId: EahatGramPreviousMessageEntryData] = [:]
    for entry in entries {
        switch entry {
        case let .MessageEntry(message, presentationData, read, location, selection, attributes):
            if attributes.isSavedDeleted {
                continue
            }
            _ = location
            _ = selection
            result[message.id] = EahatGramPreviousMessageEntryData(message: message, presentationData: presentationData, read: read, attributes: attributes)
        case let .MessageGroupEntry(_, messages, presentationData):
            for (message, read, selection, attributes, location) in messages {
                if attributes.isSavedDeleted {
                    continue
                }
                _ = location
                _ = selection
                result[message.id] = EahatGramPreviousMessageEntryData(message: message, presentationData: presentationData, read: read, attributes: attributes)
            }
        default:
            break
        }
    }
    return result
}

private func eahatGramUpdatedAttributesForSavedEdit(
    previousEntryData: EahatGramPreviousMessageEntryData?,
    cachedPreviousText: String?,
    message: Message,
    attributes: ChatMessageEntryAttributes,
    saveEditedMessages: Bool
) -> ChatMessageEntryAttributes {
    var attributes = attributes
    attributes.isSavedDeleted = false
    if let previousEntryData {
        attributes.savedEditPreviousText = previousEntryData.attributes.savedEditPreviousText ?? cachedPreviousText
        if saveEditedMessages, previousEntryData.message.id == message.id, previousEntryData.message.text != message.text, !previousEntryData.message.text.isEmpty {
            attributes.savedEditPreviousText = previousEntryData.message.text
        }
    } else {
        attributes.savedEditPreviousText = cachedPreviousText
    }
    if !saveEditedMessages {
        attributes.savedEditPreviousText = nil
    }
    return attributes
}

private func eahatGramCanPersistDeletedEntry(message: Message) -> Bool {
    if message.flags.contains(.Sending) || message.flags.contains(.Unsent) {
        return false
    }
    if Namespaces.Message.allLocal.contains(message.id.namespace) || Namespaces.Message.allNonRegular.contains(message.id.namespace) {
        return false
    }
    if !message.media.isEmpty {
        return false
    }
    return !message.text.isEmpty
}

func preparedChatHistoryViewTransition(from fromView: ChatHistoryView?, to toView: ChatHistoryView, reason: ChatHistoryViewTransitionReason, reverse: Bool, chatLocation: ChatLocation, source: ChatHistoryListSource, controllerInteraction: ChatControllerInteraction, scrollPosition: ChatHistoryViewScrollPosition?, scrollAnimationCurve: ListViewAnimationCurve?, initialData: InitialMessageHistoryData?, keyboardButtonsMessage: Message?, cachedData: CachedPeerData?, cachedDataMessages: [MessageId: Message]?, readStateData: [PeerId: ChatHistoryCombinedInitialReadStateData]?, flashIndicators: Bool, updatedMessageSelection: Bool, messageTransitionNode: ChatMessageTransitionNodeImpl?, allUpdated: Bool, saveDeletedMessages: Bool, saveEditedMessages: Bool) -> ChatHistoryViewTransition {
    let previousMessageEntries = eahatGramPreviousMessageEntryDataMap(entries: fromView?.filteredEntries ?? [])
    let cacheKey = eahatGramSavedChatStateKey(chatLocation: chatLocation)
    let currentPresentationData = eahatGramResolvedPresentationData(entries: toView.filteredEntries) ?? eahatGramResolvedPresentationData(entries: fromView?.filteredEntries ?? [])
    var savedChatState = eahatGramSavedChatStateCache.with { $0[cacheKey] ?? EahatGramSavedChatState() }
    if saveEditedMessages {
        let persistedEditedTexts = eahatGramLoadPersistedEditedTexts(cacheKey: cacheKey)
        for (messageId, text) in persistedEditedTexts where savedChatState.editedTexts[messageId] == nil {
            savedChatState.editedTexts[messageId] = text
        }
    }
    if saveDeletedMessages {
        let persistedDeletedEntries = eahatGramLoadPersistedDeletedEntries(cacheKey: cacheKey)
        for (messageId, entry) in persistedDeletedEntries where savedChatState.deletedEntries[messageId] == nil {
            savedChatState.deletedEntries[messageId] = entry
        }
    }
    if !saveDeletedMessages {
        savedChatState.deletedEntries.removeAll()
    }
    if !saveEditedMessages {
        savedChatState.editedTexts.removeAll()
    }
    var currentMessageIds = Set<MessageId>()
    var effectiveToEntries: [ChatHistoryEntry] = toView.filteredEntries.map { entry in
        switch entry {
        case let .MessageEntry(message, presentationData, read, location, selection, attributes):
            currentMessageIds.insert(message.id)
            let updatedAttributes = eahatGramUpdatedAttributesForSavedEdit(previousEntryData: previousMessageEntries[message.id], cachedPreviousText: savedChatState.editedTexts[message.id], message: message, attributes: attributes, saveEditedMessages: saveEditedMessages)
            if let savedEditPreviousText = updatedAttributes.savedEditPreviousText, !savedEditPreviousText.isEmpty {
                savedChatState.editedTexts[message.id] = savedEditPreviousText
            } else {
                savedChatState.editedTexts.removeValue(forKey: message.id)
            }
            return .MessageEntry(message, presentationData, read, location, selection, updatedAttributes)
        case let .MessageGroupEntry(groupInfo, messages, presentationData):
            let updatedMessages = messages.map { message, read, selection, attributes, location in
                currentMessageIds.insert(message.id)
                let updatedAttributes = eahatGramUpdatedAttributesForSavedEdit(previousEntryData: previousMessageEntries[message.id], cachedPreviousText: savedChatState.editedTexts[message.id], message: message, attributes: attributes, saveEditedMessages: saveEditedMessages)
                if let savedEditPreviousText = updatedAttributes.savedEditPreviousText, !savedEditPreviousText.isEmpty {
                    savedChatState.editedTexts[message.id] = savedEditPreviousText
                } else {
                    savedChatState.editedTexts.removeValue(forKey: message.id)
                }
                return (
                    message,
                    read,
                    selection,
                    updatedAttributes,
                    location
                )
            }
            return .MessageGroupEntry(groupInfo, updatedMessages, presentationData)
        default:
            return entry
        }
    }
    for messageId in currentMessageIds {
        savedChatState.deletedEntries.removeValue(forKey: messageId)
    }
    if saveDeletedMessages, let fromView {
        var nextDisplayId = eahatGramNextDeletedDisplayId(existingEntries: savedChatState.deletedEntries)
        for previousEntry in fromView.filteredEntries {
            switch previousEntry {
            case let .MessageEntry(message, _, read, _, _, attributes):
                if attributes.isSavedDeleted {
                    continue
                }
                if currentMessageIds.contains(message.id) {
                    continue
                }
                if !eahatGramCanPersistDeletedEntry(message: message) {
                    continue
                }
                let displayId: Int32
                if let existing = savedChatState.deletedEntries[message.id] {
                    displayId = existing.displayId
                } else {
                    displayId = nextDisplayId
                    if nextDisplayId != Int32.min {
                        nextDisplayId -= 1
                    }
                }
                savedChatState.deletedEntries[message.id] = eahatGramDeletedMessageSnapshot(
                    message: message,
                    read: read,
                    attributes: attributes,
                    displayId: displayId
                )
            case let .MessageGroupEntry(_, messages, _):
                for (message, read, _, attributes, _) in messages {
                    if attributes.isSavedDeleted {
                        continue
                    }
                    if currentMessageIds.contains(message.id) {
                        continue
                    }
                    if !eahatGramCanPersistDeletedEntry(message: message) {
                        continue
                    }
                    let displayId: Int32
                    if let existing = savedChatState.deletedEntries[message.id] {
                        displayId = existing.displayId
                    } else {
                        displayId = nextDisplayId
                        if nextDisplayId != Int32.min {
                            nextDisplayId -= 1
                        }
                    }
                    savedChatState.deletedEntries[message.id] = eahatGramDeletedMessageSnapshot(
                        message: message,
                        read: read,
                        attributes: attributes,
                        displayId: displayId
                    )
                }
            default:
                break
            }
        }
    }
    var invalidDeletedMessageIds: [MessageId] = []
    if let currentPresentationData {
        for (messageId, previousEntryData) in savedChatState.deletedEntries {
            if currentMessageIds.contains(messageId) {
                continue
            }
            let restoredMessage = eahatGramDeletedMessage(snapshot: previousEntryData)
            if !eahatGramCanPersistDeletedEntry(message: restoredMessage) {
                invalidDeletedMessageIds.append(messageId)
                continue
            }
            var updatedAttributes = ChatMessageEntryAttributes(
                rank: nil,
                isContact: previousEntryData.isContact,
                contentTypeHint: .generic,
                updatingMedia: nil,
                isPlaying: false,
                isCentered: false,
                authorStoryStats: nil,
                displayContinueThreadFooter: false
            )
            updatedAttributes.isSavedDeleted = true
            if saveEditedMessages, let savedEditPreviousText = savedChatState.editedTexts[messageId], !savedEditPreviousText.isEmpty {
                updatedAttributes.savedEditPreviousText = savedEditPreviousText
            }
            effectiveToEntries.append(.MessageEntry(restoredMessage, currentPresentationData, previousEntryData.read, nil, .none, updatedAttributes))
        }
    }
    for messageId in invalidDeletedMessageIds {
        savedChatState.deletedEntries.removeValue(forKey: messageId)
    }
    _ = eahatGramSavedChatStateCache.modify { current in
        var current = current
        if savedChatState.deletedEntries.isEmpty && savedChatState.editedTexts.isEmpty {
            current.removeValue(forKey: cacheKey)
        } else {
            current[cacheKey] = savedChatState
        }
        return current
    }
    eahatGramStorePersistedEditedTexts(cacheKey: cacheKey, editedTexts: saveEditedMessages ? savedChatState.editedTexts : [:])
    eahatGramStorePersistedDeletedEntries(cacheKey: cacheKey, deletedEntries: saveDeletedMessages ? savedChatState.deletedEntries : [:])
    effectiveToEntries.sort()
    let effectiveToView = ChatHistoryView(
        originalView: toView.originalView,
        filteredEntries: effectiveToEntries,
        associatedData: toView.associatedData,
        lastHeaderId: toView.lastHeaderId,
        id: toView.id,
        locationInput: toView.locationInput,
        ignoreMessagesInTimestampRange: toView.ignoreMessagesInTimestampRange,
        ignoreMessageIds: toView.ignoreMessageIds
    )
    var mergeResult: (deleteIndices: [Int], indicesAndItems: [(Int, ChatHistoryEntry, Int?)], updateIndices: [(Int, ChatHistoryEntry, Int)])
    let allUpdated = allUpdated || (fromView?.associatedData != toView.associatedData)
    if reverse {
        mergeResult = mergeListsStableWithUpdatesReversed(leftList: fromView?.filteredEntries ?? [], rightList: effectiveToView.filteredEntries, allUpdated: allUpdated)
    } else {
        mergeResult = mergeListsStableWithUpdates(leftList: fromView?.filteredEntries ?? [], rightList: effectiveToView.filteredEntries, allUpdated: allUpdated)
    }

    if let messageTransitionNode = messageTransitionNode, messageTransitionNode.hasOngoingTransitions, let previousEntries = fromView?.filteredEntries {
        for i in 0 ..< mergeResult.updateIndices.count {
            switch mergeResult.updateIndices[i].1 {
            case let .MessageEntry(message, presentationData, flag, monthLocation, messageSelection, entryAttributes):
                if messageTransitionNode.isAnimatingMessage(stableId: message.stableId) {
                    var updatedMessage = message
                    mediaLoop: for media in message.media {
                        if let webpage = media as? TelegramMediaWebpage, case .Loaded = webpage.content {
                            var filterMedia = false
                            switch previousEntries[mergeResult.updateIndices[i].2] {
                            case let .MessageEntry(previousMessage, _, _, _, _, _):
                                if previousMessage.media.contains(where: { value in
                                    if let value = value as? TelegramMediaWebpage, case .Loaded = value.content {
                                        return true
                                    } else {
                                        return false
                                    }
                                }) {
                                    if messageTransitionNode.hasScheduledUpdateMessageAfterAnimationCompleted(stableId: message.stableId) {
                                        filterMedia = true
                                    }
                                } else {
                                    filterMedia = true
                                }
                            default:
                                break
                            }

                            if filterMedia {
                                updatedMessage = message.withUpdatedMedia(message.media.filter {
                                    $0 !== media
                                })
                                messageTransitionNode.scheduleUpdateMessageAfterAnimationCompleted(stableId: message.stableId)
                            }

                            break mediaLoop
                        }
                    }
                    mergeResult.updateIndices[i].1 = .MessageEntry(updatedMessage, presentationData, flag, monthLocation, messageSelection, entryAttributes)
                }
            default:
                break
            }
        }
    }

    var adjustedDeleteIndices: [ListViewDeleteItem] = []
    let previousCount: Int
    if let fromView = fromView {
        previousCount = fromView.filteredEntries.count
    } else {
        previousCount = 0
    }
    for index in mergeResult.deleteIndices {
        adjustedDeleteIndices.append(ListViewDeleteItem(index: previousCount - 1 - index, directionHint: nil))
    }

    var adjustedIndicesAndItems: [ChatHistoryViewTransitionInsertEntry] = []
    var adjustedUpdateItems: [ChatHistoryViewTransitionUpdateEntry] = []
    let updatedCount = effectiveToView.filteredEntries.count

    var options: ListViewDeleteAndInsertOptions = []
    var animateIn = false
    var maxAnimatedInsertionIndex = -1
    var stationaryItemRange: (Int, Int)?
    var scrollToItem: ListViewScrollToItem?

    switch reason {
    case let .Initial(fadeIn):
        if fadeIn {
            animateIn = true
        } else {
            let _ = options.insert(.LowLatency)
            let _ = options.insert(.Synchronous)
            let _ = options.insert(.PreferSynchronousResourceLoading)
        }
    case .InteractiveChanges:
        let _ = options.insert(.AnimateAlpha)
        let _ = options.insert(.AnimateInsertion)

        for (index, _, _) in mergeResult.indicesAndItems.sorted(by: { $0.0 > $1.0 }) {
            let adjustedIndex = updatedCount - 1 - index
            if adjustedIndex == maxAnimatedInsertionIndex + 1 {
                maxAnimatedInsertionIndex += 1
            }
        }
    case .Reload:
        stationaryItemRange = (0, Int.max)
    case .HoleReload:
        stationaryItemRange = (0, Int.max)
    }

    for (index, entry, previousIndex) in mergeResult.indicesAndItems {
        let adjustedIndex = updatedCount - 1 - index

        let adjustedPrevousIndex: Int?
        if let previousIndex = previousIndex {
            adjustedPrevousIndex = previousCount - 1 - previousIndex
        } else {
            adjustedPrevousIndex = nil
        }

        var directionHint: ListViewItemOperationDirectionHint?
        if maxAnimatedInsertionIndex >= 0 && adjustedIndex <= maxAnimatedInsertionIndex {
            directionHint = .Down
        }

        adjustedIndicesAndItems.append(ChatHistoryViewTransitionInsertEntry(index: adjustedIndex, previousIndex: adjustedPrevousIndex, entry: entry, directionHint: directionHint))
    }

    for (index, entry, previousIndex) in mergeResult.updateIndices {
        let adjustedIndex = updatedCount - 1 - index
        let adjustedPreviousIndex = previousCount - 1 - previousIndex

        let directionHint: ListViewItemOperationDirectionHint? = nil
        adjustedUpdateItems.append(ChatHistoryViewTransitionUpdateEntry(index: adjustedIndex, previousIndex: adjustedPreviousIndex, entry: entry, directionHint: directionHint))
    }

    var scrolledToIndex: MessageHistoryScrollToSubject?
    var scrolledToSomeIndex = false

    let curve: ListViewAnimationCurve = scrollAnimationCurve ?? .Default(duration: nil)

    var isSavedMusic = false
    if case let .custom(_, _, _, isSavedMusicValue, _, _) = source {
        isSavedMusic = isSavedMusicValue
    }

    if let scrollPosition = scrollPosition {
        switch scrollPosition {
            case let .unread(unreadIndex):
                var index = effectiveToView.filteredEntries.count - 1
                for entry in effectiveToView.filteredEntries {
                    if case .UnreadEntry = entry {
                        scrollToItem = ListViewScrollToItem(index: index, position: .bottom(0.0), animated: false, curve: curve, directionHint: .Down)
                        break
                    }
                    index -= 1
                }

                if scrollToItem == nil {
                    var index = effectiveToView.filteredEntries.count - 1
                    for entry in effectiveToView.filteredEntries {
                        if entry.index >= unreadIndex {
                            scrollToItem = ListViewScrollToItem(index: index, position: .bottom(0.0), animated: false, curve: curve,  directionHint: .Down)
                            break
                        }
                        index -= 1
                    }

                    if let currentScrollToItem = scrollToItem {
                        index = 0
                        for entry in effectiveToView.filteredEntries.reversed() {
                            if index > currentScrollToItem.index {
                                if entry.index.timestamp > 10 {
                                    break
                                } else if case .ChatInfoEntry = entry {
                                    scrollToItem = ListViewScrollToItem(index: index, position: .bottom(0.0), animated: false, curve: curve,  directionHint: .Down)
                                    break
                                }
                            }
                            index += 1
                        }
                    }
                }

                if scrollToItem == nil {
                    var index = 0
                    for entry in effectiveToView.filteredEntries.reversed() {
                        if entry.index < unreadIndex {
                            scrollToItem = ListViewScrollToItem(index: index, position: .bottom(0.0), animated: false, curve: curve, directionHint: .Down)
                            break
                        }
                        index += 1
                    }
                }
            case let .positionRestoration(scrollIndex, relativeOffset):
                var index = effectiveToView.filteredEntries.count - 1
                for entry in effectiveToView.filteredEntries {
                    if entry.index >= scrollIndex {
                        scrollToItem = ListViewScrollToItem(index: index, position: .top(relativeOffset), animated: false, curve: curve,  directionHint: .Down)
                        break
                    }
                    index -= 1
                }

                if scrollToItem == nil {
                    var index = 0
                    for entry in effectiveToView.filteredEntries.reversed() {
                        if entry.index < scrollIndex {
                            scrollToItem = ListViewScrollToItem(index: index, position: .top(0.0), animated: false, curve: curve, directionHint: .Down)
                            break
                        }
                        index += 1
                    }
                }
            case let .index(scrollSubject, position, directionHint, animated, highlight, displayLink, _):
                let scrollIndex = scrollSubject
                var position = position
                if case .center = position, highlight {
                    scrolledToIndex = scrollSubject
                }
                if case .center = position {
                    if let quote = scrollSubject.quote {
                        position = .center(.custom({ itemNode in
                            if let itemNode = itemNode as? ChatMessageBubbleItemNode {
                                if let quoteRect = itemNode.getQuoteRect(quote: quote.string, offset: quote.offset) {
                                    return quoteRect.midY
                                }
                            }
                            return 0.0
                        }))
                    } else if let subject = scrollSubject.subject {
                        position = .center(.custom({ itemNode in
                            if let itemNode = itemNode as? ChatMessageBubbleItemNode {
                                if let taskRect = itemNode.getInnerReplySubjectRect(innerSubject: subject) {
                                    return taskRect.midY
                                }
                            }
                            return 0.0
                        }))
                    }
                }
                var index = effectiveToView.filteredEntries.count - 1
                for entry in effectiveToView.filteredEntries {
                    if isSavedMusic {
                        if case let .message(messageIndex) = scrollIndex.index, messageIndex.id == entry.index.id {
                            print(messageIndex.id)
                            scrollToItem = ListViewScrollToItem(index: index, position: position, animated: animated, curve: curve, directionHint: directionHint, displayLink: displayLink)
                            break
                        }
                    } else {
                        if scrollIndex.index.isLessOrEqual(to: entry.index) {
                            scrollToItem = ListViewScrollToItem(index: index, position: position, animated: animated, curve: curve, directionHint: directionHint, displayLink: displayLink)
                            break
                        }
                    }
                    index -= 1
                }

                if scrollToItem == nil {
                    var index = 0
                    for entry in effectiveToView.filteredEntries.reversed() {
                        if !scrollIndex.index.isLess(than: entry.index) {
                            scrolledToSomeIndex = true
                            scrollToItem = ListViewScrollToItem(index: index, position: position, animated: animated, curve: curve, directionHint: directionHint)
                            break
                        }
                        index += 1
                    }
                }
        }
    } else if case .Initial = reason, scrollToItem == nil {
        var index = effectiveToView.filteredEntries.count - 1
        for entry in effectiveToView.filteredEntries {
            if case let .MessageEntry(message, _, _, _, _, _) = entry {
                if let _ = message.adAttribute {
                    scrollToItem = ListViewScrollToItem(index: index + 1, position: .top(0.0), animated: false, curve: curve, directionHint: .Down)
                    break
                }
            }
            index -= 1
        }
    }

    if updatedMessageSelection {
        options.insert(.Synchronous)
    }

    return ChatHistoryViewTransition(historyView: effectiveToView, deleteItems: adjustedDeleteIndices, insertEntries: adjustedIndicesAndItems, updateEntries: adjustedUpdateItems, options: options, scrollToItem: scrollToItem, stationaryItemRange: stationaryItemRange, initialData: initialData, keyboardButtonsMessage: keyboardButtonsMessage, cachedData: cachedData, cachedDataMessages: cachedDataMessages, readStateData: readStateData, scrolledToIndex: scrolledToIndex, scrolledToSomeIndex: scrolledToSomeIndex || scrolledToIndex != nil, animateIn: animateIn, reason: reason, flashIndicators: flashIndicators)
}
