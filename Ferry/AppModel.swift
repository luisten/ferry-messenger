import Foundation
import Observation
import UIKit
#if DEBUG
import os
#endif

/// App root state: the Instagram accounts (each one's session in the Keychain, a `core/` client per account), their
/// identities, and the chats as Matrix-shaped rooms (`IGAdapter`, docs/PLAN-core.md §2), kept current by core's
/// events while the app is open.
@Observable
final class AppModel {
    /// Every stored account, in the bridge's whoami shape (`IGAdapter.login`) so `Health` and the views stay as they were.
    private(set) var accounts: [BridgeAPI.Login] = []
    /// The stored accounts' IDs: a room whose account was removed hides at once.
    private(set) var loginIDs: Set<String>?
    /// Per-account name, color and mark and order, keyed by account ID.
    private(set) var identities = AccountIdentity.load()
    /// When Requests was last opened, per scope (`Inbox.Scope.key`, ms): what's "new" for the Folders badge and the
    /// Requests card (D14). Local only.
    private(set) var requestsSeen = Inbox.loadRequestsSeen()
    private(set) var rooms: [String: Room] = [:]
    /// Every account's first load has finished (or failed), so the inbox can tell "loading" from "empty".
    private(set) var initialSyncDone = false
    /// Consecutive network failures with no account connected ("Can't reach Instagram" from 2).
    private(set) var syncFailures = 0
    /// Rooms with a back-pagination request in flight (the thread shows a spinner at the top).
    private(set) var paginating: Set<String> = []
    /// The last action that failed, for an alert.
    var actionError: String?
    /// A short confirmation shown over the app ("Accepted. This chat is now in Studio.").
    var toast: String?
    /// The banner the user dismissed with "Later"; it stays hidden until the next launch (DESIGN §7.2).
    var hiddenBanner: Inbox.Banner?
    /// Unresolved reels being fetched, by message ID (P5).
    private(set) var resolving: [String: ResolveState] = [:]
    /// The last resolved message, which its thread opens full screen once.
    var autoOpen: String?
    /// Media uploads in flight by transaction ID (0…1), for the local echo's ring (P5).
    private(set) var uploads: [String: Double] = [:]
    /// The people in our chats by user ID: names, pictures and @handles, straight from Instagram's thread data.
    private(set) var profiles: [String: UserProfile] = [:]
    /// N1 just opened this room: its thread focuses the composer once (DESIGN N1).
    var focusComposer: String?
    /// Both observable themselves; the views read their state directly.
    @ObservationIgnored let media = MediaCache()
    @ObservationIgnored let voice = VoicePlayback()

    /// The user every view treats as "us", in every account's chats.
    let me = IGAdapter.me

    enum ResolveState: Equatable { case running, failed }

    /// What each account is doing (whoami `state_event` names) and since when.
    private struct Status {
        var state: String
        var message: String?
        var since: Date
    }

    @ObservationIgnored private var sessions: [String: Keychain.Account]
    @ObservationIgnored private var statuses: [String: Status] = [:]
    /// Accounts with a core client, or a login in flight.
    @ObservationIgnored private var running: Set<String> = []
    /// Accounts whose first load this launch has finished, either way.
    @ObservationIgnored private var loaded: Set<String> = []
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var retries: [String: Task<Void, Never>] = [:]
    /// Typing names a thread by its long ID and people by their Instagram user ID (P0): both mapped as threads load.
    /// Keyed by account too: both of our accounts' rooms for one thread share its long ID.
    @ObservationIgnored private var roomByLongID: [String: String] = [:]
    @ObservationIgnored private var fbidByUserID: [String: String] = [:]
    /// When each room was last read in full (opening a chat re-reads it, at most every 30 s).
    @ObservationIgnored private var refreshed: [String: Date] = [:]
    /// The "Seen" we last sent per room, so a re-render doesn't send it again.
    @ObservationIgnored private var sentReceipts: [String: String] = [:]
    @ObservationIgnored private var typingTimers: [String: Task<Void, Never>] = [:]
    /// When we last told Instagram we're typing, per room (at most once per 20 s).
    @ObservationIgnored private var typingSince: [String: Date] = [:]
    @ObservationIgnored private var otidCounter: Int64 = 0
    /// New Message's chats with people we've never messaged (`IGAdapter.draft`): not in `rooms`, so the inbox and search
    /// never show an empty chat. When the first message makes the thread, `movedRooms` leads from the draft to it.
    private var drafts: [String: Room] = [:]
    @ObservationIgnored private var movedRooms: [String: String] = [:]
    /// Each thread's key: Instagram's uploads go to it (`IGSendMedia`).
    @ObservationIgnored private var threadKeys: [String: String] = [:]
    /// Media on its way, by transaction ID, kept until Instagram's echo names its link (the file is filed there, so our
    /// own photo, video or voice note opens without a download).
    @ObservationIgnored private var sending: [String: OutgoingMedia] = [:]
    @ObservationIgnored private var uploadTasks: [String: Task<Void, Never>] = [:]
    /// Archived chats, this device only (Instagram isn't told): room ID → when (ms). `Inbox.folder(of:)` reads it as the
    /// room's `u.archived` tag, so a new message still brings a chat back.
    @ObservationIgnored private var archived = UserDefaults.standard.dictionary(forKey: AppModel.archiveKey) as? [String: Int64] ?? [:]
    private static let archiveKey = "archived"

