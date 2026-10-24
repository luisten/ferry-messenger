import SwiftUI

/// A1 Accounts (DESIGN A1): each account's health with the fix inline, drag to reorder the scope bar, tap for A2, and
/// "Add Instagram account". No sign-out: each account has Remove (A2). Presented as a sheet from the inbox's account stack. Not in v1:
/// the Privacy and Reels sections (no read-receipt opt-out yet; no auto-download).
struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var connecting = false
    @State private var detail: String?
    @State private var relogin: ReloginTarget?

    var body: some View {
        List {
            Section {
                if model.accounts.isEmpty {
                    Text("No accounts yet").foregroundStyle(.secondary)
                }
                ForEach(model.orderedAccounts) { login in
                    AccountRow(login: login, open: { detail = login.id }, logIn: { relogin = ReloginTarget(id: login.id) })
                }
                .onMove { model.moveAccounts(from: $0, to: $1) }
                Button("Add Instagram account", systemImage: "plus") { connecting = true }
                    .accessibilityIdentifier("accounts.add")
            } header: {
                Text("Instagram accounts")
            } footer: {
                Text(model.accounts.count > 1 ? "Each chat stays tied to the account it belongs to. Touch and hold an account, then drag to reorder the scope bar."
                     : "Each chat stays tied to the account it belongs to.")
            }
            Section {
                NotificationsRow()
            } header: {
                Text("Notifications")
            } footer: {
                Text("Notifications come when iOS lets Ferry Messenger check, sometimes hours after a message arrives, and one that waits too long is skipped. None come after you swipe the app away, until you open it again. Reactions, and photos and videos taken with Instagram's camera, don't notify.")
                    .foregroundStyle(.inkSecondary)  // the List's own footer grey is 3.3:1
            }
            Section {} footer: {
                Text(Self.appVersion ?? "").accessibilityIdentifier("accounts.footer")
            }
        }
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)  // A1 mockup: one row with the confirm button
        .navigationDestination(item: $detail) { AccountDetailView(loginID: $0) }
        .refreshable { await model.refreshAccounts() }
        .task { await model.refreshAccounts() }
        .environment(\.markRing, Color(.secondarySystemGroupedBackground))
        // A new account opens its detail page, where it gets a name, color and mark (O5's editor).
        .sheet(isPresented: $connecting) { ConnectSheet(onConnected: { detail = $0 }) }
        .sheet(item: $relogin) { ReloginSheet(loginID: $0.id) }
    }

    /// "Ferry Messenger 1.0" (DESIGN A1 footer; no server any more).
    private static let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "Ferry Messenger \($0)" }
}

/// Catch-up notifications (docs/PLAN-push.md W4): on, off with the way to turn them on, or allowed but unable to arrive
/// because Background App Refresh is off for the app or Low Power Mode is on. Status lines carry a glyph, not colour
/// alone (DESIGN §7.1); HStacks, not Labels, for the same reason as `HealthLabel`.
private struct NotificationsRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var status: AppModel.NotificationStatus?

    var body: some View {
        Group {
            switch status {
            case .notAsked:
                Button("Turn On Notifications", systemImage: "bell") { Task { await model.turnOnNotifications(); await check() } }
            case .off:
                Button(action: openSettings) {
                    line("Notifications are off", opensSettings: true) {
                        Text("Turn them on in Settings.").foregroundStyle(.inkSecondary)
                    }
                }
            case .noRefresh:
                Button(action: openSettings) {
                    line("Notifications can't arrive", opensSettings: true) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Background App Refresh is off for Ferry Messenger. Turn it on in Settings, under General → Background App Refresh.")
                        }
                        .foregroundStyle(.statusWarn)
                    }
                }
            case .lowPower:
                line("Notifications are paused") {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "battery.25percent")
                        Text("Low Power Mode is on, so iOS won't let Ferry Messenger check.")
                    }
                    .foregroundStyle(.inkSecondary)
                }
            case .on:
                Label("Notifications are on", systemImage: "bell")
            case nil:  // for the moment the check takes; an empty view would never appear, so it never ran
                Label("Notifications", systemImage: "bell").foregroundStyle(.inkSecondary)
            }
        }
        .accessibilityIdentifier("accounts.notifications")
        .task { await check() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in Task { await check() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in Task { await check() } }
    }

    /// A state with its second line under the title (not the icon), and a chevron when the row opens Settings.
    private func line(_ title: String, opensSettings: Bool = false, @ViewBuilder detail: () -> some View) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    detail().font(.footnote)
                }
            } icon: {
                Image(systemName: "bell.slash")
            }
            if opensSettings {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }

    private func check() async { status = await model.notificationStatus() }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

