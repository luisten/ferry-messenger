import SwiftUI

enum InboxRoute: Hashable {
    case thread(String)
    case folder(Inbox.Folder, Inbox.Scope)
    /// T3 chat info.
    case chatInfo(String)
}

/// I1 Inbox (DESIGN §4, I1; v2 D14): account stack, inline title, Folders menu, scope bar, connection banner, the
/// Requests card while new requests wait, and chat rows.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: [InboxRoute]
    /// "" is All; otherwise a bridge login ID. Remembered per scene (DESIGN §4.1).
    @SceneStorage("inbox.scope") private var scopeID = ""
    @State private var showingAccounts = false
    @State private var relogin: ReloginTarget?
    /// N1: the sheet, and the chat it chose, opened once the sheet is gone (pushing under a sheet is unreliable).
    @State private var composing = false
    @State private var openAfterCompose: String?
    /// I5: filters by chat name within the current scope.
    @State private var query = ""
    @State private var archived = 0
    /// The signed-out banner buzzes when an account drops while the app is open, never for what launch finds.
    @State private var launchSettled = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scope: Inbox.Scope {
        // A login removed since the scope was saved falls back to All.
        scopeID.isEmpty || model.loginIDs?.contains(scopeID) == false ? .all : .account(scopeID)
    }

    private var scopedAccount: (login: BridgeAPI.Login?, identity: AccountIdentity?)? {
        guard case .account(let id) = scope else { return nil }
        return (model.accounts.first { $0.id == id }, model.identities[id])
    }

    /// One account means no scope bar and no marks (DESIGN §3.6 rule 6).
    private var multiAccount: Bool { (model.loginIDs?.count ?? model.identities.count) > 1 }

    /// No first load yet and Instagram isn't answering: say so instead of showing placeholders forever.
    private var unreachable: Bool { !model.initialSyncDone && model.syncFailures >= 2 }

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let rooms = searching ? Inbox.search(model.rooms.values, query: query, scope: scope, logins: model.loginIDs)
            : Inbox.rooms(model.rooms.values, scope: scope, folder: .chats, logins: model.loginIDs)
        let banner = Inbox.banner(syncFailures: model.syncFailures, accounts: model.accounts)
            .flatMap { $0 == model.hiddenBanner || (unreachable && $0 == .offline) ? nil : $0 }  // "Later" hides it until the next launch
        let newRequests = Inbox.newRequests(model.rooms.values, scope: scope, logins: model.loginIDs, seen: model.requestsSeen)
        List {
            // A folder shows itself in the list only when it has something new: today, requests (General stays quiet).
            if !searching && model.initialSyncDone && !newRequests.isEmpty {
                RequestsCard(requests: newRequests, showsMarks: scope == .all && multiAccount) { path.append(.folder(.requests, scope)) }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
            }
            if model.initialSyncDone {
                ForEach(rooms) { room in
                    NavigationLink(value: InboxRoute.thread(room.id)) {
                        ChatRow(room: room, showsMark: scope == .all && multiAccount)
                    }
                    .archiveActions(room) { archived += 1 }
                    .listRowInsets(EdgeInsets(top: 10, leading: 22, bottom: 10, trailing: 16))
                    .listRowSeparator(room.id == rooms.first?.id ? .hidden : .automatic, edges: .top)  // no line under the chips
                }
            } else if !unreachable {
                ForEach(0..<8, id: \.self) { _ in PlaceholderRow() }
            }
        }
        .listStyle(.plain)
        .navigationLinkIndicatorVisibility(.hidden)
        .overlay {
            if unreachable { unreachableState }
            else if model.initialSyncDone && rooms.isEmpty { if searching { ContentUnavailableView.search(text: query) } else { emptyState } }
        }
        .overlay(alignment: .top) { wash }
        .safeAreaBar(edge: .top) {
            VStack(spacing: 2) {
                if model.accounts.count > 1 { ScopeBar(scopeID: $scopeID) }  // chips need whoami's accounts
                if let banner {
                    ConnectionBanner(banner: banner, logIn: { relogin = ReloginTarget(id: $0) }, openAccounts: { showingAccounts = true })
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.bottom, 4)
            .animation(.smooth(duration: 0.35), value: banner)
        }
        .navigationTitle(scopedAccount?.identity?.name ?? "Chats")
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)  // the chips below already say where you are (review 2026-10-14 H1)
        .searchable(text: $query, prompt: scopedAccount?.identity.map { "Search \($0.name)" } ?? "Search")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AccountStackButton { showingAccounts = true }
            }
            .sharedBackgroundVisibility(.hidden)  // the stack has its own capsule
            ToolbarItem(placement: .topBarTrailing) {
                FoldersMenu(menu: Inbox.foldersMenu(model.rooms.values, scope: scope, accounts: model.accounts, logins: model.loginIDs,
                                                    seen: model.requestsSeen)) { path.append(.folder($0, scope)) }
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                // DESIGN I1: compose sits right of the search field in the bottom glass bar.
                Button("New Message", systemImage: "square.and.pencil") { composing = true }
                    .disabled(model.accounts.isEmpty)
                    .accessibilityIdentifier("inbox.compose")
            }
        }
        .tint(scopedAccount?.identity?.color.ink ?? .primary)
        .sensoryFeedback(.impact(weight: .medium), trigger: archived)
        .sensoryFeedback(trigger: banner) { old, new in
            guard launchSettled, old == nil, let new, new != .offline else { return nil }
            return .warning
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            launchSettled = true
        }
        // W4 (docs/PLAN-push.md): the system's question once, when the inbox first shows its chats.
        .onChange(of: model.initialSyncDone, initial: true) { _, done in if done { model.askForNotificationsOnce() } }
        .navigationDestination(for: InboxRoute.self) { route in
            switch route {
            case .thread(let id): ThreadView(roomID: id, path: $path)
            case .folder(let folder, let scope): FolderView(folder: folder, scope: scope, path: $path)
            case .chatInfo(let id): ChatInfoView(roomID: id)
            }
        }
        .sheet(isPresented: $showingAccounts) {
            NavigationStack {
                AccountsView().toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { showingAccounts = false }
                    }
                }
            }
        }
        .sheet(item: $relogin) { ReloginSheet(loginID: $0.id) }
        .sheet(isPresented: $composing, onDismiss: {
            if let id = openAfterCompose {
                model.focusComposer = id
                path.append(.thread(id))
            }
            openAfterCompose = nil
        }) {
            NewMessageSheet(scope: scope, accounts: model.accounts) { openAfterCompose = $0 }
        }
        .refreshable { await model.refreshAccounts() }
        #if DEBUG
        .onChange(of: rooms.isEmpty, initial: true) { _, empty in if !empty && model.initialSyncDone { LaunchTimer.inboxVisible() } }
        #endif
    }

    /// "@handle", or "@handle · Primary" for a professional account; "Primary" beside a three-account stack.
    private var subtitle: String {
        guard let account = scopedAccount else { return "" }
        return Inbox.scopeSubtitle(handle: account.login?.profile?.username, isProfessional: account.login?.isProfessional == true,
                                   accounts: model.accounts.count)
    }

    /// Account scope wears the account's color: a faint wash fading down from the top (DESIGN §3.3).
    @ViewBuilder private var wash: some View {
        if let identity = scopedAccount?.identity { AccountWash(identity: identity, height: 200) }  // inline title: less to wash
    }

    private var unreachableState: some View {
        ContentUnavailableView {
            Label("Can't reach Instagram", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Retrying. Your chats appear when it's back.")
        } actions: {
            Button("Try Again") { model.restartSync() }.buttonStyle(.bordered).accessibilityIdentifier("inbox.retry")
        }
    }

    private var emptyState: some View {
        let name = scopedAccount?.identity?.name
        // Everything archived or in General isn't "no chats yet": say where they went.
        let archived = !Inbox.rooms(model.rooms.values, scope: scope, folder: .archived, logins: model.loginIDs).isEmpty
        let general = !Inbox.rooms(model.rooms.values, scope: scope, folder: .general, logins: model.loginIDs).isEmpty
        return ContentUnavailableView {
            Label(archived || general ? "All caught up" : name.map { "No chats in \($0) yet" } ?? "No chats yet",
                  systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text(general && archived ? "Your other chats are in General and Archived. Open Folders, top right."
                 : general ? "Your other chats are in General. Open Folders, top right."
                 : archived ? "Your other chats are in Archived. Open Folders, top right. A new message brings one back."
                 : name == nil ? "New messages from all your accounts land here." : "New messages to this account land here.")
        }
    }
}

// MARK: - Scope bar (DESIGN §4.1)

private struct ScopeBar: View {
    @Environment(AppModel.self) private var model
    @Binding var scopeID: String

    var body: some View {
        // A plain row while the chips fit (the usual 2–3 accounts); scrolling only when they don't. A horizontal
        // ScrollView here that exists when the inbox first lays out (accounts already loaded, e.g. right after
        // onboarding) takes the large title's height as a top content inset and draws the chips ~128 pt too low,
        // hidden under the list but still tappable. Inserted later (whoami answering at launch) it's fine.
        ViewThatFits(in: .horizontal) {
            chips.fixedSize(horizontal: true, vertical: false)  // measured whole, never squeezed
            ScrollView(.horizontal) { chips }.scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sensoryFeedback(.selection, trigger: scopeID)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            chip(id: "", label: "All", identity: nil, count: unread(.all), health: nil)
            ForEach(model.orderedAccounts) { login in
                chip(id: login.id, label: model.identities[login.id]?.name ?? login.displayName,
                     identity: model.identities[login.id], count: unread(.account(login.id)), health: login.health)
            }
        }
        .padding(.horizontal, 16)
    }

    /// "Studio, 3 unread" (DESIGN §3.7), or what the chip's glyph says instead of the count.
    private func chipLabel(_ label: String, count: Int, health: BridgeAPI.Login.Health?) -> String {
        if let health, health.needsUser { return "\(label), needs attention" }
        if let health, health.isBusy { return "\(label), \(health.label)" }
        return count > 0 ? "\(label), \(count) unread" : label
    }

    private func unread(_ scope: Inbox.Scope) -> Int {
        Inbox.unreadChats(model.rooms.values, scope: scope, logins: model.loginIDs)
    }

    private func chip(id: String, label: String, identity: AccountIdentity?, count: Int, health: BridgeAPI.Login.Health?) -> some View {
        let selected = scopeID == id
        let fill: Color = selected ? (identity?.color.fill ?? .primary) : Color(.tertiarySystemFill)
        let text: Color = selected ? (identity == nil ? Color(.systemBackground) : .white) : .primary
        return Button {
            withAnimation(.snappy(duration: 0.25)) { scopeID = id }
        } label: {
            HStack(spacing: 6) {
                if let identity { AccountMark(identity: identity, size: 18, inverted: selected) }
                Text(label).lineLimit(1)
                if let health, health.needsUser {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if let health, health.isBusy {
                    ProgressView().controlSize(.mini).tint(text)
                } else if count > 0 {
                    Text("\(count)").font(.footnote.weight(.medium)).monospacedDigit().opacity(selected ? 0.85 : 0.6)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(text)
            .padding(.leading, identity == nil ? 14 : 8)
            .padding(.trailing, identity == nil ? 14 : 12)
            .padding(.vertical, 4)
            .frame(minHeight: 34)  // grows with large text instead of clipping it
            .background(fill, in: .capsule)
            .frame(minHeight: 44)  // 34 pt chip, 44 pt target (DESIGN §8.4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chipLabel(label, count: count, health: health))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id.isEmpty ? "scope.all" : "scope.\(id)")
    }
}

// MARK: - Folders menu and Requests card (D14; DESIGN §4.2)

extension Inbox.Folder {
    var title: String {
        switch self {
        case .chats: "Chats"
        case .general: "General"
        case .requests: "Requests"
        case .archived: "Archived"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .general: "tray.full"
        case .requests: "person.crop.circle.badge.questionmark"
        case .archived: "archivebox"
        }
    }
}

/// Top right: General (professional scopes), Requests and Archived, each pushing its folder screen. Subtitles and the
/// badge only when non-zero.
private struct FoldersMenu: View {
    let menu: Inbox.FoldersMenu
    let open: (Inbox.Folder) -> Void

    var body: some View {
        Menu {
            ForEach(menu.items, id: \.self) { folder in
                Button { open(folder) } label: {
                    Label(folder.title, systemImage: folder.symbol)
                    if let subtitle = menu.subtitle(folder) { Text(subtitle) }  // a menu shows a second Text as the subtitle
                }
                .accessibilityIdentifier("folder.\(folder.rawValue)")
            }
        } label: {
            // Not a Label: the toolbar would reduce it to a bar-button image and drop the overlay. The badge stays inside
            // the glass circle, which clips what's outside it.
            Image(systemName: "tray.2")
                .frame(width: 32, height: 32)
                .overlay(alignment: .topTrailing) { badge }
        }
        .accessibilityLabel(menu.accessibilityLabel)
        .accessibilityIdentifier("inbox.folders")
    }

    /// Label colour, not the system badge: `.badge` on a toolbar item is always red on iOS 26 (neither the tint nor
    /// `badgeProminence` changes it), and color means account.
    @ViewBuilder private var badge: some View {
        if menu.badge > 0 {
            Text("\(menu.badge)")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color(.systemBackground))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Color.primary, in: .capsule)
                .padding(1.5)
                .background(Color(.systemBackground), in: .capsule)  // a cut-out where it overlaps the glyph
                .fixedSize()
                .offset(x: 3, y: -3)
        }
    }
}

/// The first row while requests newer than the last look wait: who's waiting (with each account's mark in All), never
/// what they wrote. A filled card, unlike a chat row; it opens the Requests list, never a request thread.
private struct RequestsCard: View {
    @Environment(AppModel.self) private var model
    let requests: [Room]
    let showsMarks: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: Inbox.Folder.requests.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 36)
                    .background(Color(.systemBackground), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Inbox.requestsCardTitle(count: requests.count)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                    // Every name if they fit, else the first two or one and "+N" (rather than cutting each name short).
                    ViewThatFits(in: .horizontal) {
                        names(requests.count)
                        if requests.count > 2 { names(2) }
                        if requests.count > 1 { names(1) }
                    }
                    .font(.footnote)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.inkSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Inbox.requestsCardLabel(names: requests.map(\.name)))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("inbox.requestsCard")
    }

    private func names(_ shown: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(requests.prefix(shown).enumerated()), id: \.element.id) { index, room in
                if showsMarks, let identity = room.bridge?.receiver.flatMap({ model.identities[$0] }) {
                    AccountMark(identity: identity, size: 14)
                }
                Text(room.name + (index < shown - 1 ? "," : ""))
            }
            if shown < requests.count { Text("+\(requests.count - shown)").monospacedDigit() }
        }
    }
}

