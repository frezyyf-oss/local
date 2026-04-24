import Foundation
import UIKit
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import Display
import LegacyComponents
import PresentationDataUtils

private enum EahatGramPickerSection: Int32 {
    case main
}

private final class EahatGramPickerArguments {
    let select: (Int) -> Void

    init(select: @escaping (Int) -> Void) {
        self.select = select
    }
}

private enum EahatGramPickerEntry: ItemListNodeEntry {
    case option(Int, String, Bool)

    var section: ItemListSectionId {
        return EahatGramPickerSection.main.rawValue
    }

    var stableId: Int {
        switch self {
        case let .option(index, _, _):
            return index
        }
    }

    static func ==(lhs: EahatGramPickerEntry, rhs: EahatGramPickerEntry) -> Bool {
        switch lhs {
        case let .option(lhsIndex, lhsText, lhsSelected):
            if case let .option(rhsIndex, rhsText, rhsSelected) = rhs {
                return lhsIndex == rhsIndex && lhsText == rhsText && lhsSelected == rhsSelected
            } else {
                return false
            }
        }
    }

    static func <(lhs: EahatGramPickerEntry, rhs: EahatGramPickerEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! EahatGramPickerArguments
        switch self {
        case let .option(index, text, selected):
            return ItemListCheckboxItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: text,
                style: .left,
                checked: selected,
                zeroSeparatorInsets: false,
                sectionId: self.section,
                action: {
                    arguments.select(index)
                }
            )
        }
    }
}

