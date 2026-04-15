import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import AvatarNode

final class EahatGramDebugSettings {
    private static let targetHudEnabledKey = "eahatGram.targetHudEnabled"
    private static let nftUsernameTagKey = "eahatGram.nftUsernameTag"

    static let targetHudEnabled = Atomic<Bool>(value: UserDefaults.standard.object(forKey: targetHudEnabledKey) as? Bool ?? false)
    static let nftUsernameTag = Atomic<String>(value: UserDefaults.standard.string(forKey: nftUsernameTagKey) ?? "")
    static let targetHudOrigin = Atomic<CGPoint?>(value: nil)

    static func setTargetHudEnabled(_ value: Bool) {
        _ = self.targetHudEnabled.modify { _ in
            value
        }
        UserDefaults.standard.set(value, forKey: self.targetHudEnabledKey)
    }

    static func setNftUsernameTag(_ value: String) {
        _ = self.nftUsernameTag.modify { _ in
            value
        }
        UserDefaults.standard.set(value, forKey: self.nftUsernameTagKey)
    }
}

struct EahatGramTargetHudStats: Equatable {
    let giftsCount: Int
    let giftsStarsCount: Int64?
    let nftCount: Int
}

final class EahatGramTargetHudStatsContext {
    private let giftsContext: ProfileGiftsContext
    private let keepUpdatedDisposable = MetaDisposable()
    private let cachedStarGiftsDisposable = MetaDisposable()
    private let giftsStateDisposable = MetaDisposable()

    private var baseGiftPrices: [Int64: Int64]?
    private var currentGiftsState: ProfileGiftsContext.State?

    private let stateValue = ValuePromise<EahatGramTargetHudStats?>(nil, ignoreRepeated: true)
    var state: Signal<EahatGramTargetHudStats?, NoError> {
        return self.stateValue.get()
    }

    init(context: AccountContext, peerId: EnginePeer.Id) {
        self.giftsContext = ProfileGiftsContext(account: context.account, peerId: peerId, filter: .All, limit: 200)

        self.keepUpdatedDisposable.set(context.engine.payments.keepStarGiftsUpdated().start())
        self.cachedStarGiftsDisposable.set((context.engine.payments.cachedStarGifts()
        |> deliverOnMainQueue).start(next: { [weak self] gifts in
            guard let self else {
                return
            }
            var updatedPrices: [Int64: Int64] = [:]
            for gift in gifts ?? [] {
                if case let .generic(baseGift) = gift {
                    updatedPrices[baseGift.id] = baseGift.price
                }
            }
            self.baseGiftPrices = updatedPrices
            self.updateStatsIfReady()
        }))
        self.giftsStateDisposable.set((self.giftsContext.state
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self else {
                return
            }
            self.currentGiftsState = state
            if case let .ready(canLoadMore, _) = state.dataState, canLoadMore {
                self.giftsContext.loadMore()
            }
            self.updateStatsIfReady()
        }))
    }

    deinit {
        self.keepUpdatedDisposable.dispose()
        self.cachedStarGiftsDisposable.dispose()
        self.giftsStateDisposable.dispose()
    }

    private func updateStatsIfReady() {
        guard let currentGiftsState = self.currentGiftsState else {
            return
        }
        guard case let .ready(canLoadMore, _) = currentGiftsState.dataState, !canLoadMore else {
            return
        }

        let gifts = currentGiftsState.gifts
        let hasUniqueGifts = gifts.contains(where: { gift in
            if case .unique = gift.gift {
                return true
            } else {
                return false
            }
        })
        if hasUniqueGifts && self.baseGiftPrices == nil {
            return
        }

        var nftCount = 0
        var giftsStarsCount: Int64 = 0
        var hasMissingGiftPrice = false

        for gift in gifts {
            switch gift.gift {
            case let .generic(baseGift):
                giftsStarsCount += baseGift.price
            case let .unique(uniqueGift):
                nftCount += 1
                if let baseGiftPrice = self.baseGiftPrices?[uniqueGift.giftId] {
                    giftsStarsCount += baseGiftPrice
                } else {
                    hasMissingGiftPrice = true
                }
            }
        }

        self.stateValue.set(EahatGramTargetHudStats(
            giftsCount: gifts.count,
            giftsStarsCount: hasMissingGiftPrice ? nil : giftsStarsCount,
            nftCount: nftCount
        ))
    }
}

final class EahatGramTargetHudNode: ASDisplayNode {
    static let preferredSize = CGSize(width: 220.0, height: 110.0)

