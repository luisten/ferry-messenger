import SwiftUI

/// DESIGN §3.4 account palette. Fills are the same in both modes (all ≥ 4.99:1 with white text); "ink" is the
/// account color for text and lightens in dark mode; "wash" is the fill at 12% (light) / 22% (dark).
nonisolated enum AccountColor: String, CaseIterable, Codable, Sendable {
    case ocean, ember, grape, teal, berry, moss, cocoa, slate

    private var hex: (fill: UInt32, darkInk: UInt32) {
        switch self {
        case .ocean: (0x1F5FD6, 0x7FAAF7)
        case .ember: (0xC2410C, 0xF59A6B)
        case .grape: (0x7A3FD1, 0xB897F5)
        case .teal: (0x0F766E, 0x5FCFC3)
        case .berry: (0xC2255C, 0xF27DA6)
        case .moss: (0x4D7C0F, 0xA3CF5F)
        case .cocoa: (0x8A5A2B, 0xD6A877)
        case .slate: (0x475B78, 0xA9B8CF)
        }
    }

    var fill: Color { Color(UIColor(rgb: hex.fill)) }

    var ink: Color {
        let (fill, darkInk) = hex
        return traitColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: darkInk) : UIColor(rgb: fill) }
    }

    var wash: Color {
        let fill = hex.fill
        return traitColor { UIColor(rgb: fill).withAlphaComponent($0.userInterfaceStyle == .dark ? 0.22 : 0.12) }
    }
}

/// How the user tells their Instagram accounts apart (DESIGN §3.1): name, color and a one-grapheme mark, plus the
/// scope-bar order. Keyed by bridge login ID and stored locally in v1 (DESIGN §14).
nonisolated struct AccountIdentity: Codable, Equatable, Sendable {
    var name: String
    var color: AccountColor
    var mark: String
    var order: Int

    /// Gives every login without an identity a default: its Instagram name (or @username if that name is taken),
    /// the next unused palette color, and the first unused letter of its name. Existing identities are kept.
    static func withDefaults(_ existing: [String: AccountIdentity], for logins: [BridgeAPI.Login]) -> [String: AccountIdentity] {
        var result = existing
        for login in logins where result[login.id] == nil {
            let taken = Array(result.values)
            let names = Set(taken.map { $0.name.lowercased() })
            let name = [login.displayName, login.profile?.username ?? login.id].map { String($0.prefix(16)) }
                .first { !names.contains($0.lowercased()) } ?? String(login.id.suffix(16))
            let color = AccountColor.allCases.first { color in !taken.contains { $0.color == color } }
                ?? AccountColor.allCases[taken.count % AccountColor.allCases.count]  // more than 8 accounts: reuse
            let marks = Set(taken.map { $0.mark.uppercased() })
            let candidates = name.uppercased().filter(\.isLetter).map(String.init) + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
            let mark = candidates.first { !marks.contains($0) } ?? "•"
            let order = (taken.map(\.order).max() ?? -1) + 1
            result[login.id] = AccountIdentity(name: name, color: color, mark: mark, order: order)
        }
        return result
    }

    /// The scope-bar order after a drag in Accounts: `ids` in their new order; identities not listed keep theirs.
    static func reordered(_ identities: [String: AccountIdentity], ids: [String]) -> [String: AccountIdentity] {
        var result = identities
        for (index, id) in ids.enumerated() { result[id]?.order = index }
        return result
    }

    // MARK: Editing (O5, A2; DESIGN §3.1, §3.6 rule 1: no two accounts share a color, mark or name)

    static let maxNameLength = 16

    enum Problem: Equatable, Sendable {
        case nameEmpty
        /// The other account's name.
        case nameTaken(by: String)
        case markEmpty
        case markTaken(by: String)
        case colorTaken(by: String)

        var isAboutName: Bool {
            switch self {
            case .nameEmpty, .nameTaken: true
            default: false
            }
        }

        var isAboutMark: Bool {
            switch self {
            case .markEmpty, .markTaken: true
            default: false
            }
        }

        var message: String {
            switch self {
            case .nameEmpty: "Give this account a name."
            case .nameTaken(let other): "\(other) already uses this name."
            case .markEmpty: "Pick a letter or an emoji."
            case .markTaken(let other): "\(other) already uses this mark."
            case .colorTaken(let other): "\(other) already uses this color."
            }
        }
    }

    /// What stops `draft` from being saved for `loginID`, given every account's identity (its own included).
    static func problems(_ draft: AccountIdentity, for loginID: String, among identities: [String: AccountIdentity]) -> [Problem] {
        let others = identities.filter { $0.key != loginID }.values.sorted { $0.order < $1.order }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        var problems: [Problem] = []
        if name.isEmpty { problems.append(.nameEmpty) }
        else if let other = others.first(where: { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame }) {
            problems.append(.nameTaken(by: other.name))
        }
        if draft.mark.isEmpty { problems.append(.markEmpty) }
        else if let other = others.first(where: { $0.mark.uppercased() == draft.mark.uppercased() }) { problems.append(.markTaken(by: other.name)) }
        if let other = others.first(where: { $0.color == draft.color }) { problems.append(.colorTaken(by: other.name)) }
        return problems
    }

    /// The account already using `color`, if it isn't `loginID` (taken swatches show its mark, DESIGN O5).
    static func owner(of color: AccountColor, excluding loginID: String, in identities: [String: AccountIdentity]) -> AccountIdentity? {
        identities.first { $0.key != loginID && $0.value.color == color }?.value
    }

    /// One grapheme: the last one typed, as a capital if it's a letter.
    static func normalizedMark(_ text: String) -> String {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return "" }
        let upper = String(last).uppercased()
        return upper.count == 1 ? upper : String(last)  // "ß" uppercases to two letters
    }

    /// Mark chips (DESIGN O5): the first distinct letters of the name, then a few emoji, minus marks already taken. No
    /// camera: next to "Instagram" it was the one Instagram-like glyph in the app (review 2026-10-15 #12).
    static func markSuggestions(name: String, taken: Set<String>) -> [String] {
        var letters: [String] = []
        for letter in name.uppercased().filter(\.isLetter).map(String.init) where !letters.contains(letter) && !taken.contains(letter) {
            letters.append(letter)
        }
        return Array(letters.prefix(3)) + ["✦", "⛵️", "🌊"].filter { !taken.contains($0) }
    }

    /// Name chips (DESIGN O5): the Instagram name, then common labels, minus names already taken.
    static func nameSuggestions(instagramName: String?, taken: Set<String>) -> [String] {
        let candidates = [instagramName.map { String($0.prefix(maxNameLength)) }].compactMap(\.self) + ["Personal", "Work", "Studio", "Shop", "Creator"]
        let lowered = Set(taken.map { $0.lowercased() })
        var result: [String] = []
        for name in candidates where !lowered.contains(name.lowercased()) && !result.contains(name) { result.append(name) }
        return Array(result.prefix(4))
    }

    private static let defaultsKey = "accountIdentities"

    static func load(from defaults: UserDefaults = .standard) -> [String: AccountIdentity] {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([String: AccountIdentity].self, from: $0) } ?? [:]
    }

    static func save(_ identities: [String: AccountIdentity], to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(identities), forKey: defaultsKey)
    }
}

