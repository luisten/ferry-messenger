import SwiftUI
import WebKit

/// O3: the user logs in on instagram.com in a throwaway web view; the session cookies go to `core/` and the Keychain
/// (PLAN §2.9, D7, decision C3). The app never sees the password.
struct ConnectSheet: View {
    /// Set to re-login an existing account (A3); nil adds a new one.
    var reloginID: String? = nil
    /// Called with the account ID once it's logged in (onboarding goes on to O4 with it).
    var onConnected: ((String) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var attempt = 0
    @State private var page: WebPage?
    @State private var store: WKWebsiteDataStore?
    @State private var gate = CookieGate.Result.waiting(missing: [])
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                            .disabled(submitting)  // cancelling mid-submit would abort a login IG already accepted
                            .accessibilityIdentifier("connect.cancel")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Reload", systemImage: "arrow.clockwise") { page?.reload() }
                            .disabled(page == nil || submitting)
                    }
                }
                .safeAreaInset(edge: .bottom) { if error == nil { footer } }
        }
        .interactiveDismissDisabled(submitting)
        // DESIGN O3: success when the login cookies appear, error when Instagram refuses them.
        .sensoryFeedback(.success, trigger: gate.values != nil) { _, captured in captured }
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        .task(id: attempt) { start() }
    }

    @ViewBuilder private var content: some View {
        if let error {
            ContentUnavailableView {
                Label("Couldn't connect", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { self.error = nil; attempt += 1 }
                    .buttonStyle(.borderedProminent).labelOnTint()
            }
        } else if let page {
            WebView(page)
                .accessibilityIdentifier("connect.web")
                .overlay(alignment: .top) {
                    if page.isLoading { ProgressView(value: page.estimatedProgress) }
                }
                .overlay {
                    if submitting {
                        ZStack {
                            Color.black.opacity(0.25).ignoresSafeArea()
                            ProgressView("Connecting…").padding(24).background(.regularMaterial, in: .rect(cornerRadius: 20))
                        }
                    }
                }
                .onChange(of: page.url) { Task { await evaluate() } }
                .onChange(of: page.isLoading) { Task { await evaluate() } }
        } else {
            ProgressView()
        }
    }

    /// Re-login names the account: finishing as a different one is refused (`AppModel.connect`).
    private var title: String {
        guard let reloginID, let handle = model.accounts.first(where: { $0.id == reloginID })?.profile?.username else {
            return "Log in to Instagram"
        }
        return "Log in as @\(handle)"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if gate.values != nil {
                // IG's "Save your login info?" page doesn't match the logged-in URL pattern; don't leave the user stuck.
                Button { Task { await submit() } } label: {
                    Text("Logged in. Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).labelOnTint()
                .disabled(submitting)
                .accessibilityIdentifier("connect.continue")
            } else {
                Label("Your password goes only to Instagram. Ferry Messenger keeps the session on this iPhone, in the Keychain.",
                      systemImage: "lock.shield")
                Text("Instagram may ask you to confirm it's you. Keep your Instagram app or email nearby.")
                    .foregroundStyle(.inkSecondary)
            }
        }
        .font(.footnote)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func start() {
        page = nil; store = nil; gate = .waiting(missing: [])
        // Fresh memory-only store per attempt: nothing reaches disk and accounts never share a session.
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        // Not a spoof: WebPage leaves out the "Mobile/15E148" suffix that a stock WKWebView sends on iPhone, and
        // without it instagram.com shows its "tablet app" interstitial instead of the login form.
        configuration.applicationNameForUserAgent = "Mobile/15E148"
        let page = WebPage(configuration: configuration, navigationDecider: LogoutBlocker())
        page.load(URLRequest(url: CookieStep.instagram.url))
        store = configuration.websiteDataStore
        self.page = page
    }

    private func evaluate() async {
        guard let store, let page, !submitting else { return }
        gate = CookieGate.evaluate(.instagram, cookies: await store.httpCookieStore.allCookies(), url: page.url)
        if gate.isReady { await submit() }
    }

    /// Instagram's index, mailbox and socket for the new session (`IGLogin`), then the Keychain. The cookies live in
    /// this view's state only until then.
    private func submit() async {
        guard !submitting, let values = gate.values else { return }
        submitting = true
        defer { submitting = false }
        do {
            let id = try await model.connect(cookies: values, reloginID: reloginID)
            onConnected?(id)
            dismiss()
        } catch {
            self.error = (error as? IGCore.Failure).flatMap { InstagramLogin.message(reason: $0.reason) } ?? error.localizedDescription
        }
    }
}

/// Logging out in this web view would kill the session the app just received.
private struct LogoutBlocker: WebPage.NavigationDeciding {
    func decidePolicy(for action: WebPage.NavigationAction,
                      preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        if let url = action.request.url, InstagramLogin.isLogoutURL(url) { return .cancel }
        return .allow
    }
}
