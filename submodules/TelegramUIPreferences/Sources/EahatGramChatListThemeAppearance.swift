import Foundation
import UIKit
import Display
import GradientBackground

public func eahatGramChatListColorFromArgb(_ argb: UInt32) -> UIColor {
    let alpha = CGFloat((argb >> 24) & 0xff) / 255.0
    let red = CGFloat((argb >> 16) & 0xff) / 255.0
    let green = CGFloat((argb >> 8) & 0xff) / 255.0
    let blue = CGFloat(argb & 0xff) / 255.0
    return UIColor(red: red, green: green, blue: blue, alpha: alpha)
}

public func eahatGramChatListArgbFromColor(_ color: UIColor) -> UInt32 {
    var red: CGFloat = 0.0
    var green: CGFloat = 0.0
    var blue: CGFloat = 0.0
    var alpha: CGFloat = 0.0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (UInt32(alpha * 255.0) << 24)
        | (UInt32(red * 255.0) << 16)
        | (UInt32(green * 255.0) << 8)
        | UInt32(blue * 255.0)
}

public func eahatGramChatListBogatiColor(
    for element: ExperimentalUISettings.ChatListCustomThemeElement,
    isDark: Bool
) -> UIColor {
    switch element {
    case .header:
        return isDark ? UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.94) : UIColor(red: 0.89, green: 0.94, blue: 1.00, alpha: 0.96)
    case .foldersStrip:
        return isDark ? UIColor(red: 0.14, green: 0.18, blue: 0.23, alpha: 0.92) : UIColor(red: 0.86, green: 0.92, blue: 0.99, alpha: 0.94)
    case .selectedFolder:
        return isDark ? UIColor(red: 0.22, green: 0.52, blue: 0.94, alpha: 0.98) : UIColor(red: 0.24, green: 0.56, blue: 0.98, alpha: 0.96)
    case .listBackground:
        return isDark ? UIColor(red: 0.09, green: 0.11, blue: 0.14, alpha: 1.0) : UIColor(red: 0.95, green: 0.98, blue: 1.0, alpha: 1.0)
    case .rowBackground:
        return isDark ? UIColor(red: 0.13, green: 0.16, blue: 0.20, alpha: 0.94) : UIColor(red: 0.91, green: 0.96, blue: 1.0, alpha: 0.96)
    case .rootTabBarBackground:
        return isDark ? UIColor(red: 0.12, green: 0.15, blue: 0.20, alpha: 0.94) : UIColor(red: 0.89, green: 0.94, blue: 1.0, alpha: 0.96)
    case .rootTabBarItemBackground:
        return isDark ? UIColor(red: 0.18, green: 0.22, blue: 0.29, alpha: 0.88) : UIColor(red: 0.82, green: 0.90, blue: 1.0, alpha: 0.90)
    case .rootTabBarSelectedItemBackground:
        return isDark ? UIColor(red: 0.22, green: 0.52, blue: 0.94, alpha: 0.98) : UIColor(red: 0.24, green: 0.56, blue: 0.98, alpha: 0.96)
    case .rootTabBarSearchBackground:
        return isDark ? UIColor(red: 0.14, green: 0.18, blue: 0.24, alpha: 0.92) : UIColor(red: 0.86, green: 0.92, blue: 0.99, alpha: 0.94)
    }
}

public func eahatGramChatListThemeStaticColor(
    _ value: ExperimentalUISettings.ChatListCustomThemeValue,
    isDark: Bool
) -> UIColor? {
    switch value.preset {
    case .none:
        return nil
    case .rgb:
        if let argb = value.argb {
            return eahatGramChatListColorFromArgb(argb)
        } else {
            return nil
        }
    case .rainbow:
        return isDark ? UIColor(red: 0.54, green: 0.19, blue: 0.96, alpha: 0.92) : UIColor(red: 0.76, green: 0.36, blue: 0.99, alpha: 0.92)
    case .asfalo:
        return isDark ? UIColor(red: 0.19, green: 0.21, blue: 0.24, alpha: 0.96) : UIColor(red: 0.33, green: 0.35, blue: 0.38, alpha: 0.92)
    case .asfolo:
        return isDark ? UIColor(red: 0.14, green: 0.48, blue: 0.84, alpha: 0.92) : UIColor(red: 0.24, green: 0.64, blue: 0.95, alpha: 0.90)
    }
}

