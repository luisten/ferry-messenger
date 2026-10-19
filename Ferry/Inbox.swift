import Foundation

/// Pure inbox rules (PLAN §2.5, §2.8, DESIGN §4): which rooms show, where, in what order, with which counts.
nonisolated enum Inbox {
    /// Whose chats you see: everyone's, or one bridge login's (its FBID).
    enum Scope: Hashable, Sendable {
        case all
        case account(String)

        /// "" for All, else the login ID (the inbox's `@SceneStorage` and the seen markers use the same keys).
        var key: String {
            switch self {
            case .all: ""
            case .account(let id): id
            }
        }
    }

    /// `chats` is the main list: Primary on professional accounts, everything on personal ones (DESIGN §4.3).
    enum Folder: String, Hashable, Sendable {
        case chats, general, requests, archived
    }

    /// The room tag that archives a chat in this app (Matrix-side only; Instagram never hears of it).
    static let archivedTag = "u.archived"
    /// Key inside the `u.archived` tag content holding when the chat was archived (ms).
    static let archivedAtKey = "com.igmessenger.archived_at"

    /// The `u.archived` tag content for archiving `room` now. Never earlier than its last message: a phone clock
    /// running behind the server would otherwise date the archive before that message and bring the chat straight
    /// back (`folder(of:)` returns a chat on activity after this time).
    static func archiveTag(for room: Room, now: Date) -> JSON {
        let ms = max(Int64(now.timeIntervalSince1970 * 1000), room.lastActivity)
        return [archivedAtKey: .number(Double(ms))]
    }

    /// A room is in the inbox when it's an Instagram portal (not a personal filtering space) and, once whoami has
    /// loaded (`logins` non-nil), its receiver is a current login. That hides the bot room, the per-login spaces and
    /// rooms left behind by removed logins.
    /// A request being deleted is hidden until the bridge removes the room (or reports a failure).
    static func isVisible(_ room: Room, logins: Set<String>?) -> Bool {
        guard let bridge = room.bridge, bridge.roomType != .personalSpace, let receiver = bridge.receiver else { return false }
        if room.requestAction?.kind == .delete && requestActionFailure(room) == nil { return false }
        return logins?.contains(receiver) ?? true
    }

    /// Requests first, then this app's archive, then Instagram's tab (General only on professional accounts).
    static func folder(of room: Room) -> Folder {
        if isRequest(room) { return .requests }
        // New activity after archiving brings the chat back (DESIGN §4.5) without anyone touching the tag.
        if let tag = room.tags[archivedTag], room.lastActivity <= tag[archivedAtKey]?.int64 ?? .max { return .archived }
        return room.bridge?.folder == .general ? .general : .chats
    }

    static func inScope(_ room: Room, _ scope: Scope) -> Bool {
        switch scope {
        case .all: true
        case .account(let id): room.bridge?.receiver == id
        }
    }

    static func inScope(login id: String, _ scope: Scope) -> Bool {
        scope == .all || scope == .account(id)
    }

    /// DESIGN §4.2–4.4: the General tile shows in a scope that holds a professional account (All included: it's the
    /// only way to those chats there), or any General chat ("data wins" over an unknown account type).
    static func showsGeneral(_ rooms: some Sequence<Room>, scope: Scope, accounts: [BridgeAPI.Login], logins: Set<String>?) -> Bool {
        accounts.contains { $0.isProfessional && inScope(login: $0.id, scope) }
            || !Self.rooms(rooms, scope: scope, folder: .general, logins: logins).isEmpty
    }

    /// The rows of one list, newest activity first (ties broken by room ID so the order never flickers).
    static func rooms(_ rooms: some Sequence<Room>, scope: Scope, folder: Folder, logins: Set<String>?) -> [Room] {
        sorted(rooms.filter { isVisible($0, logins: logins) && inScope($0, scope) && self.folder(of: $0) == folder })
    }

    /// I5: chats in scope whose name contains the query, ignoring case and accents. Archived chats are found too
    /// (search is how you get one back without scrolling Archived); requests stay in their own place.
    static func search(_ rooms: some Sequence<Room>, query: String, scope: Scope, logins: Set<String>?) -> [Room] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return sorted(rooms.filter {
            isVisible($0, logins: logins) && inScope($0, scope) && folder(of: $0) != .requests && $0.name.localizedStandardContains(query)
        })
    }

    private static func sorted(_ rooms: [Room]) -> [Room] {
        rooms.map { (room: $0, activity: $0.lastActivity) }
            .sorted { $0.activity != $1.activity ? $0.activity > $1.activity : $0.room.id < $1.room.id }
            .map(\.room)
    }

    /// T3: the contact's @handle without asking the server: a DM with another of *our* accounts (its channel ID is
    /// that login's ID). Anyone else's comes from their ghost profile (`contactUserID`, `profileHandle`).
    static func contactHandle(_ room: Room, accounts: [BridgeAPI.Login]) -> String? {
        guard let bridge = room.bridge, bridge.isDM, let other = bridge.channelID else { return nil }
        return accounts.first { $0.id == other }?.profile?.username
    }

    /// The other person's Matrix user (their bridge ghost) in a DM: the joined member who is neither us nor the
    /// bridge bot. Read from state, never built from the ghost name template.
    static func contactUserID(_ room: Room, me: String) -> String? {
        guard let bridge = room.bridge, bridge.isDM else { return nil }
        let bot = room.bridgeBot
        return room.state["m.room.member"]?
            .filter { $0.key != me && $0.key != bot && $0.value.content["membership"]?.string == "join" }
            .keys.sorted().first
    }

    /// The handle in a ghost's profile (`com.beeper.bridge.identifiers`, set with `ghost_extra_profile_info`). The
    /// bridge fills it when it next updates that contact (a search finds them, or Instagram sends their info), so
    /// older ghosts may not have it yet.
    static func profileHandle(_ profile: JSON) -> String? {
        BridgeAPI.Contact.handle(in: profile["com.beeper.bridge.identifiers"]?.array?.compactMap(\.string))
    }

    // MARK: Members (T3, groups)

    /// One row of Chat Info's Members section.
    struct Member: Identifiable, Equatable, Sendable {
        /// The Matrix user ID.
        var id: String
        /// "You" for us.
        var name: String
        var avatarURL: String?
        var handle: String?
        var isMe: Bool
    }

    /// Who's in the chat: the room's joined member events (`IGAdapter` makes one per thread participant). Never the
    /// bridge bot. Names fall back like the thread's (`Room.displayName`), handles come from profiles. Sorted by name,
    /// you last: the list is about the others.
    static func members(of room: Room, me: String, profiles: [String: UserProfile]) -> [Member] {
        let ids = (room.state["m.room.member"] ?? [:]).filter { $0.value.content["membership"]?.string == "join" }.map(\.key)
        let bot = room.bridgeBot
        return ids.filter { $0 != bot }.map { id in
            if id == me { return Member(id: id, name: "You", isMe: true) }
            let profile = profiles[id]
            return Member(id: id, name: room.displayName(of: id, profile: profile), avatarURL: room.avatarURL(of: id, profile: profile),
                          handle: profile?.handle, isMe: false)
        }
        .sorted { a, b in
            if a.isMe != b.isMe { return b.isMe }
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    /// The two faces a group without its own picture shows (`RoomAvatar`), people with a picture first; none with fewer
    /// than two others, which keeps the people glyph.
    static func faces(of room: Room) -> [Member] {
        let others = members(of: room, me: room.ownUserID ?? IGAdapter.me, profiles: [:]).filter { !$0.isMe }
        guard others.count >= 2 else { return [] }
        return Array((others.filter { $0.avatarURL != nil } + others.filter { $0.avatarURL == nil }).prefix(2))
    }

    /// People in the chat, us included, the bridge bot not: sync's room summary (lazy loading leaves most member
    /// events out), else the joined member events we have.
    static func memberCount(of room: Room) -> Int {
        let bot = room.bridgeBot
        guard let joined = room.joinedMemberCount else {
            return (room.state["m.room.member"] ?? [:]).count { $0.key != bot && $0.value.content["membership"]?.string == "join" }
        }
        // The bot is in every portal; only its own leave event says otherwise.
        let botJoined = bot.map { (room.stateEvent("m.room.member", $0)?.content["membership"]?.string ?? "join") == "join" } ?? false
        return max(joined - (botJoined ? 1 : 0), 0)
    }

    // MARK: Start block (DESIGN T1, review 2026-10-15 #3)

    /// The top of a thread's history: who it's with, then (only while there are no messages, where it's the only cue;
    /// otherwise the composer says it) which account you're writing from.
    struct StartBlock: Equatable, Sendable {
        /// "4 members" in a group, "@handle" in a DM when it's known.
        var subtitle: String?
        var messagingFrom: String?
    }

    static func startBlock(isGroup: Bool, members: Int, handle: String?, account: String?, isEmpty: Bool) -> StartBlock {
        StartBlock(subtitle: isGroup ? (members > 0 ? "\(members) member\(members == 1 ? "" : "s")" : nil) : handle.map { "@\($0)" },
                   messagingFrom: isEmpty ? account.map { "You're messaging from \($0)." } : nil)
    }

    // MARK: Request bar (DESIGN T2, review 2026-10-15 #5)

    struct RequestTitle: Equatable, Sendable {
        var shown: String
        var spoken: String
    }

    /// On screen the account's tag ends the title ("@lena.ortiz wants to message [S Studio]"), so the words stop at
    /// "message"; VoiceOver reads one sentence with the account's name instead.
    static func requestTitle(requester: String, account: String?) -> RequestTitle {
        guard let account else { return RequestTitle(shown: "\(requester) wants to message you.", spoken: "\(requester) wants to message you.") }
        return RequestTitle(shown: "\(requester) wants to message", spoken: "\(requester) wants to message \(account).")
    }

    // MARK: Account stack (DESIGN §3.5, review 2026-10-15 §3)

    /// The inbox toolbar's accounts, side by side and never over each other (principle 9): all of them up to three,
    /// else the first two and a "+N" disc, so the capsule is never wider than 112 pt. A problem is a badge on the
    /// avatar of the account it's about, or on "+N" when that account is behind it.
    struct AccountStack: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case needsYou, connecting
        }

        struct Account: Equatable, Sendable {
            var id: String
            var name: String
            var status: Status?

            init(id: String, name: String, health: BridgeAPI.Login.Health) {
                self.id = id
                self.name = name
                status = health.needsUser ? .needsYou : health.isBusy ? .connecting : nil
            }
        }

        /// In Accounts order.
        var shown: [Account]
        var hidden: [Account]

        init(_ accounts: [Account]) {
            let count = accounts.count <= 3 ? accounts.count : 2
            shown = Array(accounts.prefix(count))
            hidden = Array(accounts.dropFirst(count))
        }

        /// The "+N" disc's badge: needs-you wins over connecting.
        var hiddenStatus: Status? {
            hidden.contains { $0.status == .needsYou } ? .needsYou : hidden.contains { $0.status == .connecting } ? .connecting : nil
        }

        /// One element: "Accounts: Alex, Alex Studio, and 2 more. Alex Studio needs attention." Hidden accounts are
        /// named in the status sentences, since the count can't say whose problem it is.
        var accessibilityLabel: String {
            let all = shown + hidden
            guard !all.isEmpty else { return "Accounts" }
            let names = shown.map(\.name) + (hidden.isEmpty ? [] : ["\(hidden.count) more"])
            let needs = all.filter { $0.status == .needsYou }.map(\.name)
            let busy = all.filter { $0.status == .connecting }.map(\.name)
            return (["Accounts: \(Self.listed(names))."]
                    + (needs.isEmpty ? [] : ["\(Self.listed(needs)) \(needs.count == 1 ? "needs" : "need") attention."])
                    + (busy.isEmpty ? [] : ["\(Self.listed(busy)) \(busy.count == 1 ? "is" : "are") connecting."]))
                .joined(separator: " ")
        }

        /// "A", "A and B", "A, B, and C" (the review's wording keeps the serial comma).
        private static func listed(_ names: [String]) -> String {
            guard let last = names.last, names.count > 1 else { return names.first ?? "" }
            return names.count == 2 ? "\(names[0]) and \(last)" : "\(names.dropLast().joined(separator: ", ")), and \(last)"
        }
    }

    /// The inbox subtitle in an account scope: "@handle", "@handle · Primary" for a professional account (General is in
    /// the Folders menu), or just "Primary" beside a 112 pt stack (three or more accounts), where the title has about
    /// 120 pt. The handle is still in Chat Info and Accounts.
    static func scopeSubtitle(handle: String?, isProfessional: Bool, accounts: Int) -> String {
        guard let handle else { return "" }
        guard isProfessional else { return "@\(handle)" }
        return accounts >= 3 ? "Primary" : "@\(handle) · Primary"
    }

    /// N1: the DM we already have with `userID` on `account`, so tapping a search result opens it without asking
    /// Instagram (the bridge's search omits `dm_room_mxid` even when the DM exists). Requests count too.
    static func existingDM(with userID: String, account: String, in rooms: some Sequence<Room>) -> Room? {
        rooms.first { room in
            guard let bridge = room.bridge else { return false }
            return bridge.isDM && bridge.receiver == account && bridge.channelID == userID && isVisible(room, logins: nil)
        }
    }

    /// Unread chats in one list of the scope, the main list by default (chips): requests, archived and General
    /// chats don't count there (DESIGN §4.5); General's unread feeds the Folders badge.
    static func unreadChats(_ rooms: some Sequence<Room>, scope: Scope, folder: Folder = .chats, logins: Set<String>?) -> Int {
        Self.rooms(rooms, scope: scope, folder: folder, logins: logins).count(where: \.isUnread)
    }

    /// Requests waiting in scope ("3 waiting" in the Folders menu).
    static func requestCount(_ rooms: some Sequence<Room>, scope: Scope, logins: Set<String>?) -> Int {
        Self.rooms(rooms, scope: scope, folder: .requests, logins: logins).count
    }

    // MARK: Folders menu and Requests card (D14)

    /// Requests in scope that arrived (or got a message) after Requests was last opened in a scope that shows them:
    /// All, or their own account. `seen` holds those local times (ms) by `Scope.key`. Request "unread" never clears
    /// (no receipts go to requests), so only this local marker can say what's new; nothing is sent.
    static func newRequests(_ rooms: some Sequence<Room>, scope: Scope, logins: Set<String>?, seen: [String: Int64]) -> [Room] {
        Self.rooms(rooms, scope: scope, folder: .requests, logins: logins).filter { room in
            room.lastActivity > max(seen[Scope.all.key] ?? .min, room.bridge?.receiver.flatMap { seen[$0] } ?? .min)
        }
    }

    /// The marker to store when Requests opens in `scope`: now, but never before the newest request there, or a phone
    /// clock behind the server would leave the card up after looking.
    static func requestsSeenMarker(_ rooms: some Sequence<Room>, scope: Scope, logins: Set<String>?, now: Date) -> Int64 {
        let newest = Self.rooms(rooms, scope: scope, folder: .requests, logins: logins).first?.lastActivity ?? .min
        return max(Int64(now.timeIntervalSince1970 * 1000), newest)
    }

    private static let requestsSeenKey = "requests.seen"

    static func loadRequestsSeen(from defaults: UserDefaults = .standard) -> [String: Int64] {
        defaults.dictionary(forKey: requestsSeenKey) as? [String: Int64] ?? [:]
    }

    static func saveRequestsSeen(_ seen: [String: Int64], to defaults: UserDefaults = .standard) {
        defaults.set(seen, forKey: requestsSeenKey)
    }

    /// The toolbar Folders menu for one scope: which items, their subtitles and the badge.
    struct FoldersMenu: Equatable, Sendable {
        var items: [Folder]
        var requestsWaiting: Int
        var newRequests: Int
        var generalUnread: Int

        /// Hidden at 0. General's unread chats count; requests only until you've looked.
        var badge: Int { newRequests + generalUnread }

        /// "2 waiting", "1 unread"; nothing rather than "0".
        func subtitle(_ folder: Folder) -> String? {
            switch folder {
            case .requests where requestsWaiting > 0: "\(requestsWaiting) waiting"
            case .general where generalUnread > 0: "\(generalUnread) unread"
            default: nil
            }
        }

        /// What the badge counts, since the badge itself isn't read out.
        var accessibilityLabel: String {
            (["Folders"] + [newRequests > 0 ? "\(newRequests) new request\(newRequests == 1 ? "" : "s")" : nil,
                            generalUnread > 0 ? "\(generalUnread) unread in General" : nil].compactMap(\.self))
                .joined(separator: ", ")
        }
    }

    static func foldersMenu(_ rooms: some Collection<Room>, scope: Scope, accounts: [BridgeAPI.Login], logins: Set<String>?,
                            seen: [String: Int64]) -> FoldersMenu {
        FoldersMenu(items: (showsGeneral(rooms, scope: scope, accounts: accounts, logins: logins) ? [.general] : []) + [.requests, .archived],
                    requestsWaiting: requestCount(rooms, scope: scope, logins: logins),
                    newRequests: newRequests(rooms, scope: scope, logins: logins, seen: seen).count,
                    generalUnread: unreadChats(rooms, scope: scope, folder: .general, logins: logins))
    }

    static func requestsCardTitle(count: Int) -> String {
        "\(count) message request\(count == 1 ? "" : "s")"
    }

    /// Names only: no message text, so spam never reaches the main list.
    static func requestsCardLabel(names: [String]) -> String {
        "\(requestsCardTitle(count: names.count)), from \(listed(names)). Opens Requests."
    }

    /// "A", "A and B", "A, B and C".
    private static func listed(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return "\(names.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// The bridge forwards `m.read` and typing to Instagram as "Seen"/typing, which would reveal to a requester that
    /// we read their request; it also marks the chat read before handling *any* event we send (implicit read receipts,
    /// mautrix-go `bridgev2/portal.go:874`). So every receipt, typing, reaction, edit and unsend must pass this
    /// (PLAN §2.8). It follows the bridge's flag, not our optimistic Accept. Unknown rooms are refused.
    static func allowsReceipts(_ room: Room) -> Bool {
        guard let bridge = room.bridge else { return false }
        return !bridge.isRequest
    }

    // MARK: Requests (PLAN §2.8, DESIGN I2/T2)

    /// A request as the user sees it: the bridge's flag, unless they just accepted or replied (optimistic; a failure
    /// status from the bridge undoes it).
    static func isRequest(_ room: Room) -> Bool {
        guard room.bridge?.isRequest == true else { return false }
        return room.requestAction?.kind != .accept || requestActionFailure(room) != nil
    }

    /// The bridge's failure message for our Accept or Delete (`com.beeper.message_send_status`), if it failed.
    static func requestActionFailure(_ room: Room) -> String? {
        guard let id = room.requestAction?.eventID else { return nil }
        let status = room.events.last {
            $0.type == "com.beeper.message_send_status" && $0.content["m.relates_to"]?["event_id"]?.string == id
        }?.content
        guard let code = status?["status"]?.string, code.hasPrefix("FAIL") else { return nil }
        return status?["message"]?.string ?? "Instagram didn't accept that."
    }

    /// What sits at the bottom of a thread (DESIGN T2, §7.2).
    enum ThreadBar: Equatable, Sendable {
        case composer
        /// Accept / Delete / "Reply instead" instead of the composer.
        case request
        /// The composer, with "Replying accepts the request." (the bridge accepts before sending, portal.go:1345).
        case replyAccepts
        /// The account is signed out: "Log in again" instead of the composer.
        case signedOut
    }

    static func threadBar(_ room: Room, health: BridgeAPI.Login.Health?, replyingInstead: Bool) -> ThreadBar {
        if health == .needsLogin { return .signedOut }
        guard isRequest(room) else { return .composer }
        return replyingInstead ? .replyAccepts : .request
    }

    /// DESIGN A3 reassurance: "Personal and Band keep working."
    static func othersKeepWorking(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "\(listed(names)) \(names.count == 1 ? "keeps" : "keep") working."
    }

    // MARK: Row content

    struct Preview: Equatable, Sendable {
        var symbol: String?
        var text: String
    }

    /// Line 2 of a chat row (DESIGN I1). Kinds come from the thread's classifier, so rows and bubbles agree.
    /// `profiles`: ghost profiles already read, for a group sender whose member event has no name.
    static func preview(of room: Room, me: String, profiles: [String: UserProfile] = [:]) -> Preview? {
        guard let message = room.lastMessage else { return nil }
        let content = room.currentContent(of: message)
        let mine = message.sender == me
        // In groups, name the sender ("Theo: …"), or nobody rather than an ID; in DMs only our own messages get a prefix.
        let who: String? = mine ? "You" : room.bridge?.isDM == false
            ? message.sender.flatMap { room.knownName(of: $0, profile: profiles[$0]) }?.split(separator: " ").first.map(String.init) : nil
        let prefix = who.map { "\($0): " } ?? ""

        let kind = MessageKind(type: message.type, content: content)
        if let text = content[MessageKind.shareTextKey]?.string {  // a story reply or reaction: what was said, as Instagram's
            return Preview(symbol: nil, text: prefix + text)
        }
        let sent: String? = switch kind {
        case .share(let type, _): type.phrase
        case .unsupported(let what): what
        default: nil
        }
        if let sent {
            let text = mine ? "You sent \(sent)" : who.map { "\($0) sent \(sent)" } ?? "Sent \(sent)"
            let author = ShareCaption(content: content).author.map { " by @\($0)" } ?? ""
            return Preview(symbol: kind.media?.symbol, text: text + author)
        }
        if let media = kind.media { return Preview(symbol: media.symbol, text: prefix + media.label) }
        let body = Timeline.body(of: content).split(whereSeparator: \.isNewline).joined(separator: " ")
        return Preview(symbol: nil, text: (kind == .event ? "" : prefix) + body)  // an event names who did it
    }

    /// Row time: "9:41" today, "Yesterday", weekday within a week, then a short date.
    static func timeLabel(_ ts: Int64, now: Date = .now, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: Double(ts) / 1000)
        var style = Date.FormatStyle(timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(style.hour().minute()) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return date.formatted(style.weekday(.abbreviated))
        }
        style = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? style.day().month(.abbreviated) : style.day().month(.abbreviated).year()
        return date.formatted(style)
    }

    // MARK: Connection banner (PLAN §2.10, DESIGN §7.2)

    enum Banner: Equatable, Sendable {
        /// No account can reach Instagram (2 failed connects in a row).
        case offline
        /// One account is signed out, erroring or reconnecting for over 2 minutes; the login ID.
        case account(String)
        /// Several accounts are in trouble.
        case accounts(Int)
    }

    /// At most one banner, most fundamental cause first: without the network nothing else can be known.
    static func banner(syncFailures: Int, accounts: [BridgeAPI.Login], now: Date = .now) -> Banner? {
        if syncFailures >= 2 { return .offline }
        let trouble = accounts.filter { $0.health(at: now).raisesBanner }
        switch trouble.count {
        case 0: return nil
        case 1: return .account(trouble[0].id)
        default: return .accounts(trouble.count)
        }
    }
}

/// A user's `/profile` as the bridge fills it for a ghost: name and avatar (fallbacks for a member whose event has
/// none) and the @handle (`com.beeper.bridge.identifiers`, `Inbox.profileHandle`). Read from our server only.
nonisolated struct UserProfile: Equatable, Sendable {
    var name: String?
    var avatarURL: String?
    var handle: String?

    init(name: String? = nil, avatarURL: String? = nil, handle: String? = nil) {
        self.name = name
        self.avatarURL = avatarURL
        self.handle = handle
    }

    init(_ profile: JSON) {
        self.init(name: profile["displayname"]?.string, avatarURL: profile["avatar_url"]?.string, handle: Inbox.profileHandle(profile))
    }
}
