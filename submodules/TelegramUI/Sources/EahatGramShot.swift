import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import UndoUI
import ChatMessageItem
import ChatMessageItemView

private struct EahatGramShotMessage {
    let text: String
    let frame: CGRect
    let originalIncoming: Bool
}

extension ChatControllerImpl {
    func eahatGramMakeShot() {
        self.chatDisplayNode.dismissInput()
        self.navigationActionDisposable.set((self.context.account.postbox.loadedPeerWithId(self.context.account.peerId)
        |> deliverOnMainQueue).startStrict(next: { [weak self] accountPeer in
            guard let self else {
                return
            }
            let accountTitle = EnginePeer(accountPeer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)
            let messages = self.eahatGramCollectVisibleShotMessages()
            guard !messages.isEmpty else {
                self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: "No visible messages for shot", timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
                    return false
                }), in: .current)
                return
            }
            let image = self.eahatGramRenderShot(accountTitle: accountTitle, messages: messages)
            UIPasteboard.general.image = image
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .copy(text: "shot copied"), elevatedLayout: false, animateInAsReplacement: false, action: { _ in
                return false
            }), in: .current)
        }))
    }

    private func eahatGramCollectVisibleShotMessages() -> [EahatGramShotMessage] {
        var result: [EahatGramShotMessage] = []
        let accountPeerId = self.context.account.peerId
        let visibleBounds = self.view.bounds.insetBy(dx: 0.0, dy: -80.0)

        self.chatDisplayNode.historyNode.forEachVisibleItemNode { itemNode in
            guard let itemNode = itemNode as? ChatMessageItemView, let item = itemNode.item else {
                return
            }

            var parts: [String] = []
            for (message, _) in item.content {
                if let text = eahatGramShotText(for: message), !text.isEmpty {
                    parts.append(text)
                }
            }
            let text = parts.joined(separator: "\n")
            guard !text.isEmpty else {
                return
            }

            let frame = itemNode.view.convert(itemNode.view.bounds, to: self.view)
            guard frame.intersects(visibleBounds) else {
                return
            }

            result.append(EahatGramShotMessage(
                text: text,
                frame: frame,
                originalIncoming: item.content.effectivelyIncoming(accountPeerId, associatedData: item.associatedData)
            ))
        }

        return result.sorted(by: { lhs, rhs in
            if abs(lhs.frame.minY - rhs.frame.minY) > 1.0 {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        })
    }

    private func eahatGramRenderShot(accountTitle: String, messages: [EahatGramShotMessage]) -> UIImage {
        let size = self.view.bounds.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cgContext = context.cgContext
            let theme = self.presentationData.theme
            let bounds = CGRect(origin: .zero, size: size)
            let statusBarHeight = self.validLayout?.statusBarHeight ?? self.view.safeAreaInsets.top
            let navigationBarHeight = max(self.navigationBar?.backgroundNode.bounds.height ?? (statusBarHeight + 44.0), statusBarHeight + 44.0)
            let safeInsets = self.validLayout?.safeInsets ?? self.view.safeAreaInsets
            let inputPanelFrame = self.chatDisplayNode.inputPanelBackgroundNode.view.convert(self.chatDisplayNode.inputPanelBackgroundNode.bounds, to: self.view)
            let inputPanelTop: CGFloat
            if inputPanelFrame.height > 1.0 && inputPanelFrame.minY > navigationBarHeight {
                inputPanelTop = min(size.height, inputPanelFrame.minY)
            } else {
                inputPanelTop = max(navigationBarHeight, size.height - max(56.0 + safeInsets.bottom, 56.0))
            }
            let contentBottom = max(navigationBarHeight + 1.0, inputPanelTop)

            theme.list.plainBackgroundColor.setFill()
            cgContext.fill(bounds)

            theme.chat.inputPanel.panelBackgroundColorNoWallpaper.setFill()
            cgContext.fill(CGRect(x: 0.0, y: inputPanelTop, width: size.width, height: size.height - inputPanelTop))

            eahatGramDrawNavigationBar(
                context: cgContext,
                size: size,
                navigationBarHeight: navigationBarHeight,
                statusBarHeight: statusBarHeight,
                title: accountTitle,
                theme: theme
            )

            eahatGramDrawMessages(
                context: cgContext,
                messages: messages,
                size: size,
                top: navigationBarHeight,
                bottom: contentBottom,
                safeInsets: safeInsets,
                theme: theme
            )

            eahatGramDrawInputPanel(
                context: cgContext,
                size: size,
                top: inputPanelTop,
                safeInsets: safeInsets,
                placeholder: self.presentationData.strings.Conversation_InputTextPlaceholder,
                theme: theme
            )
        }
    }
}

private func eahatGramShotText(for message: Message) -> String? {
    let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedText.isEmpty {
        return trimmedText
    }

    for media in message.media {
        if media is TelegramMediaImage {
            return "Photo"
        }
        if let file = media as? TelegramMediaFile {
            if file.isVoice {
                return "Voice message"
            }
            if file.isInstantVideo {
                return "Video message"
            }
            if file.isVideo {
                return "Video"
            }
            if file.isSticker || file.isAnimatedSticker || file.isVideoSticker {
                return "Sticker"
            }
            return "File"
        }
        if media is TelegramMediaMap {
            return "Location"
        }
    }

    return nil
}