private func eahatGramPickerScreen(
    context: AccountContext,
    title: String,
    options: [String],
    selectedIndex: Int?,
    apply: @escaping (Int) -> Void
) -> ViewController {
    let arguments = EahatGramPickerArguments(select: apply)
    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [EahatGramPickerEntry] = []
        for i in 0 ..< options.count {
            entries.append(.option(i, options[i], selectedIndex == i))
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}

private enum EahatGramAddGiftSection: Int32 {
    case assets
    case params
    case flags
    case actions
    case status
}

private struct EahatGramAddGiftAssets: Equatable {
    var baseGifts: [TelegramCore.StarGift.Gift] = []
    var models: [TelegramCore.StarGift.UniqueGift.Attribute] = []
    var backdrops: [TelegramCore.StarGift.UniqueGift.Attribute] = []
    var symbols: [TelegramCore.StarGift.UniqueGift.Attribute] = []
}

private struct EahatGramAddGiftDraft: Equatable {
    var selectedGiftId: Int64?
    var selectedModelIndex: Int?
    var selectedBackdropIndex: Int?
    var selectedSymbolIndex: Int?
    var numberText: String
    var customTitleText: String
    var customSlugText: String
    var customAvatarText: String
    var customPriceText: String
    var customTotalText: String
    var advancedEnabled: Bool
    var commentText: String
    var fromTagText: String
    var transferStarsText: String
    var canTransferDateText: String
    var nameHidden: Bool
    var savedToProfile: Bool
    var pinnedToTop: Bool
    var batchCount: String
}

private struct EahatGramAddGiftState: Equatable {
    var assets: EahatGramAddGiftAssets
    var draft: EahatGramAddGiftDraft
    var statusText: String
}

private enum EahatGramAddGiftEntry: ItemListNodeEntry {
    case baseGift(String)
    case model(String)
    case backdrop(String)
    case symbol(String)
    case number(String)
    case customTitle(String)
    case customSlug(String)
    case customAvatar(String)
    case customPrice(String)
    case customTotal(String)
    case comment(String)
    case fromTag(String)
    case transferStars(String)
    case canTransferDate(String)
    case advanced(Bool)
    case nameHidden(Bool)
    case savedToProfile(Bool)
    case pinnedToTop(Bool)
    case batchCount(String)
    case addNumber
    case addNftTag
    case addRandom
    case addSelected
    case status(String)

    var section: ItemListSectionId {
        switch self {
        case .baseGift, .model, .backdrop, .symbol:
            return EahatGramAddGiftSection.assets.rawValue
        case .number, .customTitle, .customSlug, .customAvatar, .customPrice, .customTotal, .comment, .fromTag, .transferStars, .canTransferDate:
            return EahatGramAddGiftSection.params.rawValue
        case .advanced, .nameHidden, .savedToProfile, .pinnedToTop:
            return EahatGramAddGiftSection.flags.rawValue
        case .batchCount, .addNumber, .addNftTag, .addRandom, .addSelected:
            return EahatGramAddGiftSection.actions.rawValue
        case .status:
            return EahatGramAddGiftSection.status.rawValue
        }
    }

    var stableId: Int {
        switch self {
        case .baseGift:
            return 0
        case .model:
            return 1
        case .backdrop:
            return 2
        case .symbol:
            return 3
        case .number:
            return 4
        case .customTitle:
            return 5
        case .customSlug:
            return 6
        case .customAvatar:
            return 7
        case .customPrice:
            return 8
        case .customTotal:
            return 9
        case .comment:
            return 10
        case .fromTag:
            return 11
        case .transferStars:
            return 12
        case .canTransferDate:
            return 13
        case .advanced:
            return 14
        case .nameHidden:
            return 15
        case .savedToProfile:
            return 16
        case .pinnedToTop:
            return 17
        case .batchCount:
            return 18
        case .addNumber:
            return 19
        case .addNftTag:
            return 20
        case .addRandom:
            return 21
        case .addSelected:
            return 22
        case .status:
            return 23
        }
    }

    static func <(lhs: EahatGramAddGiftEntry, rhs: EahatGramAddGiftEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }
}

private final class EahatGramAddGiftArguments {
    let context: AccountContext
    let selectBaseGift: () -> Void
    let selectModel: () -> Void
    let selectBackdrop: () -> Void
    let selectSymbol: () -> Void
    let updateNumber: (String) -> Void
    let updateCustomTitle: (String) -> Void
    let updateCustomSlug: (String) -> Void
    let updateCustomAvatar: (String) -> Void
    let updateCustomPrice: (String) -> Void
    let updateCustomTotal: (String) -> Void
    let updateAdvanced: (Bool) -> Void
    let updateComment: (String) -> Void
    let updateFromTag: (String) -> Void
    let updateTransferStars: (String) -> Void
    let updateCanTransferDate: (String) -> Void
    let updateNameHidden: (Bool) -> Void
    let updateSavedToProfile: (Bool) -> Void
    let updatePinnedToTop: (Bool) -> Void
    let updateBatchCount: (String) -> Void
    let addNumber: () -> Void
    let addNftTag: () -> Void
    let addRandom: () -> Void
    let addSelected: () -> Void

    init(
        context: AccountContext,
        selectBaseGift: @escaping () -> Void,
        selectModel: @escaping () -> Void,
        selectBackdrop: @escaping () -> Void,
        selectSymbol: @escaping () -> Void,
        updateNumber: @escaping (String) -> Void,
        updateCustomTitle: @escaping (String) -> Void,
        updateCustomSlug: @escaping (String) -> Void,
        updateCustomAvatar: @escaping (String) -> Void,
        updateCustomPrice: @escaping (String) -> Void,
        updateCustomTotal: @escaping (String) -> Void,
        updateAdvanced: @escaping (Bool) -> Void,
        updateComment: @escaping (String) -> Void,
        updateFromTag: @escaping (String) -> Void,
        updateTransferStars: @escaping (String) -> Void,
        updateCanTransferDate: @escaping (String) -> Void,
        updateNameHidden: @escaping (Bool) -> Void,
        updateSavedToProfile: @escaping (Bool) -> Void,
        updatePinnedToTop: @escaping (Bool) -> Void,
        updateBatchCount: @escaping (String) -> Void,
        addNumber: @escaping () -> Void,
        addNftTag: @escaping () -> Void,
        addRandom: @escaping () -> Void,
        addSelected: @escaping () -> Void
    ) {
        self.context = context
        self.selectBaseGift = selectBaseGift
        self.selectModel = selectModel
        self.selectBackdrop = selectBackdrop
        self.selectSymbol = selectSymbol
        self.updateNumber = updateNumber
        self.updateCustomTitle = updateCustomTitle
        self.updateCustomSlug = updateCustomSlug
        self.updateCustomAvatar = updateCustomAvatar
        self.updateCustomPrice = updateCustomPrice
        self.updateCustomTotal = updateCustomTotal
        self.updateAdvanced = updateAdvanced
        self.updateComment = updateComment
        self.updateFromTag = updateFromTag
        self.updateTransferStars = updateTransferStars
        self.updateCanTransferDate = updateCanTransferDate
        self.updateNameHidden = updateNameHidden
        self.updateSavedToProfile = updateSavedToProfile
        self.updatePinnedToTop = updatePinnedToTop
        self.updateBatchCount = updateBatchCount
        self.addNumber = addNumber
        self.addNftTag = addNftTag
        self.addRandom = addRandom
        self.addSelected = addSelected
    }
}

private func eahatGramBaseGiftTitle(_ gift: TelegramCore.StarGift.Gift) -> String {
    let availabilitySuffix: String
    if let availability = gift.availability {
        let issued = max(0, availability.total - availability.remains)
        availabilitySuffix = " issued=\(issued)/\(availability.total)"
    } else {
        availabilitySuffix = ""
    }
    if let title = gift.title, !title.isEmpty {
        return "\(title) (\(gift.id))\(availabilitySuffix)"
    } else {
        return "Gift \(gift.id)\(availabilitySuffix)"
    }
}

private func eahatGramGiftIssuedCount(_ gift: TelegramCore.StarGift.Gift) -> Int32? {
    guard let availability = gift.availability else {
        return nil
    }
    return max(0, availability.total - availability.remains)
}

private func eahatGramGiftRandomUpperBound(_ gift: TelegramCore.StarGift.Gift) -> Int32 {
    if let availability = gift.availability {
        return max(1, max(eahatGramGiftIssuedCount(gift) ?? 0, availability.total))
    } else {
        return 999_999
    }
}

private func eahatGramRandomGiftNumber(_ gift: TelegramCore.StarGift.Gift) -> Int32 {
    let upperBound = eahatGramGiftRandomUpperBound(gift)
    if upperBound > 1 {
        return Int32.random(in: 1 ... upperBound)
    } else {
        return 1
    }
}

private func eahatGramRandomGiftNumbers(_ gift: TelegramCore.StarGift.Gift, count: Int) -> [Int32] {
    guard count > 0 else {
        return []
    }

    let upperBound = eahatGramGiftRandomUpperBound(gift)
    if upperBound == 1 {
        return Array(repeating: 1, count: count)
    }

    if upperBound >= Int32(count) {
        var used = Set<Int32>()
        var result: [Int32] = []
        result.reserveCapacity(count)
        while result.count < count {
            let value = Int32.random(in: 1 ... upperBound)
            if used.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }

    let startValue = Int32.random(in: 1 ... upperBound)
    var result: [Int32] = []
    result.reserveCapacity(count)
    for index in 0 ..< count {
        let offset = Int32(index % Int(upperBound))
        let value = ((startValue - 1 + offset) % upperBound) + 1
        result.append(value)
    }
    return result
}

private func eahatGramResolvedGiftNumber(_ value: String, gift: TelegramCore.StarGift.Gift) -> Int32 {
    let fallback = eahatGramRandomGiftNumber(gift)
    guard let parsed = Int32(value), parsed > 0 else {
        return fallback
    }
    if let issued = eahatGramGiftIssuedCount(gift), issued > 0 {
        return min(parsed, issued)
    } else {
        return parsed
    }
}

private func eahatGramParsedGiftNumber(_ value: String) -> Int32? {
    guard let parsed = Int32(value), parsed > 0 else {
        return nil
    }
    return parsed
}

private func eahatGramNormalizedNumericText(_ value: String, maxLength: Int) -> String {
    let filtered = value.filter(\.isNumber)
    if filtered.count <= maxLength {
        return filtered
    } else {
        return String(filtered.prefix(maxLength))
    }
}

private func eahatGramResolvedGiftSlug(baseTag: String, number: Int32, batchIndex: Int?, forceNumberSuffix: Bool) -> String {
    let trimmedBaseTag = baseTag.trimmingCharacters(in: .whitespacesAndNewlines)
    var resolved = trimmedBaseTag.isEmpty ? "eahatgram-\(number)" : trimmedBaseTag
    if resolved.contains("{number}") {
        resolved = resolved.replacingOccurrences(of: "{number}", with: "\(number)")
    } else if trimmedBaseTag.isEmpty {
        resolved = "eahatgram-\(number)"
    } else if forceNumberSuffix {
        resolved = "\(trimmedBaseTag)-\(number)"
    }
    if let batchIndex, batchIndex > 0 {
        resolved += "-\(batchIndex + 1)"
    }
    return resolved
}

private func eahatGramNormalizedTag(_ value: String) -> String {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.hasPrefix("@") {
        normalized.removeFirst()
    }
    return normalized
}

private func eahatGramResolvedComment(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func eahatGramResolvedFromPeer(_ value: String) -> EnginePeer? {
    let normalizedTag = eahatGramNormalizedTag(value)
    guard !normalizedTag.isEmpty else {
        return nil
    }
    var syntheticIdValue: Int64 = 0
    for scalar in normalizedTag.lowercased().unicodeScalars {
        syntheticIdValue = syntheticIdValue &* 31 &+ Int64(scalar.value)
    }
    syntheticIdValue = max(1, syntheticIdValue & 0x7fffffff)
    let peerId = EnginePeer.Id(namespace: Namespaces.Peer.Empty, id: EnginePeer.Id.Id._internalFromInt64Value(syntheticIdValue))
    return .user(TelegramUser(
        id: peerId,
        accessHash: nil,
        firstName: normalizedTag,
        lastName: nil,
        username: normalizedTag,
        phone: nil,
        photo: [],
        botInfo: nil,
        restrictionInfo: nil,
        flags: [],
        emojiStatus: nil,
        usernames: [],
        storiesHidden: nil,
        nameColor: nil,
        backgroundEmojiId: nil,
        profileColor: nil,
        profileBackgroundEmojiId: nil,
        subscriberCount: nil,
        verificationIconFileId: nil
    ))
}

private enum EahatGramInsertActionMode: Equatable {
    case number
    case nftTag
    case random
    case selected
}

private func eahatGramRandomAttribute(from attributes: [TelegramCore.StarGift.UniqueGift.Attribute]) -> TelegramCore.StarGift.UniqueGift.Attribute? {
    guard !attributes.isEmpty else {
        return nil
    }
    let index = Int.random(in: 0 ..< attributes.count)
    return attributes[index]
}

private func eahatGramRarityText(_ rarity: TelegramCore.StarGift.UniqueGift.Attribute.Rarity) -> String {
    switch rarity {
    case let .permille(value):
        return "permille=\(value)"
    case .rare:
        return "rare"
    case .epic:
        return "epic"
    case .legendary:
        return "legendary"
    case .uncommon:
        return "uncommon"
    }
}

private func eahatGramAttributeTitle(_ attribute: TelegramCore.StarGift.UniqueGift.Attribute) -> String {
    switch attribute {
    case let .model(name, _, rarity, crafted):
        return "\(name) [\(eahatGramRarityText(rarity))] crafted=\(crafted)"
    case let .pattern(name, _, rarity):
        return "\(name) [\(eahatGramRarityText(rarity))]"
    case let .backdrop(name, id, _, _, _, _, rarity):
        return "\(name) id=\(id) [\(eahatGramRarityText(rarity))]"
    case let .originalInfo(senderPeerId, recipientPeerId, date, _, _):
        return "original sender=\(String(describing: senderPeerId)) recipient=\(recipientPeerId) date=\(date)"
    }
}

final class EahatGramInsertCountSliderItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let systemStyle: ItemListSystemStyle
    let title: String
    let minimumValue: Int32
    let maximumValue: Int32
    let value: Int32
    let sectionId: ItemListSectionId
    let updated: (Int32) -> Void

    init(
        presentationData: ItemListPresentationData,
        systemStyle: ItemListSystemStyle,
        title: String = "Add Count",
        minimumValue: Int32 = 1,
        maximumValue: Int32 = 1000,
        value: Int32,
        sectionId: ItemListSectionId,
        updated: @escaping (Int32) -> Void
    ) {
        self.presentationData = presentationData
        self.systemStyle = systemStyle
        self.title = title
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.value = value
        self.sectionId = sectionId
        self.updated = updated
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = EahatGramInsertCountSliderItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply(.None) })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? EahatGramInsertCountSliderItemNode {
                let makeLayout = nodeValue.asyncLayout()
                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply(animation)
                        })
                    }
                }
            }
        }
    }

    var selectable: Bool = false
}

