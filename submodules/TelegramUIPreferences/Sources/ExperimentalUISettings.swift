import Foundation
import TelegramCore
import SwiftSignalKit

public struct ExperimentalUISettings: Codable, Equatable {
    public struct AccountReactionOverrides: Equatable, Codable {
        public struct Item: Equatable, Codable {
            public var key: MessageReaction.Reaction
            public var messageId: EngineMessage.Id
            public var mediaId: EngineMedia.Id

            public init(key: MessageReaction.Reaction, messageId: EngineMessage.Id, mediaId: EngineMedia.Id) {
                self.key = key
                self.messageId = messageId
                self.mediaId = mediaId
            }
        }

        public var accountId: Int64
        public var items: [Item]

        public init(accountId: Int64, items: [Item]) {
            self.accountId = accountId
            self.items = items
        }
    }

    public enum ChatListCustomThemeElement: String, Equatable {
        case header
        case foldersStrip
        case selectedFolder
        case listBackground
        case rowBackground
        case rootTabBarBackground
        case rootTabBarItemBackground
        case rootTabBarSelectedItemBackground
        case rootTabBarSearchBackground
    }

    public enum ChatListCustomThemePreset: String, Equatable {
        case none
        case rgb
        case rainbow
        case asfalo
        case asfolo
    }

    public struct ChatListCustomThemeValue: Codable, Equatable {
        // Postbox's Codable bridge preconditions on single-value encoding, so keep
        // the raw-value enum/UInt32 payload in a keyed representation here.
        private enum CodingKeys: String, CodingKey {
            case preset
            case argb
        }

        public var preset: ChatListCustomThemePreset
        public var argb: UInt32?

        public init(preset: ChatListCustomThemePreset, argb: UInt32? = nil) {
            self.preset = preset
            self.argb = argb
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let presetRawValue = try container.decode(String.self, forKey: .preset)
            self.preset = ChatListCustomThemePreset(rawValue: presetRawValue) ?? .none
            if let argbValue = try container.decodeIfPresent(Int64.self, forKey: .argb) {
                self.argb = UInt32(exactly: argbValue)
            } else {
                self.argb = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.preset.rawValue, forKey: .preset)
            if let argb = self.argb {
                try container.encode(Int64(argb), forKey: .argb)
            } else {
                try container.encodeNil(forKey: .argb)
            }
        }

        public static var none: ChatListCustomThemeValue {
            return ChatListCustomThemeValue(preset: .none, argb: nil)
        }
    }

    public struct ChatListCustomThemeSettings: Codable, Equatable {
        private enum CodingKeys: String, CodingKey {
            case header
            case foldersStrip
            case selectedFolder
            case listBackground
            case rowBackground
            case rootTabBarBackground
            case rootTabBarItemBackground
            case rootTabBarSelectedItemBackground
            case rootTabBarSearchBackground
        }

        public var header: ChatListCustomThemeValue
        public var foldersStrip: ChatListCustomThemeValue
        public var selectedFolder: ChatListCustomThemeValue
        public var listBackground: ChatListCustomThemeValue
        public var rowBackground: ChatListCustomThemeValue
        public var rootTabBarBackground: ChatListCustomThemeValue
        public var rootTabBarItemBackground: ChatListCustomThemeValue
        public var rootTabBarSelectedItemBackground: ChatListCustomThemeValue
        public var rootTabBarSearchBackground: ChatListCustomThemeValue