// MARK: - Rows

/// I1 chat row: unread dot, 52 pt avatar (with the account's mark in All scope), name, time, two-line preview.
struct ChatRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let room: Room
    let showsMark: Bool

    var body: some View {
        let me = model.me
        let identity = room.bridge?.receiver.flatMap { model.identities[$0] }
        let unread = room.isUnread
        let typing = room.typing.contains { $0 != me }
        let preview = Inbox.preview(of: room, me: me, profiles: room.bridge?.isDM == false ? model.profiles : [:])  // DM rows never re-render for profiles
        let time = room.lastMessage == nil ? "" : Inbox.timeLabel(room.lastActivity)
        // At accessibility sizes the time moves under the name (DESIGN §8.2).
        let header = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        HStack(alignment: .top, spacing: 12) {
            RoomAvatar(room: room, size: 52)
                .overlay {
                    if showsMark, let identity { AccountMark(identity: identity, size: 20, ring: 2).position(x: 52 * 0.84, y: 52 * 0.84) }
                }
            VStack(alignment: .leading, spacing: 1) {
                header {
                    Text(room.name).font(.headline).lineLimit(1)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    Text(time).font(.subheadline).monospacedDigit().foregroundStyle(unread ? Color.primary : .inkSecondary)
                }
                Group {
                    if typing {
                        Text("typing…").italic()
                    } else if let preview {
                        if let symbol = preview.symbol { Text("\(Image(systemName: symbol)) \(preview.text)") } else { Text(preview.text) }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(unread && !typing ? Color.primary : .inkSecondary)
                .lineLimit(2)
            }
        }
        .frame(minHeight: 56, alignment: .top)
        .overlay(alignment: .leading) {
            if unread { Circle().fill(.primary).frame(width: 10, height: 10).offset(x: -17).accessibilityHidden(true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(identity: identity, typing: typing, preview: preview?.text, time: time))
        .accessibilityIdentifier("inbox.row")
    }

    /// "Kivo Studio, via Tamo account, 2 unread, You sent a reel, 9:41" (DESIGN §3.7). The account is named whenever
    /// there's more than one, scoped or not: the mark that says it is hidden from VoiceOver.
    private func accessibilityText(identity: AccountIdentity?, typing: Bool, preview: String?, time: String) -> String {
        let multiAccount = (model.loginIDs?.count ?? model.identities.count) > 1
        let count = max(room.notificationCount, room.highlightCount)
        return [room.name, multiAccount ? identity.map { "via \($0.name) account" } : nil, count > 0 ? "\(count) unread" : nil,
                typing ? "typing" : preview, time].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - Archive actions (DESIGN I1/I4: trailing full swipe and the row's context menu)

extension View {
    /// Archive, or Unarchive for a chat in Archived. Requests have neither (they stay in Requests either way).
    func archiveActions(_ room: Room, committed: @escaping () -> Void) -> some View {
        modifier(ArchiveActions(room: room, committed: committed))
    }
}

private struct ArchiveActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let room: Room
    let committed: () -> Void

    func body(content: Content) -> some View {
        let archived = Inbox.folder(of: room) == .archived
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { button(archived: archived) }
            .contextMenu { button(archived: archived) }
    }

    private func button(archived: Bool) -> some View {
        Button(archived ? "Unarchive" : "Archive", systemImage: archived ? "tray.and.arrow.up" : "archivebox") {
            committed()
            model.setArchived(!archived, room)
        }
        .tint(.swipeArchive)
        .accessibilityIdentifier(archived ? "row.unarchive" : "row.archive")
    }
}

/// First-sync loading row (DESIGN I1: redacted placeholders, no shimmer per §14).
private struct PlaceholderRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(Color(.systemGray5)).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Instagram friend").font(.headline)
                    Spacer()
                    Text("9:41").font(.subheadline)
                }
                Text("A message preview that runs on for a while").font(.subheadline)
            }
        }
        .redacted(reason: .placeholder)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 10, leading: 22, bottom: 10, trailing: 16))
        .accessibilityHidden(true)
    }
}