private final class EahatGramInsertCountSliderItemNode: ListViewItemNode, ItemListItemNode {
    private let backgroundNode = ASDisplayNode()
    private let topStripeNode = ASDisplayNode()
    private let bottomStripeNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    private let leftTextNode = ImmediateTextNode()
    private let rightTextNode = ImmediateTextNode()
    private let titleTextNode = ImmediateTextNode()

    private var sliderView: UISlider?
    private var item: EahatGramInsertCountSliderItem?

    var tag: ItemListItemTag? {
        return self.item?.tag
    }

    override var canBeSelected: Bool {
        return false
    }

    init() {
        self.backgroundNode.isLayerBacked = true
        self.topStripeNode.isLayerBacked = true
        self.bottomStripeNode.isLayerBacked = true
        self.titleTextNode.displaysAsynchronously = false
        self.leftTextNode.displaysAsynchronously = false
        self.rightTextNode.displaysAsynchronously = false

        super.init(layerBacked: false)

        self.addSubnode(self.leftTextNode)
        self.addSubnode(self.rightTextNode)
        self.addSubnode(self.titleTextNode)
    }

    override func didLoad() {
        super.didLoad()

        let sliderView = UISlider()
        sliderView.addTarget(self, action: #selector(self.sliderValueChanged), for: .valueChanged)
        self.view.addSubview(sliderView)
        self.sliderView = sliderView
    }

    func asyncLayout() -> (_ item: EahatGramInsertCountSliderItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        return { item, params, neighbors in
            let separatorHeight = UIScreenPixel
            let contentSize = CGSize(width: params.width, height: 88.0)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            return (layout, { [weak self] animation in
                guard let self else {
                    return
                }
                self.item = item

                if self.backgroundNode.supernode == nil {
                    self.insertSubnode(self.backgroundNode, at: 0)
                    self.insertSubnode(self.topStripeNode, at: 1)
                    self.insertSubnode(self.bottomStripeNode, at: 2)
                    self.addSubnode(self.maskNode)
                }

                let theme = item.presentationData.theme
                self.backgroundNode.backgroundColor = theme.list.itemBlocksBackgroundColor
                self.topStripeNode.backgroundColor = theme.list.itemBlocksSeparatorColor
                self.bottomStripeNode.backgroundColor = theme.list.itemBlocksSeparatorColor

                let hasCorners = itemListHasRoundedBlockLayout(params)
                var hasTopCorners = false
                var hasBottomCorners = false
                switch neighbors.top {
                case .sameSection(false):
                    self.topStripeNode.isHidden = true
                default:
                    hasTopCorners = true
                    self.topStripeNode.isHidden = hasCorners
                }
                let bottomStripeInset: CGFloat
                switch neighbors.bottom {
                case .sameSection(false):
                    bottomStripeInset = params.leftInset + 16.0
                    self.bottomStripeNode.isHidden = false
                default:
                    bottomStripeInset = 0.0
                    hasBottomCorners = true
                    self.bottomStripeNode.isHidden = hasCorners
                }

                self.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(theme, top: hasTopCorners, bottom: hasBottomCorners, glass: item.systemStyle == .glass) : nil

                let transition = animation.transition
                transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight))))
                transition.updateFrame(node: self.maskNode, frame: self.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0))
                transition.updateFrame(node: self.topStripeNode, frame: CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: separatorHeight)))
                transition.updateFrame(node: self.bottomStripeNode, frame: CGRect(origin: CGPoint(x: bottomStripeInset, y: contentSize.height - separatorHeight), size: CGSize(width: params.width - bottomStripeInset, height: separatorHeight)))

                self.leftTextNode.attributedText = NSAttributedString(string: "\(item.minimumValue)", font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor)
                self.rightTextNode.attributedText = NSAttributedString(string: "\(item.maximumValue)", font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor)
                self.titleTextNode.attributedText = NSAttributedString(string: "\(item.title): \(item.value)", font: Font.regular(16.0), textColor: theme.list.itemPrimaryTextColor)

                let sideInset: CGFloat = 18.0
                let leftTextSize = self.leftTextNode.updateLayout(CGSize(width: 100.0, height: 100.0))
                let rightTextSize = self.rightTextNode.updateLayout(CGSize(width: 100.0, height: 100.0))
                let titleTextSize = self.titleTextNode.updateLayout(CGSize(width: params.width - sideInset * 2.0, height: 100.0))

                self.leftTextNode.frame = CGRect(origin: CGPoint(x: params.leftInset + sideInset, y: 15.0), size: leftTextSize)
                self.rightTextNode.frame = CGRect(origin: CGPoint(x: params.width - params.leftInset - sideInset - rightTextSize.width, y: 15.0), size: rightTextSize)
                self.titleTextNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((params.width - titleTextSize.width) / 2.0), y: 11.0), size: titleTextSize)

                if let sliderView = self.sliderView {
                    sliderView.backgroundColor = theme.list.itemBlocksBackgroundColor
                    sliderView.minimumValue = Float(item.minimumValue)
                    sliderView.maximumValue = Float(item.maximumValue)
                    sliderView.minimumTrackTintColor = theme.list.itemAccentColor
                    sliderView.maximumTrackTintColor = theme.list.itemSwitchColors.frameColor
                    sliderView.thumbTintColor = theme.list.itemPrimaryTextColor
                    sliderView.frame = CGRect(origin: CGPoint(x: params.leftInset + sideInset, y: 36.0), size: CGSize(width: params.width - params.leftInset - params.rightInset - sideInset * 2.0, height: 44.0))
                    if !sliderView.isTracking {
                        sliderView.value = Float(item.value)
                    }
                }
            })
        }
    }

    @objc private func sliderValueChanged() {
        guard let item = self.item, let sliderView = self.sliderView else {
            return
        }
        let updatedValue = min(item.maximumValue, max(item.minimumValue, Int32(sliderView.value.rounded())))
        item.updated(updatedValue)
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}