private func eahatGramDrawNavigationBar(context: CGContext, size: CGSize, navigationBarHeight: CGFloat, statusBarHeight: CGFloat, title: String, theme: PresentationTheme) {
    theme.rootController.navigationBar.opaqueBackgroundColor.setFill()
    context.fill(CGRect(x: 0.0, y: 0.0, width: size.width, height: navigationBarHeight))

    theme.rootController.navigationBar.separatorColor.setFill()
    context.fill(CGRect(x: 0.0, y: navigationBarHeight - 1.0 / UIScreen.main.scale, width: size.width, height: 1.0 / UIScreen.main.scale))

    let titleFont = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: theme.rootController.navigationBar.primaryTextColor
    ]
    let titleSize = (title as NSString).boundingRect(
        with: CGSize(width: max(10.0, size.width - 160.0), height: 24.0),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: titleAttributes,
        context: nil
    ).size
    let titleRect = CGRect(
        x: floor((size.width - ceil(titleSize.width)) / 2.0),
        y: statusBarHeight + floor((navigationBarHeight - statusBarHeight - 24.0) / 2.0),
        width: ceil(titleSize.width),
        height: 24.0
    )
    (title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: titleAttributes, context: nil)

    let backColor = theme.rootController.navigationBar.buttonColor
    backColor.setStroke()
    context.setLineWidth(2.0)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 19.0, y: statusBarHeight + 22.0))
    context.addLine(to: CGPoint(x: 10.0, y: statusBarHeight + 31.0))
    context.addLine(to: CGPoint(x: 19.0, y: statusBarHeight + 40.0))
    context.strokePath()
}

private func eahatGramDrawMessages(context: CGContext, messages: [EahatGramShotMessage], size: CGSize, top: CGFloat, bottom: CGFloat, safeInsets: UIEdgeInsets, theme: PresentationTheme) {
    let horizontalInset: CGFloat = 8.0
    let maxBubbleWidth = min(320.0, max(120.0, size.width * 0.72))
    var lastMaxY = top + 8.0

    for message in messages {
        let displayIncoming = !message.originalIncoming
        let bubbleTheme = displayIncoming ? theme.chat.message.incoming : theme.chat.message.outgoing
        let fillColor = bubbleTheme.bubble.withoutWallpaper.fill.first ?? (displayIncoming ? UIColor(white: 0.94, alpha: 1.0) : theme.rootController.navigationBar.buttonColor)
        let textColor = bubbleTheme.primaryTextColor
        let font = UIFont.systemFont(ofSize: 16.0)
        let textInsets = UIEdgeInsets(top: 7.0, left: 12.0, bottom: 8.0, right: 12.0)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        let textBounds = (message.text as NSString).boundingRect(
            with: CGSize(width: maxBubbleWidth - textInsets.left - textInsets.right, height: 1000.0),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes,
            context: nil
        ).integral
        let bubbleWidth = min(maxBubbleWidth, max(44.0, textBounds.width + textInsets.left + textInsets.right))
        let bubbleHeight = max(34.0, textBounds.height + textInsets.top + textInsets.bottom)
        var bubbleY = max(message.frame.minY, lastMaxY)
        if bubbleY + bubbleHeight > bottom - 8.0 {
            bubbleY = bottom - 8.0 - bubbleHeight
        }
        guard bubbleY >= top + 4.0, bubbleY + bubbleHeight <= bottom - 4.0 else {
            continue
        }

        let bubbleX: CGFloat
        if displayIncoming {
            bubbleX = safeInsets.left + horizontalInset
        } else {
            bubbleX = size.width - safeInsets.right - horizontalInset - bubbleWidth
        }
        let bubbleRect = CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight)
        fillColor.setFill()
        UIBezierPath(roundedRect: bubbleRect, cornerRadius: 17.0).fill()

        let textRect = bubbleRect.inset(by: textInsets)
        (message.text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: textAttributes, context: nil)
        lastMaxY = bubbleRect.maxY + 5.0
    }
}

private func eahatGramDrawInputPanel(context: CGContext, size: CGSize, top: CGFloat, safeInsets: UIEdgeInsets, placeholder: String, theme: PresentationTheme) {
    let panel = theme.chat.inputPanel
    panel.panelSeparatorColor.setFill()
    context.fill(CGRect(x: 0.0, y: top, width: size.width, height: 1.0 / UIScreen.main.scale))

    let fieldHeight: CGFloat = 36.0
    let fieldY = top + 7.0
    let leftInset = safeInsets.left + 44.0
    let rightInset = safeInsets.right + 52.0
    let fieldRect = CGRect(x: leftInset, y: fieldY, width: max(40.0, size.width - leftInset - rightInset), height: fieldHeight)

    panel.inputBackgroundColor.setFill()
    UIBezierPath(roundedRect: fieldRect, cornerRadius: fieldHeight / 2.0).fill()
    panel.inputStrokeColor.setStroke()
    UIBezierPath(roundedRect: fieldRect, cornerRadius: fieldHeight / 2.0).stroke()

    let placeholderAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 16.0),
        .foregroundColor: panel.inputPlaceholderColor
    ]
    (placeholder as NSString).draw(
        with: CGRect(x: fieldRect.minX + 14.0, y: fieldRect.minY + 8.0, width: fieldRect.width - 28.0, height: 22.0),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: placeholderAttributes,
        context: nil
    )

    panel.inputControlColor.setStroke()
    context.setLineWidth(2.0)
    context.strokeEllipse(in: CGRect(x: safeInsets.left + 13.0, y: fieldY + 7.0, width: 21.0, height: 21.0))
    panel.panelControlAccentColor.setFill()
    context.fillEllipse(in: CGRect(x: size.width - safeInsets.right - 36.0, y: fieldY + 5.0, width: 26.0, height: 26.0))
}
