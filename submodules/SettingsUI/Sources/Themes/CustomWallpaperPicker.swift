import Foundation
import UIKit
import Display
import AccountContext

private let eahatGramCustomWallpaperPathDefaultsKey = "eahatGram.customWallpaper.path"
private let eahatGramCustomWallpaperKindDefaultsKey = "eahatGram.customWallpaper.kind"
private let eahatGramCustomWallpaperDidChangeNotificationName = Notification.Name("eahatGram.customWallpaperDidChange")

private final class EahatGramCustomWallpaperPickerController: ViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private var didPresentPicker = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !self.didPresentPicker {
            self.didPresentPicker = true
            self.presentPicker()
        }
    }

    private func presentPicker() {
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
            self.dismiss(animated: true)
            return
        }

        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.delegate = self
        picker.allowsEditing = false
        self.present(picker, animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true, completion: { [weak self] in
            self?.dismiss(animated: true)
        })
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let mediaType = info[.mediaType] as? String
        if mediaType == "public.movie", let url = info[.mediaURL] as? URL {
            self.storeVideo(url: url)
        } else if let image = info[.originalImage] as? UIImage {
            self.storeImage(image: image)
        }

        picker.dismiss(animated: true, completion: { [weak self] in
            self?.dismiss(animated: true)
        })
    }

    private func wallpaperDirectory() -> URL? {
        guard let baseUrl = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = baseUrl.appendingPathComponent("eahatGram/Wallpaper", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    private func storeVideo(url: URL) {
        guard let directory = self.wallpaperDirectory() else {
            return
        }
        let destinationUrl = directory.appendingPathComponent("custom-wallpaper.mov")
        do {
            if FileManager.default.fileExists(atPath: destinationUrl.path) {
                try FileManager.default.removeItem(at: destinationUrl)
            }
            try FileManager.default.copyItem(at: url, to: destinationUrl)
            UserDefaults.standard.set(destinationUrl.path, forKey: eahatGramCustomWallpaperPathDefaultsKey)
            UserDefaults.standard.set("video", forKey: eahatGramCustomWallpaperKindDefaultsKey)
            NotificationCenter.default.post(name: eahatGramCustomWallpaperDidChangeNotificationName, object: nil)
        } catch {
        }
    }

    private func storeImage(image: UIImage) {
        guard let directory = self.wallpaperDirectory(), let data = image.jpegData(compressionQuality: 0.94) else {
            return
        }
        let destinationUrl = directory.appendingPathComponent("custom-wallpaper.jpg")
        do {
            try data.write(to: destinationUrl, options: .atomic)
            UserDefaults.standard.set(destinationUrl.path, forKey: eahatGramCustomWallpaperPathDefaultsKey)
            UserDefaults.standard.set("image", forKey: eahatGramCustomWallpaperKindDefaultsKey)
            NotificationCenter.default.post(name: eahatGramCustomWallpaperDidChangeNotificationName, object: nil)
        } catch {
        }
    }
}

public func presentCustomWallpaperPicker(context: AccountContext, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void) {
    _ = context
    _ = push
    present(EahatGramCustomWallpaperPickerController(navigationBarPresentationData: nil))
}