/// One account: avatar, name, @handle and a status line with its glyph (DESIGN §7.1). "Log in" sits inline when the
/// account is signed out. Two separate buttons: one `List` row can't hold a link and a button that both work.
private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let login: BridgeAPI.Login
    let open: () -> Void
    let logIn: () -> Void

    var body: some View {
        let identity = model.identities[login.id]
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 14) {
                    AccountAvatar(identity: identity, avatarURL: login.profile?.avatar, initial: login.displayName, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity?.name ?? login.displayName).font(.headline)
                        if let username = login.profile?.username {
                            Text("@\(username)").font(.subheadline).foregroundStyle(.inkSecondary)
                        }
                        // Which account has Instagram's two tabs (review 2026-10-15 #8).
                        if login.isProfessional {
                            Text("Professional · Primary and General").font(.footnote).foregroundStyle(.inkSecondary)
                        }
                        HealthLabel(health: login.health).font(.caption)
                    }
                    Spacer(minLength: 0)
                    if login.health != .needsLogin {
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("accounts.row")
            if login.health == .needsLogin {
                Button("Log in", action: logIn).buttonStyle(.glassProminent).labelOnTint().accessibilityIdentifier("accounts.logIn")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Status glyph + label (DESIGN §7.1: status always carries a glyph, never color alone).
struct HealthLabel: View {
    let health: BridgeAPI.Login.Health

    var body: some View {
        // HStacks, not Labels: inside a List a Label's icon gets the row's wide icon column.
        HStack(spacing: 5) {
            switch health {
            case .connected: Image(systemName: "checkmark.circle.fill")
            case .connecting, .syncing, .reconnecting: ProgressView().controlSize(.mini)
            case .needsLogin: Image(systemName: "exclamationmark.triangle.fill")
            case .error: Image(systemName: "exclamationmark.circle.fill")
            }
            Text(health.label)
        }
        .foregroundStyle(color)
    }

    private var color: Color {
        switch health {
        case .connected: .statusOK
        case .connecting, .syncing, .reconnecting: .inkSecondary
        case .needsLogin: .statusWarn
        case .error: .statusError
        }
    }
}

// MARK: - A2 Account detail

/// DESIGN A2: header row, the name/color/mark editor with live preview (saved as you go, whenever it's valid), status
/// with the recovery action, the E2EE note, and Remove. No notification toggles (D6).
struct AccountDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let loginID: String
    @State private var draft: AccountIdentity?
    @State private var confirmingRemove = false
    @State private var removing = false
    @State private var error: String?
    @State private var relogin: ReloginTarget?

    var body: some View {
        if let login = model.accounts.first(where: { $0.id == loginID }), let identity = model.identities[loginID] {
            form(login, identity)
        } else {
            ContentUnavailableView("Account removed", systemImage: "person.crop.circle.badge.xmark")
        }
    }

    private func form(_ login: BridgeAPI.Login, _ identity: AccountIdentity) -> some View {
        let handle = login.profile?.username.map { "@\($0)" } ?? identity.name
        let editing = Binding(get: { draft ?? identity }, set: { draft = $0 })
        return Form {
            Section {
                // A compact row like A1's, without a second copy of the name (the title has it), so the editor starts
                // on the first screen (review 2026-10-14, finding 3).
                HStack(spacing: 14) {
                    AccountAvatar(identity: editing.wrappedValue, avatarURL: login.profile?.avatar, initial: login.displayName, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(handle)
                        HealthLabel(health: login.health).font(.subheadline)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            IdentityEditor(draft: editing, loginID: loginID, login: login)
            Section("Status") {
                LabeledContent("State", value: login.health.label)
                if let ts = login.state?.timestamp {
                    LabeledContent("Since", value: Date(timeIntervalSince1970: ts).formatted(.relative(presentation: .named)))
                }
                if case .error(let message?) = login.health { Text(message).font(.footnote).foregroundStyle(.inkSecondary) }
                if login.health == .needsLogin {
                    Button("Log in again") { relogin = ReloginTarget(id: loginID) }
                }
            }
            Section {
                Label("Instagram's end-to-end encrypted chats can't be shown here. Open them in Instagram.", systemImage: "lock")
                    .font(.footnote).foregroundStyle(.inkSecondary)
            }
            Section {
                Button(role: .destructive) { confirmingRemove = true } label: {
                    if removing { ProgressView() } else { Text("Remove Account…") }
                }
                .disabled(removing)
                .accessibilityIdentifier("account.remove")
            }
        }
        .navigationTitle(identity.name)
        .navigationBarTitleDisplayMode(.inline)
        .listSectionSpacing(.compact)  // the editor up to Mark on the first screen, as in O5
        .contentMargins(.top, 0, for: .scrollContent)
        .environment(\.markRing, Color(.secondarySystemGroupedBackground))
        .onChange(of: draft) { _, draft in
            guard var draft, AccountIdentity.problems(draft, for: loginID, among: model.identities).isEmpty else { return }
            draft.name = draft.name.trimmingCharacters(in: .whitespaces)
            if draft != model.identities[loginID] { model.setIdentity(draft, for: loginID) }
        }
        .sheet(item: $relogin) { ReloginSheet(loginID: $0.id) }
        // DESIGN A2 copy (DESIGN §16 Q2): no logout reaches Instagram; the session and the chats leave this iPhone.
        .alert("Remove \(identity.name)?", isPresented: $confirmingRemove) {
            Button("Remove Account", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chats from \(handle) leave Ferry Messenger on this iPhone. Your Instagram account and its chats on Instagram aren't affected. To add it back, you'll log in to Instagram again.")
        }
        .alert("Couldn't remove the account", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func remove() async {
        removing = true
        defer { removing = false }
        do {
            try await model.removeAccount(loginID)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

}

// MARK: - A3 Re-login

/// DESIGN A3: why the account needs a login, that nothing is lost, then "Log in again" opens the instagram.com sheet
/// for this account (PLAN §2.9). Closes itself once the account is no longer signed out.
struct ReloginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let loginID: String
    @State private var connecting = false

    var body: some View {
        let login = model.accounts.first { $0.id == loginID }
        let identity = model.identities[loginID]
        let name = identity?.name ?? login?.displayName ?? "this account"
        let handle = login?.profile?.username.map { "@\($0)" } ?? name
        let others = model.orderedAccounts.filter { $0.id != loginID && !$0.health.needsUser }
            .map { model.identities[$0.id]?.name ?? $0.displayName }
        VStack(spacing: 14) {
            AccountAvatar(identity: identity, avatarURL: login?.profile?.avatar, initial: login?.displayName ?? name, size: 64, showsMark: false)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.orange)
                        .padding(3).background(Color(.systemBackground), in: .circle).offset(x: 8, y: 8)
                }
                .padding(.top, 8)
            Text("Log in to \(name) again").font(.title2.bold()).multilineTextAlignment(.center)
            Text("Instagram ended the session for \(handle). This usually happens after a password change, or when Instagram resets logins.")
                .font(.subheadline).foregroundStyle(.inkSecondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Label("Your chats are safe. Missed messages sync after you log in.", systemImage: "checkmark.circle")
                if let line = Inbox.othersKeepWorking(others) { Label(line, systemImage: "checkmark.circle") }
            }
            .fixedSize(horizontal: false, vertical: true)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            Button { connecting = true } label: { Text("Log in again").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).labelOnTint().controlSize(.large)
                .accessibilityIdentifier("relogin.logIn")
            Button("Not now") { dismiss() }.accessibilityIdentifier("relogin.notNow")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .topTrailing) {
            // A3 mockup's close button, well away from "Log in again".
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly).font(.body.weight(.semibold)).foregroundStyle(Color.primary)
                .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
                .padding(12)
                .accessibilityIdentifier("relogin.close")
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $connecting, onDismiss: {
            if model.accounts.first(where: { $0.id == loginID })?.health != .needsLogin { dismiss() }
        }) {
            ConnectSheet(reloginID: loginID)
        }
    }
}
