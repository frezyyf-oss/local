import UIKit

/// Helper for safe UIScreen access on iOS 26+
/// UIScreen.main was removed in iOS 26
public enum UIScreenCompat {
    
    /// Returns the scale of the main screen
    public static var mainScreenScale: CGFloat {
        if #available(iOS 26.0, *) {
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first {
                return window.screen.scale
            }
            return UITraitCollection.current.displayScale
        } else {
            return UIScreen.main.scale
        }
    }
    
    /// Returns the bounds of the main screen
    public static var mainScreenBounds: CGRect {
        if #available(iOS 26.0, *) {
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first {
                return window.screen.bounds
            }
            // Fallback to first scene bounds
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                return scene.coordinateSpace.bounds
            }
            return .zero
        } else {
            return UIScreen.main.bounds
        }
    }
    
    /// Returns the brightness of the main screen
    public static var mainScreenBrightness: CGFloat {
        if #available(iOS 26.0, *) {
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first {
                return window.screen.brightness
            }
            return 0.5 // Default brightness fallback
        } else {
            return UIScreen.main.brightness
        }
    }
    
    /// Returns the display corner radius of the main screen
    public static var mainScreenDisplayCornerRadius: CGFloat {
        if #available(iOS 26.0, *) {
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first {
                return window.screen.displayCornerRadius
            }
            return 0.0
        } else {
            return UIScreen.main.displayCornerRadius
        }
    }
}
