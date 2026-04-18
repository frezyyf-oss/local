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

    private init() {
        let jobsValue = EahatGramFarmManager.loadPersistedJobs()
        self.jobsValue = jobsValue
        self.jobsPromise = ValuePromise(jobsValue, ignoreRepeated: true)
    }

    public func updatePrimaryContext(_ context: AccountContext?) {
        self.queue.async {
            self.primaryContext = context
            self.updateTimer()
        }
    }

    func jobsSignal() -> Signal<[EahatGramFarmJob], NoError> {
        return self.jobsPromise.get()
    }

    func jobsSnapshot() -> [EahatGramFarmJob] {
        return self.jobsValue
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
    }

    private func updateTimer() {
        let shouldRun = self.primaryContext != nil && self.jobsValue.contains(where: { $0.isEnabled })
        if shouldRun {
            if self.timer == nil {
                let timer = SwiftSignalKit.Timer(timeout: 30.0, repeat: true, completion: { [weak self] in
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

    private func processDueJobs() {
        guard let context = self.primaryContext else {
            return
        }
        let now = Int32(Date().timeIntervalSince1970)
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
            self.commitJobs()

            let command = job.command
            let signal = (context.engine.peers.resolvePeerByName(name: job.botUsername, referrer: nil)
            |> take(1)
            |> mapToSignal { result -> Signal<(EnginePeer.Id?, [MessageId?]), NoError> in
                guard case let .result(peer) = result, let resolvedPeer = peer else {
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

            let _ = signal.startStandalone(next: { [weak self] (peerId: EnginePeer.Id?, messageIds: [MessageId?]) in
                guard let self else {
                    return
                }
                guard let resultIndex = self.jobsValue.firstIndex(where: { $0.id == job.id }) else {
                    return
                }
                if let peerId {
                    let hasMessageId = messageIds.contains(where: { $0 != nil })
                    self.jobsValue[resultIndex].lastResultText = "sent peerId=\(peerId.toInt64()) messageId=\(hasMessageId ? 1 : 0)"
                } else {
                    self.jobsValue[resultIndex].lastResultText = "resolve_failed"
                }
                self.commitJobs()
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
            push(eahatGramScreen(context: self.context, starsContext: self.controller?.starsContext))
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
    let addGiftToProfile: () -> Void
    let addCustomGiftToProfile: () -> Void
    let clearGifts: () -> Void
    let updateNftUsernameTag: (String) -> Void
    let updateNftUsernamePrice: (String) -> Void
    let updateFakePhoneNumber: (String) -> Void
    let updateStarsAmount: (Int32) -> Void
    let addStars: () -> Void
    let updateTargetHudEnabled: (Bool) -> Void
    let updateLiquidGlassEnabled: (Bool) -> Void
    let updateReplyQuoteEnabled: (Bool) -> Void
    let updateGhostModeEnabled: (Bool) -> Void
    let updateFakeOnlineEnabled: (Bool) -> Void
    let updateSaveDeletedMessagesEnabled: (Bool) -> Void
    let updateSaveEditedMessagesEnabled: (Bool) -> Void
    let updateNoLagsEnabled: (Bool) -> Void
    let updateViewUnread2ReadEnabled: (Bool) -> Void
    let updateFarmBotUsername: (String) -> Void
    let updateFarmCommand: (String) -> Void
    let updateFarmInterval: (String) -> Void
    let addFarmJob: () -> Void
    let updateFarmJobEnabled: (Int, Bool) -> Void
    let removeFarmJob: (Int) -> Void
    let updateVoiceModEnabled: (Bool) -> Void
    let selectVoiceModPreset: () -> Void
    let updateUseDirectRpc: (Bool) -> Void
    let updateChainPeerId: (String) -> Void
    let updateChainDepth: (String) -> Void
    let updateChainPeerLimit: (String) -> Void
    let updateChainWorkerCount: (String) -> Void
    let openCurrentChainVisualization: () -> Void
    let runChainScan: () -> Void
    let refreshResponses: () -> Void
    let runGiftProbe: (Int) -> Void
    let showOtherMethod: (Int) -> Void

    init(
        context: AccountContext,
        selectPeer: @escaping () -> Void,
        addGiftToProfile: @escaping () -> Void,
        addCustomGiftToProfile: @escaping () -> Void,
        clearGifts: @escaping () -> Void,
        updateNftUsernameTag: @escaping (String) -> Void,
        updateNftUsernamePrice: @escaping (String) -> Void,
        updateFakePhoneNumber: @escaping (String) -> Void,
        updateStarsAmount: @escaping (Int32) -> Void,
        addStars: @escaping () -> Void,
        updateTargetHudEnabled: @escaping (Bool) -> Void,
        updateLiquidGlassEnabled: @escaping (Bool) -> Void,
        updateReplyQuoteEnabled: @escaping (Bool) -> Void,
        updateGhostModeEnabled: @escaping (Bool) -> Void,
        updateFakeOnlineEnabled: @escaping (Bool) -> Void,
        updateSaveDeletedMessagesEnabled: @escaping (Bool) -> Void,
        updateSaveEditedMessagesEnabled: @escaping (Bool) -> Void,
        updateNoLagsEnabled: @escaping (Bool) -> Void,
        updateViewUnread2ReadEnabled: @escaping (Bool) -> Void,
        updateFarmBotUsername: @escaping (String) -> Void,
        updateFarmCommand: @escaping (String) -> Void,
        updateFarmInterval: @escaping (String) -> Void,
        addFarmJob: @escaping () -> Void,
        updateFarmJobEnabled: @escaping (Int, Bool) -> Void,
        removeFarmJob: @escaping (Int) -> Void,
        updateVoiceModEnabled: @escaping (Bool) -> Void,
        selectVoiceModPreset: @escaping () -> Void,
        updateUseDirectRpc: @escaping (Bool) -> Void,
        updateChainPeerId: @escaping (String) -> Void,
        updateChainDepth: @escaping (String) -> Void,
        updateChainPeerLimit: @escaping (String) -> Void,
        updateChainWorkerCount: @escaping (String) -> Void,
        openCurrentChainVisualization: @escaping () -> Void,
        runChainScan: @escaping () -> Void,
        refreshResponses: @escaping () -> Void,
        runGiftProbe: @escaping (Int) -> Void,
        showOtherMethod: @escaping (Int) -> Void
    ) {
        self.context = context
        self.selectPeer = selectPeer
        self.addGiftToProfile = addGiftToProfile
        self.addCustomGiftToProfile = addCustomGiftToProfile
        self.clearGifts = clearGifts
        self.updateNftUsernameTag = updateNftUsernameTag
        self.updateNftUsernamePrice = updateNftUsernamePrice
        self.updateFakePhoneNumber = updateFakePhoneNumber
        self.updateStarsAmount = updateStarsAmount
        self.addStars = addStars
        self.updateTargetHudEnabled = updateTargetHudEnabled
        self.updateLiquidGlassEnabled = updateLiquidGlassEnabled
        self.updateReplyQuoteEnabled = updateReplyQuoteEnabled
        self.updateGhostModeEnabled = updateGhostModeEnabled
        self.updateFakeOnlineEnabled = updateFakeOnlineEnabled
        self.updateSaveDeletedMessagesEnabled = updateSaveDeletedMessagesEnabled
        self.updateSaveEditedMessagesEnabled = updateSaveEditedMessagesEnabled
        self.updateNoLagsEnabled = updateNoLagsEnabled
        self.updateViewUnread2ReadEnabled = updateViewUnread2ReadEnabled
        self.updateFarmBotUsername = updateFarmBotUsername
        self.updateFarmCommand = updateFarmCommand
        self.updateFarmInterval = updateFarmInterval
        self.addFarmJob = addFarmJob
        self.updateFarmJobEnabled = updateFarmJobEnabled
        self.removeFarmJob = removeFarmJob
        self.updateVoiceModEnabled = updateVoiceModEnabled
        self.selectVoiceModPreset = selectVoiceModPreset
        self.updateUseDirectRpc = updateUseDirectRpc
        self.updateChainPeerId = updateChainPeerId
        self.updateChainDepth = updateChainDepth
        self.updateChainPeerLimit = updateChainPeerLimit
        self.updateChainWorkerCount = updateChainWorkerCount
        self.openCurrentChainVisualization = openCurrentChainVisualization
        self.runChainScan = runChainScan
        self.refreshResponses = refreshResponses
        self.runGiftProbe = runGiftProbe
        self.showOtherMethod = showOtherMethod
    }
}

private enum EahatGramSection: Int32 {
    case controls
    case farm
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
    case farm
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
    var saveDeletedMessagesEnabled: Bool
    var saveEditedMessagesEnabled: Bool
    var noLagsEnabled: Bool
    var viewUnread2ReadEnabled: Bool
    var farmBotUsernameText: String
    var farmCommandText: String
    var farmIntervalText: String
    var voiceModEnabled: Bool
    var voiceModPreset: String
    var nftUsernameTagText: String
    var nftUsernamePriceText: String
    var fakePhoneNumberText: String
    var useDirectRpc: Bool
    var starsAmount: Int32
    var chainPeerIdText: String
    var chainDepthText: String
    var chainPeerLimitText: String
    var chainWorkerCountText: String
    var chainStatusText: String
    var hasCurrentChainVisualization: Bool
    var responses: [String]

    init(liquidGlassEnabled: Bool, replyQuoteEnabled: Bool, ghostModeEnabled: Bool, fakeOnlineEnabled: Bool, saveDeletedMessagesEnabled: Bool, saveEditedMessagesEnabled: Bool, noLagsEnabled: Bool, viewUnread2ReadEnabled: Bool, hasCurrentChainVisualization: Bool) {
        self.selectedTab = .me
        self.selectedPeerId = nil
        self.selectedPeerTitle = ""
        self.targetHudEnabled = EahatGramDebugSettings.targetHudEnabled.with { $0 }
        self.liquidGlassEnabled = liquidGlassEnabled
        self.replyQuoteEnabled = replyQuoteEnabled
        self.ghostModeEnabled = ghostModeEnabled
        self.fakeOnlineEnabled = fakeOnlineEnabled
        self.saveDeletedMessagesEnabled = saveDeletedMessagesEnabled
        self.saveEditedMessagesEnabled = saveEditedMessagesEnabled
        self.noLagsEnabled = noLagsEnabled
        self.viewUnread2ReadEnabled = viewUnread2ReadEnabled
        self.farmBotUsernameText = ""
        self.farmCommandText = ""
        self.farmIntervalText = "240"
        self.voiceModEnabled = EahatGramDebugSettings.voiceModEnabled.with { $0 }
        self.voiceModPreset = EahatGramDebugSettings.resolvedVoiceModPreset().title
        self.nftUsernameTagText = EahatGramDebugSettings.nftUsernameTag.with { $0 }
        self.nftUsernamePriceText = EahatGramDebugSettings.nftUsernamePrice.with { $0 }
        self.fakePhoneNumberText = EahatGramDebugSettings.fakePhoneNumber.with { $0 }
        self.useDirectRpc = true
        self.starsAmount = 100
        self.chainPeerIdText = ""
        self.chainDepthText = "5"
        self.chainPeerLimitText = "5"
        self.chainWorkerCountText = "\(eahatGramGiftChainDefaultConcurrentPeers)"
        self.chainStatusText = "No chain scan started"
        self.hasCurrentChainVisualization = hasCurrentChainVisualization
        self.responses = []
    }
}

private enum EahatGramEntry: ItemListNodeEntry {
    case selectPeer(String)
    case addGiftToProfile
    case addCustomGiftToProfile
    case clearGifts
    case nftUsernameTag(String)
    case nftUsernamePrice(String)
    case fakePhoneNumber(String)
    case starsAmount(Int32)
    case addStars
    case starsStatus(String)
    case targetHud(Bool)
    case liquidGlass(Bool)
    case replyQuote(Bool)
    case ghostMode(Bool)
    case fakeOnline(Bool)
    case saveDeletedMessages(Bool)
    case saveEditedMessages(Bool)
    case noLags(Bool)
    case viewUnread2Read(Bool)
    case farmBotUsername(String)
    case farmCommand(String)
    case farmInterval(String)
    case addFarmJob
    case farmJobEnabled(Int, String, Bool)
    case farmJobInfo(Int, String)
    case removeFarmJob(Int, String)
    case voiceMod(Bool)
    case voiceModPreset(String)
    case useDirectRpc(Bool)
    case chainPeerId(String)
    case chainDepth(String)
    case chainPeerLimit(String)
    case chainWorkerCount(String)
    case openCurrentChainVisualization
    case runChainScan
    case chainStatus(String)
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
        case .selectPeer, .addGiftToProfile, .clearGifts, .nftUsernameTag, .nftUsernamePrice, .fakePhoneNumber, .targetHud, .liquidGlass, .replyQuote, .ghostMode, .fakeOnline, .saveDeletedMessages, .saveEditedMessages, .noLags, .viewUnread2Read, .voiceMod, .voiceModPreset, .useDirectRpc, .refreshResponses:
            return EahatGramSection.controls.rawValue
        case .farmBotUsername, .farmCommand, .farmInterval, .addFarmJob, .farmJobEnabled, .farmJobInfo, .removeFarmJob:
            return EahatGramSection.farm.rawValue
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
        case .addGiftToProfile:
            return 0
        case .clearGifts:
            return 2
        case .nftUsernameTag:
            return 3
        case .nftUsernamePrice:
            return 16
        case .fakePhoneNumber:
            return 11
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
        case .saveDeletedMessages:
            return 9
        case .saveEditedMessages:
            return 10
        case .noLags:
            return 14
        case .viewUnread2Read:
            return 15
        case .farmBotUsername:
            return 17
        case .farmCommand:
            return 18
        case .farmInterval:
            return 19
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
        case let .fakePhoneNumber(lhsText):
            if case let .fakePhoneNumber(rhsText) = rhs {
                return lhsText == rhsText
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

private func eahatGramEntries(
    state: EahatGramState,
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
        entries.append(.nftUsernameTag(state.nftUsernameTagText))
        entries.append(.nftUsernamePrice(state.nftUsernamePriceText))
        entries.append(.fakePhoneNumber(state.fakePhoneNumberText))
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
            entries.append(.saveDeletedMessages(state.saveDeletedMessagesEnabled))
            entries.append(.saveEditedMessages(state.saveEditedMessagesEnabled))
            entries.append(.noLags(state.noLagsEnabled))
            entries.append(.viewUnread2Read(state.viewUnread2ReadEnabled))
            entries.append(.voiceMod(state.voiceModEnabled))
            if state.voiceModEnabled {
                entries.append(.voiceModPreset(state.voiceModPreset))
            }
            if gifts.isEmpty {
            entries.append(.noGifts(noGiftsText))
        } else {
            entries.append(.giftsSummary("Loaded gifts: \(gifts.count)"))
        }
    case .test:
        entries.append(.selectPeer(state.selectedPeerTitle.isEmpty ? "Not selected" : state.selectedPeerTitle))
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
    case .farm:
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

private func eahatGramScreen(context: AccountContext, starsContext: StarsContext?) -> ViewController {
    let initialState = EahatGramState(
        liquidGlassEnabled: context.sharedContext.immediateExperimentalUISettings.fakeGlass,
        replyQuoteEnabled: context.sharedContext.immediateExperimentalUISettings.replyQuote,
        ghostModeEnabled: context.sharedContext.immediateExperimentalUISettings.ghostMode,
        fakeOnlineEnabled: context.sharedContext.immediateExperimentalUISettings.fakeOnline,
        saveDeletedMessagesEnabled: context.sharedContext.immediateExperimentalUISettings.saveDeletedMessages,
        saveEditedMessagesEnabled: context.sharedContext.immediateExperimentalUISettings.saveEditedMessages,
        noLagsEnabled: context.sharedContext.immediateExperimentalUISettings.noLagsEnabled,
        viewUnread2ReadEnabled: context.sharedContext.immediateExperimentalUISettings.viewUnread2Read,
        hasCurrentChainVisualization: eahatGramPersistedChainVisualizationState.with { $0 != nil }
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let giftsPromise = ValuePromise([ProfileGiftsContext.State.StarGift](), ignoreRepeated: true)
    let currentGifts = Atomic(value: [ProfileGiftsContext.State.StarGift]())
    EahatGramFarmManager.shared.updatePrimaryContext(context)
    let currentFarmJobs = Atomic(value: EahatGramFarmManager.shared.jobsSnapshot())
    let probeDisposable = MetaDisposable()
    let chainBuildDisposable = MetaDisposable()
    let chainBuildGeneration = Atomic(value: 0)
    let chainVisualizationState = Atomic<EahatGramGiftChainVisualizationState?>(value: nil)
    let profileGiftsContextStateDisposable = MetaDisposable()
    let profileGiftsContextRef = Atomic<ProfileGiftsContext?>(value: nil)

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

    let ensureProfileGiftsContext: () -> ProfileGiftsContext = {
        if let current = profileGiftsContextRef.with({ $0 }) {
            return current
        }
        let created = ProfileGiftsContext(account: context.account, peerId: context.account.peerId, filter: .All)
        _ = profileGiftsContextRef.swap(created)
        profileGiftsContextStateDisposable.set((created.state
        |> deliverOnMainQueue).start(next: { giftsState in
            let gifts = giftsState.gifts
            giftsPromise.set(gifts)
            _ = currentGifts.swap(gifts)
        }))
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
                    current.liquidGlassEnabled = false
                }
                return current
            }
            appendResponse("noLags enabled=\(value)")
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
            title: .textWithTabs("eahatGram", ["me", "test", "chain", "farm"], state.selectedTab.rawValue),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: eahatGramEntries(state: state, gifts: gifts, farmJobs: farmJobs, noGiftsText: noGiftsText, hasStarsContext: starsContext != nil),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        probeDisposable.dispose()
        chainBuildDisposable.dispose()
        profileGiftsContextStateDisposable.dispose()
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
