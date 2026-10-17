import SwiftUI

/// Onboarding (DESIGN §2.1; no O2 server sign-in any more, no O7 push pre-prompt, D6): Welcome → the instagram.com
/// sheet → connecting → name, color and mark → "Add another?" (after the first account only). A small
/// NavigationStack of steps (DESIGN §13).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let finish: () -> Void
    @State private var path: [Step] = []
    @State private var connect: ConnectTarget?

    enum Step: Hashable {
        /// O4–O6 for the login the connect sheet just added.
        case connecting(String)
        case identity(String)
        case addAnother(String)
    }

    struct ConnectTarget: Identifiable {
        /// O4's "Try again" logs the same account in again.
        var reloginID: String?
        var id: String { reloginID ?? "new" }
    }

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(connect: start)
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .connecting(let id):
                        ConnectingView(loginID: id, retry: { connect = ConnectTarget(reloginID: id) }, next: { path.append(.identity(id)) })
                    case .identity(let id):
                        NameAccountView(loginID: id, saved: { afterNaming(id) }, addAnother: { connect = ConnectTarget() })
                    case .addAnother(let id):
                        AddAnotherView(loginID: id, connect: { connect = ConnectTarget() }, notNow: finish)
                    }
                }
        }
        .sheet(item: $connect) { target in
            ConnectSheet(reloginID: target.reloginID) { id in
                if path.last != .connecting(id) { path.append(.connecting(id)) }
            }
        }
        #if DEBUG
        .task { await debugStart() }
        #endif
    }

    private func start() {
        connect = ConnectTarget()
    }

    /// O6 only after the first account; a second or later one goes straight to the inbox.
    private func afterNaming(_ id: String) {
        if model.accounts.count <= 1 { path.append(.addAnother(id)) } else { finish() }
    }

    #if DEBUG
    /// `FERRY_DEBUG_ONBOARDING=welcome|connecting|identity|another`: opens that step for the first existing
    /// account, so screenshots need no new Instagram login (and no account removed).
    private func debugStart() async {
        guard let step = DebugFixtures.onboardingStep, path.isEmpty else { return }
        guard let id = model.orderedAccounts.first?.id else { return }
        switch step {
        case "connecting": path = [.connecting(id)]
        case "identity": path = [.identity(id)]
        case "another": path = [.addAnother(id)]
        default: break
        }
    }
    #endif
}

// O1 Welcome: WelcomeView.swift.

// MARK: - O4 Connecting

/// O4: logged in ✓ → connected to Instagram ✓ → syncing recent chats, with the number of chats loaded so far. The
/// state comes from `core/`'s events. Continue unlocks at step 2.
private struct ConnectingView: View {
    @Environment(AppModel.self) private var model
    let loginID: String
    let retry: () -> Void
    let next: () -> Void
    @State private var copied = false

    private enum StepState { case waiting, running, done, failed }

    var body: some View {
        let login = model.accounts.first { $0.id == loginID }
        let health = login?.health ?? .connecting
        let connected = health == .connected || health == .syncing
        let chats = model.rooms.values.count { $0.bridge?.receiver == loginID && Inbox.isVisible($0, logins: model.loginIDs) }
        ScrollView {
            VStack(spacing: 18) {
                // The account on deck (DESIGN O4, O1's echo): it bobs while the first sync runs, with O1's pause rules.
                AmbientMotion { motion in
                    let bobbing = health == .syncing && motion != .still
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !bobbing || motion != .running)) { timeline in
                        FerryDeck(width: 150, bob: bobbing ? Crossing.pose(at: timeline.date.timeIntervalSinceReferenceDate).bob : 0) {
                            // Neutral ring until O5 picks a color (DESIGN O4).
                            AccountAvatar(identity: nil, avatarURL: login?.profile?.avatar, initial: login?.displayName ?? "", size: 88)
                                .overlay { Circle().strokeBorder(Color(.separator), lineWidth: 2).padding(-4) }
                        }
                        .animation(.smooth(duration: 0.6), value: bobbing)  // settles when synced
                    }
                }
                .padding(.top, 32)
                Text(login?.profile?.username.map { "Connected as @\($0)" } ?? "Connecting…")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 16) {
                    row("Logged in", state: .done)
                    row("Connected to Instagram", state: health.needsUser ? .failed : connected ? .done : .running)
                    row("Syncing recent chats", detail: chats == 0 ? nil : "\(chats == 1 ? "1 chat" : "\(chats) chats")\(health == .connected ? "" : " so far")",
                        state: health == .connected ? .done : health == .syncing ? .running : .waiting)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                if health.needsUser {
                    failure(login)
                } else {
                    Text("You can start chatting while older messages load.")
                        .font(.subheadline).foregroundStyle(.inkSecondary).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
        }
        .safeAreaBar(edge: .bottom) {
            Button(action: next) { Text("Continue").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }
                .buttonStyle(.glassProminent).labelOnTint()
                .disabled(!connected)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier("connecting.continue")
        }
        .navigationBarBackButtonHidden()
        .sensoryFeedback(.success, trigger: connected) { _, now in now }
    }