    init() {
        sessions = Keychain.accounts()
        for id in sessions.keys { statuses[id] = Status(state: "CONNECTING", since: .now) }
        #if DEBUG
        if DebugFixtures.demo {  // C8: made-up accounts that never connect, so nothing reaches Instagram
            sessions = DebugFixtures.demoSessions
            statuses = sessions.mapValues { _ in Status(state: "CONNECTED", since: .now) }
            loaded = Set(sessions.keys)
            initialSyncDone = true
        }
        if let dir = ProcessInfo.processInfo.environment["FERRY_DEBUG_CAPTURE"], !dir.isEmpty { IGCore.capture(to: dir) }
        #endif
        updateAccounts()
    }

    /// First run: no Instagram account yet.
    var needsOnboarding: Bool { sessions.isEmpty }

    /// Accounts in the user's order (scope bar, account stack).
    var orderedAccounts: [BridgeAPI.Login] {
        accounts.enumerated().sorted { a, b in
            (identities[a.element.id]?.order ?? Int.max, a.offset) < (identities[b.element.id]?.order ?? Int.max, b.offset)
        }.map(\.element)
    }

    // MARK: Accounts and connections (PLAN-core P1)

    /// The app became active: listen to core, and connect every account that isn't.
    func startSync() {
        if eventTask == nil { eventTask = Task { await eventLoop() } }
        for id in sessions.keys where !running.contains(id) { connect(id) }
    }

