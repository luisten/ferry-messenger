import SwiftUI

/// Onboarding until there's at least one account; then the inbox, the app's only root (no tab bar,
/// DESIGN §2.2).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [InboxRoute] = []
    /// Stays on once started, until the user finishes O5/O6: the first account makes onboarding "not needed" halfway
    /// through, and O4–O6 come after that.
    @State private var onboarding = Self.debugOnboarding

    var body: some View {
        Group {
            if onboarding {
                OnboardingView { onboarding = false }
            } else {
                NavigationStack(path: $path) { InboxView(path: $path) }
            }
        }
        .onChange(of: model.needsOnboarding, initial: true) { _, needed in if needed { onboarding = true; path = [] } }
        // A tapped notification's chat (catch-up notifications, docs/PLAN-push.md).
        .onChange(of: model.openRoom) { _, id in
            guard let id, !onboarding else { return }
            path = [.thread(id)]
            model.openRoom = nil
        }
        .tint(.primary)  // monochrome chrome: color means account (DESIGN §0.1); account scopes override it
        .overlay(alignment: .top) { toast }
        // One alert for failed thread and request actions, wherever they were started.
        .alert("Couldn't do that", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.actionError ?? "")
        }
        .animation(.smooth(duration: 0.3), value: model.toast)
    }

    private static var debugOnboarding: Bool {
        #if DEBUG
        DebugFixtures.onboardingStep != nil
        #else
        false
        #endif
    }

    /// "Accepted. This chat is now in Studio." (DESIGN T2), gone after a moment.
    @ViewBuilder private var toast: some View {
        if let text = model.toast {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(2.5))
                    if model.toast == text { model.toast = nil }
                }
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("toast")
        }
    }
}

/// The connection banner under the scope bar (PLAN §2.10, DESIGN §7.2/§7.3). Account banners have "Later", which
/// hides them until the next launch.
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model
    let banner: Inbox.Banner
    var logIn: (String) -> Void
    var openAccounts: () -> Void

    var body: some View {
        // Title and body get the full width, the buttons a row under them: beside them the title wrapped after the
        // account's name (review 2026-10-15 #10).
        HStack(alignment: .top, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Label(copy.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(BannerTitleStyle())
                Text(copy.body).font(.footnote).foregroundStyle(.inkSecondary)
                if copy.button != nil || isAboutAccounts {
                    HStack(spacing: 8) {
                        if let button = copy.button {
                            Button(button, action: action).buttonStyle(.glassProminent).labelOnTint().accessibilityIdentifier("banner.action")
                        }
                        if isAboutAccounts {
                            Button("Later") { model.hiddenBanner = banner }.buttonStyle(.bordered).accessibilityIdentifier("banner.later")
                        }
                    }
                    .controlSize(.small)
                    .font(.footnote.weight(.semibold))
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banner")
    }

    @ViewBuilder private var leading: some View {
        if case .account(let id) = banner, let login = model.accounts.first(where: { $0.id == id }) {
            AccountAvatar(identity: model.identities[id], avatarURL: login.profile?.avatar, initial: login.displayName,
                          size: 32, showsMark: false)
        }
    }

    private var isAboutAccounts: Bool {
        switch banner {
        case .account, .accounts: true
        case .offline: false
        }
    }

    private var copy: (title: String, body: String, button: String?) {
        switch banner {
        case .offline:
            return ("Can't reach Instagram", "Retrying. New messages arrive when it's back.", nil)
        case .accounts(let count):
            return ("\(count) accounts need attention", "Open Accounts to see what's wrong.", "Open")
        case .account(let id):
            let login = model.accounts.first { $0.id == id }
            let name = model.identities[id]?.name ?? login?.displayName ?? "An account"
            let handle = login?.profile?.username.map { "@\($0)" } ?? name
            switch login?.health {
            case .error:  // Instagram's own message is technical; A2 shows it
                return ("Can't connect \(name) to Instagram", "Retrying automatically. Your messages are safe.", nil)
            case .reconnecting:
                return ("Reconnecting to \(name)…", "Instagram dropped the connection. Retrying automatically.", nil)
            default:
                return ("\(name) is signed out", "New messages to \(handle) aren't arriving.", "Log in")
            }
        }
    }

    private func action() {
        switch banner {
        case .account(let id): logIn(id)
        default: openAccounts()
        }
    }
}

/// Orange triangle glyph before the banner title (status always carries a glyph, DESIGN §8.1).
private struct BannerTitleStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(.orange)
            configuration.title
        }
    }
}