public func eahatGramChatListThemeGradientColors(
    _ value: ExperimentalUISettings.ChatListCustomThemeValue,
    isDark: Bool
) -> [UIColor]? {
    switch value.preset {
    case .none, .rgb:
        return nil
    case .rainbow:
        return [
            UIColor(red: 1.00, green: 0.24, blue: 0.37, alpha: 0.96),
            UIColor(red: 1.00, green: 0.64, blue: 0.22, alpha: 0.96),
            UIColor(red: 0.97, green: 0.87, blue: 0.27, alpha: 0.96),
            UIColor(red: 0.23, green: 0.86, blue: 0.42, alpha: 0.96),
            UIColor(red: 0.19, green: 0.64, blue: 1.00, alpha: 0.96),
            UIColor(red: 0.70, green: 0.33, blue: 1.00, alpha: 0.96)
        ]
    case .asfalo:
        if isDark {
            return [
                UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 0.98),
                UIColor(red: 0.18, green: 0.20, blue: 0.23, alpha: 0.98),
                UIColor(red: 0.24, green: 0.25, blue: 0.28, alpha: 0.98),
                UIColor(red: 0.15, green: 0.17, blue: 0.20, alpha: 0.98)
            ]
        } else {
            return [
                UIColor(red: 0.39, green: 0.40, blue: 0.43, alpha: 0.96),
                UIColor(red: 0.52, green: 0.53, blue: 0.56, alpha: 0.96),
                UIColor(red: 0.41, green: 0.43, blue: 0.46, alpha: 0.96),
                UIColor(red: 0.34, green: 0.36, blue: 0.39, alpha: 0.96)
            ]
        }
    case .asfolo:
        return [
            UIColor(red: 0.11, green: 0.68, blue: 0.89, alpha: 0.95),
            UIColor(red: 0.19, green: 0.86, blue: 0.63, alpha: 0.95),
            UIColor(red: 0.73, green: 0.93, blue: 0.30, alpha: 0.95),
            UIColor(red: 0.99, green: 0.74, blue: 0.22, alpha: 0.95),
            UIColor(red: 0.86, green: 0.26, blue: 0.75, alpha: 0.95)
        ]
    }
}

public func eahatGramResolvedChatListThemeValue(
    settings: ExperimentalUISettings,
    element: ExperimentalUISettings.ChatListCustomThemeElement,
    isDark: Bool
) -> ExperimentalUISettings.ChatListCustomThemeValue? {
    let value = settings.chatListCustomTheme.value(for: element)
    if value.preset != .none {
        return value
    }
    if settings.bogatiUiEnabled {
        return ExperimentalUISettings.ChatListCustomThemeValue(
            preset: .rgb,
            argb: eahatGramChatListArgbFromColor(
                eahatGramChatListBogatiColor(for: element, isDark: isDark)
            )
        )
    }
    return nil
}

private func eahatGramChatListThemeAnimationDuration(
    for preset: ExperimentalUISettings.ChatListCustomThemePreset
) -> Double {
    switch preset {
    case .asfalo:
        return 8.0
    case .rainbow, .asfolo:
        return 5.0
    case .none, .rgb:
        return 0.0
    }
}

public final class EahatGramChatListThemeBackgroundView: UIView {
    private let staticBackgroundView: UIView
    private var gradientBackgroundNode: GradientBackgroundNode?
    private var currentValue: ExperimentalUISettings.ChatListCustomThemeValue?
    private var currentIsDark: Bool = false
    private var isAnimating = false
    private var animationBackwards = false

