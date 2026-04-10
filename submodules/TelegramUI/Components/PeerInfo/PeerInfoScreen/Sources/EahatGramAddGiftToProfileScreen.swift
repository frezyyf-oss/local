import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import ItemListUI
import Display

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
    var slugText: String
    var transferStarsText: String
    var canTransferDateText: String
    var nameHidden: Bool
    var savedToProfile: Bool
    var pinnedToTop: Bool
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
    case slug(String)
    case transferStars(String)
    case canTransferDate(String)
    case nameHidden(Bool)
    case savedToProfile(Bool)
    case pinnedToTop(Bool)
    case insert
    case status(String)

    var section: ItemListSectionId {
        switch self {
        case .baseGift, .model, .backdrop, .symbol:
            return EahatGramAddGiftSection.assets.rawValue
        case .number, .slug, .transferStars, .canTransferDate:
            return EahatGramAddGiftSection.params.rawValue
        case .nameHidden, .savedToProfile, .pinnedToTop:
            return EahatGramAddGiftSection.flags.rawValue
        case .insert:
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
        case .slug:
            return 5
        case .transferStars:
            return 6
        case .canTransferDate:
            return 7
        case .nameHidden:
            return 8
        case .savedToProfile:
            return 9
        case .pinnedToTop:
            return 10
        case .insert:
            return 11
        case .status:
            return 12
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
    let updateSlug: (String) -> Void
    let updateTransferStars: (String) -> Void
    let updateCanTransferDate: (String) -> Void
    let updateNameHidden: (Bool) -> Void
    let updateSavedToProfile: (Bool) -> Void
    let updatePinnedToTop: (Bool) -> Void
    let insert: () -> Void

    init(
        context: AccountContext,
        selectBaseGift: @escaping () -> Void,
        selectModel: @escaping () -> Void,
        selectBackdrop: @escaping () -> Void,
        selectSymbol: @escaping () -> Void,
        updateNumber: @escaping (String) -> Void,
        updateSlug: @escaping (String) -> Void,
        updateTransferStars: @escaping (String) -> Void,
        updateCanTransferDate: @escaping (String) -> Void,
        updateNameHidden: @escaping (Bool) -> Void,
        updateSavedToProfile: @escaping (Bool) -> Void,
        updatePinnedToTop: @escaping (Bool) -> Void,
        insert: @escaping () -> Void
    ) {
        self.context = context
        self.selectBaseGift = selectBaseGift
        self.selectModel = selectModel
        self.selectBackdrop = selectBackdrop
        self.selectSymbol = selectSymbol
        self.updateNumber = updateNumber
        self.updateSlug = updateSlug
        self.updateTransferStars = updateTransferStars
        self.updateCanTransferDate = updateCanTransferDate
        self.updateNameHidden = updateNameHidden
        self.updateSavedToProfile = updateSavedToProfile
        self.updatePinnedToTop = updatePinnedToTop
        self.insert = insert
    }
}

private func eahatGramBaseGiftTitle(_ gift: TelegramCore.StarGift.Gift) -> String {
    if let title = gift.title, !title.isEmpty {
        return "\(title) (\(gift.id))"
    } else {
        return "Gift \(gift.id)"
    }
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
        case let .slug(lhsText):
            if case let .slug(rhsText) = rhs {
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
        case .insert:
            if case .insert = rhs {
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
                title: NSAttributedString(string: "Number", textColor: titleColor),
                text: text,
                placeholder: "1",
                type: .number,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateNumber(value)
                },
                action: {}
            )
        case let .slug(text):
            return ItemListSingleLineInputItem(
                context: arguments.context,
                presentationData: presentationData,
                systemStyle: .glass,
                title: NSAttributedString(string: "Slug", textColor: titleColor),
                text: text,
                placeholder: "eahatgram-1",
                type: .regular(capitalization: false, autocorrection: false),
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateSlug(value)
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
        case .insert:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Insert Local Gift",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.insert()
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

private func eahatGramAddGiftEntries(state: EahatGramAddGiftState) -> [EahatGramAddGiftEntry] {
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

    return [
        .baseGift(baseGiftText),
        .model(modelText),
        .backdrop(backdropText),
        .symbol(symbolText),
        .number(state.draft.numberText),
        .slug(state.draft.slugText),
        .transferStars(state.draft.transferStarsText),
        .canTransferDate(state.draft.canTransferDateText),
        .nameHidden(state.draft.nameHidden),
        .savedToProfile(state.draft.savedToProfile),
        .pinnedToTop(state.draft.pinnedToTop),
        .insert,
        .status(state.statusText)
    ]
}

func eahatGramAddGiftToProfileScreen(
    context: AccountContext,
    profileGiftsContext: ProfileGiftsContext,
    appendStatus: @escaping (String) -> Void
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
            slugText: "",
            transferStarsText: "25",
            canTransferDateText: "\(now)",
            nameHidden: false,
            savedToProfile: true,
            pinnedToTop: false
        ),
        statusText: "source=local_insert"
    )

    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)

    let keepUpdatedDisposable = MetaDisposable()
    let giftsDisposable = MetaDisposable()
    let attributesDisposable = MetaDisposable()

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
                current.draft.selectedGiftId = firstGift.id
                current.draft.slugText = "eahatgram-\(current.draft.numberText)"
                refreshGiftId = firstGift.id
            } else if let selectedGiftId = current.draft.selectedGiftId, baseGifts.first(where: { $0.id == selectedGiftId }) == nil {
                current.draft.selectedGiftId = baseGifts.first?.id
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
                updateState { current in
                    var current = current
                    current.draft.selectedGiftId = gift.id
                    current.draft.selectedModelIndex = nil
                    current.draft.selectedBackdropIndex = nil
                    current.draft.selectedSymbolIndex = nil
                    if current.draft.slugText.isEmpty || current.draft.slugText.hasPrefix("eahatgram-") {
                        current.draft.slugText = "eahatgram-\(current.draft.numberText)"
                    }
                    return current
                }
                refreshAttributes(gift.id)
                setStatus("selectedBaseGift giftId=\(gift.id)")
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
                current.draft.numberText = value
                if current.draft.slugText.isEmpty || current.draft.slugText.hasPrefix("eahatgram-") {
                    current.draft.slugText = "eahatgram-\(value.isEmpty ? "1" : value)"
                }
                return current
            }
        },
        updateSlug: { value in
            updateState { current in
                var current = current
                current.draft.slugText = value
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
        insert: {
            let state = stateValue.with { $0 }
            guard let baseGift = selectedBaseGift(state: state) else {
                setStatus("insertLocalGift failed reason=BASE_GIFT_NOT_SELECTED")
                return
            }

            let number = max(1, Int32(state.draft.numberText) ?? 1)
            let slug = state.draft.slugText.isEmpty ? "eahatgram-\(number)" : state.draft.slugText
            let transferStars = Int64(state.draft.transferStarsText)
            let canTransferDate = Int32(state.draft.canTransferDateText)
            let model = selectedModel(state: state)
            let backdrop = selectedBackdrop(state: state)
            let symbol = selectedSymbol(state: state)

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

            let uniqueGiftId = -Int64(Date().timeIntervalSince1970 * 1000.0)
            let uniqueGift = TelegramCore.StarGift.UniqueGift(
                id: uniqueGiftId,
                giftId: baseGift.id,
                title: baseGift.title ?? "Gift \(baseGift.id)",
                number: number,
                slug: slug,
                owner: .peerId(context.account.peerId),
                attributes: attributes,
                availability: .init(issued: number, total: number),
                giftAddress: nil,
                resellAmounts: nil,
                resellForTonOnly: false,
                releasedBy: baseGift.releasedBy,
                valueAmount: nil,
                valueCurrency: nil,
                valueUsdAmount: nil,
                flags: [],
                themePeerId: nil,
                peerColor: nil,
                hostPeerId: nil,
                minOfferStars: nil,
                craftChancePermille: nil
            )

            let insertedGift = ProfileGiftsContext.State.StarGift(
                gift: .unique(uniqueGift),
                reference: nil,
                fromPeer: nil,
                date: Int32(Date().timeIntervalSince1970),
                text: nil,
                entities: nil,
                nameHidden: state.draft.nameHidden,
                savedToProfile: state.draft.savedToProfile,
                pinnedToTop: state.draft.pinnedToTop,
                convertStars: baseGift.convertStars,
                canUpgrade: false,
                canExportDate: nil,
                upgradeStars: baseGift.upgradeStars,
                transferStars: transferStars,
                canTransferDate: canTransferDate,
                canResaleDate: nil,
                collectionIds: nil,
                prepaidUpgradeHash: nil,
                upgradeSeparate: false,
                dropOriginalDetailsStars: nil,
                number: number,
                isRefunded: false,
                canCraftAt: nil
            )

            profileGiftsContext.insertStarGifts(gifts: [insertedGift], afterPinned: true)

            let line = "insertLocalGift giftId=\(baseGift.id) uniqueGiftId=\(uniqueGiftId) number=\(number) slug=\(slug) transferStars=\(String(describing: transferStars)) canTransferDate=\(String(describing: canTransferDate)) model=\(String(describing: model.map(eahatGramAttributeTitle))) backdrop=\(String(describing: backdrop.map(eahatGramAttributeTitle))) symbol=\(String(describing: symbol.map(eahatGramAttributeTitle))) savedToProfile=\(state.draft.savedToProfile) pinnedToTop=\(state.draft.pinnedToTop) nameHidden=\(state.draft.nameHidden)"
            setStatus(line)
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
            title: .text("Add Gift To Profile"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: eahatGramAddGiftEntries(state: state),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        keepUpdatedDisposable.dispose()
        giftsDisposable.dispose()
        attributesDisposable.dispose()
    }

    let controller = ItemListController(context: context, state: signal)
    controllerRef = controller
    pushControllerImpl = { [weak controller] nextController in
        (controller?.navigationController as? NavigationController)?.pushViewController(nextController)
    }
    return controller
}