// MARK: - Folders (I2 Requests with Accept/Delete; I3 General and I4 Archived with Archive/Unarchive)

struct FolderView: View {
    @Environment(AppModel.self) private var model
    let folder: Inbox.Folder
    let scope: Inbox.Scope
    @Binding var path: [InboxRoute]
    @AppStorage("requests.explainerDismissed") private var explainerDismissed = false
    @State private var deleting: Room?
    @State private var accepted = 0
    @State private var deleted = 0
    @State private var unarchived = 0

    var body: some View {
        let rooms = Inbox.rooms(model.rooms.values, scope: scope, folder: folder, logins: model.loginIDs)
        let multi = model.accounts.count > 1
        List {
            if folder == .requests && !explainerDismissed && !rooms.isEmpty { explainer }
            if folder == .requests && scope == .all && multi {
                // DESIGN I2: in All scope, one section per account, headed by its tag and count.
                ForEach(model.orderedAccounts) { login in
                    let section = rooms.filter { $0.bridge?.receiver == login.id }
                    if !section.isEmpty, let identity = model.identities[login.id] {
                        Section {
                            rows(section, showsMark: false)
                        } header: {
                            HStack { AccountTag(identity: identity); Text("\(section.count)").monospacedDigit() }
                        }
                    }
                }
            } else {
                rows(rooms, showsMark: scope == .all && multi)
            }
        }
        .listStyle(.plain)
        .navigationLinkIndicatorVisibility(.hidden)
        .overlay { if model.initialSyncDone && rooms.isEmpty { empty } }
        .navigationTitle(folder.title)
        .navigationSubtitle(scopeAccountName ?? "All accounts")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: accepted)
        .sensoryFeedback(.impact(weight: .medium), trigger: deleted)
        .sensoryFeedback(.impact(weight: .medium), trigger: unarchived)
        // Looking at Requests clears the card and the badge for what's listed; leaving again covers what arrived meanwhile.
        .onAppear { if folder == .requests { model.markRequestsSeen(scope) } }
        .onDisappear { if folder == .requests { model.markRequestsSeen(scope) } }
        .confirmationDialog("Delete request from \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { room in
            Button("Delete", role: .destructive) { deleted += 1; model.deleteRequest(room) }
        } message: { room in
            Text(RequestCopy.deleteMessage(handle: room.bridge?.receiver.flatMap { id in model.accounts.first { $0.id == id } }?.profile?.username))
        }
    }

    @ViewBuilder private func rows(_ rooms: [Room], showsMark: Bool) -> some View {
        ForEach(rooms) { room in
            if folder == .requests {
                RequestRow(room: room, showsMark: showsMark, open: { path.append(.thread(room.id)) },
                           accept: { accepted += 1; model.accept(room) }, delete: { deleting = room })
                    .listRowInsets(EdgeInsets(top: 10, leading: 22, bottom: 10, trailing: 16))
            } else {
                NavigationLink(value: InboxRoute.thread(room.id)) { ChatRow(room: room, showsMark: showsMark) }
                    .archiveActions(room) { unarchived += 1 }
                    .listRowInsets(EdgeInsets(top: 10, leading: 22, bottom: 10, trailing: 16))
            }
        }
    }

    /// DESIGN I2 explainer: dismissible, once (v1 doesn't track it per account).
    private var explainer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye.slash").foregroundStyle(.secondary)
            Text("Requests come from people you don't follow. They won't see that you've read their message until you accept.")
                .font(.subheadline)
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark") { withAnimation { explainerDismissed = true } }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).contentShape(.rect).padding(-12)
        }
        .padding(12)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 20))
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .accessibilityIdentifier("requests.explainer")
    }

    private var scopeAccountName: String? {
        guard case .account(let id) = scope else { return nil }
        return model.identities[id]?.name
    }

    @ViewBuilder private var empty: some View {
        if folder == .requests {
            let handle: String? = if case .account(let id) = scope { model.accounts.first { $0.id == id }?.profile?.username } else { nil }
            ContentUnavailableView("No message requests", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("When someone you don't follow messages \(handle.map { "@\($0)" } ?? "your accounts"), it shows up here."))
        } else if folder == .general {
            // DESIGN I3. Moving a chat between tabs happens in Instagram; the bridge reports each move.
            ContentUnavailableView("Nothing in General", systemImage: "tray.full",
                                   description: Text("On Instagram, business and creator accounts can move chats here."))
        } else {
            ContentUnavailableView("No archived chats", systemImage: "archivebox",
                                   description: Text("Archived chats come back when there's a new message."))
        }
    }
}