extension EahatGramAddGiftEntry {
    static func ==(lhs: EahatGramAddGiftEntry, rhs: EahatGramAddGiftEntry) -> Bool {
        switch lhs {
        case let .baseGift(lhsText):
            if case let .baseGift(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .model(lhsText):
            if case let .model(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .backdrop(lhsText):
            if case let .backdrop(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .symbol(lhsText):
            if case let .symbol(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .number(lhsText):
            if case let .number(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .customTitle(lhsText):
            if case let .customTitle(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .customSlug(lhsText):
            if case let .customSlug(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .customAvatar(lhsText):
            if case let .customAvatar(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .customPrice(lhsText):
            if case let .customPrice(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .customTotal(lhsText):
            if case let .customTotal(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .comment(lhsText):
            if case let .comment(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .fromTag(lhsText):
            if case let .fromTag(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .transferStars(lhsText):
            if case let .transferStars(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .canTransferDate(lhsText):
            if case let .canTransferDate(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        case let .advanced(lhsValue):
            if case let .advanced(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .nameHidden(lhsValue):
            if case let .nameHidden(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .savedToProfile(lhsValue):
            if case let .savedToProfile(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .pinnedToTop(lhsValue):
            if case let .pinnedToTop(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case let .batchCount(lhsValue):
            if case let .batchCount(rhsValue) = rhs {
                return lhsValue == rhsValue
            } else {
                return false
            }
        case .addRandom:
            if case .addRandom = rhs {
                return true
            } else {
                return false
            }
        case .addNumber:
            if case .addNumber = rhs {
                return true
            } else {
                return false
            }
        case .addNftTag:
            if case .addNftTag = rhs {
                return true
            } else {
                return false
            }
        case .addSelected:
            if case .addSelected = rhs {
                return true
            } else {
                return false
            }
        case let .status(lhsText):
            if case let .status(rhsText) = rhs {
                return lhsText == rhsText
            } else {
                return false
            }
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! EahatGramAddGiftArguments
        let titleColor = presentationData.theme.list.itemPrimaryTextColor
        switch self {
        case let .baseGift(text):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Gift",
                label: text,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.selectBaseGift()
                }
            )
        case let .model(text):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Model",
                label: text,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.selectModel()
                }
            )
        case let .backdrop(text):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Backdrop",
                label: text,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.selectBackdrop()
                }
            )
        case let .symbol(text):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Symbol",
                label: text,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.selectSymbol()
                }
            )
        case let .number(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Custom Number", textColor: titleColor),
                text: text,
                placeholder: "1",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateNumber(value)
                },
                action: {}
            )
        case let .customTitle(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Custom Gift Name", textColor: titleColor),
                text: text,
                placeholder: "Gift name",
                type: .regular(capitalization: false, autocorrection: false),
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateCustomTitle(value)
                },
                action: {}
            )
        case let .customSlug(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Custom NFT Tag", textColor: titleColor),
                text: text,
                placeholder: "custom-tag or custom-{number}",
                type: .regular(capitalization: false, autocorrection: false),
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateCustomSlug(value)
                },
                action: {}
            )
        case let .customAvatar(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Avatar Source", textColor: titleColor),
                text: text,
                placeholder: "uses selected gift file",
                type: .regular(capitalization: false, autocorrection: false),
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateCustomAvatar(value)
                },
                action: {}
            )
        case let .customPrice(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Custom Price", textColor: titleColor),
                text: text,
                placeholder: "25",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateCustomPrice(value)
                },
                action: {}
            )
        case let .customTotal(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Custom Total", textColor: titleColor),
                text: text,
                placeholder: "1000",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateCustomTotal(value)
                },
                action: {}
            )
        case let .comment(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Gift Comment", textColor: titleColor),
                text: text,
                placeholder: "comment",
                type: .regular(capitalization: true, autocorrection: true),
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateComment(value)
                },
                action: {}
            )
        case let .fromTag(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "From Tag", textColor: titleColor),
                text: text,
                placeholder: "username",
                type: .username,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateFromTag(value)
                },
                action: {}
            )
        case let .transferStars(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Transfer Stars", textColor: titleColor),
                text: text,
                placeholder: "25",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateTransferStars(value)
                },
                action: {}
            )
        case let .canTransferDate(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Can Transfer Date", textColor: titleColor),
                text: text,
                placeholder: "",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateCanTransferDate(value)
                },
                action: {}
            )
        case let .advanced(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Advanced", value: value, sectionId: self.section, style: .blocks, updated: { updated in
                arguments.updateAdvanced(updated)
            })
        case let .nameHidden(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Name Hidden", value: value, sectionId: self.section, style: .blocks, updated: { updated in
                arguments.updateNameHidden(updated)
            })
        case let .savedToProfile(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Saved To Profile", value: value, sectionId: self.section, style: .blocks, updated: { updated in
                arguments.updateSavedToProfile(updated)
            })
        case let .pinnedToTop(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Pinned To Top", value: value, sectionId: self.section, style: .blocks, updated: { updated in
                arguments.updatePinnedToTop(updated)
            })
        case let .batchCount(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Add Count", textColor: titleColor),
                text: text,
                placeholder: "1",
                type: .number,
                maxLength: 4,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateBatchCount(value)
                },
                action: {}
            )
        case .addNumber:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Add Number",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addNumber()
                }
            )
        case .addNftTag:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Add NFT Tag",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addNftTag()
                }
            )
        case .addRandom:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Add Random Gift",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addRandom()
                }
            )
        case .addSelected:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Add Selected Gift",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addSelected()
                }
            )
        case let .status(text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(text),
                sectionId: self.section
            )
        }
    }
}