        public init(
            header: ChatListCustomThemeValue,
            foldersStrip: ChatListCustomThemeValue,
            selectedFolder: ChatListCustomThemeValue,
            listBackground: ChatListCustomThemeValue,
            rowBackground: ChatListCustomThemeValue,
            rootTabBarBackground: ChatListCustomThemeValue,
            rootTabBarItemBackground: ChatListCustomThemeValue,
            rootTabBarSelectedItemBackground: ChatListCustomThemeValue,
            rootTabBarSearchBackground: ChatListCustomThemeValue
        ) {
            self.header = header
            self.foldersStrip = foldersStrip
            self.selectedFolder = selectedFolder
            self.listBackground = listBackground
            self.rowBackground = rowBackground
            self.rootTabBarBackground = rootTabBarBackground
            self.rootTabBarItemBackground = rootTabBarItemBackground
            self.rootTabBarSelectedItemBackground = rootTabBarSelectedItemBackground
            self.rootTabBarSearchBackground = rootTabBarSearchBackground
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.header = try container.decodeIfPresent(ChatListCustomThemeValue.self, forKey: .header) ?? .none
            self.foldersStrip = try container.decodeIfPresent(ChatListCustomThemeValue.self, forKey: .foldersStrip) ?? .none
            self.selectedFolder = try container.decodeIfPresent(ChatListCustomThemeValue.self, forKey: .selectedFolder) ?? .none
            self.listBackground = try container.decodeIfPresent(ChatListCustomThemeValue.self, forKey: .listBackground) ?? .none
            self.rowBackground = try container.decodeIfPresent(ChatListCustomThemeValue.self, forKey: .rowBackground) ?? .none
            self.rootTabBarBackground = try container.decodeIfPresent(ChatListCustomThemeValue.self, forKey: .rootTabBarBackground) ?? .none
            self.rootTabBarItemBackground = try container.decodeIfPresent(ChatListCustomThemeValue.self, forKey: .rootTabBarItemBackground) ?? .none
            self.rootTabBarSelectedItemBackground = try container.decodeIfPresent(ChatListCustomThemeValue.self, forKey: .rootTabBarSelectedItemBackground) ?? .none
            self.rootTabBarSearchBackground = try container.decodeIfPresent(ChatListCustomThemeValue.self, forKey: .rootTabBarSearchBackground) ?? .none
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.header, forKey: .header)
            try container.encode(self.foldersStrip, forKey: .foldersStrip)
            try container.encode(self.selectedFolder, forKey: .selectedFolder)
            try container.encode(self.listBackground, forKey: .listBackground)
            try container.encode(self.rowBackground, forKey: .rowBackground)
            try container.encode(self.rootTabBarBackground, forKey: .rootTabBarBackground)
            try container.encode(self.rootTabBarItemBackground, forKey: .rootTabBarItemBackground)
            try container.encode(self.rootTabBarSelectedItemBackground, forKey: .rootTabBarSelectedItemBackground)
            try container.encode(self.rootTabBarSearchBackground, forKey: .rootTabBarSearchBackground)
        }

        public static var defaultValue: ChatListCustomThemeSettings {
            return ChatListCustomThemeSettings(
                header: .none,
                foldersStrip: .none,
                selectedFolder: .none,
                listBackground: .none,
                rowBackground: .none,
                rootTabBarBackground: .none,
                rootTabBarItemBackground: .none,
                rootTabBarSelectedItemBackground: .none,
                rootTabBarSearchBackground: .none
            )
        }

        public func value(for element: ChatListCustomThemeElement) -> ChatListCustomThemeValue {
            switch element {
            case .header:
                return self.header
            case .foldersStrip:
                return self.foldersStrip
            case .selectedFolder:
                return self.selectedFolder
            case .listBackground:
                return self.listBackground
            case .rowBackground:
                return self.rowBackground
            case .rootTabBarBackground:
                return self.rootTabBarBackground
            case .rootTabBarItemBackground:
                return self.rootTabBarItemBackground
            case .rootTabBarSelectedItemBackground:
                return self.rootTabBarSelectedItemBackground
            case .rootTabBarSearchBackground:
                return self.rootTabBarSearchBackground
            }
        }

        public mutating func setValue(_ value: ChatListCustomThemeValue, for element: ChatListCustomThemeElement) {
            switch element {
            case .header:
                self.header = value
            case .foldersStrip:
                self.foldersStrip = value
            case .selectedFolder:
                self.selectedFolder = value
            case .listBackground:
                self.listBackground = value
            case .rowBackground:
                self.rowBackground = value
            case .rootTabBarBackground:
                self.rootTabBarBackground = value
            case .rootTabBarItemBackground:
                self.rootTabBarItemBackground = value
            case .rootTabBarSelectedItemBackground:
                self.rootTabBarSelectedItemBackground = value
            case .rootTabBarSearchBackground:
                self.rootTabBarSearchBackground = value
            }
        }

