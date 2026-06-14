import UIKit

public enum UIScreenCompat {
    public static var mainScreenScale: CGFloat {
        return UIScreen.main.scale
    }

    public static var mainScreenBounds: CGRect {
        return UIScreen.main.bounds
    }

    public static var mainScreenBrightness: CGFloat {
        return UIScreen.main.brightness
    }
}