    private func row(_ title: String, detail: String? = nil, state: StepState) -> some View {
        HStack(spacing: 12) {
            Group {
                switch state {
                // Status tokens, not system green and red (2.2–3.4:1 on white; CLAUDE.md, design review 2026-10-15).
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.statusOK)
                case .running: ProgressView()
                case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.statusError)
                }
            }
            .font(.title3)
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(state == .waiting ? .regular : .semibold))
                    .foregroundStyle(state == .waiting ? Color.secondary : .primary)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.inkSecondary) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Self.spoken(state))
    }

    private static func spoken(_ state: StepState) -> String {
        switch state {
        case .done: "done"
        case .running: "in progress"
        case .waiting: "waiting"
        case .failed: "failed"
        }
    }

    /// DESIGN O4 errors: "Couldn't finish connecting" + Try again + Copy details (Instagram's message, for bug reports).
    private func failure(_ login: BridgeAPI.Login?) -> some View {
        let details = [login?.state?.stateEvent, login?.state?.message].compactMap(\.self).joined(separator: ": ")
        return VStack(spacing: 10) {
            Text("Couldn't finish connecting").font(.headline)
            Text(login?.health == .needsLogin ? "Instagram ended the session right away. Log in again to finish."
                 : "Instagram reported an error. Try again, or copy the details for a bug report.")
                .font(.subheadline).foregroundStyle(.inkSecondary).multilineTextAlignment(.center)
            HStack {
                Button("Try Again", action: retry).buttonStyle(.bordered)
                if !details.isEmpty {
                    Button(copied ? "Copied" : "Copy Details") {
                        UIPasteboard.general.string = details
                        copied = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

// MARK: - O5 Name, color and mark

private struct NameAccountView: View {
    @Environment(AppModel.self) private var model
    let loginID: String
    let saved: () -> Void
    let addAnother: () -> Void
    @State private var draft: AccountIdentity?

    var body: some View {
        let login = model.accounts.first { $0.id == loginID }
        let editing = Binding(get: { draft ?? start(login) }, set: { draft = $0 })
        let valid = AccountIdentity.problems(editing.wrappedValue, for: loginID, among: model.identities).isEmpty
        Form {
            Section {
                Text("Pick a name, color and mark for \(login?.profile?.username.map { "@\($0)" } ?? "this account"). You'll see them on every chat from this account.")
                    .font(.subheadline)
                    .foregroundStyle(.inkSecondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            IdentityEditor(draft: editing, loginID: loginID, login: login)
            // A row, not a bottom bar: the bar covered the colors and Mark (review 2026-10-14, finding 1).
            Section {
                Button("Add another account", systemImage: "plus") { save(editing.wrappedValue); addAnother() }
                    .disabled(!valid)
                    .accessibilityIdentifier("identity.addAnother")
            }
        }
        .navigationTitle("Name this account")
        .navigationBarTitleDisplayMode(.inline)
        .listSectionSpacing(.compact)  // all 8 colors and Mark on the first screen
        .contentMargins(.top, 0, for: .scrollContent)
        .environment(\.markRing, Color(.secondarySystemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // Save is the bar's confirm action, as in Accounts.
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark") { save(editing.wrappedValue); saved() }
                    .disabled(!valid)
                    .accessibilityIdentifier("identity.save")
            }
        }
    }

    /// The defaults `AppModel` assigned (Instagram name, next free color, first free letter).
    private func start(_ login: BridgeAPI.Login?) -> AccountIdentity {
        model.identities[loginID] ?? login.flatMap { AccountIdentity.withDefaults(model.identities, for: [$0])[loginID] }
            ?? AccountIdentity(name: "", color: .ocean, mark: "", order: model.identities.count)
    }

    private func save(_ identity: AccountIdentity) {
        var identity = identity
        identity.name = identity.name.trimmingCharacters(in: .whitespaces)
        model.setIdentity(identity, for: loginID)
    }
}

// MARK: - O6 Add another account?

private struct AddAnotherView: View {
    @Environment(AppModel.self) private var model
    let loginID: String
    let connect: () -> Void
    let notNow: () -> Void

    var body: some View {
        let login = model.accounts.first { $0.id == loginID }
        ScrollView {
            VStack(spacing: 16) {
                // Room aboard (DESIGN O6, O1's echo): your account and a free seat on one deck. Side by side, never over
                // each other (principle 9): 16 pt is 12 pt past the ring drawn outside the frame.
                FerryDeck(width: 210) {
                    HStack(spacing: 16) {
                        AccountAvatar(identity: model.identities[loginID], avatarURL: login?.profile?.avatar, initial: login?.displayName ?? "",
                                      size: 88)
                        Circle()
                            .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                            .background(Color(.systemBackground), in: .circle)
                            .frame(width: 88, height: 88)
                            .overlay { Image(systemName: "plus").font(.title.weight(.medium)).foregroundStyle(.inkSecondary) }
                    }
                }
                .padding(.top, 80)
                .padding(.bottom, 12)
                Text("Add another account?").font(.title.bold()).multilineTextAlignment(.center)
                Text("Connect a second Instagram account. Each chat stays tied to the account it belongs to.")
                    .font(.body).foregroundStyle(.inkSecondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 6) {
                Button(action: connect) { Text("Connect another account").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }
                    .buttonStyle(.glassProminent).labelOnTint()
                    .accessibilityIdentifier("another.connect")
                Button("Not now", action: notNow).frame(minHeight: 44).accessibilityIdentifier("another.notNow")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
        .navigationBarBackButtonHidden()
    }
}
