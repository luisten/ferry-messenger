import Foundation
import Observation

/// One joined Matrix room as the app knows it: merged state, the raw timeline window since the last gap, and the
/// per-room sync extras. `nonisolated` so tests drive it directly; the app only touches it on the main actor.
@Observable
nonisolated final class Room: Identifiable {
    let id: String
    /// Current state, `type → state_key → event`, built from `state` and from state events inside the timeline.
    private(set) var state: [String: [String: Event]] = [:]
    /// Timeline events in order, oldest first, since the last `limited` reset (no gap tracking, PLAN §2.4).
    private(set) var events: [Event] = []
    /// Pagination token for the start of `events` (M4 back-pagination).
    private(set) var prevBatch: String?
    private(set) var notificationCount = 0
    private(set) var highlightCount = 0
    /// Everyone joined, the bridge bot included (sync's room summary): lazy loading leaves most member events out.
    private(set) var joinedMemberCount: Int?
    /// User IDs typing right now (each `m.typing` replaces the list).
    private(set) var typing: [String] = []
    /// Latest public `m.read` per user.
    private(set) var receipts: [String: Receipt] = [:]
    /// Room tags from `m.tag` account data (`u.archived` = archived in this app).
    private(set) var tags: [String: JSON] = [:]
    /// Our sends not yet echoed by sync (local echo, PLAN §2.6).
    private(set) var pending: [PendingMessage] = []
    /// Reply targets fetched from outside the window (`/event/{id}`), by event ID.
    private(set) var related: [String: Event] = [:]
    /// Back-pagination reached the room's first event.
    private(set) var reachedStart = false
    /// Accept, reply or Delete on a request, from the tap until the bridge answers (PLAN §2.8 optimistic move).
    /// Local only, like `pending`.
    private(set) var requestAction: RequestAction?

    struct Receipt: Equatable, Sendable {
        var eventID: String
        var ts: Int64
    }

    struct RequestAction: Equatable, Sendable {
        enum Kind: Sendable { case accept, delete }
        var kind: Kind
        /// Our event once the server has it: the bridge's failure status points at it. nil while in flight, and for
        /// a reply (the bridge accepts inside the message's own handling).
        var eventID: String?
    }

    init(id: String) {
        self.id = id
    }

    func apply(_ joined: JoinedRoom) {
        for event in joined.state?.events ?? [] { setState(event) }
        if let timeline = joined.timeline {
            if timeline.limited == true {
                events.removeAll()
                reachedStart = false
            }
            if timeline.limited == true || prevBatch == nil { prevBatch = timeline.prevBatch }
            for event in timeline.events ?? [] {
                setState(event)
                events.append(event)
            }
            // Our echo is in: the pending item is done (also keeps it from reappearing after a limited reset).
            let echoed = Set((timeline.events ?? []).compactMap(\.unsigned?.transactionID))
            if !echoed.isEmpty { pending.removeAll { echoed.contains($0.txnID) } }
        }
        if let count = joined.summary?.joinedMemberCount { joinedMemberCount = count }
        if let counts = joined.unreadNotifications {
            notificationCount = counts.notificationCount ?? 0
            highlightCount = counts.highlightCount ?? 0
        }
        for event in joined.ephemeral?.events ?? [] {
            switch event.type {
            case "m.typing": typing = event.content["user_ids"]?.array?.compactMap(\.string) ?? []
            case "m.receipt": mergeReceipts(event.content)
            default: break
            }
        }
        for event in joined.accountData?.events ?? [] where event.type == "m.tag" {
            tags = event.content["tags"]?.object ?? [:]
        }
        // The bridge re-sent m.bridge without the request flag: the accept is done.
        if requestAction?.kind == .accept, bridge?.isRequest != true { requestAction = nil }
    }

    private func setState(_ event: Event) {
        guard let key = event.stateKey else { return }
        state[event.type, default: [:]][key] = event
    }

    /// Prepends one `/messages?dir=b` page fetched from `token`. Dropped if a limited sync replaced the window
    /// meanwhile (it would leave a gap). Older state only fills keys we don't know yet (lazy-loaded members); it
    /// never overwrites current state.
    func prepend(_ page: MessagesPage, from token: String) {
        guard token == prevBatch else { return }
        let known = Set(events.compactMap(\.eventID))
        let older = page.chunk.reversed().filter { !known.contains($0.eventID ?? "") }
        // Newest first, so an unknown member gets their latest event in the page (a join), not their first (the invite).
        for event in (page.state ?? []) + older.reversed() {
            if let key = event.stateKey, state[event.type]?[key] == nil { state[event.type, default: [:]][key] = event }
        }
        events.insert(contentsOf: older, at: 0)
        prevBatch = page.end
        reachedStart = page.end == nil || page.chunk.isEmpty
    }

    func setRequestAction(_ action: RequestAction?) { requestAction = action }

    /// Archive/unarchive applies at once; the next `m.tag` from sync replaces it with the server's copy.
    func setTags(_ tags: [String: JSON]) { self.tags = tags }

    func addPending(_ message: PendingMessage) { pending.append(message) }

    func updatePending(_ txnID: String, _ state: PendingMessage.State) {
        guard let i = pending.firstIndex(where: { $0.txnID == txnID }) else { return }  // sync may have echoed it already
        pending[i].state = state
    }

    func removePending(_ txnID: String) { pending.removeAll { $0.txnID == txnID } }

    func addRelated(_ event: Event) {
        if let id = event.eventID { related[id] = event }
    }

    private func mergeReceipts(_ content: JSON) {
        for (eventID, kinds) in content.object ?? [:] {
            for (user, info) in kinds["m.read"]?.object ?? [:] {
                let ts = info["ts"]?.int64 ?? 0
                if ts >= receipts[user]?.ts ?? .min { receipts[user] = Receipt(eventID: eventID, ts: ts) }
            }
        }
    }

    // MARK: Derived (pure)

    func stateEvent(_ type: String, _ key: String = "") -> Event? { state[type]?[key] }

    /// The Instagram `m.bridge` event, under any state key (DMs use `<hs>/instagram`, spaces use "").
    var bridge: BridgeInfo? {
        state["m.bridge"]?.sorted { $0.key < $1.key }.lazy.compactMap { BridgeInfo(content: $0.value.content) }.first
    }

    /// Our own Matrix user, set by AppModel; needed to tell the DM contact apart from us among the members.
    var ownUserID: String?

    /// The bridge always sets `m.room.name` (implicit names for DMs); the channel name covers the gap before it does.
    var name: String {
        if let event = stateEvent("m.room.name"), let name = event.content["name"]?.string, !name.isEmpty {
            // A DM's implicit name is the bridge's copy of the contact's name, and it isn't refreshed when the contact's
            // profile is fixed later (an inbox reload renamed kivostudio "Unknown user"); the member event is current.
            if event.content["fi.mau.implicit_name"]?.bool == true, let me = ownUserID,
               let contact = Inbox.contactUserID(self, me: me), let current = memberName(contact), !current.isEmpty {
                return current
            }
            return name
        }
        if let name = bridge?.displayName, !name.isEmpty { return name }
        return "Instagram chat"
    }

    var avatarURL: String? {
        if let url = stateEvent("m.room.avatar")?.content["url"]?.string, !url.isEmpty { return url }
        return bridge?.avatarURL
    }

    var isUnread: Bool { notificationCount > 0 || highlightCount > 0 }

    func memberName(_ userID: String) -> String? {
        stateEvent("m.room.member", userID)?.content["displayname"]?.string
    }

    /// The bridge bot (`m.bridge` `bridgebot`): a member, but never a person to show.
    var bridgeBot: String? {
        state["m.bridge"]?.values.lazy.compactMap { $0.content["bridgebot"]?.string }.first
    }

    /// A user's own name: their member event's, else their ghost profile's. nil when neither has one (a left member's
    /// event is just `{"membership": "leave"}`), so the inbox preview can leave the sender out.
    func knownName(of user: String, profile: UserProfile? = nil) -> String? {
        [memberName(user), profile?.name].lazy.compactMap(\.self).first { !$0.isEmpty }
    }

    /// Who a user is, never their raw Matrix ID: `knownName`, else in a DM the room's name (the contact's), else the
    /// ID's localpart. Lazy loading brings every sender's member event with /sync and /messages; the rest covers gaps.
    func displayName(of user: String, profile: UserProfile? = nil) -> String {
        if let known = knownName(of: user, profile: profile) { return known }
        if bridge?.isDM == true, user != ownUserID { return name }
        return Self.localpart(user)
    }

    /// A member's picture: their member event's, else their ghost profile's.
    func avatarURL(of user: String, profile: UserProfile? = nil) -> String? {
        [stateEvent("m.room.member", user)?.content["avatar_url"]?.string, profile?.avatarURL].lazy.compactMap(\.self).first { !$0.isEmpty }
    }

    /// "instagram_123" for "@instagram_123:igm.home.arpa".
    static func localpart(_ user: String) -> String {
        let id = user.hasPrefix("@") ? user.dropFirst() : Substring(user)
        return String(id.split(separator: ":", maxSplits: 1).first ?? id)
    }

    /// The newest message in the window that is neither an edit nor unsent.
    var lastMessage: Event? { lastMessage { _ in true } }

    func lastMessage(where predicate: (Event) -> Bool) -> Event? {
        let redacted = Set(events.compactMap(\.redactionTarget))
        return events.last { event in
            event.isBaseMessage && event.unsigned?.redactedBecause == nil && !redacted.contains(event.eventID ?? "") && predicate(event)
        }
    }

    /// Sort key for the inbox: the last message's time. Backfilled messages keep their Instagram timestamps while
    /// the bridge's state events are stamped later, so "newest event" would be wrong.
    var lastActivity: Int64 {
        lastMessage?.originServerTS ?? events.last?.originServerTS ?? 0
    }

    /// The content to show for a message: its latest edit's `m.new_content` (same sender only), else its own.
    func currentContent(of message: Event) -> JSON {
        let edit = events.last { $0.replacesEventID == message.eventID && $0.sender == message.sender }
        return edit?.content["m.new_content"] ?? message.content
    }
}