/// DESIGN I2 row: the chat row (tap opens T2), then Delete and Accept. Separate buttons, not a NavigationLink: a link
/// in a `List` row takes every tap in it.
private struct RequestRow: View {
    let room: Room
    let showsMark: Bool
    let open: () -> Void
    let accept: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) { ChatRow(room: room, showsMark: showsMark).contentShape(.rect) }
                .buttonStyle(.plain)
            HStack(spacing: 8) {
                Button("Delete", role: .destructive, action: delete).buttonStyle(.bordered)
                    .foregroundStyle(.statusError)  // the app-wide monochrome tint would grey out the destructive role
                    .accessibilityIdentifier("request.row.delete")
                Button("Accept", action: accept).buttonStyle(.borderedProminent).labelOnTint()
                    .accessibilityIdentifier("request.row.accept")
            }
            .controlSize(.small)
            .padding(.leading, 64)
        }
    }
}

// MARK: - Toolbar account stack (DESIGN §3.5, review 2026-10-15 §3)

/// Your accounts side by side in one glass capsule (`Inbox.AccountStack` decides what shows): 30 pt avatars 4 pt
/// apart, 7 pt in from the capsule's ends, so it's 44, 78 or 112 pt wide. Its own glass: the toolbar item hides the
/// shared one, which would add its own padding.
private struct AccountStackButton: View {
    @Environment(AppModel.self) private var model
    let action: () -> Void

