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
import GlassBackgroundComponent
import ObjectiveC.runtime

private var eahatGramDismissGestureTargetKey: UInt8 = 0
private let eahatGramPersistedChainVisualizationState = Atomic<EahatGramGiftChainVisualizationState?>(value: nil)

private final class EahatGramDismissGestureTarget: NSObject {
    weak var view: UIView?

    init(view: UIView?) {
        self.view = view
    }

    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view = self.view, recognizer.state == .ended else {
            return
        }
        let location = recognizer.location(in: view)
        if let hitView = view.hitTest(location, with: nil), hitView is UITextField || hitView is UITextView {
            return
        }
        view.endEditing(true)
    }
}

private func eahatGramInstallDismissKeyboardGesture(controller: ViewController) {
    let target = EahatGramDismissGestureTarget(view: controller.view)
    let recognizer = UITapGestureRecognizer(target: target, action: #selector(EahatGramDismissGestureTarget.handleTap(_:)))
    recognizer.cancelsTouchesInView = false
    controller.view.addGestureRecognizer(recognizer)
    objc_setAssociatedObject(controller, &eahatGramDismissGestureTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

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
            let profileGiftsContext = ProfileGiftsContext(account: self.context.account, peerId: self.context.account.peerId, filter: .All)
            profileGiftsContext.loadMore()
            push(eahatGramScreen(context: self.context, profileGiftsContext: profileGiftsContext, starsContext: self.controller?.starsContext))
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
                var maximumAvailableAccounts: Int = 3
                if accountAndPeer?.1.isPremium == true && !strongSelf.context.account.testingEnvironment {
                    maximumAvailableAccounts = 4
                }
                var count: Int = 1
                for (accountContext, peer, _) in accountsAndPeers {
                    if !accountContext.account.testingEnvironment {
                        if peer.isPremium {
                            maximumAvailableAccounts = 4
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
    let addNftUsernameTag: () -> Void
    let updateStarsAmount: (Int32) -> Void
    let addStars: () -> Void
    let updateTargetHudEnabled: (Bool) -> Void
    let updateLiquidGlassEnabled: (Bool) -> Void
    let updateReplyQuoteEnabled: (Bool) -> Void
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
        addNftUsernameTag: @escaping () -> Void,
        updateStarsAmount: @escaping (Int32) -> Void,
        addStars: @escaping () -> Void,
        updateTargetHudEnabled: @escaping (Bool) -> Void,
        updateLiquidGlassEnabled: @escaping (Bool) -> Void,
        updateReplyQuoteEnabled: @escaping (Bool) -> Void,
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
        self.addNftUsernameTag = addNftUsernameTag
        self.updateStarsAmount = updateStarsAmount
        self.addStars = addStars
        self.updateTargetHudEnabled = updateTargetHudEnabled
        self.updateLiquidGlassEnabled = updateLiquidGlassEnabled
        self.updateReplyQuoteEnabled = updateReplyQuoteEnabled
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
    case other
}

private struct EahatGramState: Equatable {
    var selectedTab: EahatGramTab
    var selectedPeerId: EnginePeer.Id?
    var selectedPeerTitle: String
    var targetHudEnabled: Bool
    var liquidGlassEnabled: Bool
    var replyQuoteEnabled: Bool
    var useDirectRpc: Bool
    var starsAmount: Int32
    var chainPeerIdText: String
    var chainDepthText: String
    var chainPeerLimitText: String
    var chainWorkerCountText: String
    var chainStatusText: String
    var hasCurrentChainVisualization: Bool
    var responses: [String]

    init(liquidGlassEnabled: Bool, replyQuoteEnabled: Bool, hasCurrentChainVisualization: Bool) {
        self.selectedTab = .me
        self.selectedPeerId = nil
        self.selectedPeerTitle = ""
        self.targetHudEnabled = EahatGramDebugSettings.targetHudEnabled.with { $0 }
        self.liquidGlassEnabled = liquidGlassEnabled
        self.replyQuoteEnabled = replyQuoteEnabled
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
    case addNftUsernameTag
    case starsAmount(Int32)
    case addStars
    case starsStatus(String)
    case targetHud(Bool)
    case liquidGlass(Bool)
    case replyQuote(Bool)
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
        case .selectPeer, .addGiftToProfile, .clearGifts, .addNftUsernameTag, .targetHud, .liquidGlass, .replyQuote, .useDirectRpc, .refreshResponses:
            return EahatGramSection.controls.rawValue
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
        case .addNftUsernameTag:
            return 3
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
        case .addNftUsernameTag:
            if case .addNftUsernameTag = rhs {
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
        case .addNftUsernameTag:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Add NFT Username Tag",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addNftUsernameTag()
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
            return EahatGramInsertCountSliderItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Stars",
                minimumValue: 1,
                maximumValue: 100000,
                value: value,
                sectionId: self.section,
                updated: { value in
                    arguments.updateStarsAmount(value)
                }
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

private func eahatGramEntries(
    state: EahatGramState,
    gifts: [ProfileGiftsContext.State.StarGift],
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
        entries.append(.addNftUsernameTag)
        entries.append(.targetHud(state.targetHudEnabled))
        entries.append(.liquidGlass(state.liquidGlassEnabled))
        entries.append(.replyQuote(state.replyQuoteEnabled))
        if gifts.isEmpty {
            entries.append(.noGifts(noGiftsText))
        } else {
            if gifts.count > visibleGiftCount {
                entries.append(.giftsSummary("Showing first \(visibleGiftCount) of \(gifts.count) gifts"))
            }
            for i in 0 ..< visibleGiftCount {
                entries.append(.meGift(i, eahatGramGiftTitle(gifts[i])))
                entries.append(.meGiftInfo(i, eahatGramGiftInfo(gifts[i])))
            }
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
    case .other:
        entries.append(.starsAmount(state.starsAmount))
        entries.append(.addStars)
        if !hasStarsContext {
            entries.append(.starsStatus("starsContext=nil"))
        }

        let methods = eahatGramOtherMethods()
        for i in 0 ..< methods.count {
            entries.append(.otherMethod(i, methods[i].title))
            entries.append(.otherMethodInfo(i, methods[i].info))
        }
    }

    return entries
}

private func eahatGramScreen(context: AccountContext, profileGiftsContext: ProfileGiftsContext, starsContext: StarsContext?) -> ViewController {
    let initialState = EahatGramState(
        liquidGlassEnabled: !context.sharedContext.immediateExperimentalUISettings.fakeGlass,
        replyQuoteEnabled: context.sharedContext.immediateExperimentalUISettings.replyQuote,
        hasCurrentChainVisualization: eahatGramPersistedChainVisualizationState.with { $0 != nil }
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let currentGifts = Atomic(value: [ProfileGiftsContext.State.StarGift]())
    let probeDisposable = MetaDisposable()
    let chainBuildDisposable = MetaDisposable()
    let chainBuildGeneration = Atomic(value: 0)
    let chainVisualizationState = Atomic<EahatGramGiftChainVisualizationState?>(value: nil)

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

    var pushControllerImpl: ((ViewController) -> Void)?
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
                profileGiftsContext: profileGiftsContext,
                appendStatus: appendResponse
            )
            pushControllerImpl?(controller)
        },
        addCustomGiftToProfile: {
            let controller = eahatGramAddGiftToProfileScreen(
                context: context,
                profileGiftsContext: profileGiftsContext,
                appendStatus: appendResponse,
                customMode: true
            )
            pushControllerImpl?(controller)
        },
        clearGifts: {
            profileGiftsContext.clearLocalInsertedStarGifts()
            appendResponse("clearLocalInsertedStarGifts completed")
        },
        addNftUsernameTag: {
            EahatGramDebugSettings.setNftUsernameTag("[NFT]")
            appendResponse("nftUsernameTag value=[NFT]")
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
                settings.fakeGlass = !value
                if value {
                    settings.forceClearGlass = false
                }
                return settings
            }).start()
            GlassBackgroundView.useCustomGlassImpl = !value
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
                        focusedPeerId: nil,
                        manualOrigins: [:],
                        selectedEdge: nil,
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
        profileGiftsContext.state
    )
    |> deliverOnMainQueue
    |> map { presentationData, state, giftsState -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let gifts = giftsState.gifts
        _ = currentGifts.swap(gifts)
        let noGiftsText = "No gifts loaded"

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .textWithTabs("eahatGram", ["me", "test", "chain", "other"], state.selectedTab.rawValue),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: eahatGramEntries(state: state, gifts: gifts, noGiftsText: noGiftsText, hasStarsContext: starsContext != nil),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        probeDisposable.dispose()
        chainBuildDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
    eahatGramInstallDismissKeyboardGesture(controller: controller)
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

    refreshResponses()

    return controller
}