private func eahatGramAddGiftEntries(state: EahatGramAddGiftState, customMode: Bool) -> [EahatGramAddGiftEntry] {
    let baseGiftText: String
    if let selectedGiftId = state.draft.selectedGiftId, let gift = state.assets.baseGifts.first(where: { $0.id == selectedGiftId }) {
        baseGiftText = eahatGramBaseGiftTitle(gift)
    } else if state.assets.baseGifts.isEmpty {
        baseGiftText = "Loading..."
    } else {
        baseGiftText = "Select"
    }

    let modelText: String
    if let index = state.draft.selectedModelIndex, index >= 0 && index < state.assets.models.count {
        modelText = eahatGramAttributeTitle(state.assets.models[index])
    } else {
        modelText = state.assets.models.isEmpty ? "Not available" : "Select"
    }

    let backdropText: String
    if let index = state.draft.selectedBackdropIndex, index >= 0 && index < state.assets.backdrops.count {
        backdropText = eahatGramAttributeTitle(state.assets.backdrops[index])
    } else {
        backdropText = state.assets.backdrops.isEmpty ? "Not available" : "Select"
    }

    let symbolText: String
    if let index = state.draft.selectedSymbolIndex, index >= 0 && index < state.assets.symbols.count {
        symbolText = eahatGramAttributeTitle(state.assets.symbols[index])
    } else {
        symbolText = state.assets.symbols.isEmpty ? "Not available" : "Select"
    }

    var entries: [EahatGramAddGiftEntry] = [
        .baseGift(baseGiftText),
        .model(modelText),
        .backdrop(backdropText),
        .symbol(symbolText),
        .number(state.draft.numberText),
        .comment(state.draft.commentText),
        .fromTag(state.draft.fromTagText),
        .transferStars(state.draft.transferStarsText),
        .canTransferDate(state.draft.canTransferDateText),
        .advanced(state.draft.advancedEnabled),
        .nameHidden(state.draft.nameHidden),
        .savedToProfile(state.draft.savedToProfile),
        .pinnedToTop(state.draft.pinnedToTop),
        .batchCount(state.draft.batchCount),
        .addNumber,
        .addNftTag,
        .addRandom,
        .addSelected,
        .status(state.statusText)
    ]
    if customMode {
        entries.insert(contentsOf: [
            .customTitle(state.draft.customTitleText),
            .customSlug(state.draft.customSlugText),
            .customAvatar(state.draft.customAvatarText),
            .customPrice(state.draft.customPriceText),
            .customTotal(state.draft.customTotalText)
        ], at: 5)
    }
    return entries.filter { entry in
        switch entry {
        case .comment, .fromTag:
            return state.draft.advancedEnabled
        default:
            return true
        }
    }
}