    /// To the background: keeps the Keychain's cookies current (Instagram rotates some). The sockets go when iOS
    /// suspends the app; the library reconnects and catches up on return (spike: 30 ms).
    func stopSync() {
        Task { for id in running { await saveSession(id) } }
        #if DEBUG
        // C6: what this launch asked of Instagram, per account (operation names only). Read it with `log show
        // --predicate 'subsystem == "<bundle ID>" AND category == "instagram"'`.
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "ferry", category: "instagram").notice("requests: \(IGCore.counts(), privacy: .public)")
        #endif
    }

    /// "Try again" on the inbox, pull to refresh, Accounts: reconnects accounts that failed for a passing reason.
    func restartSync() {
        for (id, status) in statuses where !running.contains(id) && status.state != "BAD_CREDENTIALS" { connect(id) }
    }

    func refreshAccounts() async { restartSync() }

    /// O3/A3: the cookies the web view captured become an account, or refresh `reloginID`'s session. Finishing as a
    /// different account than the one being fixed is refused (the sheet says "Log in as @handle").
    func connect(cookies: [String: String], reloginID: String?) async throws -> String {
        let login = try IG.decode(IG.Login.self, try await IGCore.login(cookies: cookies))
        if let reloginID, login.account != reloginID {
            if sessions[login.account] == nil { await IGCore.stop(login.account) }  // a stranger; one of ours just got a fresh session
            let wanted = accounts.first { $0.id == reloginID }?.profile?.username.map { "@\($0)" } ?? "the account you're fixing"
            throw IGCore.Failure(message: "That was @\(login.viewer.username ?? "another account"). Log in as \(wanted) to fix it.")
        }
        running.insert(login.account)
        loaded.insert(login.account)
        retries.removeValue(forKey: login.account)?.cancel()
        sessions[login.account] = Keychain.Account(cookies: cookies, viewer: login.viewer)
        Keychain.save(sessions[login.account]!, id: login.account)
        apply(login)
        await saveSession(login.account)
        return login.account
    }

    /// Remove account: forgets the session (Keychain), its client and its chats. Instagram isn't told, so the web
    /// session stays in Instagram's "Where you're logged in" until it expires or is removed there.
    func removeAccount(_ id: String) async throws {
        await IGCore.stop(id)
        Keychain.delete(id)
        sessions[id] = nil
        statuses[id] = nil
        running.remove(id)
        loaded.remove(id)
        retries.removeValue(forKey: id)?.cancel()
        rooms = rooms.filter { $0.value.bridge?.receiver != id }
        identities[id] = nil
        AccountIdentity.save(identities)
        updateAccounts()
    }

    private func connect(_ id: String) {
        #if DEBUG
        if DebugFixtures.demo { return }
        #endif
        guard var cookies = sessions[id]?.cookies, running.insert(id).inserted else { return }
        #if DEBUG
        if DebugFixtures.endedSessions.contains(id) { cookies["sessionid"] = "0" }  // Instagram's answer to an ended session
        #endif
        retries.removeValue(forKey: id)?.cancel()
        setStatus(id, "CONNECTING")
        Task {
            do {
                apply(try IG.decode(IG.Login.self, try await IGCore.login(cookies: cookies)))
                await saveSession(id)
            } catch {
                running.remove(id)
                failed(id, error)
            }
            loaded.insert(id)
            updateInitialSync()
        }
    }

    /// A login's result: the account, its first mailbox page, then the rest of its chats in the background.
    private func apply(_ login: IG.Login) {
        let id = login.account
        sessions[id]?.viewer = login.viewer
        if statuses[id]?.state != "CONNECTED" { setStatus(id, "CONNECTING") }  // the socket's Connected may already be in
        syncFailures = 0
        for thread in login.mailbox?.threadsByFolder?.nodes.compactMap(\.asIgDirectThread) ?? [] { apply(thread, account: id) }
        updateAccounts()
        updateInitialSync()
        Task { await loadFolders(id, after: login.mailbox?.threadsByFolder?.next) }
    }

    /// The rest of the inbox, then the first pages of Requests and (professional accounts) General, one request a
    /// page, as the bridge did (`chatsync.go:91`), so search and counts see every chat.
    /// ponytail: at most 20 pages a folder per launch; page on scroll if real inboxes outgrow that.
    private func loadFolders(_ id: String, after cursor: String?) async {
        let professional = sessions[id]?.viewer?.isProfessionalAccount == true
        for (folder, start) in [("INBOX", cursor)] + [("PENDING", ""), ("GENERAL", "")].filter({ $0.0 != "GENERAL" || professional }) {
            var next = start
            for _ in 0..<20 {
                guard let cursor = next, running.contains(id),
                      let data = try? await IGCore.inboxPage(id, folder: folder, cursor: cursor),
                      let page = try? IG.decode(IG.MailboxPage.self, data).fetchSlidemailbox?.threadsByFolder else { break }
                for thread in page.nodes.compactMap(\.asIgDirectThread) { apply(thread, account: id) }
                next = page.next
            }
        }
    }

    private func apply(_ thread: IG.Thread, account: String) {
        let thread = IGAdapter.keepingFolder(thread, of: rooms[IGAdapter.roomID(account: account, thread: thread.id)])
        let snapshot = IGAdapter.room(thread, account: account, viewer: sessions[account]?.viewer)
        let room = rooms[snapshot.id] ?? {
            let room = Room(id: snapshot.id)
            room.ownUserID = me
            rooms[snapshot.id] = room
            return room
        }()
        IGAdapter.apply(snapshot, to: room)
        if let ms = archived[snapshot.id], room.tags[Inbox.archivedTag] == nil {
            room.setTags([Inbox.archivedTag: [Inbox.archivedAtKey: .number(Double(ms))]])
        }
        // The DM a draft was waiting for: the draft gives way (its first message is in here now).
        if thread.isGroup != true, let other = room.bridge?.channelID, drafts.removeValue(forKey: IGAdapter.draftID(account: account, user: other)) != nil {
            movedRooms[IGAdapter.draftID(account: account, user: other)] = snapshot.id
        }
        profiles.merge(snapshot.profiles) { _, new in new }
        if let long = thread.threadId { roomByLongID["\(account)/\(long)"] = snapshot.id }
        if let key = thread.threadKey { threadKeys[snapshot.id] = key }
        for user in thread.users ?? [] {
            if let id = user.id, let fbid = user.interopMessagingUserFbid { fbidByUserID[id] = fbid }
        }
        #if DEBUG
        DebugFixtures.markForcedRequest(in: rooms)
        #endif
    }

    private func failed(_ id: String, _ error: any Error) {
        let failure = error as? IGCore.Failure
        let state = failure?.code ?? "UNKNOWN_ERROR"
        setStatus(id, state, message: InstagramLogin.message(reason: failure?.reason) ?? error.localizedDescription)
        guard state == "TRANSIENT_DISCONNECT" else { return }
        if !statuses.values.contains(where: { $0.state == "CONNECTED" }) { syncFailures += 1 }
        retries[id] = Task {  // ponytail: a fixed 30 s while open; backoff if it ever hammers
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { connect(id) }
        }
    }

    private func saveSession(_ id: String) async {
        #if DEBUG
        if DebugFixtures.endedSessions.contains(id) { return }  // never over the real cookies
        #endif
        guard let cookies = await IGCore.session(id), var stored = sessions[id], stored.cookies != cookies else { return }
        stored.cookies = cookies
        sessions[id] = stored
        Keychain.save(stored, id: id)
    }

    private func setStatus(_ id: String, _ state: String, message: String? = nil) {
        guard sessions[id] != nil else { return }
        if statuses[id]?.state == state && statuses[id]?.message == message { return }
        // A disconnect keeps its first time, so "Reconnecting…" can tell a blip from a long outage (Health).
        let since = state == statuses[id]?.state ? statuses[id]!.since : .now
        statuses[id] = Status(state: state, message: message, since: since)
        updateAccounts()
    }

    private func updateInitialSync() {
        initialSyncDone = sessions.keys.allSatisfy(loaded.contains)
    }

    /// Rebuilds `accounts` from the stored profiles and statuses, then the DEBUG stand-ins and default identities.
    private func updateAccounts() {
        var logins = sessions.keys.sorted().map { id in
            let status = statuses[id] ?? Status(state: "CONNECTING", since: .now)
            return IGAdapter.login(account: id, viewer: sessions[id]?.viewer, state: status.state, message: status.message,
                                   since: status.since, transientSince: status.state == "TRANSIENT_DISCONNECT" ? status.since : nil)
        }
        #if DEBUG
        logins = DebugFixtures.overridingStates(logins)
        if DebugFixtures.demo {
            identities = AccountIdentity.withDefaults([:], for: logins)  // equal below, so never saved
            for room in DebugFixtures.demoRooms(logins: logins.map(\.id), me: me) where rooms[room.id] == nil { rooms[room.id] = room }
            profiles.merge(DebugFixtures.demoProfiles) { current, _ in current }
        }
        if DebugFixtures.addsRequests {
            for room in DebugFixtures.requestRooms(logins: logins.map(\.id)) where rooms[room.id] == nil { rooms[room.id] = room }
        }
        if DebugFixtures.addsGroup, let receiver = logins.map(\.id).sorted().first {
            let group = DebugFixtures.groupRoom(receiver: receiver, me: me)
            if rooms[group.id] == nil { rooms[group.id] = group }
            profiles.merge(DebugFixtures.groupProfiles) { current, _ in current }
        }
        #endif
        accounts = logins
        loginIDs = Set(logins.map(\.id))
        let withDefaults = AccountIdentity.withDefaults(identities, for: logins)
        if withDefaults != identities {
            identities = withDefaults
            AccountIdentity.save(withDefaults)
        }
    }

    // MARK: Events (core's socket, every account)

    private func eventLoop() async {
        while !Task.isCancelled {
            guard let data = await IGCore.nextEvent(timeout: .seconds(1)), let event = try? IG.decode(IG.Event.self, data) else { continue }
            handle(event)
        }
    }

    private func handle(_ event: IG.Event) {
        let id = event.account
        switch event.kind {
        case "Connected":
            setStatus(id, "CONNECTED")
            syncFailures = 0
        case "Disconnected":
            setStatus(id, "TRANSIENT_DISCONNECT", message: event.error)
        case "AuthError":
            setStatus(id, event.code ?? "BAD_CREDENTIALS", message: event.error)
        case "Delta":
            if let delta = event.delta { apply(delta, account: id) }
        case "TypingNotification":
            typing(event)
        default:
            break
        }
    }

    /// Someone typing (`m.typing` for the room); it holds for the notice's TTL unless another notice comes.
    private func typing(_ event: IG.Event) {
        guard let long = event.thread, let id = roomByLongID["\(event.account)/\(long)"], let room = rooms[id], let typing = event.typing,
              let sender = typing.senderId.flatMap({ fbidByUserID[String($0)] }), sender != event.account else { return }
        let on = typing.activityStatus == 1
        room.apply(IGAdapter.typing(on ? [IGAdapter.user(sender)] : []))
        typingTimers[id]?.cancel()
        guard on else { return }
        typingTimers[id] = Task {
            try? await Task.sleep(for: .milliseconds(typing.ttl ?? 22_000))
            if !Task.isCancelled { room.apply(IGAdapter.typing([])) }
        }
    }

    private func apply(_ delta: IG.Delta, account: String) {
        guard let thread = delta.threadFbid else { return }
        guard let room = rooms[IGAdapter.roomID(account: account, thread: thread)] else {
            if delta.typename == "SlideUQPPNewMessage" { loadThread(thread, account: account) }  // a new DM or request
            return
        }
        let echoed = delta.message.flatMap { $0.senderFbid == account ? $0.offlineThreadingId : nil }.flatMap { sending[$0] != nil ? $0 : nil }
        defer { if let echoed { fileSentMedia(echoed, in: room) } }
        switch IGAdapter.apply(delta, account: account, to: room) {
        case .refresh: loadThread(thread, account: account)
        case .removed: rooms[room.id] = nil
        case .applied, .ignored: break
        }
    }

    /// Reads one thread (a read; nothing is sent) and adds or refreshes its room.
    private func loadThread(_ thread: String, account: String) {
        Task { _ = try? await fetchThread(thread, account: account) }
    }

    /// The same, for a caller that waits for the room (New Message opening an existing DM).
    private func fetchThread(_ thread: String, account: String) async throws -> String? {
        let data = try await IGCore.thread(account, thread)
        guard let info = try IG.decode(IG.ThreadResponse.self, data).getSlideThreadNullable?.asIgDirectThread else { return nil }
        apply(info, account: account)
        return IGAdapter.roomID(account: account, thread: info.id)
    }

    // MARK: Thread (read side)

    /// A chat opened: read it in full (the mailbox's copy of a message has no reactions or edit history, P1), at most
    /// every 30 s. A read; it sends nothing.
    func openThread(_ room: Room) {
        guard let account = room.bridge?.receiver, let thread = Self.threadID(of: room),
              Date.now.timeIntervalSince(refreshed[room.id] ?? .distantPast) > 30 else { return }
        refreshed[room.id] = .now
        loadThread(thread, account: account)
    }

    /// "Seen" on the newest incoming message: Instagram's `MarkRead` + validation (C7). Never in a request or a room we
    /// don't know (`Inbox.allowsReceipts`): the other person would see that we'd read it.
    func markRead(_ room: Room) {
        // Only when it's unread: Instagram already has our read otherwise (a reopen sent a needless "Seen" in P4).
        guard Inbox.allowsReceipts(room), room.isUnread, let account = room.bridge?.receiver, let target = Timeline.receiptTarget(room, me: me),
              sentReceipts[room.id] != target, let long = longID(of: room),
              let ms = room.events.first(where: { $0.eventID == target })?.originServerTS else { return }
        #if DEBUG
        if DebugFixtures.isFixtureRoom(room.id) { return }
        #endif
        sentReceipts[room.id] = target
        Task {
            do { try await IGCore.markRead(account, threadLong: long, message: target, ms: ms) } catch { sentReceipts[room.id] = nil }
        }
    }

    /// One page of older history, prepended. Not tied to the caller's task: the lazy list re-creates the top spinner
    /// while it settles, which cancelled the request and left pagination stuck (CLAUDE.md).
    func loadOlder(_ room: Room) {
        guard let cursor = room.prevBatch, !room.reachedStart, !paginating.contains(room.id) else { return }
        if cursor == IGAdapter.startToken { return room.prepend(MessagesPage(chunk: []), from: cursor) }
        guard let account = room.bridge?.receiver, let thread = Self.threadID(of: room) else { return }
        paginating.insert(room.id)
        Task {
            defer { paginating.remove(room.id) }
            guard let data = try? await IGCore.older(account, thread, cursor: cursor),
                  let older = try? IG.decode(IG.OlderResponse.self, data) else { return }
            room.prepend(IGAdapter.page(older.fetchSlidethread?.asIgDirectThread, account: account), from: cursor)
        }
    }

    /// The thread's long ID (unsend, mark read).
    private func longID(of room: Room) -> String? {
        roomByLongID.first { $0.value == room.id }.map { String($0.key.split(separator: "/").last ?? "") }
    }

    /// The thread's Instagram ID, from the room ID `IGAdapter.roomID` made; nil for a draft, which has no thread yet.
    private static func threadID(of room: Room) -> String? {
        guard let account = room.bridge?.receiver else { return nil }
        let prefix = "!ig-\(account)-"
        guard room.id.hasPrefix(prefix) else { return nil }
        let thread = String(room.id.dropFirst(prefix.count))
        return thread.hasPrefix("new-") ? nil : thread
    }

    /// A room by ID, a New Message draft too, following a draft to the real chat once Instagram has made it.
    func room(_ id: String) -> Room? { rooms[id] ?? drafts[id] ?? movedRooms[id].flatMap { rooms[$0] } }

    /// The contact's @handle: one of our own accounts, or Instagram's username from the thread.
    func contactHandle(of room: Room) -> String? {
        Inbox.contactHandle(room, accounts: accounts) ?? Inbox.contactUserID(room, me: me).flatMap { profiles[$0]?.handle }
    }

    func accountName(of room: Room) -> String {
        room.bridge?.receiver.flatMap { identities[$0]?.name } ?? "your chats"
    }

    // MARK: Thread (write side, PLAN-core P3). Instagram's echo through the socket confirms each one.

    /// A text, with a local echo at once. In a request it accepts first ("Reply instead"), as the bridge did.
    func send(_ text: String, replyTo: String?, in room: Room) {
        let accepting = Inbox.isRequest(room)
        if accepting {
            room.setRequestAction(.init(kind: .accept))
            toast = "Accepted. This chat is now in \(accountName(of: room))."
        }
        var content: [String: JSON] = ["msgtype": "m.text", "body": .string(text)]
        if let replyTo { content["m.relates_to"] = ["m.in_reply_to": ["event_id": .string(replyTo)]] }
        let pending = PendingMessage(txnID: nextOTID(), content: .object(content), ts: Self.nowMS, state: .sending)
        room.addPending(pending)
        setTyping(false, in: room)
        Task {
            if accepting {
                do { try await acceptRequest(room) } catch { return room.updatePending(pending.txnID, .failed(error.localizedDescription)) }
            }
            await deliver(pending, in: room)
        }
    }

    /// The local echo's transaction ID is the offline threading ID Instagram gets, so its echo clears the local one.
    private func deliver(_ pending: PendingMessage, in room: Room) async {
        guard let account = room.bridge?.receiver else { return }
        if drafts[room.id] != nil, let recipient = room.bridge?.channelID {  // the first message: Instagram makes the thread
            do {
                try checkSend(room)
                try await IGCore.sendNew(account, recipient: recipient, text: Timeline.body(of: pending.content), otid: pending.txnID)
                room.updatePending(pending.txnID, .sent(pending.txnID))
            } catch {
                room.updatePending(pending.txnID, .failed(error.localizedDescription))
            }
            return
        }
        guard let thread = Self.threadID(of: room) else { return }
        do {
            try checkSend(room)
            let data = try await IGCore.send(account, thread: thread, text: Timeline.body(of: pending.content),
                                             replyTo: Timeline.replyTarget(pending.content), otid: pending.txnID)
            let id = try? IG.decode(IG.SendResponse.self, data).xigDirectTextSendWithSlideMessagingResponse?.id
            room.updatePending(pending.txnID, .sent(id ?? pending.txnID))
        } catch {
            room.updatePending(pending.txnID, .failed(error.localizedDescription))
        }
    }

    /// "Not sent. Tap to retry": the same offline threading ID again, so an echo that's still coming clears it.
    func retry(_ message: Message, in room: Room) {
        guard case .failed = message.status, message.eventID == nil, let txnID = message.txnID,
              let pending = room.pending.first(where: { $0.txnID == txnID }) else { return }
        room.updatePending(txnID, .sending)
        if sending[txnID] != nil { return startUpload(txnID, in: room, replyTo: Timeline.replyTarget(pending.content)) }
        Task { await deliver(pending, in: room) }
    }

    /// Drops a failed local echo that never reached Instagram.
    func discard(_ message: Message, in room: Room) {
        if message.eventID == nil, let txnID = message.txnID {
            room.removePending(txnID)
            sending.removeValue(forKey: txnID)?.removeFile()
        }
    }

    // MARK: Photos, videos, voice notes (DESIGN §6.9; captions are dropped by Instagram)

    /// A local echo at once (with the upload ring), then Instagram's upload and send, from this chat's account. Never
    /// in a request, nor in a new chat before its first text (no thread to upload to yet).
    func sendMedia(_ item: OutgoingMedia, preview: UIImage?, replyTo: String?, in room: Room) {
        guard !Inbox.isRequest(room), threadKeys[room.id] != nil else {
            item.removeFile()
            if drafts[room.id] != nil { actionError = "Send a message first: Instagram starts the chat with it." }
            return
        }
        let txnID = nextOTID()
        let local = PhotoMessage.localURL(txnID)
        if let preview { media.seed(preview, for: local) }  // a photo, or a video's thumbnail
        sending[txnID] = item
        room.addPending(PendingMessage(txnID: txnID, content: item.content(url: local, thumbnailURL: local, replyTo: replyTo),
                                       ts: Self.nowMS, state: .sending))
        setTyping(false, in: room)
        startUpload(txnID, in: room, replyTo: replyTo)
    }

    /// Instagram reports no upload progress, so the ring turns until it's sent.
    private func startUpload(_ txnID: String, in room: Room, replyTo: String?) {
        guard let item = sending[txnID], let account = room.bridge?.receiver, let thread = Self.threadID(of: room),
              let key = threadKeys[room.id] else { return }
        uploads[txnID] = 0
        uploadTasks[txnID] = Task {
            defer { uploads[txnID] = nil; uploadTasks[txnID] = nil }
            do {
                try checkSend(room)
                let file = try item.fileToSend(txnID)
                try await IGCore.sendMedia(account, threadKey: key, thread: thread, file: file, mimetype: item.mimetype,
                                           voice: item.isVoice, replyTo: replyTo, otid: txnID)
                room.updatePending(txnID, .sent(txnID))
            } catch {
                if !Task.isCancelled { room.updatePending(txnID, .failed(error.localizedDescription)) }
            }
        }
    }

    /// Our media's echo arrived: its file goes into the cache under Instagram's link.
    private func fileSentMedia(_ txnID: String, in room: Room) {
        guard let item = sending.removeValue(forKey: txnID),
              let event = room.events.last(where: { $0.unsigned?.transactionID == txnID }), let url = event.content["url"]?.string else { return }
        let preview = media.cached(PhotoMessage.localURL(txnID), pixels: 0)
        // Filed under the type Instagram's message says (a picked .mov comes back as video/mp4), so tapping it finds it.
        let mimetype = event.content["info"]?["mimetype"]?.string ?? item.mimetype
        switch item {
        case .photo(let photo):
            media.store(photo.data, url: url, mimetype: mimetype)
            if let preview { media.seed(preview, for: url) }
        case .video(let video):
            media.store(file: video.file, url: url, mimetype: mimetype)
            if let preview, let thumbnail = event.content["info"]?["thumbnail_url"]?.string { media.seed(preview, for: thumbnail) }
        case .voice(let voice):
            media.store(file: voice.file, url: url, mimetype: mimetype)
        }
        item.removeSentCopy(txnID)
    }

    /// The ring's ✕ while uploading: nothing was sent, so the echo just goes.
    func cancelUpload(_ txnID: String, in room: Room) {
        uploadTasks[txnID]?.cancel()
        uploadTasks[txnID] = nil
        uploads[txnID] = nil
        sending.removeValue(forKey: txnID)?.removeFile()
        room.removePending(txnID)
    }

    /// "Load video" on a shared reel or story: a read on Instagram (allowed in requests), then the card swaps in place.
    func resolveMedia(_ message: Message, in room: Room) {
        guard let eventID = message.eventID, resolving[eventID] != .running, let account = room.bridge?.receiver,
              let unresolved = message.content["com.beeper.unresolved_media"], let target = unresolved["target_url"]?.string else { return }
        resolving[eventID] = .running
        autoOpen = nil
        Task {
            do {
                try checkSend(room)
                let media = try IG.decode(IG.Resolved.self, try await IGCore.resolveMedia(account, target: target, id: unresolved["target_id"]?.string ?? ""))
                room.apply(JoinedRoom(timeline: .init(events: [IGAdapter.resolved(media, for: message)], limited: false)))
                resolving[eventID] = nil
                autoOpen = eventID
            } catch {
                resolving[eventID] = .failed
            }
        }
    }

    /// A download failed: Instagram's links expire (33 h to 30 days, P0), so the thread is read again for fresh ones.
    func refreshMedia(in room: Room) {
        refreshed[room.id] = nil
        openThread(room)
    }

    /// Instagram keeps one reaction per person: the same emoji again removes ours, another one replaces it.
    func react(_ key: String, to message: Message, in room: Room) {
        guard Inbox.allowsReceipts(room), let target = message.eventID else { return }
        let remove = message.reactions.contains { $0.key == key && $0.senders.contains(me) }
        perform(room) { account, thread in try await IGCore.react(account, thread: thread, message: target, emoji: key, remove: remove) }
    }

    func edit(_ message: Message, to text: String, in room: Room) {
        guard Inbox.allowsReceipts(room), let target = message.eventID, Timeline.canEdit(message) else { return }
        let otid = nextOTID()
        perform(room) { account, thread in try await IGCore.edit(account, thread: thread, message: target, text: text, otid: otid) }
    }

    /// Unsend for everyone (Instagram has no "delete for me").
    func unsend(_ message: Message, in room: Room) {
        guard Inbox.allowsReceipts(room), message.isOwn, let target = message.eventID, let long = longID(of: room) else { return }
        perform(room) { account, _ in try await IGCore.unsend(account, threadLong: long, message: target) }
    }

    /// Typing reaches Instagram, so it's throttled (one "typing" per 20 s; Instagram holds it for 22) and, like "Seen",
    /// never sent in requests.
    func setTyping(_ typing: Bool, in room: Room) {
        guard Inbox.allowsReceipts(room), let account = room.bridge?.receiver, let thread = Self.threadID(of: room),
              (try? checkSend(room)) != nil else { return }
        if typing {
            if let since = typingSince[room.id], Date.now.timeIntervalSince(since) < 20 { return }
            typingSince[room.id] = .now
        } else if typingSince.removeValue(forKey: room.id) == nil {
            return
        }
        Task { try? await IGCore.typing(account, thread: thread, on: typing) }
    }

    private func perform(_ room: Room, _ work: @escaping (_ account: String, _ thread: String) async throws -> Void) {
        guard let account = room.bridge?.receiver, let thread = Self.threadID(of: room) else { return }
        Task {
            do {
                try checkSend(room)
                try await work(account, thread)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// DEBUG stand-ins never reach Instagram: fixture rooms, the room forced to look like a request, and every send
    /// under `FERRY_DEBUG_BLOCK_SENDS`.
    private func checkSend(_ room: Room) throws {
        #if DEBUG
        if DebugFixtures.isFixtureRoom(room.id) || DebugFixtures.blocksSends || room.id == DebugFixtures.forcedRequestRoom {
            throw DebugFixtures.Blocked()
        }
        #endif
    }

    private func nextOTID() -> String {
        otidCounter += 1
        return IGAdapter.offlineThreadingID(ms: Self.nowMS, counter: otidCounter)
    }

    private static var nowMS: Int64 { Int64(Date.now.timeIntervalSince1970 * 1000) }

    // MARK: New message (DESIGN N1)

    /// Instagram's user search as `loginID` (an Instagram request: the sheet debounces it).
    func searchUsers(_ query: String, from loginID: String) async throws -> [BridgeAPI.Contact] {
        let data = try await IGCore.search(loginID, query: query)
        return (try IG.decode(IG.SearchResponse.self, data).xfbCombinedigsearchquery?.searchMessengerContactV2 ?? []).compactMap(IGAdapter.contact)
    }

    /// The DM with `contact` on `loginID`: ours, else the one Instagram has (read once), else a draft until the first
    /// message makes it.
    func openDM(with contact: BridgeAPI.Contact, from loginID: String) async throws -> String {
        if let room = Inbox.existingDM(with: contact.id, account: loginID, in: rooms.values) { return room.id }
        let draftID = IGAdapter.draftID(account: loginID, user: contact.id)
        if drafts[draftID] != nil { return draftID }
        let found = try IG.decode(IG.FoundDM.self, try await IGCore.findDM(loginID, user: contact.id))
        if found.found, let thread = found.threadFbid, let id = try await fetchThread(thread, account: loginID) { return id }
        let snapshot = IGAdapter.draft(account: loginID, contact: contact, viewer: sessions[loginID]?.viewer)
        let room = Room(id: snapshot.id)
        room.ownUserID = me
        IGAdapter.apply(snapshot, to: room)
        profiles.merge(snapshot.profiles) { _, new in new }
        drafts[snapshot.id] = room
        return snapshot.id
    }

    // MARK: Requests (PLAN §2.8, DESIGN I2/T2)

    /// The chat moves to the main list at once; Instagram accepts, then a re-read brings the thread's new folder (and
    /// with it "Seen" and typing, `Inbox.allowsReceipts`). A failure puts it back.
    func accept(_ room: Room) {
        guard Inbox.isRequest(room) else { return }
        room.setRequestAction(.init(kind: .accept))
        toast = "Accepted. This chat is now in \(accountName(of: room))."
        Task {
            do {
                try await acceptRequest(room)
            } catch {
                room.setRequestAction(nil)
                toast = nil
                actionError = error.localizedDescription
            }
        }
    }

    private func acceptRequest(_ room: Room) async throws {
        guard let account = room.bridge?.receiver, let thread = Self.threadID(of: room) else { return }
        try checkSend(room)
        try await IGCore.accept(account, thread: thread, otid: nextOTID())
        _ = try? await fetchThread(thread, account: account)
    }

    /// Deletes the request on Instagram for this account; the chat hides at once and goes when Instagram confirms.
    func deleteRequest(_ room: Room) {
        guard Inbox.isRequest(room), let account = room.bridge?.receiver, let thread = Self.threadID(of: room) else { return }
        room.setRequestAction(.init(kind: .delete))
        Task {
            do {
                try checkSend(room)
                try await IGCore.deleteThread(account, thread: thread)
                rooms[room.id] = nil
            } catch {
                room.setRequestAction(nil)
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: Archive (DESIGN §4.5): this device only, Instagram isn't told

    func setArchived(_ archived: Bool, _ room: Room) {
        var tags = room.tags
        tags[Inbox.archivedTag] = archived ? Inbox.archiveTag(for: room, now: .now) : nil
        room.setTags(tags)
        self.archived[room.id] = archived ? tags[Inbox.archivedTag]?[Inbox.archivedAtKey]?.int64 : nil
        UserDefaults.standard.set(self.archived, forKey: Self.archiveKey)
        if archived { toast = "Archived. New messages bring it back." }
    }

    // MARK: Accounts (A1/A2)

    func setIdentity(_ identity: AccountIdentity, for loginID: String) {
        identities[loginID] = identity
        AccountIdentity.save(identities)
    }

    /// Requests opened (or left) in `scope`: its requests stop counting as new.
    func markRequestsSeen(_ scope: Inbox.Scope) {
        requestsSeen[scope.key] = Inbox.requestsSeenMarker(rooms.values, scope: scope, logins: loginIDs, now: .now)
        Inbox.saveRequestsSeen(requestsSeen)
    }

    /// A1 drag to reorder: sets the scope bar's order.
    func moveAccounts(from source: IndexSet, to destination: Int) {
        var ids = orderedAccounts.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        identities = AccountIdentity.reordered(identities, ids: ids)
        AccountIdentity.save(identities)
    }
}

/// What the composer sends besides text (DESIGN §6.9). A video or voice note stays a file in the temporary folder
/// until its upload moves it into the media cache.
nonisolated enum OutgoingMedia: Sendable {
    case photo(PhotoMessage.Encoded)
    case video(VideoMessage.Video)
    case voice(VoiceMessage.Recorded)

    /// The event, with `local:` URLs for the echo. A photo has no thumbnail.
    func content(url: String, thumbnailURL: String?, replyTo: String?) -> JSON {
        switch self {
        case .photo(let photo): PhotoMessage.content(url: url, photo: photo, replyTo: replyTo)
        case .video(let video): VideoMessage.content(url: url, video: video, thumbnailURL: thumbnailURL ?? url, replyTo: replyTo)
        case .voice(let voice): VoiceMessage.content(url: url, voice: voice, replyTo: replyTo)
        }
    }

    var mimetype: String {
        switch self {
        case .photo(let photo): photo.mimetype
        case .video(let video): video.mimetype
        case .voice: VoiceMessage.mimetype
        }
    }

    var isVoice: Bool { if case .voice = self { true } else { false } }

    /// The file `core/` uploads: a video's or voice note's own, a photo's JPEG written out for it.
    func fileToSend(_ txnID: String) throws -> URL {
        switch self {
        case .photo(let photo):
            let file = PhotoMessage.file(txnID, photo)
            if !FileManager.default.fileExists(atPath: file.path()) { try photo.data.write(to: file, options: .atomic) }
            return file
        case .video(let video): return video.file
        case .voice(let voice): return voice.file
        }
    }

    /// The photo's written-out copy, once sent (a video's or voice note's file has moved into the cache).
    func removeSentCopy(_ txnID: String) {
        if case .photo(let photo) = self { try? FileManager.default.removeItem(at: PhotoMessage.file(txnID, photo)) }
    }

    /// Drops a video's or voice note's file when it won't be sent (once uploaded it has moved, and this does nothing).
    func removeFile() {
        switch self {
        case .photo: break
        case .video(let video): try? FileManager.default.removeItem(at: video.file)
        case .voice(let voice): try? FileManager.default.removeItem(at: voice.file)
        }
    }
}