/// What the room's `m.bridge` state says (PLAN §2.5, spike S7). Only Instagram (`protocol.id == "instagramgo"`).
nonisolated struct BridgeInfo: Equatable, Sendable {
    enum RoomType: Equatable, Sendable {
        case dm, group, personalSpace
        case other(String)
    }

    /// Instagram's inbox tab on professional accounts (DESIGN §4.2).
    enum InboxFolder: Equatable, Sendable {
        case primary, general
    }

    /// The bridge's Beeper type, not the network id "instagram" (S7.4).
    static let protocolID = "instagramgo"
    /// Channel key our bridge patch writes (`PRIMARY`/`GENERAL`, M8): Instagram sends a thread's tab only when it's
    /// moved, so a missing key means Primary (spike S5, server/bridge/inbox-folder.patch).
    static let inboxFolderKey = "fi.mau.instagram.inbox_folder"

    /// The bridge login (Instagram account FBID) this room belongs to.
    var receiver: String?
    var channelID: String?
    var displayName: String?
    var avatarURL: String?
    var isRequest: Bool
    var roomType: RoomType
    var folder: InboxFolder

    var isDM: Bool { roomType == .dm }

    init?(content: JSON) {
        guard content["protocol"]?["id"]?.string == Self.protocolID else { return nil }
        let channel = content["channel"]
        receiver = channel?["fi.mau.receiver"]?.string
        channelID = channel?["id"]?.string
        displayName = channel?["displayname"]?.string
        avatarURL = channel?["avatar_url"]?.string
        isRequest = channel?["com.beeper.message_request"]?.bool == true  // absent means no (S6)
        folder = channel?[Self.inboxFolderKey]?.string == "GENERAL" ? .general : .primary
        switch content["com.beeper.room_type.v2"]?.string ?? content["com.beeper.room_type"]?.string {
        case "dm": roomType = .dm
        case nil, "", "group_dm": roomType = .group  // IG groups carry no room type at all (S7.6)
        case "personal_filtering_space": roomType = .personalSpace
        case let other?: roomType = .other(other)
        }
    }
}
