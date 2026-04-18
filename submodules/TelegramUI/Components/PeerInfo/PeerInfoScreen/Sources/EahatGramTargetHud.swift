import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import PhoneNumberFormat
import AvatarNode

private enum EahatGramCollectibleUsernameOwnerCacheEntry: Equatable {
    case owner(String)
    case none
}

private struct EahatGramCollectibleUsernameOwnerLookupResult: Equatable {
    let owner: String?
    let isAuthoritative: Bool
}

private let eahatGramCollectibleUsernameOwnerCache = Atomic<[String: EahatGramCollectibleUsernameOwnerCacheEntry]>(value: [:])

private func eahatGramNormalizedCollectibleUsername(_ username: String) -> String {
    return username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func eahatGramNormalizedCollectibleOwner(_ owner: String) -> String {
    return owner.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
}

private func eahatGramTonCenterCollectibleOwnerSignal(username: String) -> Signal<EahatGramCollectibleUsernameOwnerLookupResult, NoError> {
    return Signal { subscriber in
        guard var components = URLComponents(string: "https://toncenter.com/api/v3/dns/records") else {
            subscriber.putNext(EahatGramCollectibleUsernameOwnerLookupResult(owner: nil, isAuthoritative: false))
            subscriber.putCompletion()
            return ActionDisposable {
            }
        }
        components.queryItems = [
            URLQueryItem(name: "domain", value: "\(username).t.me"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url else {
            subscriber.putNext(EahatGramCollectibleUsernameOwnerLookupResult(owner: nil, isAuthoritative: false))
            subscriber.putCompletion()
            return ActionDisposable {
            }
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let result: EahatGramCollectibleUsernameOwnerLookupResult
            if
                let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200,
                let data,
                let object = try? JSONSerialization.jsonObject(with: data, options: []),
                let dict = object as? [String: Any],
                let records = dict["records"] as? [[String: Any]]
            {
                let owner = records.compactMap { record -> String? in
                    guard let owner = record["nft_item_owner"] as? String, !owner.isEmpty else {
                        return nil
                    }
                    return eahatGramNormalizedCollectibleOwner(owner)
                }.first
                result = EahatGramCollectibleUsernameOwnerLookupResult(owner: owner, isAuthoritative: true)
            } else {
                result = EahatGramCollectibleUsernameOwnerLookupResult(owner: nil, isAuthoritative: false)
            }

            DispatchQueue.main.async {
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
        }
        task.resume()

        return ActionDisposable {
            task.cancel()
        }
    }
}

private func eahatGramCollectibleUsernameOwnerSignal(context: AccountContext, username: String) -> Signal<String?, NoError> {
    let normalizedUsername = eahatGramNormalizedCollectibleUsername(username)
    if normalizedUsername.isEmpty {
        return .single(nil)
    }

    if let cachedValue = eahatGramCollectibleUsernameOwnerCache.with({ $0[normalizedUsername] }) {
        switch cachedValue {
        case let .owner(owner):
            return .single(owner)
        case .none:
            return .single(nil)
        }
    }

    return (context.engine.peers.getCollectibleUsernameInfo(username: normalizedUsername)
    |> take(1)
    |> mapToSignal { collectibleInfo -> Signal<String?, NoError> in
        guard collectibleInfo != nil else {
            _ = eahatGramCollectibleUsernameOwnerCache.modify { current in
                var current = current
                current[normalizedUsername] = EahatGramCollectibleUsernameOwnerCacheEntry.none
                return current
            }
            return .single(nil)
        }

        return eahatGramTonCenterCollectibleOwnerSignal(username: normalizedUsername)
        |> map { result -> String? in
            if let owner = result.owner {
                _ = eahatGramCollectibleUsernameOwnerCache.modify { current in
                    var current = current
                    current[normalizedUsername] = .owner(owner)
                    return current
                }
                return owner
            } else if result.isAuthoritative {
                _ = eahatGramCollectibleUsernameOwnerCache.modify { current in
                    var current = current
                    current[normalizedUsername] = EahatGramCollectibleUsernameOwnerCacheEntry.none
                    return current
                }
                return nil
            } else {
                return nil
            }
        }
    })
}

final class EahatGramDebugSettings {
    private static let targetHudEnabledKey = "eahatGram.targetHudEnabled"
    private static let nftUsernameTagKey = "eahatGram.nftUsernameTag"
    private static let nftUsernamePriceKey = "eahatGram.nftUsernamePrice"
    private static let nftUsernamePurchaseDateKey = "eahatGram.nftUsernamePurchaseDate"
    private static let fakePhoneNumberKey = "eahatGram.fakePhoneNumber"
    private static let voiceModEnabledKey = "eahatGram.voiceModEnabled"
    private static let voiceModPresetKey = "eahatGram.voiceModPreset"
    private static let voiceModV2EnabledKey = "eahatGram.voiceModV2Enabled"
    private static let voiceModV2VoiceKey = "eahatGram.voiceModV2Voice"

    static let targetHudEnabled = Atomic<Bool>(value: UserDefaults.standard.object(forKey: targetHudEnabledKey) as? Bool ?? false)
    static let nftUsernameTag = Atomic<String>(value: UserDefaults.standard.string(forKey: nftUsernameTagKey) ?? "")
    static let nftUsernamePrice = Atomic<String>(value: UserDefaults.standard.string(forKey: nftUsernamePriceKey) ?? "")
    static let nftUsernamePurchaseDate = Atomic<Int32?>(value: (UserDefaults.standard.object(forKey: nftUsernamePurchaseDateKey) as? NSNumber).map { $0.int32Value })
    static let fakePhoneNumber = Atomic<String>(value: UserDefaults.standard.string(forKey: fakePhoneNumberKey) ?? "")
    static let voiceModEnabled = Atomic<Bool>(value: UserDefaults.standard.object(forKey: voiceModEnabledKey) as? Bool ?? false)
    static let voiceModPreset = Atomic<String>(value: UserDefaults.standard.string(forKey: voiceModPresetKey) ?? EahatGramVoiceModPreset.chipmunk.rawValue)
    static let voiceModV2Enabled = Atomic<Bool>(value: UserDefaults.standard.object(forKey: voiceModV2EnabledKey) as? Bool ?? false)
    static let voiceModV2Voice = Atomic<String>(value: UserDefaults.standard.string(forKey: voiceModV2VoiceKey) ?? EahatGramVoiceModV2Voice.ruNeutral.rawValue)
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

    static func setNftUsernamePrice(_ value: String) {
        _ = self.nftUsernamePrice.modify { _ in
            value
        }
        UserDefaults.standard.set(value, forKey: self.nftUsernamePriceKey)
    }

    static func setNftUsernamePurchaseDate(_ value: Int32?) {
        _ = self.nftUsernamePurchaseDate.modify { _ in
            value
        }
        if let value {
            UserDefaults.standard.set(Int(value), forKey: self.nftUsernamePurchaseDateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.nftUsernamePurchaseDateKey)
        }
    }

    static func setFakePhoneNumber(_ value: String) {
        _ = self.fakePhoneNumber.modify { _ in
            value
        }
        UserDefaults.standard.set(value, forKey: self.fakePhoneNumberKey)
    }

    static func setVoiceModEnabled(_ value: Bool) {
        _ = self.voiceModEnabled.modify { _ in
            value
        }
        UserDefaults.standard.set(value, forKey: self.voiceModEnabledKey)
    }

    static func setVoiceModPreset(_ value: EahatGramVoiceModPreset) {
        _ = self.voiceModPreset.modify { _ in
            value.rawValue
        }
        UserDefaults.standard.set(value.rawValue, forKey: self.voiceModPresetKey)
    }

    static func setVoiceModV2Enabled(_ value: Bool) {
        _ = self.voiceModV2Enabled.modify { _ in
            value
        }
        UserDefaults.standard.set(value, forKey: self.voiceModV2EnabledKey)
    }

    static func setVoiceModV2Voice(_ value: EahatGramVoiceModV2Voice) {
        _ = self.voiceModV2Voice.modify { _ in
            value.rawValue
        }
        UserDefaults.standard.set(value.rawValue, forKey: self.voiceModV2VoiceKey)
    }

    static func resolvedVoiceModPreset() -> EahatGramVoiceModPreset {
        return EahatGramVoiceModPreset(rawValue: self.voiceModPreset.with { $0 }) ?? .chipmunk
    }

    static func resolvedVoiceModV2Voice() -> EahatGramVoiceModV2Voice {
        return EahatGramVoiceModV2Voice(rawValue: self.voiceModV2Voice.with { $0 }) ?? .ruNeutral
    }
}

enum EahatGramVoiceModPreset: String, CaseIterable {
    case chipmunk
    case deep
    case robot
    case helium
    case giant
    case alien
    case monster
    case radio
    case megaphone
    case whisper
    case tremolo
    case echo

    var title: String {
        switch self {
        case .chipmunk:
            return "Chipmunk"
        case .deep:
            return "Deep"
        case .robot:
            return "Robot"
        case .helium:
            return "Helium"
        case .giant:
            return "Giant"
        case .alien:
            return "Alien"
        case .monster:
            return "Monster"
        case .radio:
            return "Radio"
        case .megaphone:
            return "Megaphone"
        case .whisper:
            return "Whisper"
        case .tremolo:
            return "Tremolo"
        case .echo:
            return "Echo"
        }
    }
}

public enum EahatGramVoiceModV2Voice: String, CaseIterable {
    case ruNeutral
    case ruSoft
    case ruFast
    case ruLow
    case enNeutral
    case enSoft
    case enFast
    case enLow
    case deNeutral
    case frNeutral
    case esNeutral
    case itNeutral
    case jaNeutral
    case koNeutral

    public var title: String {
        switch self {
        case .ruNeutral:
            return "RU Neutral"
        case .ruSoft:
            return "RU Soft"
        case .ruFast:
            return "RU Fast"
        case .ruLow:
            return "RU Low"
        case .enNeutral:
            return "EN Neutral"
        case .enSoft:
            return "EN Soft"
        case .enFast:
            return "EN Fast"
        case .enLow:
            return "EN Low"
        case .deNeutral:
            return "DE Neutral"
        case .frNeutral:
            return "FR Neutral"
        case .esNeutral:
            return "ES Neutral"
        case .itNeutral:
            return "IT Neutral"
        case .jaNeutral:
            return "JA Neutral"
        case .koNeutral:
            return "KO Neutral"
        }
    }
}

struct EahatGramDisplayedUsername: Equatable {
    let text: String?
    let additionalText: String?
    let openValue: String?
}

struct EahatGramVisualCollectibleUsername: Equatable {
    let username: String
    let priceText: String
    let purchaseDate: Int32?
}

func eahatGramNormalizedUsernameTag(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return ""
    }
    if trimmed.hasPrefix("@") {
        return String(trimmed.dropFirst())
    } else {
        return trimmed
    }
}

func eahatGramNormalizedNftPriceText(_ value: String) -> String {
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func eahatGramDisplayedVisualCollectibleUsername(mainUsername: String?, additionalActiveUsernames: [String], isMyProfile: Bool) -> EahatGramVisualCollectibleUsername? {
    guard isMyProfile else {
        return nil
    }
    let normalizedMainUsername = mainUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
    let mainUsernameValue = (normalizedMainUsername?.isEmpty == false) ? normalizedMainUsername : nil
    let nftUsernameTag = eahatGramNormalizedUsernameTag(EahatGramDebugSettings.nftUsernameTag.with { $0 })
    guard !nftUsernameTag.isEmpty else {
        return nil
    }
    let normalizedAdditionalUsernames = Set(additionalActiveUsernames.map(eahatGramNormalizedCollectibleUsername))
    let normalizedVisualUsername = eahatGramNormalizedCollectibleUsername(nftUsernameTag)
    if normalizedVisualUsername == eahatGramNormalizedCollectibleUsername(mainUsernameValue ?? "") {
        return nil
    }
    if normalizedAdditionalUsernames.contains(normalizedVisualUsername) {
        return nil
    }
    return EahatGramVisualCollectibleUsername(
        username: nftUsernameTag,
        priceText: eahatGramNormalizedNftPriceText(EahatGramDebugSettings.nftUsernamePrice.with { $0 }),
        purchaseDate: EahatGramDebugSettings.nftUsernamePurchaseDate.with { $0 }
    )
}

#if false
private func eahatGramFormattedVisualNftTag(_ usernameTag: String, priceText: String) -> String {
    if priceText.isEmpty {
        return "@\(usernameTag)"
    } else {
        return "@\(usernameTag) • куплен за \(priceText)"
    }
}

func eahatGramDisplayedUsername(mainUsername: String?, additionalActiveUsernames: [String], isMyProfile: Bool) -> EahatGramDisplayedUsername {
    let normalizedMainUsername = mainUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
    let mainUsernameValue = (normalizedMainUsername?.isEmpty == false) ? normalizedMainUsername : nil
    guard isMyProfile else {
        if let mainUsernameValue {
            return EahatGramDisplayedUsername(text: "@\(mainUsernameValue)", additionalText: nil, openValue: mainUsernameValue)
        } else {
            return EahatGramDisplayedUsername(text: nil, additionalText: nil, openValue: nil)
        }
    }
    if let visualCollectibleUsername = eahatGramDisplayedVisualCollectibleUsername(mainUsername: mainUsername, additionalActiveUsernames: additionalActiveUsernames, isMyProfile: isMyProfile) {
        if let mainUsernameValue {
            if additionalActiveUsernames.isEmpty {
                return EahatGramDisplayedUsername(text: "@\(mainUsernameValue)", additionalText: "а также @\(visualCollectibleUsername.username)", openValue: mainUsernameValue)
            } else {
                return EahatGramDisplayedUsername(text: "@\(mainUsernameValue)", additionalText: "@\(visualCollectibleUsername.username)", openValue: mainUsernameValue)
            }
        } else {
            return EahatGramDisplayedUsername(text: "@\(visualCollectibleUsername.username)", additionalText: nil, openValue: nil)
        }
        if let mainUsernameValue {
            let additionalText: String
            if additionalActiveUsernames.isEmpty {
                additionalText = "а также @\(visualCollectibleUsername.username)"
            } else {
                additionalText = "@\(visualCollectibleUsername.username)"
            }
            return EahatGramDisplayedUsername(text: "@\(mainUsernameValue)", additionalText: additionalText, openValue: mainUsernameValue)
        } else {
            return EahatGramDisplayedUsername(text: "@\(visualCollectibleUsername.username)", additionalText: nil, openValue: nil)
        }
    }
    let nftUsernameTag = eahatGramNormalizedUsernameTag(EahatGramDebugSettings.nftUsernameTag.with { $0 })
    let nftUsernamePrice = ""
    let normalizedAdditionalUsernames = Set(additionalActiveUsernames.map(eahatGramNormalizedCollectibleUsername))
    let shouldDisplayVisualTag = !nftUsernameTag.isEmpty && eahatGramNormalizedCollectibleUsername(nftUsernameTag) != eahatGramNormalizedCollectibleUsername(mainUsernameValue ?? "") && !normalizedAdditionalUsernames.contains(eahatGramNormalizedCollectibleUsername(nftUsernameTag))
    if shouldDisplayVisualTag {
        if let mainUsernameValue {
            if additionalActiveUsernames.isEmpty {
                return EahatGramDisplayedUsername(text: "@\(mainUsernameValue)", additionalText: "а также @\(nftUsernameTag)", openValue: mainUsernameValue)
            } else {
                return EahatGramDisplayedUsername(text: "@\(mainUsernameValue)", additionalText: "@\(nftUsernameTag)", openValue: mainUsernameValue)
            }
        } else {
            return EahatGramDisplayedUsername(text: "@\(nftUsernameTag)", additionalText: nil, openValue: nil)
        }
    }

    if let mainUsernameValue {
        let mainText = "@\(mainUsernameValue)"
        let visualTagText = "@\(nftUsernameTag)"
        if shouldDisplayVisualTag {
            if additionalActiveUsernames.isEmpty {
                return EahatGramDisplayedUsername(text: mainText, additionalText: "а также \(visualTagText)", openValue: mainUsernameValue)
            } else {
                return EahatGramDisplayedUsername(text: mainText, additionalText: visualTagText, openValue: mainUsernameValue)
            }
        } else {
            return EahatGramDisplayedUsername(text: mainText, additionalText: nil, openValue: mainUsernameValue)
        }
    } else if shouldDisplayVisualTag {
        if nftUsernamePrice.isEmpty {
            return EahatGramDisplayedUsername(text: "@\(nftUsernameTag)", additionalText: nil, openValue: nil)
        } else {
            return EahatGramDisplayedUsername(text: "@\(nftUsernameTag)", additionalText: "куплен за \(nftUsernamePrice)", openValue: nil)
        }
    } else {
        return EahatGramDisplayedUsername(text: nil, additionalText: nil, openValue: nil)
    }
}

#endif

func eahatGramDisplayedUsername(mainUsername: String?, additionalActiveUsernames: [String], isMyProfile: Bool) -> EahatGramDisplayedUsername {
    let normalizedMainUsername = mainUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
    let mainUsernameValue = (normalizedMainUsername?.isEmpty == false) ? normalizedMainUsername : nil
    guard isMyProfile else {
        if let mainUsernameValue {
            return EahatGramDisplayedUsername(text: "@\(mainUsernameValue)", additionalText: nil, openValue: mainUsernameValue)
        } else {
            return EahatGramDisplayedUsername(text: nil, additionalText: nil, openValue: nil)
        }
    }
    if let visualCollectibleUsername = eahatGramDisplayedVisualCollectibleUsername(mainUsername: mainUsername, additionalActiveUsernames: additionalActiveUsernames, isMyProfile: isMyProfile) {
        if let mainUsernameValue {
            let additionalText: String
            if additionalActiveUsernames.isEmpty {
                additionalText = "а также @\(visualCollectibleUsername.username)"
            } else {
                additionalText = "@\(visualCollectibleUsername.username)"
            }
            return EahatGramDisplayedUsername(text: "@\(mainUsernameValue)", additionalText: additionalText, openValue: mainUsernameValue)
        } else {
            return EahatGramDisplayedUsername(text: "@\(visualCollectibleUsername.username)", additionalText: nil, openValue: nil)
        }
    }
    if let mainUsernameValue {
        return EahatGramDisplayedUsername(text: "@\(mainUsernameValue)", additionalText: nil, openValue: mainUsernameValue)
    } else {
        return EahatGramDisplayedUsername(text: nil, additionalText: nil, openValue: nil)
    }
}

func eahatGramDisplayedUsernameText(mainUsername: String?, additionalActiveUsernames: [String], isMyProfile: Bool) -> String {
    let displayedUsername = eahatGramDisplayedUsername(mainUsername: mainUsername, additionalActiveUsernames: additionalActiveUsernames, isMyProfile: isMyProfile)
    if let text = displayedUsername.text, let additionalText = displayedUsername.additionalText, !additionalText.isEmpty {
        return "\(text) \(additionalText)"
    } else {
        return displayedUsername.text ?? ""
    }
}

func eahatGramDisplayedPhoneRaw(phone: String?, isMyProfile: Bool) -> String? {
    guard isMyProfile else {
        if let phone, !phone.isEmpty {
            return phone
        } else {
            return nil
        }
    }
    let fakePhoneNumber = EahatGramDebugSettings.fakePhoneNumber.with { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    if !fakePhoneNumber.isEmpty {
        return fakePhoneNumber
    } else if let phone, !phone.isEmpty {
        return phone
    } else {
        return nil
    }
}

func eahatGramDisplayedPhoneText(context: AccountContext, phone: String?, isMyProfile: Bool) -> String {
    guard let rawPhone = eahatGramDisplayedPhoneRaw(phone: phone, isMyProfile: isMyProfile) else {
        return ""
    }
    return formatPhoneNumber(context: context, number: rawPhone)
}

enum EahatGramTargetHudRentState: Equatable {
    case user
    case nft
    case nftAndUser
    case dontRent
}

struct EahatGramTargetHudStats: Equatable {
    let giftsCount: Int
    let giftsStarsCount: Int64?
    let nftCount: Int
    let nftUsdValue: Int64?
    let rentState: EahatGramTargetHudRentState
}

final class EahatGramTargetHudStatsContext {
    private let context: AccountContext
    private let giftsContext: ProfileGiftsContext
    private let keepUpdatedDisposable = MetaDisposable()
    private let giftsStateDisposable = MetaDisposable()
    private let peerDisposable = MetaDisposable()
    private let userRentDisposable = MetaDisposable()

    private var currentGiftsState: ProfileGiftsContext.State?
    private var currentPeer: EnginePeer?
    private var currentUserRentState: Bool?
    private var currentUserRentLookupKey: String?

    private let stateValue = ValuePromise<EahatGramTargetHudStats?>(EahatGramTargetHudStats(
        giftsCount: 0,
        giftsStarsCount: 0,
        nftCount: 0,
        nftUsdValue: 0,
        rentState: .dontRent
    ), ignoreRepeated: true)
    var state: Signal<EahatGramTargetHudStats?, NoError> {
        return self.stateValue.get()
    }

    init(context: AccountContext, peerId: EnginePeer.Id) {
        self.context = context
        self.giftsContext = ProfileGiftsContext(account: context.account, peerId: peerId, filter: .All, limit: 200)

        self.keepUpdatedDisposable.set(context.engine.payments.keepStarGiftsUpdated().start())
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
        self.peerDisposable.set((context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self else {
                return
            }
            self.currentPeer = peer
            self.refreshUserRentState()
        }))
    }

    deinit {
        self.keepUpdatedDisposable.dispose()
        self.giftsStateDisposable.dispose()
        self.peerDisposable.dispose()
        self.userRentDisposable.dispose()
    }

    private func refreshUserRentState() {
        guard let currentPeer = self.currentPeer else {
            self.currentUserRentState = nil
            self.currentUserRentLookupKey = nil
            self.userRentDisposable.set(nil)
            return
        }
        guard case let .user(user) = currentPeer else {
            self.currentUserRentState = false
            self.currentUserRentLookupKey = nil
            self.userRentDisposable.set(nil)
            self.updateStatsIfReady()
            return
        }

        var collectibleUsernameCandidates: [String] = []
        var seenUsernames = Set<String>()

        if let username = user.username {
            let normalizedUsername = eahatGramNormalizedCollectibleUsername(username)
            if !normalizedUsername.isEmpty, seenUsernames.insert(normalizedUsername).inserted {
                collectibleUsernameCandidates.append(normalizedUsername)
            }
        }
        for username in user.usernames {
            let normalizedUsername = eahatGramNormalizedCollectibleUsername(username.username)
            if !normalizedUsername.isEmpty, seenUsernames.insert(normalizedUsername).inserted {
                collectibleUsernameCandidates.append(normalizedUsername)
            }
        }

        if collectibleUsernameCandidates.isEmpty {
            self.currentUserRentState = false
            self.currentUserRentLookupKey = ""
            self.userRentDisposable.set(nil)
            self.updateStatsIfReady()
            return
        }

        let lookupKey = collectibleUsernameCandidates.sorted().joined(separator: "|")
        if self.currentUserRentLookupKey == lookupKey {
            return
        }

        self.currentUserRentLookupKey = lookupKey
        self.currentUserRentState = false
        self.updateStatsIfReady()
        self.userRentDisposable.set((combineLatest(collectibleUsernameCandidates.map { username in
            eahatGramCollectibleUsernameOwnerSignal(context: self.context, username: username)
        })
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] owners in
            guard let self else {
                return
            }
            let uniqueOwners = Set(owners.compactMap { $0 })
            self.currentUserRentState = uniqueOwners.count > 1
            self.updateStatsIfReady()
        }))
    }

    private func updateStatsIfReady() {
        guard let currentGiftsState = self.currentGiftsState else {
            return
        }
        let currentUserRentState = self.currentUserRentState ?? false

        let gifts = currentGiftsState.gifts

        var nftCount = 0
        var genericGiftCount = 0
        var giftsStarsCount: Int64 = 0
        var nftUsdValue: Int64 = 0
        var hasMissingNftUsdValue = false
        var hostedOwnerAddresses = Set<String>()

        for gift in gifts {
            switch gift.gift {
            case let .generic(baseGift):
                genericGiftCount += 1
                giftsStarsCount += baseGift.price
            case let .unique(uniqueGift):
                nftCount += 1
                let isOnSale = !(uniqueGift.resellAmounts ?? []).isEmpty
                if !isOnSale {
                    if let valueUsdAmount = uniqueGift.valueUsdAmount {
                        nftUsdValue += valueUsdAmount
                    } else if let valueAmount = uniqueGift.valueAmount, uniqueGift.valueCurrency?.uppercased() == "USD" {
                        nftUsdValue += valueAmount
                    } else {
                        hasMissingNftUsdValue = true
                    }
                }

                if uniqueGift.giftAddress != nil, case let .address(ownerAddress)? = uniqueGift.owner {
                    hostedOwnerAddresses.insert(ownerAddress)
                }
            }
        }

        let hasNftRent = hostedOwnerAddresses.count > 1
        let hasUserRent = currentUserRentState
        let rentState: EahatGramTargetHudRentState
        if hasNftRent && hasUserRent {
            rentState = .nftAndUser
        } else if hasNftRent {
            rentState = .nft
        } else if hasUserRent {
            rentState = .user
        } else {
            rentState = .dontRent
        }

        self.stateValue.set(EahatGramTargetHudStats(
            giftsCount: genericGiftCount,
            giftsStarsCount: giftsStarsCount,
            nftCount: nftCount,
            nftUsdValue: hasMissingNftUsdValue ? nil : nftUsdValue,
            rentState: rentState
        ))
    }
}

final class EahatGramTargetHudNode: ASDisplayNode {
    static let preferredSize = CGSize(width: 260.0, height: 128.0)

    private let outerNode = ASDisplayNode()
    private let innerNode = ASDisplayNode()
    private let avatarFrameNode = ASDisplayNode()
    private let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 16.0))
    private let accentNode = ASDisplayNode()
    private let accentGradientLayer = CAGradientLayer()
    private let rentNode = ImmediateTextNode()
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

        for textNode in [self.rentNode, self.nameNode, self.tagNode, self.idNode, self.giftsNode, self.nftNode] {
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
        self.innerNode.addSubnode(self.rentNode)
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

        self.nameNode.attributedText = NSAttributedString(
            string: peer.compactDisplayTitle,
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
        let rentText: String?
        if let stats {
            let starsText: String
            if let giftsStarsCount = stats.giftsStarsCount {
                starsText = "\(giftsStarsCount)"
            } else {
                starsText = "?"
            }
            let nftUsdText: String
            if let nftUsdValue = stats.nftUsdValue {
                nftUsdText = formatCurrencyAmount(nftUsdValue, currency: "USD")
            } else {
                nftUsdText = "?"
            }
            giftsText = "gifts: \(stats.giftsCount) | \(starsText) stars"
            nftText = "nft: \(stats.nftCount) | \(nftUsdText)"
            switch stats.rentState {
            case .user:
                rentText = "rent: user"
            case .nft:
                rentText = "rent: nft"
            case .nftAndUser:
                rentText = "rent: nft+user"
            case .dontRent:
                rentText = "dont rent"
            }
        } else {
            giftsText = "gifts: loading"
            nftText = "nft: loading"
            rentText = nil
        }

        if let rentText {
            let rentColor: UIColor
            if let stats, stats.rentState != .dontRent {
                rentColor = UIColor(red: 1.00, green: 0.24, blue: 0.24, alpha: 1.0)
            } else {
                rentColor = UIColor(red: 0.72, green: 0.92, blue: 0.72, alpha: 1.0)
            }
            self.rentNode.attributedText = NSAttributedString(
                string: rentText,
                font: Font.with(size: 11.0, weight: .semibold, traits: .monospacedNumbers),
                textColor: rentColor
            )
        } else {
            self.rentNode.attributedText = nil
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

        self.avatarFrameNode.frame = CGRect(x: 8.0, y: 8.0, width: 58.0, height: max(58.0, self.innerNode.bounds.height - 16.0))
        self.avatarNode.frame = self.avatarFrameNode.bounds.insetBy(dx: 2.0, dy: 2.0)

        let textOriginX: CGFloat = 76.0
        let textWidth = self.innerNode.bounds.width - textOriginX - 8.0

        let rentSize = self.rentNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.rentNode.frame = CGRect(origin: CGPoint(x: textOriginX, y: 4.0), size: rentSize)

        let nameSize = self.nameNode.updateLayout(CGSize(width: textWidth, height: 24.0))
        self.nameNode.frame = CGRect(origin: CGPoint(x: textOriginX, y: 20.0), size: nameSize)

        self.accentNode.frame = CGRect(x: textOriginX, y: 45.0, width: min(textWidth, 120.0), height: 3.0)
        self.accentGradientLayer.frame = self.accentNode.bounds

        let tagSize = self.tagNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.tagNode.frame = CGRect(origin: CGPoint(x: textOriginX, y: 53.0), size: tagSize)

        let idSize = self.idNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.idNode.frame = CGRect(origin: CGPoint(x: textOriginX, y: 68.0), size: idSize)

        let giftsSize = self.giftsNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.giftsNode.frame = CGRect(origin: CGPoint(x: textOriginX, y: 83.0), size: giftsSize)

        let nftSize = self.nftNode.updateLayout(CGSize(width: textWidth, height: 14.0))
        self.nftNode.frame = CGRect(origin: CGPoint(x: textOriginX, y: 98.0), size: nftSize)
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