    static let avatar: CGFloat = 30

    var body: some View {
        let logins = model.orderedAccounts
        let stack = Inbox.AccountStack(logins.map {
            .init(id: $0.id, name: model.identities[$0.id]?.name ?? $0.displayName, health: $0.health)
        } + debugAccounts)
        Button(action: action) {
            HStack(spacing: 4) {
                if stack.shown.isEmpty {
                    Image(systemName: "person.crop.circle").font(.title3).frame(width: Self.avatar, height: Self.avatar)
                }
                ForEach(stack.shown, id: \.id) { account in
                    let login = logins.first { $0.id == account.id }
                    // The frame includes the ring, which `AccountAvatar` draws outside its 24 pt photo.
                    AccountAvatar(identity: model.identities[account.id] ?? Self.debugIdentity(account.id), avatarURL: login?.profile?.avatar,
                                  initial: account.name, size: 24, showsMark: false)
                        .frame(width: Self.avatar, height: Self.avatar)
                        .overlay(alignment: .bottomTrailing) { StatusBadge(status: account.status) }
                }
                if !stack.hidden.isEmpty {
                    Text("+\(stack.hidden.count)")
                        .font(.footnote.weight(.semibold)).fontDesign(.rounded).monospacedDigit()
                        .foregroundStyle(Color.primary)
                        .minimumScaleFactor(0.7)
                        .offset(x: stack.hiddenStatus == nil ? 0 : -2, y: stack.hiddenStatus == nil ? 0 : -2)  // clear of the badge
                        .frame(width: Self.avatar, height: Self.avatar)
                        .background(Color(.tertiarySystemFill), in: .circle)
                        .overlay(alignment: .bottomTrailing) { StatusBadge(status: stack.hiddenStatus) }
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stack.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("inbox.accounts")
    }

    /// `FERRY_DEBUG_STACK_EXTRA`: stand-in accounts for the stack only (nothing else sees them).
    private var debugAccounts: [Inbox.AccountStack.Account] {
        #if DEBUG
        DebugFixtures.extraStackAccounts
        #else
        []
        #endif
    }

    private static func debugIdentity(_ id: String) -> AccountIdentity? {
        #if DEBUG
        DebugFixtures.extraStackIdentity(id)
        #else
        nil
        #endif
    }
}

/// 14 pt, at the avatar's bottom-right inside its 30 pt frame, so it never reaches the next avatar: a warning when the
/// account needs you, a spinner while it connects. A cut-out in the background colour, like the marks.
private struct StatusBadge: View {
    let status: Inbox.AccountStack.Status?

    var body: some View {
        if let status {
            Group {
                switch status {
                case .needsYou:
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.statusWarn)
                case .connecting:
                    ProgressView().controlSize(.mini).scaleEffect(0.75)
                }
            }
            .frame(width: 14, height: 14)
            .background(Color(.systemBackground), in: .circle)
        }
    }
}