// MARK: - Views (DESIGN §3.2, §3.5)

/// Filled circle in the account color with the mark in white rounded bold. `ring` adds the cut-out in the
/// surface color used when the mark sits on an avatar; `inverted` is the selected scope chip (white disc).
struct AccountMark: View {
    let identity: AccountIdentity
    var size: CGFloat = 20
    var ring: CGFloat = 0
    var inverted = false
    @ScaledMetric(relativeTo: .caption2) private var scale: CGFloat = 1
    @Environment(\.markRing) private var ringColor

    var body: some View {
        let side = size * min(scale, 1.4)  // grows with Dynamic Type, capped at 1.4× (DESIGN §3.5)
        Text(identity.mark)
            .font(.system(size: side * 0.55, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(inverted ? identity.color.fill : .white)
            .frame(width: side, height: side)
            .background(inverted ? Color.white : identity.color.fill, in: .circle)
            .padding(ring)
            .background(ring > 0 ? ringColor : .clear, in: .circle)
            .accessibilityHidden(true)  // its meaning goes into the parent's label (DESIGN §3.7)
    }
}

extension EnvironmentValues {
    /// The surface a mark's cut-out ring matches: the screen background, or the cell color inside a `Form`.
    @Entry var markRing = Color(.systemBackground)
}

/// Capsule with mark and name (optionally the handle): thread header, requests sections, banners. Where space is
/// short (the thread header at large text sizes) it can show only the name's first word, or only the mark. `compact`
/// is the thread header's, under the name inside its 44 pt capsule.
struct AccountTag: View {
    let identity: AccountIdentity
    var handle: String?
    var length = Length.full
    var compact = false

    enum Length { case full, firstWord, markOnly }

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            AccountMark(identity: identity, size: compact ? 14 : 16)
            switch length {
            case .full: Text(identity.name).fontWeight(.semibold)
            case .firstWord: Text(identity.name.split(separator: " ").first.map(String.init) ?? identity.name).fontWeight(.semibold)
            case .markOnly: EmptyView()
            }
            if let handle, length == .full { Text("· @\(handle)") }
        }
        .font(compact ? .caption : .footnote)
        .lineLimit(1)
        .foregroundStyle(identity.color.ink)
        .padding(.leading, compact ? 2 : 3)
        .padding(.trailing, length == .markOnly ? (compact ? 2 : 3) : (compact ? 7 : 9))
        .frame(height: compact ? 18 : 22)
        .background(identity.color.wash, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(handle.map { "\(identity.name) account, @\($0)" } ?? "\(identity.name) account")
    }
}

/// One of *your* accounts: its Instagram avatar with a gap and a ring in the account color, mark at bottom-right.
/// The ring is drawn outside the frame (like the mockup's box-shadow), so `size` is the photo's size.
struct AccountAvatar: View {
    let identity: AccountIdentity?
    let avatarURL: String?
    var initial = ""
    var size: CGFloat = 44
    var showsMark = true

    var body: some View {
        let line: CGFloat = size <= 32 ? 1.5 : 2
        MXCImage(mxc: avatarURL, size: size, initial: initial)
            .overlay {
                if let identity { Circle().strokeBorder(identity.color.fill, lineWidth: line).padding(-2 * line) }
            }
            .overlay {
                if showsMark, let identity {
                    AccountMark(identity: identity, size: max(12, size * 0.4), ring: line).position(x: size * 0.84, y: size * 0.84)
                }
            }
    }
}

/// The account's color as a faint wash fading down from the top (DESIGN §3.3: account scope, thread toolbar).
/// Dropped with Reduce Transparency (DESIGN §8.5).
struct AccountWash: View {
    let identity: AccountIdentity
    var height: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !reduceTransparency {
            LinearGradient(colors: [identity.color.wash, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: height)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }
}
