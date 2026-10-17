import SwiftUI

/// Name, color and mark (DESIGN O5, A2): a live preview of exactly what changes, then the three fields. Taken colors
/// show their owner's mark and can't be picked; a taken name or mark says so under its field. Sections only: the
/// caller puts it in a `Form` and decides when to save (`AccountIdentity.problems` empty).
struct IdentityEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AccountIdentity
    let loginID: String
    let login: BridgeAPI.Login?
    /// The mark field's own text: a field bound straight to a normalizing binding keeps showing what was typed ("Pk").
    @State private var markText = ""

    var body: some View {
        let problems = AccountIdentity.problems(draft, for: loginID, among: model.identities)
        let others = model.identities.filter { $0.key != loginID }.values.sorted { $0.order < $1.order }
        Section {
            IdentityPreview(identity: draft, login: login)
        }
        Section {
            TextField("Name", text: $draft.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .onChange(of: draft.name) { _, name in
                    if name.count > AccountIdentity.maxNameLength { draft.name = String(name.prefix(AccountIdentity.maxNameLength)) }
                }
                .accessibilityIdentifier("identity.name")
            Chips(AccountIdentity.nameSuggestions(instagramName: login?.displayName, taken: Set(others.map(\.name))),
                  selected: draft.name) { name in
                // A mark that was the old name's initial follows the new name; one picked by hand stays.
                let followsName = draft.mark == AccountIdentity.normalizedMark(String(draft.name.prefix(1)))
                draft.name = name
                if followsName, let first = AccountIdentity.markSuggestions(name: name, taken: Set(others.map(\.mark))).first {
                    draft.mark = first
                }
            }
        } header: {
            Text("Name")
        } footer: {
            if let problem = problems.first(where: \.isAboutName) { Text(problem.message) }
        }
        Section {
            Swatches(selected: $draft.color, loginID: loginID)
        } header: {
            Text("Color")
        } footer: {
            let taken = AccountColor.allCases.compactMap { color in others.first { $0.color == color }.map { "\(color.name) is used by \($0.name)." } }
            if !taken.isEmpty { Text(taken.joined(separator: " ")) }
        }
        Section {
            HStack(spacing: 12) {
                AccountMark(identity: draft, size: 30)
                TextField("Mark", text: $markText)
                    .frame(width: 56)
                    .onChange(of: markText) { _, text in
                        let mark = AccountIdentity.normalizedMark(text)
                        if draft.mark != mark { draft.mark = mark }
                        if text != mark { markText = mark }
                    }
                    .onChange(of: draft.mark, initial: true) { _, mark in if markText != mark { markText = mark } }
                    .accessibilityLabel("Mark")
                    .accessibilityIdentifier("identity.mark")
                Spacer(minLength: 0)
            }
            Chips(AccountIdentity.markSuggestions(name: draft.name, taken: Set(others.map(\.mark))), selected: draft.mark) { draft.mark = $0 }
        } header: {
            Text("Mark")
        } footer: {
            if let problem = problems.first(where: \.isAboutMark) {
                Text(problem.message)
            } else {
                Text("One letter or emoji, shown on every chat from this account.")
            }
        }
    }
}

extension AccountColor {
    var name: String { rawValue.capitalized }
}

/// DESIGN O5 preview card: an inbox row with this account's mark, an outgoing bubble in its color, the composer.
private struct IdentityPreview: View {
    let identity: AccountIdentity
    let login: BridgeAPI.Login?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                MXCImage(mxc: nil, size: 44, initial: "Maya")
                    .overlay { AccountMark(identity: identity, size: 18, ring: 2).position(x: 44 * 0.84, y: 44 * 0.84) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Maya Chen").font(.headline)
                    Text("Sent a reel by @tidepool.films").font(.subheadline).foregroundStyle(.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("9:41").font(.subheadline).foregroundStyle(.inkSecondary)
            }
            Text("On my way!")
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(identity.color.fill, in: .rect(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(spacing: 8) {
                AccountAvatar(identity: identity, avatarURL: login?.profile?.avatar, initial: login?.displayName ?? identity.name, size: 24)
                Text("Message as \(identity.name.isEmpty ? "…" : identity.name)").foregroundStyle(.inkSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: .capsule)
        }
        .animation(.snappy(duration: 0.25), value: identity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: chats show the mark \(identity.mark), your messages are \(identity.color.name), and the composer says Message as \(identity.name).")
    }
}

/// 8 swatches, 36 pt, 2 rows of 4 (DESIGN O5). Selected: checkmark and an outer ring. Taken: the owner's mark at
/// 40%, not selectable.
private struct Swatches: View {
    @Environment(AppModel.self) private var model
    @Binding var selected: AccountColor
    let loginID: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
            ForEach(AccountColor.allCases, id: \.self) { color in
                let owner = AccountIdentity.owner(of: color, excluding: loginID, in: model.identities)
                Button { selected = color } label: {
                    ZStack {
                        // Taken: a 40% fill with the owner's mark in the full color (a white mark on the faded fill
                        // couldn't be read).
                        Circle().fill(color.fill.opacity(owner == nil ? 1 : 0.4))
                        if color == selected {
                            Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        } else if let owner {
                            Text(owner.mark).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(color.ink)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .overlay { if color == selected { Circle().strokeBorder(color.fill, lineWidth: 2).padding(-4) } }
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(owner != nil)
                .accessibilityLabel(owner.map { "\(color.name), used by \($0.name)" } ?? color.name)
                .accessibilityAddTraits(color == selected ? .isSelected : [])
                .accessibilityIdentifier("identity.color.\(color.rawValue)")
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// A scrolling row of suggestion capsules; the current value gets an outline.
private struct Chips: View {
    let values: [String]
    let selected: String
    let pick: (String) -> Void

    init(_ values: [String], selected: String, pick: @escaping (String) -> Void) {
        self.values = values
        self.selected = selected
        self.pick = pick
    }

    var body: some View {
        if !values.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(values, id: \.self) { value in
                        Button { pick(value) } label: {
                            Text(value)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .frame(minWidth: 36, minHeight: 32)
                                .background(Color(.tertiarySystemFill), in: .capsule)
                                .overlay { if value == selected { Capsule().strokeBorder(.primary, lineWidth: 1.5) } }
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(value == selected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Edge to edge inside the card, first chip still at the row's 16 pt: inset rows cut chips hard at the
            // card's inner padding ("Stud", review 2026-10-15 #13).
            .scrollClipDisabled()
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .listRowInsets(EdgeInsets())
        }
    }
}
