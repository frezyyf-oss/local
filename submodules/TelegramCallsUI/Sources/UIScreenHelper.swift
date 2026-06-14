import UIKit

func getMainScreenScale() -> CGFloat {
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

func getMainScreenBounds() -> CGRect {
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
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return scene.coordinateSpace.bounds
        }
        return .zero
    } else {
        return UIScreen.main.bounds
    }
}