func eahatGramAddGiftToProfileScreen(
    context: AccountContext,
    profileGiftsContext: ProfileGiftsContext,
    appendStatus: @escaping (String) -> Void,
    customMode: Bool = false
) -> ViewController {
    let now = Int32(Date().timeIntervalSince1970)
    let initialState = EahatGramAddGiftState(
        assets: EahatGramAddGiftAssets(),
        draft: EahatGramAddGiftDraft(
            selectedGiftId: nil,
            selectedModelIndex: nil,
            selectedBackdropIndex: nil,
            selectedSymbolIndex: nil,
            numberText: "1",
            customTitleText: "",
            customSlugText: "",
            customAvatarText: "",
            customPriceText: "",
            customTotalText: "",
            advancedEnabled: false,
            commentText: "",
            fromTagText: "",
            transferStarsText: "25",
            canTransferDateText: "\(now)",
            nameHidden: false,
            savedToProfile: true,
            pinnedToTop: false,
            batchCount: "1"
        ),
        statusText: "source=local_insert"
    )

    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)

    let keepUpdatedDisposable = MetaDisposable()
    let giftsDisposable = MetaDisposable()
    let attributesDisposable = MetaDisposable()
    let insertDisposable = MetaDisposable()
    let nftInsertCounter = Atomic<Int>(value: 0)

    let updateState: ((EahatGramAddGiftState) -> EahatGramAddGiftState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let setStatus: (String) -> Void = { status in
        appendStatus(status)
        updateState { current in
            var current = current
            current.statusText = status
            return current
        }
    }

    let refreshAttributes: (Int64) -> Void = { giftId in
        attributesDisposable.set((context.engine.payments.getStarGiftUpgradeAttributes(giftId: giftId)
        |> deliverOnMainQueue).start(next: { attributes in
            let values = attributes ?? []
            let models = values.compactMap { attribute -> TelegramCore.StarGift.UniqueGift.Attribute? in
                if case .model = attribute {
                    return attribute
                } else {
                    return nil
                }
            }
            let backdrops = values.compactMap { attribute -> TelegramCore.StarGift.UniqueGift.Attribute? in
                if case .backdrop = attribute {
                    return attribute
                } else {
                    return nil
                }
            }
            let symbols = values.compactMap { attribute -> TelegramCore.StarGift.UniqueGift.Attribute? in
                if case .pattern = attribute {
                    return attribute
                } else {
                    return nil
                }
            }
            updateState { current in
                var current = current
                current.assets.models = models
                current.assets.backdrops = backdrops
                current.assets.symbols = symbols
                if current.draft.selectedModelIndex == nil && !models.isEmpty {
                    current.draft.selectedModelIndex = 0
                } else if let selectedModelIndex = current.draft.selectedModelIndex, selectedModelIndex >= models.count {
                    current.draft.selectedModelIndex = models.isEmpty ? nil : 0
                }
                if current.draft.selectedBackdropIndex == nil && !backdrops.isEmpty {
                    current.draft.selectedBackdropIndex = 0
                } else if let selectedBackdropIndex = current.draft.selectedBackdropIndex, selectedBackdropIndex >= backdrops.count {
                    current.draft.selectedBackdropIndex = backdrops.isEmpty ? nil : 0
                }
                if current.draft.selectedSymbolIndex == nil && !symbols.isEmpty {
                    current.draft.selectedSymbolIndex = 0
                } else if let selectedSymbolIndex = current.draft.selectedSymbolIndex, selectedSymbolIndex >= symbols.count {
                    current.draft.selectedSymbolIndex = symbols.isEmpty ? nil : 0
                }
                return current
            }
            setStatus("loadedUpgradeAttributes giftId=\(giftId) models=\(models.count) backdrops=\(backdrops.count) symbols=\(symbols.count)")
        }))
    }

    keepUpdatedDisposable.set(context.engine.payments.keepStarGiftsUpdated().start())
    giftsDisposable.set((context.engine.payments.cachedStarGifts()
    |> deliverOnMainQueue).start(next: { gifts in
        let baseGifts = (gifts ?? []).compactMap { gift -> TelegramCore.StarGift.Gift? in
            if case let .generic(value) = gift {
                return value
            } else {
                return nil
            }
        }
        var refreshGiftId: Int64?
        updateState { current in
            var current = current
            current.assets.baseGifts = baseGifts
            if current.draft.selectedGiftId == nil, let firstGift = baseGifts.first {
                let randomNumber = eahatGramRandomGiftNumber(firstGift)
                current.draft.selectedGiftId = firstGift.id
                current.draft.numberText = "\(randomNumber)"
                if current.draft.customAvatarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    current.draft.customAvatarText = "baseGift:\(firstGift.id)"
                }
                refreshGiftId = firstGift.id
            } else if let selectedGiftId = current.draft.selectedGiftId, baseGifts.first(where: { $0.id == selectedGiftId }) == nil {
                if let firstGift = baseGifts.first {
                    let randomNumber = eahatGramRandomGiftNumber(firstGift)
                    current.draft.selectedGiftId = firstGift.id
                    current.draft.numberText = "\(randomNumber)"
                    if current.draft.customAvatarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        current.draft.customAvatarText = "baseGift:\(firstGift.id)"
                    }
                } else {
                    current.draft.selectedGiftId = nil
                }
                current.draft.selectedModelIndex = nil
                current.draft.selectedBackdropIndex = nil
                current.draft.selectedSymbolIndex = nil
                refreshGiftId = current.draft.selectedGiftId
            }
            return current
        }
        if let refreshGiftId {
            refreshAttributes(refreshGiftId)
        }
        setStatus("cachedStarGifts count=\(baseGifts.count)")
    }))

    var pushControllerImpl: ((ViewController) -> Void)?
    var controllerRef: ItemListController?

    func selectedBaseGift(state: EahatGramAddGiftState) -> TelegramCore.StarGift.Gift? {
        guard let selectedGiftId = state.draft.selectedGiftId else {
            return nil
        }
        return state.assets.baseGifts.first(where: { $0.id == selectedGiftId })
    }

    func selectedModel(state: EahatGramAddGiftState) -> TelegramCore.StarGift.UniqueGift.Attribute? {
        guard let index = state.draft.selectedModelIndex, index >= 0 && index < state.assets.models.count else {
            return nil
        }
        return state.assets.models[index]
    }

    func selectedBackdrop(state: EahatGramAddGiftState) -> TelegramCore.StarGift.UniqueGift.Attribute? {
        guard let index = state.draft.selectedBackdropIndex, index >= 0 && index < state.assets.backdrops.count else {
            return nil
        }
        return state.assets.backdrops[index]
    }

    func selectedSymbol(state: EahatGramAddGiftState) -> TelegramCore.StarGift.UniqueGift.Attribute? {
        guard let index = state.draft.selectedSymbolIndex, index >= 0 && index < state.assets.symbols.count else {
            return nil
        }
        return state.assets.symbols[index]
    }

    func makeInsertedGift(
        baseGift: TelegramCore.StarGift.Gift,
        state: EahatGramAddGiftState,
        number: Int32,
        slug: String,
        model: TelegramCore.StarGift.UniqueGift.Attribute?,
        backdrop: TelegramCore.StarGift.UniqueGift.Attribute?,
        symbol: TelegramCore.StarGift.UniqueGift.Attribute?,
        uniqueGiftId: Int64,
        giftDate: Int32,
        realUniqueGift: TelegramCore.StarGift.UniqueGift?,
        valueInfo: TelegramCore.StarGift.UniqueGift.ValueInfo?
    ) -> ProfileGiftsContext.State.StarGift {
        let customTotal = Int32(state.draft.customTotalText).flatMap { $0 > 0 ? $0 : nil }
        let fallbackIssued = eahatGramGiftIssuedCount(baseGift) ?? number
        let issued = realUniqueGift?.availability.issued ?? max(number, customTotal ?? fallbackIssued)
        let total = realUniqueGift?.availability.total ?? max(issued, customTotal ?? baseGift.availability?.total ?? number)
        let customTitle = eahatGramResolvedComment(state.draft.customTitleText)
        let title = customTitle ?? baseGift.title ?? "Gift \(baseGift.id)"
        let customPrice = Int64(state.draft.customPriceText).flatMap { $0 > 0 ? $0 : nil }
        let commentText = state.draft.advancedEnabled ? eahatGramResolvedComment(state.draft.commentText) : nil
        let fromPeer = state.draft.advancedEnabled ? eahatGramResolvedFromPeer(state.draft.fromTagText) : nil

        var attributes: [TelegramCore.StarGift.UniqueGift.Attribute] = []
        if let model {
            attributes.append(model)
        }
        if let backdrop {
            attributes.append(backdrop)
        }
        if let symbol {
            attributes.append(symbol)
        }
        if attributes.isEmpty, let realUniqueGift {
            attributes = realUniqueGift.attributes.filter { $0.attributeType != .originalInfo }
        }

        let resellAmounts = realUniqueGift?.resellAmounts ?? customPrice.map { [CurrencyAmount(amount: StarsAmount(value: $0, nanos: 0), currency: .stars)] }
        let valueAmount = realUniqueGift?.valueAmount ?? valueInfo?.value
        let valueCurrency = realUniqueGift?.valueCurrency ?? valueInfo?.currency
        let valueUsdAmount = realUniqueGift?.valueUsdAmount
        let giftAddress = realUniqueGift?.giftAddress
        let resellForTonOnly = realUniqueGift?.resellForTonOnly ?? false
        let releasedBy = realUniqueGift?.releasedBy ?? baseGift.releasedBy
        let themePeerId = realUniqueGift?.themePeerId
        let peerColor = realUniqueGift?.peerColor
        let hostPeerId = realUniqueGift?.hostPeerId
        let minOfferStars = realUniqueGift?.minOfferStars
        let craftChancePermille = realUniqueGift?.craftChancePermille

        let uniqueGift = TelegramCore.StarGift.UniqueGift(
            id: uniqueGiftId,
            giftId: baseGift.id,
            title: title,
            number: number,
            slug: slug,
            owner: .peerId(context.account.peerId),
            attributes: attributes,
            availability: .init(issued: issued, total: total),
            giftAddress: giftAddress,
            resellAmounts: resellAmounts,
            resellForTonOnly: resellForTonOnly,
            releasedBy: releasedBy,
            valueAmount: valueAmount,
            valueCurrency: valueCurrency,
            valueUsdAmount: valueUsdAmount,
            flags: [],
            themePeerId: themePeerId,
            peerColor: peerColor,
            hostPeerId: hostPeerId,
            minOfferStars: minOfferStars,
            craftChancePermille: craftChancePermille
        )

        return ProfileGiftsContext.State.StarGift(
            gift: .unique(uniqueGift),
            reference: nil,
            fromPeer: fromPeer,
            date: giftDate,
            text: commentText,
            entities: nil,
            nameHidden: state.draft.nameHidden,
            savedToProfile: state.draft.savedToProfile,
            pinnedToTop: state.draft.pinnedToTop,
            convertStars: baseGift.convertStars,
            canUpgrade: false,
            canExportDate: nil,
            upgradeStars: baseGift.upgradeStars,
            transferStars: Int64(state.draft.transferStarsText),
            canTransferDate: Int32(state.draft.canTransferDateText),
            canResaleDate: nil,
            collectionIds: nil,
            prepaidUpgradeHash: nil,
            upgradeSeparate: false,
            dropOriginalDetailsStars: nil,
            number: number,
            isRefunded: false,
            canCraftAt: nil
        )
    }

    func enrichedInsertedGiftSignal(
        baseGift: TelegramCore.StarGift.Gift,
        state: EahatGramAddGiftState,
        number: Int32,
        slug: String,
        resolveRemotely: Bool,
        model: TelegramCore.StarGift.UniqueGift.Attribute?,
        backdrop: TelegramCore.StarGift.UniqueGift.Attribute?,
        symbol: TelegramCore.StarGift.UniqueGift.Attribute?,
        uniqueGiftId: Int64,
        giftDate: Int32
    ) -> Signal<ProfileGiftsContext.State.StarGift, NoError> {
        let fallbackGift = makeInsertedGift(
            baseGift: baseGift,
            state: state,
            number: number,
            slug: slug,
            model: model,
            backdrop: backdrop,
            symbol: symbol,
            uniqueGiftId: uniqueGiftId,
            giftDate: giftDate,
            realUniqueGift: nil,
            valueInfo: nil
        )

        guard resolveRemotely else {
            return .single(fallbackGift)
        }

        let normalizedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSlug.isEmpty else {
            return .single(fallbackGift)
        }

        let uniqueGiftSignal = context.engine.payments.getUniqueStarGift(slug: normalizedSlug)
        |> map(Optional.init)
        |> `catch` { _ -> Signal<TelegramCore.StarGift.UniqueGift?, NoError> in
            return .single(nil)
        }

        let valueInfoSignal = context.engine.payments.getUniqueStarGiftValueInfo(slug: normalizedSlug)
        let fallbackRemoteSignal: Signal<(TelegramCore.StarGift.UniqueGift?, TelegramCore.StarGift.UniqueGift.ValueInfo?), NoError> = .single((nil, nil))

        return combineLatest(uniqueGiftSignal, valueInfoSignal)
        |> timeout(1.5, queue: Queue.mainQueue(), alternate: fallbackRemoteSignal)
        |> map { realUniqueGift, valueInfo in
            return makeInsertedGift(
                baseGift: baseGift,
                state: state,
                number: number,
                slug: slug,
                model: model,
                backdrop: backdrop,
                symbol: symbol,
                uniqueGiftId: uniqueGiftId,
                giftDate: giftDate,
                realUniqueGift: realUniqueGift,
                valueInfo: valueInfo
            )
        }
    }

    func insertLocalGifts(mode: EahatGramInsertActionMode) {
        let state = stateValue.with { $0 }
        guard let baseGift = selectedBaseGift(state: state) else {
            setStatus("insertLocalGift failed reason=BASE_GIFT_NOT_SELECTED")
            return
        }
        if case .number = mode {
            guard let parsedNumber = Int32(state.draft.numberText), parsedNumber > 0 else {
                setStatus("insertLocalGift failed reason=NUMBER_NOT_SET")
                return
            }
        }

        let batchCount = Int(min(1000, max(1, Int32(state.draft.batchCount) ?? 1)))
        let fallbackNumber = max(1, eahatGramResolvedGiftNumber(state.draft.numberText, gift: baseGift))
        let selectedNumber = max(1, eahatGramParsedGiftNumber(state.draft.numberText) ?? fallbackNumber)
        let fixedModel = selectedModel(state: state)
        let fixedBackdrop = selectedBackdrop(state: state)
        let fixedSymbol = selectedSymbol(state: state)
        let randomized = mode == .random
        let randomNumbers = randomized ? eahatGramRandomGiftNumbers(baseGift, count: batchCount) : []
        let baseTag: String
        switch mode {
        case .nftTag:
            baseTag = eahatGramNormalizedTag(state.draft.customSlugText)
        case .number, .random, .selected:
            baseTag = ""
        }
        if case .nftTag = mode, baseTag.isEmpty {
            setStatus("insertLocalGift failed reason=NFT_TAG_EMPTY")
            return
        }
        let resolveRemotely = mode == .nftTag
        let nftInsertSeries = mode == .nftTag ? (nftInsertCounter.modify { current -> Int in
            return current + 1
        } - 1) : 0
        let baseTimestamp = Date().timeIntervalSince1970
        let baseDate = Int32(baseTimestamp)
        let baseUniqueGiftId = Int64(baseTimestamp * 1000.0)

        var insertSignals: [Signal<ProfileGiftsContext.State.StarGift, NoError>] = []
        insertSignals.reserveCapacity(batchCount)

        var firstSlug: String?
        var lastSlug: String?
        var firstNumber: Int32?
        var lastNumber: Int32?

        for index in 0 ..< batchCount {
            let number: Int32
            let model: TelegramCore.StarGift.UniqueGift.Attribute?
            let backdrop: TelegramCore.StarGift.UniqueGift.Attribute?
            let symbol: TelegramCore.StarGift.UniqueGift.Attribute?

            if randomized {
                number = randomNumbers[index]
                model = eahatGramRandomAttribute(from: state.assets.models)
                backdrop = eahatGramRandomAttribute(from: state.assets.backdrops)
                symbol = eahatGramRandomAttribute(from: state.assets.symbols)
            } else {
                number = selectedNumber
                model = fixedModel
                backdrop = fixedBackdrop
                symbol = fixedSymbol
            }

            let slug = eahatGramResolvedGiftSlug(
                baseTag: baseTag,
                number: number,
                batchIndex: mode == .nftTag ? (nftInsertSeries * batchCount + index) : (batchCount > 1 ? index : nil),
                forceNumberSuffix: randomized || (mode == .nftTag && nftInsertSeries > 0)
            )
            let insertedGift = enrichedInsertedGiftSignal(
                baseGift: baseGift,
                state: state,
                number: number,
                slug: slug,
                resolveRemotely: resolveRemotely,
                model: model,
                backdrop: backdrop,
                symbol: symbol,
                uniqueGiftId: -(baseUniqueGiftId + Int64(index) + 1),
                giftDate: baseDate + Int32(index)
            )

            insertSignals.append(insertedGift)
            if firstSlug == nil {
                firstSlug = slug
                firstNumber = number
            }
            lastSlug = slug
            lastNumber = number
        }

        let modeText: String
        switch mode {
        case .number:
            modeText = "number"
        case .nftTag:
            modeText = "nftTag"
        case .random:
            modeText = "random"
        case .selected:
            modeText = "selected"
        }
        let startedLine = "insertLocalGifts mode=\(modeText) giftId=\(baseGift.id) count=\(batchCount) firstNumber=\(String(describing: firstNumber)) lastNumber=\(String(describing: lastNumber)) firstSlug=\(String(describing: firstSlug)) lastSlug=\(String(describing: lastSlug)) transferStars=\(String(describing: Int64(state.draft.transferStarsText))) canTransferDate=\(String(describing: Int32(state.draft.canTransferDateText))) advanced=\(state.draft.advancedEnabled) comment=\(String(describing: eahatGramResolvedComment(state.draft.commentText))) fromTag=\(eahatGramNormalizedTag(state.draft.fromTagText)) customTitle=\(String(describing: eahatGramResolvedComment(state.draft.customTitleText))) customSlug=\(eahatGramNormalizedTag(state.draft.customSlugText)) customAvatar=\(String(describing: eahatGramResolvedComment(state.draft.customAvatarText))) customPrice=\(String(describing: Int64(state.draft.customPriceText))) customTotal=\(String(describing: Int32(state.draft.customTotalText))) savedToProfile=\(state.draft.savedToProfile) pinnedToTop=\(state.draft.pinnedToTop) nameHidden=\(state.draft.nameHidden)"
        setStatus(startedLine)
        insertDisposable.set((combineLatest(insertSignals)
        |> deliverOnMainQueue).start(next: { gifts in
            profileGiftsContext.insertStarGifts(gifts: gifts, afterPinned: true)
            let realPrices = gifts.compactMap { gift -> Int64? in
                guard case let .unique(uniqueGift) = gift.gift else {
                    return nil
                }
                return uniqueGift.resellAmounts?.first(where: { $0.currency == .stars })?.amount.value
            }
            let issuedCounts = gifts.compactMap { gift -> String? in
                guard case let .unique(uniqueGift) = gift.gift else {
                    return nil
                }
                return "\(uniqueGift.availability.issued)/\(uniqueGift.availability.total)"
            }
            let completedLine = "insertLocalGifts completed count=\(gifts.count) realPrices=\(realPrices) availability=\(issuedCounts)"
            setStatus(completedLine)
        }))
    }

    let arguments = EahatGramAddGiftArguments(
        context: context,
        selectBaseGift: {
            let state = stateValue.with { $0 }
            let options = state.assets.baseGifts.map(eahatGramBaseGiftTitle)
            guard !options.isEmpty else {
                setStatus("selectBaseGift failed reason=EMPTY_GIFTS")
                return
            }
            let selectedIndex = state.assets.baseGifts.firstIndex(where: { $0.id == state.draft.selectedGiftId })
            let picker = eahatGramPickerScreen(context: context, title: "Gift", options: options, selectedIndex: selectedIndex, apply: { index in
                guard index >= 0 && index < stateValue.with({ $0.assets.baseGifts.count }) else {
                    return
                }
                let gift = stateValue.with { $0.assets.baseGifts[index] }
                let randomNumber = eahatGramRandomGiftNumber(gift)
                updateState { current in
                    var current = current
                    current.draft.selectedGiftId = gift.id
                    current.draft.selectedModelIndex = nil
                    current.draft.selectedBackdropIndex = nil
                    current.draft.selectedSymbolIndex = nil
                    current.draft.numberText = "\(randomNumber)"
                    if current.draft.customAvatarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        current.draft.customAvatarText = "baseGift:\(gift.id)"
                    }
                    return current
                }
                refreshAttributes(gift.id)
                let issued = eahatGramGiftIssuedCount(gift)
                let total = gift.availability?.total
                setStatus("selectedBaseGift giftId=\(gift.id) issued=\(String(describing: issued)) total=\(String(describing: total)) randomNumber=\(randomNumber)")
                if let navigationController = controllerRef?.navigationController as? NavigationController {
                    _ = navigationController.popViewController(animated: true)
                }
            })
            pushControllerImpl?(picker)
        },
        selectModel: {
            let state = stateValue.with { $0 }
            let options = state.assets.models.map(eahatGramAttributeTitle)
            guard !options.isEmpty else {
                setStatus("selectModel failed reason=EMPTY_MODELS")
                return
            }
            let picker = eahatGramPickerScreen(context: context, title: "Model", options: options, selectedIndex: state.draft.selectedModelIndex, apply: { index in
                updateState { current in
                    var current = current
                    current.draft.selectedModelIndex = index
                    return current
                }
                setStatus("selectedModel index=\(index)")
                if let navigationController = controllerRef?.navigationController as? NavigationController {
                    _ = navigationController.popViewController(animated: true)
                }
            })
            pushControllerImpl?(picker)
        },
        selectBackdrop: {
            let state = stateValue.with { $0 }
            let options = state.assets.backdrops.map(eahatGramAttributeTitle)
            guard !options.isEmpty else {
                setStatus("selectBackdrop failed reason=EMPTY_BACKDROPS")
                return
            }
            let picker = eahatGramPickerScreen(context: context, title: "Backdrop", options: options, selectedIndex: state.draft.selectedBackdropIndex, apply: { index in
                updateState { current in
                    var current = current
                    current.draft.selectedBackdropIndex = index
                    return current
                }
                setStatus("selectedBackdrop index=\(index)")
                if let navigationController = controllerRef?.navigationController as? NavigationController {
                    _ = navigationController.popViewController(animated: true)
                }
            })
            pushControllerImpl?(picker)
        },
        selectSymbol: {
            let state = stateValue.with { $0 }
            let options = state.assets.symbols.map(eahatGramAttributeTitle)
            guard !options.isEmpty else {
                setStatus("selectSymbol failed reason=EMPTY_SYMBOLS")
                return
            }
            let picker = eahatGramPickerScreen(context: context, title: "Symbol", options: options, selectedIndex: state.draft.selectedSymbolIndex, apply: { index in
                updateState { current in
                    var current = current
                    current.draft.selectedSymbolIndex = index
                    return current
                }
                setStatus("selectedSymbol index=\(index)")
                if let navigationController = controllerRef?.navigationController as? NavigationController {
                    _ = navigationController.popViewController(animated: true)
                }
            })
            pushControllerImpl?(picker)
        },
        updateNumber: { value in
            updateState { current in
                var current = current
                current.draft.numberText = eahatGramNormalizedNumericText(value, maxLength: 9)
                return current
            }
        },
        updateCustomTitle: { value in
            updateState { current in
                var current = current
                current.draft.customTitleText = value
                return current
            }
        },
        updateCustomSlug: { value in
            updateState { current in
                var current = current
                current.draft.customSlugText = value
                return current
            }
        },
        updateCustomAvatar: { value in
            updateState { current in
                var current = current
                current.draft.customAvatarText = value
                return current
            }
        },
        updateCustomPrice: { value in
            updateState { current in
                var current = current
                current.draft.customPriceText = value
                return current
            }
        },
        updateCustomTotal: { value in
            updateState { current in
                var current = current
                current.draft.customTotalText = value
                return current
            }
        },
        updateAdvanced: { value in
            updateState { current in
                var current = current
                current.draft.advancedEnabled = value
                return current
            }
        },
        updateComment: { value in
            updateState { current in
                var current = current
                current.draft.commentText = value
                return current
            }
        },
        updateFromTag: { value in
            updateState { current in
                var current = current
                current.draft.fromTagText = value
                return current
            }
        },
        updateTransferStars: { value in
            updateState { current in
                var current = current
                current.draft.transferStarsText = value
                return current
            }
        },
        updateCanTransferDate: { value in
            updateState { current in
                var current = current
                current.draft.canTransferDateText = value
                return current
            }
        },
        updateNameHidden: { value in
            updateState { current in
                var current = current
                current.draft.nameHidden = value
                return current
            }
        },
        updateSavedToProfile: { value in
            updateState { current in
                var current = current
                current.draft.savedToProfile = value
                return current
            }
        },
        updatePinnedToTop: { value in
            updateState { current in
                var current = current
                current.draft.pinnedToTop = value
                return current
            }
        },
        updateBatchCount: { value in
            updateState { current in
                var current = current
                current.draft.batchCount = eahatGramNormalizedNumericText(value, maxLength: 4)
                return current
            }
        },
        addNumber: {
            insertLocalGifts(mode: .number)
        },
        addNftTag: {
            insertLocalGifts(mode: .nftTag)
        },
        addRandom: {
            insertLocalGifts(mode: .random)
        },
        addSelected: {
            insertLocalGifts(mode: .selected)
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(customMode ? "Custom Gift" : "Add Gift To Profile"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: eahatGramAddGiftEntries(state: state, customMode: customMode),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        keepUpdatedDisposable.dispose()
        giftsDisposable.dispose()
        attributesDisposable.dispose()
        insertDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
    controllerRef = controller
    pushControllerImpl = { [weak controller] nextController in
        (controller?.navigationController as? NavigationController)?.pushViewController(nextController)
    }
    return controller
}