    private let outerNode = ASDisplayNode()
    private let innerNode = ASDisplayNode()
    private let avatarFrameNode = ASDisplayNode()
    private let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 16.0))
    private let accentNode = ASDisplayNode()
    private let accentGradientLayer = CAGradientLayer()
    private let nameNode = ImmediateTextNode()
    private let tagNode = ImmediateTextNode()
    private let idNode = ImmediateTextNode()
    private let giftsNode = ImmediateTextNode()
    private let nftNode = ImmediateTextNode()

    var positionUpdated: ((CGPoint) -> Void)?

    private var panStartOrigin: CGPoint = .zero
    private var copiedPeerIdText: String?

    override init() {
        super.init()

        self.isUserInteractionEnabled = true
        self.clipsToBounds = false

        self.outerNode.isUserInteractionEnabled = true
        self.innerNode.isUserInteractionEnabled = true

        self.outerNode.cornerRadius = 6.0
        self.outerNode.borderWidth = UIScreenPixel

        self.innerNode.cornerRadius = 4.0
        self.innerNode.borderWidth = UIScreenPixel

        self.avatarFrameNode.cornerRadius = 3.0
        self.avatarFrameNode.borderWidth = UIScreenPixel
        self.avatarFrameNode.clipsToBounds = true

        self.avatarNode.clipsToBounds = true
        self.avatarNode.cornerRadius = 2.0

        self.accentNode.cornerRadius = 1.5
        self.accentGradientLayer.cornerRadius = 1.5
        self.accentGradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        self.accentGradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        self.accentGradientLayer.masksToBounds = true

        for textNode in [self.nameNode, self.tagNode, self.idNode, self.giftsNode, self.nftNode] {
            textNode.displaysAsynchronously = false
            textNode.maximumNumberOfLines = 1
            textNode.truncationMode = .byTruncatingTail
            textNode.isUserInteractionEnabled = false
        }
        self.idNode.isUserInteractionEnabled = true

        self.addSubnode(self.outerNode)
        self.outerNode.addSubnode(self.innerNode)
        self.innerNode.addSubnode(self.avatarFrameNode)
        self.avatarFrameNode.addSubnode(self.avatarNode)
        self.innerNode.addSubnode(self.accentNode)
        self.accentNode.layer.addSublayer(self.accentGradientLayer)
        self.innerNode.addSubnode(self.nameNode)
        self.innerNode.addSubnode(self.tagNode)
        self.innerNode.addSubnode(self.idNode)
        self.innerNode.addSubnode(self.giftsNode)
        self.innerNode.addSubnode(self.nftNode)
    }

    override func didLoad() {
        super.didLoad()

        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
        self.view.addGestureRecognizer(recognizer)

        let idTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleIdTap))
        self.idNode.view.addGestureRecognizer(idTapRecognizer)
    }

    func update(
        context: AccountContext,
        theme: PresentationTheme,
        peer: EnginePeer,
        username: String?,
        peerId: Int64,
        dcId: Int?,
        stats: EahatGramTargetHudStats?
    ) {
        self.outerNode.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 0.96)
        self.outerNode.borderColor = UIColor(red: 0.27, green: 0.27, blue: 0.27, alpha: 1.0).cgColor

        self.innerNode.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 0.98)
        self.innerNode.borderColor = UIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1.0).cgColor

        self.avatarFrameNode.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1.0)
        self.avatarFrameNode.borderColor = UIColor(red: 0.24, green: 0.24, blue: 0.24, alpha: 1.0).cgColor

        self.accentGradientLayer.colors = [
            UIColor(red: 1.00, green: 0.18, blue: 0.18, alpha: 1.0).cgColor,
            UIColor(red: 1.00, green: 0.58, blue: 0.10, alpha: 1.0).cgColor,
            UIColor(red: 1.00, green: 0.92, blue: 0.16, alpha: 1.0).cgColor,
            UIColor(red: 0.15, green: 0.86, blue: 0.28, alpha: 1.0).cgColor,
            UIColor(red: 0.10, green: 0.78, blue: 0.96, alpha: 1.0).cgColor,
            UIColor(red: 0.24, green: 0.36, blue: 1.00, alpha: 1.0).cgColor,
            UIColor(red: 0.66, green: 0.26, blue: 1.00, alpha: 1.0).cgColor,
            UIColor(red: 1.00, green: 0.18, blue: 0.18, alpha: 1.0).cgColor
        ]
        self.accentGradientLayer.locations = [0.0, 0.14, 0.28, 0.42, 0.56, 0.7, 0.84, 1.0]
        self.ensureAccentAnimation()

        let nftUsernameTag = EahatGramDebugSettings.nftUsernameTag.with { $0 }.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = nftUsernameTag.isEmpty ? peer.compactDisplayTitle : "\(peer.compactDisplayTitle) \(nftUsernameTag)"
        self.nameNode.attributedText = NSAttributedString(
            string: displayTitle,
            font: Font.semibold(18.0),
            textColor: .white
        )
        self.tagNode.attributedText = NSAttributedString(
            string: username.flatMap { "@\($0)" } ?? "-",
            font: Font.regular(11.0),
            textColor: UIColor(red: 0.86, green: 0.86, blue: 0.86, alpha: 1.0)
        )
        self.copiedPeerIdText = "\(peerId)"
        let dcText = dcId.map { "dc \($0)" } ?? "dc ?"
        self.idNode.attributedText = NSAttributedString(
            string: "id \(peerId) \(dcText)",
            font: Font.with(size: 11.0, weight: .medium, traits: .monospacedNumbers),
            textColor: UIColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1.0)
        )

        let giftsText: String
        let nftText: String
        if let stats {
            let starsText: String
            if let giftsStarsCount = stats.giftsStarsCount {
                starsText = "\(giftsStarsCount)"
            } else {
                starsText = "?"
            }
            giftsText = "gifts: \(stats.giftsCount) | \(starsText) stars"
            nftText = "nft: \(stats.nftCount)"
        } else {
            giftsText = "gifts: loading"
            nftText = "nft: loading"
        }

        self.giftsNode.attributedText = NSAttributedString(
            string: giftsText,
            font: Font.with(size: 11.0, weight: .medium, traits: .monospacedNumbers),
            textColor: UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1.0)
        )
        self.nftNode.attributedText = NSAttributedString(
            string: nftText,
            font: Font.with(size: 11.0, weight: .medium, traits: .monospacedNumbers),
            textColor: UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1.0)
        )

        self.avatarNode.setPeer(
            context: context,
            theme: theme,
            peer: peer,
            clipStyle: .roundedRect,
            synchronousLoad: false,
            displayDimensions: CGSize(width: 54.0, height: 54.0)
        )

        self.setNeedsLayout()
    }

    func updateFrame(origin: CGPoint) {
        self.frame = CGRect(origin: origin, size: Self.preferredSize)
        self.setNeedsLayout()
    }

    override func layout() {
        super.layout()

        self.outerNode.frame = self.bounds
        self.innerNode.frame = self.bounds.insetBy(dx: 6.0, dy: 6.0)

        self.avatarFrameNode.frame = CGRect(x: 8.0, y: 8.0, width: 58.0, height: 58.0)
        self.avatarNode.frame = self.avatarFrameNode.bounds.insetBy(dx: 2.0, dy: 2.0)

        let textOriginX: CGFloat = 76.0
        let textWidth = self.innerNode.bounds.width - textOriginX - 8.0

        let nameSize = self.nameNode.updateLayout(CGSize(width: textWidth, height: 24.0))
        self.nameNode.frame = CGRect(origin: CGPoint(x: textOriginX, y: 6.0), size: nameSize)

        self.accentNode.frame = CGRect(x: textOriginX, y: 31.0, width: min(textWidth, 120.0), height: 3.0)
        self.accentGradientLayer.frame = self.accentNode.bounds

        let tagSize = self.tagNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.tagNode.frame = CGRect(origin: CGPoint(x: textOriginX, y: 39.0), size: tagSize)

        let idSize = self.idNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.idNode.frame = CGRect(origin: CGPoint(x: textOriginX, y: 54.0), size: idSize)

        let giftsSize = self.giftsNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.giftsNode.frame = CGRect(origin: CGPoint(x: textOriginX, y: 69.0), size: giftsSize)

        let nftSize = self.nftNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.nftNode.frame = CGRect(origin: CGPoint(x: textOriginX, y: 84.0), size: nftSize)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let superview = self.view.superview else {
            return
        }

        switch recognizer.state {
        case .began:
            self.panStartOrigin = self.frame.origin
        case .changed, .ended:
            let translation = recognizer.translation(in: superview)
            var origin = CGPoint(
                x: self.panStartOrigin.x + translation.x,
                y: self.panStartOrigin.y + translation.y
            )
            origin = self.clampedOrigin(origin, in: superview)
            self.frame.origin = origin
            self.positionUpdated?(origin)
        default:
            break
        }
    }

    @objc private func handleIdTap() {
        guard let copiedPeerIdText = self.copiedPeerIdText else {
            return
        }
        UIPasteboard.general.string = copiedPeerIdText
        self.idNode.layer.animateAlpha(from: 0.35, to: 1.0, duration: 0.2)
    }

    private func ensureAccentAnimation() {
        if self.accentGradientLayer.animation(forKey: "eahatGramAccentLocations") != nil {
            return
        }
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.35, -0.2, -0.05, 0.1, 0.25, 0.4, 0.55, 0.7]
        animation.toValue = [0.3, 0.45, 0.6, 0.75, 0.9, 1.05, 1.2, 1.35]
        animation.duration = 2.0
        animation.repeatCount = .infinity
        animation.autoreverses = false
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        self.accentGradientLayer.add(animation, forKey: "eahatGramAccentLocations")
    }

    private func clampedOrigin(_ origin: CGPoint, in superview: UIView) -> CGPoint {
        let safeInsets = superview.safeAreaInsets
        let minX = safeInsets.left + 8.0
        let minY = safeInsets.top + 8.0
        let maxX = max(minX, superview.bounds.width - safeInsets.right - Self.preferredSize.width - 8.0)
        let maxY = max(minY, superview.bounds.height - safeInsets.bottom - Self.preferredSize.height - 8.0)

        return CGPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }
}
