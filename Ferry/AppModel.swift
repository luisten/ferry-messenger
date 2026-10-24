import Foundation
import Observation
import UIKit
#if DEBUG
import os
#endif

/// App root state: the Instagram accounts (each one's session in the Keychain, a `core/` client per account), their
/// identities, and the chats as Matrix-shaped rooms, kept current by the engine's updates while the app is open
/// (core/chat makes them from Instagram's data and keeps Instagram's rules, docs/PLAN-android.md stages 1–2). What's
/// left here is the app's own: accounts and the Keychain, local echoes, the optimistic Accept, archive, media, toasts.
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
    /// Accounts a re-login turned out to be (refused): the engine's last updates for them are dropped.
    @ObservationIgnored private var strangers: Set<String> = []
    #if DEBUG
    /// `FERRY_DEBUG_WEB_PUSH`'s registration ran this launch.
    @ObservationIgnored private var registeredWebPush = false
    #endif
    /// The engine's updates applied so far (`IG.Update.seq`), and callers waiting for one (`applied(through:)`).
    @ObservationIgnored private var appliedSeq = 0
    @ObservationIgnored private var seqWaiters: [(seq: Int, done: CheckedContinuation<Void, Never>)] = []
    /// New Message's chats with people we've never messaged (the engine's `Draft` updates): not in `rooms`, so the inbox
    /// and search never show an empty chat. When the first message makes the thread, `movedRooms` leads from the draft
    /// to it (`RoomMoved`).
    private var drafts: [String: Room] = [:]
    @ObservationIgnored private var movedRooms: [String: String] = [:]
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
        IGCore.setDebug(blockSends: DebugFixtures.blocksSends, requestRoom: DebugFixtures.forcedRequestRoom)
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
        let login = try await IGCore.login(cookies: cookies)
        await applied(through: login.seq ?? 0)
        if let reloginID, login.account != reloginID {
            if sessions[login.account] == nil {  // a stranger; one of ours just got a fresh session
                strangers.insert(login.account)
                await IGCore.stop(login.account)
                rooms = rooms.filter { $0.value.bridge?.receiver != login.account }
            }
            let wanted = accounts.first { $0.id == reloginID }?.profile?.username.map { "@\($0)" } ?? "the account you're fixing"
            throw IGCore.Failure(message: "That was @\(login.viewer.username ?? "another account"). Log in as \(wanted) to fix it.")
        }
        strangers.remove(login.account)
        running.insert(login.account)
        loaded.insert(login.account)
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
        setStatus(id, "CONNECTING")
        Task {
            do {
                let login = try await IGCore.resume(id, cookies: cookies)
                await applied(through: login.seq ?? 0)  // its first page's chats, so the inbox never reads as empty
                apply(login)
                await saveSession(id)
            } catch {
                running.remove(id)
                failed(id, error)
            }
            loaded.insert(id)
            updateInitialSync()
        }
    }

    /// A login's result: the account (its first mailbox page's chats come as updates; the engine loads the rest).
    private func apply(_ login: IG.Login) {
        let id = login.account
        sessions[id]?.viewer = login.viewer
        if statuses[id]?.state != "CONNECTED" { setStatus(id, "CONNECTING") }  // the socket's Connected may already be in
        syncFailures = 0
        updateAccounts()
        updateInitialSync()
        #if DEBUG
        if let push = DebugFixtures.webPush, push.account == id, !registeredWebPush {
            registeredWebPush = true
            Task {
                let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ferry", category: "push")
                do {
                    try await IGCore.registerPush(id, subscription: push.subscription)
                    log.notice("web push registered")
                } catch {
                    log.error("web push registration failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        #endif
    }

    /// One of the engine's updates for a chat. A room starts with its first fresh window (an update for a room this
    /// side has already dropped, such as a deleted request's, doesn't bring it back).
    private func apply(_ update: IG.Update, account: String) {
        guard let id = update.room else { return }
        let room: Room
        if let existing = rooms[id] {
            room = existing
        } else if update.update?.timeline?.limited == true {
            room = Room(id: id)
            room.ownUserID = me
            rooms[id] = room
        } else {
            return
        }
        IGAdapter.apply(update, to: room)
        if let ms = archived[id], room.tags[Inbox.archivedTag] == nil {
            room.setTags([Inbox.archivedTag: [Inbox.archivedAtKey: .number(Double(ms))]])
        }
        if let people = update.profiles { profiles.merge(people) { _, new in new } }
        // Our media's echo: its file goes into the cache under Instagram's link.
        for txnID in update.update?.timeline?.events?.compactMap(\.unsigned?.transactionID) ?? [] where sending[txnID] != nil {
            fileSentMedia(txnID, in: room)
        }
    }

    /// New Message's chat with someone we've never messaged, until its first message makes the thread.
    private func draft(_ update: IG.Update) {
        guard let id = update.room, drafts[id] == nil else { return }
        let room = Room(id: id)
        room.ownUserID = me
        IGAdapter.apply(update, to: room)
        if let people = update.profiles { profiles.merge(people) { _, new in new } }
        drafts[id] = room
    }

    /// A connection that failed. After a passing failure the engine tries again every 30 s by itself (`Login`,
    /// `LoginFailed`).
    private func failed(_ id: String, _ error: any Error) {
        let failure = error as? IGCore.Failure
        let state = failure?.code ?? "UNKNOWN_ERROR"
        setStatus(id, state, message: InstagramLogin.message(reason: failure?.reason) ?? error.localizedDescription)
        if state == "TRANSIENT_DISCONNECT", !statuses.values.contains(where: { $0.state == "CONNECTED" }) { syncFailures += 1 }
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
            if rooms[group.id] == nil {
                rooms[group.id] = group
                if DebugFixtures.groupIncoming > 0 {
                    Task {
                        for i in 0... {
                            try? await Task.sleep(for: .seconds(DebugFixtures.groupIncoming))
                            group.apply(JoinedRoom(timeline: .init(events: [DebugFixtures.groupIncomingEvent(i)], limited: false)))
                        }
                    }
                }
            }
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
            for update in await IGCore.nextUpdates(timeout: .seconds(1)) { handle(update) }
        }
    }

    /// The engine's events, in its order: an account's connection, or a chat's change (live, typing, a thread it read
    /// by itself, or what a call asked for).
    private func handle(_ update: IG.Update) {
        defer {
            appliedSeq = max(appliedSeq, update.seq ?? 0)
            seqWaiters.removeAll { waiter in
                guard waiter.seq <= appliedSeq else { return false }
                waiter.done.resume()
                return true
            }
        }
        // A new login's chats can come before its account is stored; a removed account's last ones hide (`loginIDs`).
        guard let id = update.account, !strangers.contains(id) else { return }
        switch update.kind {
        case "Connected":
            setStatus(id, "CONNECTED")
            syncFailures = 0
        case "Disconnected":
            setStatus(id, "TRANSIENT_DISCONNECT", message: update.error)
        case "AuthError":
            setStatus(id, update.code ?? "BAD_CREDENTIALS", message: update.error)
        case "Login":  // a retried connection got through
            guard sessions[id] != nil, let viewer = try? IG.decode(IG.Viewer.self, JSONEncoder().encode(update.viewer)) else { return }
            running.insert(id)
            loaded.insert(id)
            apply(IG.Login(account: id, viewer: viewer, seq: update.seq))
            Task { await saveSession(id) }
        case "LoginFailed":
            failed(id, IGCore.Failure(message: update.error ?? "Can't reach Instagram.", code: update.code, reason: update.reason))
        case "Room":
            apply(update, account: id)
        case "RoomRemoved":
            if let room = update.room { rooms[room] = nil }
        case "Draft":
            draft(update)
        case "RoomMoved":  // the draft's first message made its thread
            if let from = update.room, let to = update.to, drafts.removeValue(forKey: from) != nil { movedRooms[from] = to }
        default:
            break
        }
    }

    /// Waits until the engine's updates up to `seq` are applied (a call's own, such as the chat it read).
    private func applied(through seq: Int) async {
        guard seq > appliedSeq else { return }
        if eventTask == nil { eventTask = Task { await eventLoop() } }
        await withCheckedContinuation { seqWaiters.append((seq, $0)) }
    }

    // MARK: Thread (read side)

    /// A chat opened: the engine reads it in full (the mailbox's copy of a message has no reactions or edit history,
    /// P1), at most every 30 s. A read; it sends nothing.
    func openThread(_ room: Room) {
        guard hasThread(room) else { return }
        Task { try? await IGCore.openChat(room.id) }
    }

    /// The chat opened, or a new message in it while it shows: "Seen" on their newest message, which the engine sends
    /// only when the chat is unread and isn't a request (C7), reading it here at once.
    func markRead(_ room: Room) {
        guard hasThread(room) else { return }
        Task { try? await IGCore.markRead(room.id) }
    }

    /// One page of older history, prepended. Not tied to the caller's task: the lazy list re-creates the top spinner
    /// while it settles, which cancelled the request and left pagination stuck (CLAUDE.md).
    func loadOlder(_ room: Room) {
        guard let cursor = room.prevBatch, !room.reachedStart, !paginating.contains(room.id) else { return }
        if cursor == IGAdapter.startToken { return room.prepend(MessagesPage(chunk: []), from: cursor) }
        guard hasThread(room) else { return }
        paginating.insert(room.id)
        Task {
            defer { paginating.remove(room.id) }
            guard let page = try? await IGCore.older(room.id) else { return }
            room.prepend(page, from: cursor)
        }
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
    /// In a request the engine accepts first ("Reply instead"), as the bridge did; the chat moves to the main list here
    /// at once. To a New Message draft it's the first message, which makes the thread.
    func send(_ text: String, replyTo: String?, in room: Room) {
        if Inbox.isRequest(room) {
            room.setRequestAction(.init(kind: .accept))
            toast = "Accepted. This chat is now in \(accountName(of: room))."
        }
        var content: [String: JSON] = ["msgtype": "m.text", "body": .string(text)]
        if let replyTo { content["m.relates_to"] = ["m.in_reply_to": ["event_id": .string(replyTo)]] }
        let pending = PendingMessage(txnID: nextOTID(), content: .object(content), ts: Self.nowMS, state: .sending)
        room.addPending(pending)
        Task { await deliver(pending, in: room) }
    }

    /// The local echo's transaction ID is the offline threading ID Instagram gets, so its echo clears the local one.
    private func deliver(_ pending: PendingMessage, in room: Room) async {
        do {
            try checkSend(room)
            let id = try await IGCore.send(room.id, text: Timeline.body(of: pending.content), replyTo: Timeline.replyTarget(pending.content),
                                           otid: pending.txnID)
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
        guard !Inbox.isRequest(room), hasThread(room) else {
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
        startUpload(txnID, in: room, replyTo: replyTo)
    }

    /// Instagram reports no upload progress, so the ring turns until it's sent.
    private func startUpload(_ txnID: String, in room: Room, replyTo: String?) {
        guard let item = sending[txnID] else { return }
        uploads[txnID] = 0
        uploadTasks[txnID] = Task {
            defer { uploads[txnID] = nil; uploadTasks[txnID] = nil }
            do {
                try checkSend(room)
                let file = try item.fileToSend(txnID)
                try await IGCore.sendMedia(room.id, file: file, mimetype: item.mimetype, voice: item.isVoice, replyTo: replyTo, otid: txnID)
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
        guard let eventID = message.eventID, resolving[eventID] != .running, message.content["com.beeper.unresolved_media"] != nil else { return }
        resolving[eventID] = .running
        autoOpen = nil
        Task {
            do {
                try checkSend(room)
                await applied(through: try await IGCore.resolveMedia(room.id, message: eventID))
                resolving[eventID] = nil
                autoOpen = eventID
            } catch {
                resolving[eventID] = .failed
            }
        }
    }

    /// A download failed: Instagram's links expire (33 h to 30 days, P0), so the thread is read again for fresh ones.
    func refreshMedia(in room: Room) {
        guard hasThread(room) else { return }
        Task { try? await IGCore.readChat(room.id) }
    }

    /// Instagram keeps one reaction per person: the same emoji again removes ours, another one replaces it. Never in a
    /// request (the engine refuses).
    func react(_ key: String, to message: Message, in room: Room) {
        guard let target = message.eventID else { return }
        let mine = message.reactions.first { Message.Reaction.same($0.key, key) && $0.senders.contains(me) }
        if mine == nil { RecentReactions.use(key) }
        // A removal names Instagram's own key ("❤" for our "❤️"): with ours, it took the removal and kept the heart
        // (Android's A4/A5 checks, 2026-10-21).
        let emoji = mine?.key ?? key
        perform(room) { try await IGCore.react(room.id, message: target, emoji: emoji, remove: mine != nil) }
    }

    /// Our own text, within 15 minutes and 5 edits (the engine refuses otherwise; `Timeline.canEdit` hides the menu item).
    func edit(_ message: Message, to text: String, in room: Room) {
        guard let target = message.eventID else { return }
        perform(room) { try await IGCore.edit(room.id, message: target, text: text) }
    }

    /// Unsend for everyone (Instagram has no "delete for me"): our own messages.
    func unsend(_ message: Message, in room: Room) {
        guard let target = message.eventID else { return }
        perform(room) { try await IGCore.unsend(room.id, message: target) }
    }

    /// The composer's typing state, as it changes: the engine tells Instagram at most once per 20 s (Instagram holds it
    /// for 22) and, like "Seen", never in a request.
    func setTyping(_ typing: Bool, in room: Room) {
        guard hasThread(room), (try? checkSend(room)) != nil else { return }
        Task { try? await IGCore.typing(room.id, on: typing) }
    }

    private func perform(_ room: Room, _ work: @escaping () async throws -> Void) {
        guard hasThread(room) else { return }
        Task {
            do {
                try checkSend(room)
                try await work()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// A chat with an Instagram thread: not a New Message draft (none until its first message), nor a DEBUG fixture room.
    private func hasThread(_ room: Room) -> Bool {
        #if DEBUG
        if DebugFixtures.isFixtureRoom(room.id) { return false }
        #endif
        return drafts[room.id] == nil
    }

    /// DEBUG stand-ins never reach Instagram: fixture rooms here; every send under `FERRY_DEBUG_BLOCK_SENDS` and the
    /// chat shown as a request in the engine (`IGCore.setDebug`).
    private func checkSend(_ room: Room) throws {
        #if DEBUG
        if DebugFixtures.isFixtureRoom(room.id) { throw DebugFixtures.Blocked() }
        #endif
    }

    private func nextOTID() -> String { IGCore.newOTID() }

    private static var nowMS: Int64 { Int64(Date.now.timeIntervalSince1970 * 1000) }

    // MARK: New message (DESIGN N1)

    /// Instagram's user search as `loginID` (an Instagram request: the sheet debounces it).
    func searchUsers(_ query: String, from loginID: String) async throws -> [BridgeAPI.Contact] {
        try await IGCore.search(loginID, query: query)
    }

    /// The DM with `contact` on `loginID`: ours, else the one Instagram has (read once), else a draft until the first
    /// message makes it (the engine decides).
    func openDM(with contact: BridgeAPI.Contact, from loginID: String) async throws -> String {
        let found = try await IGCore.openDM(loginID, contact: contact)
        await applied(through: found.seq)
        return found.room
    }

    // MARK: Requests (PLAN §2.8, DESIGN I2/T2)

    /// The chat moves to the main list at once; Instagram accepts, then a re-read brings the thread's new folder (and
    /// with it "Seen" and typing). A failure puts it back.
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

    /// Instagram accepts, then the engine reads the chat again (its new folder lets "Seen" and typing through).
    private func acceptRequest(_ room: Room) async throws {
        guard hasThread(room) else { return }
        try checkSend(room)
        try await IGCore.accept(room.id)
    }

    /// Deletes the request on Instagram for this account; the chat hides at once and goes when Instagram confirms.
    func deleteRequest(_ room: Room) {
        guard Inbox.isRequest(room), hasThread(room) else { return }
        room.setRequestAction(.init(kind: .delete))
        Task {
            do {
                try checkSend(room)
                try await IGCore.deleteThread(room.id)
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
