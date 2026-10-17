import SwiftUI

/// N1 New message (DESIGN N1): pick the From account first, then search Instagram *as that account* and open the DM.
/// Choosing the account before anything else means a chat can't start from the wrong one (DESIGN §0). In an account
/// scope it's preselected; in All nothing is, and the search stays off until a chip is picked.
struct NewMessageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Called with the room to open once the sheet is gone.
    let open: (String) -> Void
    @State private var from: String?
    @State private var query = ""
    @State private var search: Search = .idle
    /// The result being opened (spinner on its row).
    @State private var opening: String?
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    private enum Search: Equatable {
        case idle, searching, failed
        case done([BridgeAPI.Contact])
    }

    /// Each search is an Instagram request: 300 ms after the last keystroke (DESIGN N1), and not for one letter.
    private static let minimumQuery = 2

    init(scope: Inbox.Scope, accounts: [BridgeAPI.Login], open: @escaping (String) -> Void) {
        self.open = open
        // One account leaves nothing to choose; DESIGN N1's "nothing preselected" is about picking between several.
        let preselected: String? = if case .account(let id) = scope { id } else if accounts.count == 1 { accounts[0].id } else { nil }
        _from = State(initialValue: preselected)
    }

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = from.flatMap { id in model.accounts.first { $0.id == id } }
        let name = from.flatMap { model.identities[$0]?.name } ?? login?.displayName ?? "this account"
        NavigationStack {
            List {
                Section {
                    FromChips(selection: $from)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    Text("From")
                }
                Section {
                    HStack(spacing: 8) {
                        Text("To:").foregroundStyle(.inkSecondary)
                        TextField("To", text: $query, prompt: Text(from == nil ? "Choose an account first" : "Search Instagram")
                            .foregroundStyle(.inkSecondary))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .focused($searchFocused)
                            .disabled(from == nil)
                            .accessibilityIdentifier("newMessage.to")
                        if search == .searching { ProgressView() }
                    }
                    results(trimmed: trimmed, name: name)
                } footer: {
                    if let username = login?.profile?.username { Text("Searching Instagram from @\(username)") }
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("newMessage.cancel")
                }
            }
            .environment(\.markRing, Color(.secondarySystemGroupedBackground))
        }
        .presentationDetents([.large])
        .onChange(of: from) { _, new in if new != nil { searchFocused = true } }
        .onAppear { if from != nil { searchFocused = true } }
        // Debounce: a new keystroke or account cancels the waiting search and starts over.
        .task(id: [from ?? "", trimmed]) {
            guard let from, trimmed.count >= Self.minimumQuery else { search = .idle; return }
            search = .searching
            do {
                try await Task.sleep(for: .milliseconds(300))
                search = .done(try await model.searchUsers(trimmed, from: from))
            } catch {
                if !Task.isCancelled { search = .failed }
            }
        }
        .alert("Couldn't open the chat", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder private func results(trimmed: String, name: String) -> some View {
        switch search {
        case .idle, .searching:
            EmptyView()
        case .failed:
            Text("Couldn't search from \(name). Check that it's connected.").foregroundStyle(.inkSecondary)
                .accessibilityIdentifier("newMessage.error")
        case .done(let contacts) where contacts.isEmpty:
            Text("No Instagram accounts match “\(trimmed)”").foregroundStyle(.inkSecondary)
                .accessibilityIdentifier("newMessage.empty")
        case .done(let contacts):
            ForEach(contacts) { contact in
                if let from { row(contact, from: from) }
            }
        }
    }

    private func row(_ contact: BridgeAPI.Contact, from: String) -> some View {
        let existing = Inbox.existingDM(with: contact.id, account: from, in: model.rooms.values) != nil
        let detail = [contact.handle.map { "@\($0)" }, existing ? "Open chat" : nil].compactMap(\.self).joined(separator: " · ")
        return Button { start(contact, from: from) } label: {
            HStack(spacing: 12) {
                MXCImage(mxc: contact.avatarURL, size: 36, initial: contact.name ?? contact.handle ?? "?")
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.name ?? contact.handle ?? contact.id).font(.body.weight(.semibold)).foregroundStyle(Color.primary)
                    if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.inkSecondary) }
                }
                Spacer(minLength: 0)
                if opening == contact.id { ProgressView() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(opening != nil)
        .accessibilityIdentifier("newMessage.result")
    }

    private func start(_ contact: BridgeAPI.Contact, from: String) {
        opening = contact.id
        Task {
            defer { opening = nil }
            do {
                let roomID = try await model.openDM(with: contact, from: from)
                open(roomID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// DESIGN N1's From row: one chip per account (mark and name), the chosen one filled with its color like a scope
/// chip. Wraps to a scrolling row when the chips don't fit.
private struct FromChips: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips.fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal) { chips }.scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(model.orderedAccounts) { login in
                if let identity = model.identities[login.id] { chip(login, identity) }
            }
        }
        .padding(.vertical, 4)
    }

    private func chip(_ login: BridgeAPI.Login, _ identity: AccountIdentity) -> some View {
        let selected = selection == login.id
        return Button {
            withAnimation(.snappy(duration: 0.25)) { selection = login.id }
        } label: {
            HStack(spacing: 6) {
                AccountMark(identity: identity, size: 20, inverted: selected)
                Text(identity.name).lineLimit(1)
                if login.health.needsUser { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 4)
            .frame(minHeight: 36)
            .background(selected ? identity.color.fill : Color(.tertiarySystemFill), in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(login.profile?.username.map { "\(identity.name) account, @\($0)" } ?? "\(identity.name) account")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("newMessage.from.\(login.id)")
    }
}