        public var hasAnimatedPresets: Bool {
            let values = [
                self.header,
                self.foldersStrip,
                self.selectedFolder,
                self.listBackground,
                self.rowBackground,
                self.rootTabBarBackground,
                self.rootTabBarItemBackground,
                self.rootTabBarSelectedItemBackground,
                self.rootTabBarSearchBackground
            ]
            return values.contains(where: {
                switch $0.preset {
                case .rainbow, .asfalo, .asfolo:
                    return true
                case .none, .rgb:
                    return false
                }
            })
        }
    }

    public var keepChatNavigationStack: Bool
    public var skipReadHistory: Bool
    public var alwaysDisplayTyping: Bool
    public var crashOnLongQueries: Bool
    public var chatListPhotos: Bool
    public var knockoutWallpaper: Bool
    public var foldersTabAtBottom: Bool
    public var preferredVideoCodec: String?
    public var disableVideoAspectScaling: Bool
    public var enableVoipTcp: Bool
    public var experimentalCompatibility: Bool
    public var enableDebugDataDisplay: Bool
    public var fakeGlass: Bool
    public var replyQuote: Bool
    public var ghostMode: Bool
    public var fakeOnline: Bool
    public var saveDeletedMessages: Bool
    public var saveEditedMessages: Bool
    public var compressedEmojiCache: Bool
    public var localTranscription: Bool
    public var enableReactionOverrides: Bool
    public var browserExperiment: Bool
    public var accountReactionEffectOverrides: [AccountReactionOverrides]
    public var accountStickerEffectOverrides: [AccountReactionOverrides]
    public var disableQuickReaction: Bool
    public var disableLanguageRecognition: Bool
    public var disableImageContentAnalysis: Bool
    public var disableBackgroundAnimation: Bool
    public var logLanguageRecognition: Bool
    public var storiesExperiment: Bool
    public var storiesJpegExperiment: Bool
    public var crashOnMemoryPressure: Bool
    public var dustEffect: Bool
    public var disableCallV2: Bool
    public var experimentalCallMute: Bool
    public var allowWebViewInspection: Bool
    public var disableReloginTokens: Bool
    public var liveStreamV2: Bool
    public var dynamicStreaming: Bool
    public var enableLocalTranslation: Bool
    public var autoBenchmarkReflectors: Bool?
    public var playerV2: Bool
    public var devRequests: Bool
    public var fakeAds: Bool
    public var conferenceDebug: Bool
    public var checkSerializedData: Bool
    public var allForumsHaveTabs: Bool
    public var debugRatingLayout: Bool
    public var enableUpdates: Bool
    public var enablePWA: Bool
    public var forceClearGlass: Bool
    public var noLagsEnabled: Bool
    public var viewUnread2Read: Bool
    public var debugRipple: Bool
    public var bogatiUiEnabled: Bool
    public var hideFailedWarning: Bool
    public var sendMode: Bool
    public var chatListCustomTheme: ChatListCustomThemeSettings

    public static var defaultSettings: ExperimentalUISettings {
        return ExperimentalUISettings(
            keepChatNavigationStack: false,
            skipReadHistory: false,
            alwaysDisplayTyping: false,
            crashOnLongQueries: false,
            chatListPhotos: false,
            knockoutWallpaper: false,
            foldersTabAtBottom: false,
            preferredVideoCodec: nil,
            disableVideoAspectScaling: false,
            enableVoipTcp: false,
            experimentalCompatibility: false,
            enableDebugDataDisplay: false,
            fakeGlass: false,
            replyQuote: false,
            ghostMode: false,
            fakeOnline: false,
            saveDeletedMessages: false,
            saveEditedMessages: false,
            compressedEmojiCache: false,
            localTranscription: false,
            enableReactionOverrides: false,
            browserExperiment: false,
            accountReactionEffectOverrides: [],
            accountStickerEffectOverrides: [],
            disableQuickReaction: false,
            disableLanguageRecognition: false,
            disableImageContentAnalysis: false,
            disableBackgroundAnimation: false,
            logLanguageRecognition: false,
            storiesExperiment: false,
            storiesJpegExperiment: false,
            crashOnMemoryPressure: false,
            dustEffect: false,
            disableCallV2: false,
            experimentalCallMute: false,
            allowWebViewInspection: false,
            disableReloginTokens: false,
            liveStreamV2: false,
            dynamicStreaming: false,
            enableLocalTranslation: false,
            autoBenchmarkReflectors: nil,
            playerV2: false,
            devRequests: false,
            fakeAds: false,
            conferenceDebug: false,
            checkSerializedData: false,
            allForumsHaveTabs: false,
            debugRatingLayout: false,
            enableUpdates: false,
            enablePWA: false,
            forceClearGlass: false,
            noLagsEnabled: false,
            viewUnread2Read: false,
            debugRipple: false,
            bogatiUiEnabled: false,
            hideFailedWarning: false,
            sendMode: false,
            chatListCustomTheme: .defaultValue
        )
    }

    public init(
        keepChatNavigationStack: Bool,
        skipReadHistory: Bool,
        alwaysDisplayTyping: Bool,
        crashOnLongQueries: Bool,
        chatListPhotos: Bool,
        knockoutWallpaper: Bool,
        foldersTabAtBottom: Bool,
        preferredVideoCodec: String?,
        disableVideoAspectScaling: Bool,
        enableVoipTcp: Bool,
        experimentalCompatibility: Bool,
        enableDebugDataDisplay: Bool,
        fakeGlass: Bool,
        replyQuote: Bool,
        ghostMode: Bool,
        fakeOnline: Bool,
        saveDeletedMessages: Bool,
        saveEditedMessages: Bool,
        compressedEmojiCache: Bool,
        localTranscription: Bool,
        enableReactionOverrides: Bool,
        browserExperiment: Bool,
        accountReactionEffectOverrides: [AccountReactionOverrides],
        accountStickerEffectOverrides: [AccountReactionOverrides],
        disableQuickReaction: Bool,
        disableLanguageRecognition: Bool,
        disableImageContentAnalysis: Bool,
        disableBackgroundAnimation: Bool,
        logLanguageRecognition: Bool,
        storiesExperiment: Bool,
        storiesJpegExperiment: Bool,
        crashOnMemoryPressure: Bool,
        dustEffect: Bool,
        disableCallV2: Bool,
        experimentalCallMute: Bool,
        allowWebViewInspection: Bool,
        disableReloginTokens: Bool,
        liveStreamV2: Bool,
        dynamicStreaming: Bool,
        enableLocalTranslation: Bool,
        autoBenchmarkReflectors: Bool?,
        playerV2: Bool,
        devRequests: Bool,
        fakeAds: Bool,
        conferenceDebug: Bool,
        checkSerializedData: Bool,
        allForumsHaveTabs: Bool,
        debugRatingLayout: Bool,
        enableUpdates: Bool,
        enablePWA: Bool,
        forceClearGlass: Bool,
        noLagsEnabled: Bool,
        viewUnread2Read: Bool,
        debugRipple: Bool,
        bogatiUiEnabled: Bool,
        hideFailedWarning: Bool,
        sendMode: Bool,
        chatListCustomTheme: ChatListCustomThemeSettings
    ) {
        self.keepChatNavigationStack = keepChatNavigationStack
        self.skipReadHistory = skipReadHistory
        self.alwaysDisplayTyping = alwaysDisplayTyping
        self.crashOnLongQueries = crashOnLongQueries
        self.chatListPhotos = chatListPhotos
        self.knockoutWallpaper = knockoutWallpaper
        self.foldersTabAtBottom = foldersTabAtBottom
        self.preferredVideoCodec = preferredVideoCodec
        self.disableVideoAspectScaling = disableVideoAspectScaling
        self.enableVoipTcp = enableVoipTcp
        self.experimentalCompatibility = experimentalCompatibility
        self.enableDebugDataDisplay = enableDebugDataDisplay
        self.fakeGlass = fakeGlass
        self.replyQuote = replyQuote
        self.ghostMode = ghostMode
        self.fakeOnline = fakeOnline
        self.saveDeletedMessages = saveDeletedMessages
        self.saveEditedMessages = saveEditedMessages
        self.compressedEmojiCache = compressedEmojiCache
        self.localTranscription = localTranscription
        self.enableReactionOverrides = enableReactionOverrides
        self.browserExperiment = browserExperiment
        self.accountReactionEffectOverrides = accountReactionEffectOverrides
        self.accountStickerEffectOverrides = accountStickerEffectOverrides
        self.disableQuickReaction = disableQuickReaction
        self.disableLanguageRecognition = disableLanguageRecognition
        self.disableImageContentAnalysis = disableImageContentAnalysis
        self.disableBackgroundAnimation = disableBackgroundAnimation
        self.logLanguageRecognition = logLanguageRecognition
        self.storiesExperiment = storiesExperiment
        self.storiesJpegExperiment = storiesJpegExperiment
        self.crashOnMemoryPressure = crashOnMemoryPressure
        self.dustEffect = dustEffect
        self.disableCallV2 = disableCallV2
        self.experimentalCallMute = experimentalCallMute
        self.allowWebViewInspection = allowWebViewInspection
        self.disableReloginTokens = disableReloginTokens
        self.liveStreamV2 = liveStreamV2
        self.dynamicStreaming = dynamicStreaming
        self.enableLocalTranslation = enableLocalTranslation
        self.autoBenchmarkReflectors = autoBenchmarkReflectors
        self.playerV2 = playerV2
        self.devRequests = devRequests
        self.fakeAds = fakeAds
        self.conferenceDebug = conferenceDebug
        self.checkSerializedData = checkSerializedData
        self.allForumsHaveTabs = allForumsHaveTabs
        self.debugRatingLayout = debugRatingLayout
        self.enableUpdates = enableUpdates
        self.enablePWA = enablePWA
        self.forceClearGlass = forceClearGlass
        self.noLagsEnabled = noLagsEnabled
        self.viewUnread2Read = viewUnread2Read
        self.debugRipple = debugRipple
        self.bogatiUiEnabled = bogatiUiEnabled
        self.hideFailedWarning = hideFailedWarning
        self.sendMode = sendMode
        self.chatListCustomTheme = chatListCustomTheme
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        self.keepChatNavigationStack = (try container.decodeIfPresent(Int32.self, forKey: "keepChatNavigationStack") ?? 0) != 0
        self.skipReadHistory = (try container.decodeIfPresent(Int32.self, forKey: "skipReadHistory") ?? 0) != 0
        self.alwaysDisplayTyping = (try container.decodeIfPresent(Int32.self, forKey: "alwaysDisplayTyping") ?? 0) != 0
        self.crashOnLongQueries = (try container.decodeIfPresent(Int32.self, forKey: "crashOnLongQueries") ?? 0) != 0
        self.chatListPhotos = (try container.decodeIfPresent(Int32.self, forKey: "chatListPhotos") ?? 0) != 0
        self.knockoutWallpaper = (try container.decodeIfPresent(Int32.self, forKey: "knockoutWallpaper") ?? 0) != 0
        self.foldersTabAtBottom = (try container.decodeIfPresent(Int32.self, forKey: "foldersTabAtBottom") ?? 0) != 0
        self.preferredVideoCodec = try container.decodeIfPresent(String.self.self, forKey: "preferredVideoCodec")
        self.disableVideoAspectScaling = (try container.decodeIfPresent(Int32.self, forKey: "disableVideoAspectScaling") ?? 0) != 0
        self.enableVoipTcp = (try container.decodeIfPresent(Int32.self, forKey: "enableVoipTcp") ?? 0) != 0
        self.experimentalCompatibility = (try container.decodeIfPresent(Int32.self, forKey: "experimentalCompatibility") ?? 0) != 0
        self.enableDebugDataDisplay = (try container.decodeIfPresent(Int32.self, forKey: "enableDebugDataDisplay") ?? 0) != 0
        self.fakeGlass = (try container.decodeIfPresent(Int32.self, forKey: "fakeGlass") ?? 0) != 0
        self.replyQuote = (try container.decodeIfPresent(Int32.self, forKey: "replyQuote") ?? 0) != 0
        self.ghostMode = (try container.decodeIfPresent(Int32.self, forKey: "ghostMode") ?? 0) != 0
        self.fakeOnline = (try container.decodeIfPresent(Int32.self, forKey: "fakeOnline") ?? 0) != 0
        self.saveDeletedMessages = (try container.decodeIfPresent(Int32.self, forKey: "saveDeletedMessages") ?? 0) != 0
        self.saveEditedMessages = (try container.decodeIfPresent(Int32.self, forKey: "saveEditedMessages") ?? 0) != 0
        self.compressedEmojiCache = (try container.decodeIfPresent(Int32.self, forKey: "compressedEmojiCache") ?? 0) != 0
        self.localTranscription = (try container.decodeIfPresent(Int32.self, forKey: "localTranscription") ?? 0) != 0
        self.enableReactionOverrides = try container.decodeIfPresent(Bool.self, forKey: "enableReactionOverrides") ?? false
        self.browserExperiment = try container.decodeIfPresent(Bool.self, forKey: "browserExperiment") ?? false
        self.accountReactionEffectOverrides = (try? container.decodeIfPresent([AccountReactionOverrides].self, forKey: "accountReactionEffectOverrides")) ?? []
        self.accountStickerEffectOverrides = (try? container.decodeIfPresent([AccountReactionOverrides].self, forKey: "accountStickerEffectOverrides")) ?? []
        self.disableQuickReaction = try container.decodeIfPresent(Bool.self, forKey: "disableQuickReaction") ?? false
        self.disableLanguageRecognition = try container.decodeIfPresent(Bool.self, forKey: "disableLanguageRecognition") ?? false
        self.disableImageContentAnalysis = try container.decodeIfPresent(Bool.self, forKey: "disableImageContentAnalysis") ?? false
        self.disableBackgroundAnimation = try container.decodeIfPresent(Bool.self, forKey: "disableBackgroundAnimation") ?? false
        self.logLanguageRecognition = try container.decodeIfPresent(Bool.self, forKey: "logLanguageRecognition") ?? false
        self.storiesExperiment = try container.decodeIfPresent(Bool.self, forKey: "storiesExperiment") ?? false
        self.storiesJpegExperiment = try container.decodeIfPresent(Bool.self, forKey: "storiesJpegExperiment") ?? false
        self.crashOnMemoryPressure = try container.decodeIfPresent(Bool.self, forKey: "crashOnMemoryPressure") ?? false
        self.dustEffect = try container.decodeIfPresent(Bool.self, forKey: "dustEffect") ?? false
        self.disableCallV2 = try container.decodeIfPresent(Bool.self, forKey: "disableCallV2") ?? false
        self.experimentalCallMute = try container.decodeIfPresent(Bool.self, forKey: "experimentalCallMute") ?? false
        self.allowWebViewInspection = try container.decodeIfPresent(Bool.self, forKey: "allowWebViewInspection") ?? false
        self.disableReloginTokens = try container.decodeIfPresent(Bool.self, forKey: "disableReloginTokens") ?? false
        self.liveStreamV2 = try container.decodeIfPresent(Bool.self, forKey: "liveStreamV2") ?? false
        self.dynamicStreaming = try container.decodeIfPresent(Bool.self, forKey: "dynamicStreaming_v2") ?? false
        self.enableLocalTranslation = try container.decodeIfPresent(Bool.self, forKey: "enableLocalTranslation") ?? false
        self.autoBenchmarkReflectors = try container.decodeIfPresent(Bool.self, forKey: "autoBenchmarkReflectors")
        self.playerV2 = try container.decodeIfPresent(Bool.self, forKey: "playerV2") ?? false
        self.devRequests = try container.decodeIfPresent(Bool.self, forKey: "devRequests") ?? false
        self.fakeAds = try container.decodeIfPresent(Bool.self, forKey: "fakeAds") ?? false
        self.conferenceDebug = try container.decodeIfPresent(Bool.self, forKey: "conferenceDebug") ?? false
        self.checkSerializedData = try container.decodeIfPresent(Bool.self, forKey: "checkSerializedData") ?? false
        self.allForumsHaveTabs = try container.decodeIfPresent(Bool.self, forKey: "allForumsHaveTabs") ?? false
        self.debugRatingLayout = try container.decodeIfPresent(Bool.self, forKey: "debugRatingLayout") ?? false
        self.enableUpdates = try container.decodeIfPresent(Bool.self, forKey: "enableUpdates") ?? false
        self.enablePWA = try container.decodeIfPresent(Bool.self, forKey: "enablePWA") ?? false
        self.forceClearGlass = try container.decodeIfPresent(Bool.self, forKey: "forceClearGlass") ?? false
        self.noLagsEnabled = try container.decodeIfPresent(Bool.self, forKey: "noLagsEnabled") ?? false
        self.viewUnread2Read = try container.decodeIfPresent(Bool.self, forKey: "viewUnread2Read") ?? false
        self.debugRipple = try container.decodeIfPresent(Bool.self, forKey: "debugRipple") ?? false
        self.bogatiUiEnabled = try container.decodeIfPresent(Bool.self, forKey: "bogatiUiEnabled") ?? false
        self.hideFailedWarning = try container.decodeIfPresent(Bool.self, forKey: "hideFailedWarning") ?? false
        self.sendMode = try container.decodeIfPresent(Bool.self, forKey: "sendMode") ?? false
        self.chatListCustomTheme = try container.decodeIfPresent(ChatListCustomThemeSettings.self, forKey: "chatListCustomTheme") ?? .defaultValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode((self.keepChatNavigationStack ? 1 : 0) as Int32, forKey: "keepChatNavigationStack")
        try container.encode((self.skipReadHistory ? 1 : 0) as Int32, forKey: "skipReadHistory")
        try container.encode((self.alwaysDisplayTyping ? 1 : 0) as Int32, forKey: "alwaysDisplayTyping")
        try container.encode((self.crashOnLongQueries ? 1 : 0) as Int32, forKey: "crashOnLongQueries")
        try container.encode((self.chatListPhotos ? 1 : 0) as Int32, forKey: "chatListPhotos")
        try container.encode((self.knockoutWallpaper ? 1 : 0) as Int32, forKey: "knockoutWallpaper")
        try container.encode((self.foldersTabAtBottom ? 1 : 0) as Int32, forKey: "foldersTabAtBottom")
        try container.encodeIfPresent(self.preferredVideoCodec, forKey: "preferredVideoCodec")
        try container.encode((self.disableVideoAspectScaling ? 1 : 0) as Int32, forKey: "disableVideoAspectScaling")
        try container.encode((self.enableVoipTcp ? 1 : 0) as Int32, forKey: "enableVoipTcp")
        try container.encode((self.experimentalCompatibility ? 1 : 0) as Int32, forKey: "experimentalCompatibility")
        try container.encode((self.enableDebugDataDisplay ? 1 : 0) as Int32, forKey: "enableDebugDataDisplay")
        try container.encode((self.fakeGlass ? 1 : 0) as Int32, forKey: "fakeGlass")
        try container.encode((self.replyQuote ? 1 : 0) as Int32, forKey: "replyQuote")
        try container.encode((self.ghostMode ? 1 : 0) as Int32, forKey: "ghostMode")
        try container.encode((self.fakeOnline ? 1 : 0) as Int32, forKey: "fakeOnline")
        try container.encode((self.saveDeletedMessages ? 1 : 0) as Int32, forKey: "saveDeletedMessages")
        try container.encode((self.saveEditedMessages ? 1 : 0) as Int32, forKey: "saveEditedMessages")
        try container.encode((self.compressedEmojiCache ? 1 : 0) as Int32, forKey: "compressedEmojiCache")
        try container.encode((self.localTranscription ? 1 : 0) as Int32, forKey: "localTranscription")
        try container.encode(self.enableReactionOverrides, forKey: "enableReactionOverrides")
        try container.encode(self.browserExperiment, forKey: "browserExperiment")
        try container.encode(self.accountReactionEffectOverrides, forKey: "accountReactionEffectOverrides")
        try container.encode(self.accountStickerEffectOverrides, forKey: "accountStickerEffectOverrides")
        try container.encode(self.disableQuickReaction, forKey: "disableQuickReaction")
        try container.encode(self.disableLanguageRecognition, forKey: "disableLanguageRecognition")
        try container.encode(self.disableImageContentAnalysis, forKey: "disableImageContentAnalysis")
        try container.encode(self.disableBackgroundAnimation, forKey: "disableBackgroundAnimation")
        try container.encode(self.logLanguageRecognition, forKey: "logLanguageRecognition")
        try container.encode(self.storiesExperiment, forKey: "storiesExperiment")
        try container.encode(self.storiesJpegExperiment, forKey: "storiesJpegExperiment")
        try container.encode(self.crashOnMemoryPressure, forKey: "crashOnMemoryPressure")
        try container.encode(self.dustEffect, forKey: "dustEffect")
        try container.encode(self.disableCallV2, forKey: "disableCallV2")
        try container.encode(self.experimentalCallMute, forKey: "experimentalCallMute")
        try container.encode(self.allowWebViewInspection, forKey: "allowWebViewInspection")
        try container.encode(self.disableReloginTokens, forKey: "disableReloginTokens")
        try container.encode(self.liveStreamV2, forKey: "liveStreamV2")
        try container.encode(self.dynamicStreaming, forKey: "dynamicStreaming")
        try container.encode(self.enableLocalTranslation, forKey: "enableLocalTranslation")
        try container.encodeIfPresent(self.autoBenchmarkReflectors, forKey: "autoBenchmarkReflectors")
        try container.encodeIfPresent(self.playerV2, forKey: "playerV2")
        try container.encodeIfPresent(self.devRequests, forKey: "devRequests")
        try container.encodeIfPresent(self.fakeAds, forKey: "fakeAds")
        try container.encodeIfPresent(self.conferenceDebug, forKey: "conferenceDebug")
        try container.encodeIfPresent(self.checkSerializedData, forKey: "checkSerializedData")
        try container.encodeIfPresent(self.allForumsHaveTabs, forKey: "allForumsHaveTabs")
        try container.encodeIfPresent(self.debugRatingLayout, forKey: "debugRatingLayout")
        try container.encodeIfPresent(self.enableUpdates, forKey: "enableUpdates")
        try container.encodeIfPresent(self.enablePWA, forKey: "enablePWA")
        try container.encodeIfPresent(self.forceClearGlass, forKey: "forceClearGlass")
        try container.encodeIfPresent(self.noLagsEnabled, forKey: "noLagsEnabled")
        try container.encodeIfPresent(self.viewUnread2Read, forKey: "viewUnread2Read")
        try container.encodeIfPresent(self.debugRipple, forKey: "debugRipple")
        try container.encodeIfPresent(self.bogatiUiEnabled, forKey: "bogatiUiEnabled")
        try container.encodeIfPresent(self.hideFailedWarning, forKey: "hideFailedWarning")
        try container.encodeIfPresent(self.sendMode, forKey: "sendMode")
        try container.encodeIfPresent(self.chatListCustomTheme, forKey: "chatListCustomTheme")
    }
}

public func updateExperimentalUISettingsInteractively(accountManager: AccountManager<TelegramAccountManagerTypes>, _ f: @escaping (ExperimentalUISettings) -> ExperimentalUISettings) -> Signal<Void, NoError> {
    return accountManager.transaction { transaction -> Void in
        transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { entry in
            let currentSettings: ExperimentalUISettings
            if let entry = entry?.get(ExperimentalUISettings.self) {
                currentSettings = entry
            } else {
                currentSettings = .defaultSettings
            }
            return SharedPreferencesEntry(f(currentSettings))
        })
    }
}

public let eahatGramChatListThemeEditModeRequestedNotification = Notification.Name("eahatGramChatListThemeEditModeRequestedNotification")

private let eahatGramChatListThemeEditModePending = Atomic<Bool>(value: false)

public func eahatGramRequestChatListThemeEditMode() {
    _ = eahatGramChatListThemeEditModePending.swap(true)
    NotificationCenter.default.post(name: eahatGramChatListThemeEditModeRequestedNotification, object: nil)
}

public func eahatGramConsumeChatListThemeEditModeRequest() -> Bool {
    return eahatGramChatListThemeEditModePending.swap(false)
}