    public override init(frame: CGRect) {
        self.staticBackgroundView = UIView()

        super.init(frame: frame)

        self.isUserInteractionEnabled = false
        self.clipsToBounds = true
        self.addSubview(self.staticBackgroundView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        self.staticBackgroundView.frame = self.bounds
        self.gradientBackgroundNode?.view.frame = self.bounds
        self.gradientBackgroundNode?.updateLayout(
            size: self.bounds.size,
            transition: .immediate,
            extendAnimation: false,
            backwards: false,
            completion: {}
        )
        self.updateCornerRadius()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()

        if self.window == nil {
            self.isAnimating = false
        } else {
            self.restartAnimationIfNeeded()
        }
    }

    public func update(
        value: ExperimentalUISettings.ChatListCustomThemeValue?,
        isDark: Bool,
        cornerRadius: CGFloat
    ) {
        let previousPreset = self.currentValue?.preset
        let previousArgb = self.currentValue?.argb
        self.currentValue = value
        self.currentIsDark = isDark

        let staticColor = value.flatMap { eahatGramChatListThemeStaticColor($0, isDark: isDark) }
        self.staticBackgroundView.backgroundColor = staticColor ?? UIColor.clear

        if let value, let colors = eahatGramChatListThemeGradientColors(value, isDark: isDark) {
            let gradientBackgroundNode: GradientBackgroundNode
            if let current = self.gradientBackgroundNode {
                gradientBackgroundNode = current
            } else {
                gradientBackgroundNode = createGradientBackgroundNode(colors: colors, useSharedAnimationPhase: true)
                self.gradientBackgroundNode = gradientBackgroundNode
                gradientBackgroundNode.isUserInteractionEnabled = false
                self.insertSubview(gradientBackgroundNode.view, at: 0)
            }
            gradientBackgroundNode.view.isHidden = false
            gradientBackgroundNode.updateColors(colors: colors)
            gradientBackgroundNode.view.frame = self.bounds
            gradientBackgroundNode.updateLayout(
                size: self.bounds.size,
                transition: .immediate,
                extendAnimation: false,
                backwards: false,
                completion: {}
            )
        } else if let gradientBackgroundNode = self.gradientBackgroundNode {
            gradientBackgroundNode.view.removeFromSuperview()
            self.gradientBackgroundNode = nil
        }

        self.layer.cornerRadius = cornerRadius
        self.updateCornerRadius()

        if previousPreset != value?.preset || previousArgb != value?.argb {
            self.isAnimating = false
        }
        self.restartAnimationIfNeeded()
    }

    private func updateCornerRadius() {
        self.staticBackgroundView.layer.cornerRadius = self.layer.cornerRadius
        self.gradientBackgroundNode?.view.layer.cornerRadius = self.layer.cornerRadius
        self.gradientBackgroundNode?.view.clipsToBounds = true
    }

    private func restartAnimationIfNeeded() {
        guard self.window != nil, let value = self.currentValue, eahatGramChatListThemeGradientColors(value, isDark: self.currentIsDark) != nil else {
            self.isAnimating = false
            return
        }
        guard !self.isAnimating else {
            return
        }
        self.isAnimating = true
        self.animationBackwards = false
        self.enqueueNextAnimationStep()
    }

    private func enqueueNextAnimationStep() {
        guard
            self.isAnimating,
            self.window != nil,
            let gradientBackgroundNode = self.gradientBackgroundNode,
            let value = self.currentValue
        else {
            self.isAnimating = false
            return
        }

        gradientBackgroundNode.animateEvent(
            transition: .animated(duration: eahatGramChatListThemeAnimationDuration(for: value.preset), curve: .linear),
            extendAnimation: true,
            backwards: self.animationBackwards,
            completion: { [weak self] in
                guard let self, self.isAnimating else {
                    return
                }
                self.animationBackwards.toggle()
                self.enqueueNextAnimationStep()
            }
        )
    }
}
