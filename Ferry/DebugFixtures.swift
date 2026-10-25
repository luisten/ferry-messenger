#if DEBUG
import Foundation

/// DEBUG-only stand-ins for states the live accounts can't produce safely: no request rooms exist (D11: no third
/// account) and nothing may make Instagram end a session. Launch environment switches (`SIMCTL_CHILD_…`):
/// - `FERRY_DEBUG_REQUESTS=1`: adds three hand-made request rooms (I2/T2 screenshots).
/// - `FERRY_DEBUG_GROUP=1`: adds one hand-made Instagram group (thread sender labels, Chat Info members); no group
///   exists on the dummies (FOLLOWUPS #24).
///   `FERRY_DEBUG_GROUP_EXTRA=<n>` adds n more unread messages to it, so what's new overflows the screen (where the
///   thread opens, its jump-to-newest button); `FERRY_DEBUG_GROUP_INCOMING=<seconds>` makes one more arrive that
///   often while the app runs (the button's count, nothing scrolling while you're up the thread).
///   Fixture rooms (`!debug-…`) aren't real: the engine refuses rooms it didn't make, `AppModel.hasThread` skips them
///   and `AppModel.checkSend` refuses them, so nothing about them leaves the app.
/// - `FERRY_DEBUG_AS_REQUEST=<room id>`: treats one real room as a request, for the "opening a request sends nothing"
///   check in the C6 request count. The engine marks it one (`IGCore.setDebug`), so every request rule applies, and
///   holds back its sends (Accept or Delete would act on the real thread); receipts and typing aren't blocked, so the
///   check exercises the rule itself.
/// - `FERRY_DEBUG_LOGIN_STATE=<login id>=<STATE>[,…]`: replaces the state of those accounts (needs-login banner,
///   A1, A3) without touching the real session.
/// - `FERRY_DEBUG_ENDED_SESSION=<account id>[,…]`: connects those accounts with a broken `sessionid` for this launch,
///   so Instagram answers as it does for a session it ended (signed-out banner, A3) when "Where you're logged in"
///   can't be used. The Keychain keeps the real cookies (nothing is saved over them); a launch without it brings the
///   account back. A3's login replaces them as usual.
/// - `FERRY_DEBUG_ONBOARDING=welcome|signin|connecting|identity|another` (`1` = welcome): shows onboarding over a
///   signed-in session with accounts, at that step, for the first account. Nothing is disconnected; finishing it
///   ("Not now", Save on a later account) returns to the inbox.
/// - `FERRY_DEBUG_BLOCK_SENDS=1`: every message send and media upload fails in the engine, before Instagram (UI tests
///   that exercise the composer's send gestures: if a gesture misfires, nothing reaches Instagram).
/// - `FERRY_DEBUG_VOICE_FILE=<path to an .m4a>`: the mic records nothing; holding it "records" until release and then
///   sends this file through the same path (the simulator's microphone follows the Mac's input, which may not work).
/// - `FERRY_DEBUG_STACK_EXTRA=<STATE>[,…]`: one stand-in account per state, after the real ones, in the inbox's
///   account stack only (the dev stack has two accounts; the stack changes from four). Nothing else sees them.
/// - `FERRY_DEBUG_PLAYER_FAILS=1`: every video in the player and every voice note fails to play, as when AVFoundation
///   drops them (M1's failed state, a voice note's "Can't play"). Downloads still happen.
/// - `FERRY_DEBUG_NOTIFICATIONS_CARD=1`: the inbox's one-time notifications card shows whatever was answered before;
///   with made-up data its buttons only hide it (screenshots, the UI test).
/// - `FERRY_DEBUG_REFRESH_AFTER_HOME=<seconds>`: that long after the app goes to the background, the same wake as
///   Background App Refresh's (catch-up notifications from Mozilla, docs/PLAN-push.md), which the simulator can't be
///   relied on to run. Within iOS's background time (about 30 s). It shows everything Mozilla held, what came while
///   the app was open too, so a message sent before HOME can be checked.
/// - `FERRY_DEBUG_DEMO=1`: made-up accounts and chats only, for the README's screenshots (the repo is public) and the UI
///   tests (C8): the Keychain's accounts are left alone and nothing connects, so nothing reaches Instagram. Includes the
///   requests and the group.
nonisolated enum DebugFixtures {
    private static let env = ProcessInfo.processInfo.environment
    static let addsRequests = env["FERRY_DEBUG_REQUESTS"] == "1" || demo
    static let addsGroup = env["FERRY_DEBUG_GROUP"] == "1" || demo
    static let groupExtra = Int(env["FERRY_DEBUG_GROUP_EXTRA"] ?? "") ?? 0
    static let groupIncoming = Double(env["FERRY_DEBUG_GROUP_INCOMING"] ?? "") ?? 0
    static let demo = env["FERRY_DEBUG_DEMO"] == "1"
    static let onboardingStep = env["FERRY_DEBUG_ONBOARDING"].flatMap { $0.isEmpty ? nil : $0 }
    static let forcedRequestRoom = env["FERRY_DEBUG_AS_REQUEST"].flatMap { $0.isEmpty ? nil : $0 }
    static let blocksSends = env["FERRY_DEBUG_BLOCK_SENDS"] == "1"
    static let voiceFile = env["FERRY_DEBUG_VOICE_FILE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    static let playerFails = env["FERRY_DEBUG_PLAYER_FAILS"] == "1"
    static let refreshAfterHome = Double(env["FERRY_DEBUG_REFRESH_AFTER_HOME"] ?? "")
    static let offersNotifications = env["FERRY_DEBUG_NOTIFICATIONS_CARD"] == "1"
    static let endedSessions = Set((env["FERRY_DEBUG_ENDED_SESSION"] ?? "").split(separator: ",").map(String.init))
    private static let loginStates: [String: String] = Dictionary(
        (env["FERRY_DEBUG_LOGIN_STATE"] ?? "").split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { _, new in new })

    static func overridingStates(_ logins: [BridgeAPI.Login]) -> [BridgeAPI.Login] {
        logins.map { login in
            guard let state = loginStates[login.id] else { return login }
            var login = login
            login.state = .init(stateEvent: state, message: state == "UNKNOWN_ERROR" ? "DEBUG override" : nil,
                                timestamp: Date.now.timeIntervalSince1970 - 600, info: login.state?.info)
            return login
        }
    }

    /// `FERRY_DEBUG_STACK_EXTRA`: "Extra 1", "Extra 2", … with the health their state gives a real login.
    static let extraStackAccounts: [Inbox.AccountStack.Account] = (env["FERRY_DEBUG_STACK_EXTRA"] ?? "").split(separator: ",")
        .enumerated().map { i, state in
            var login = BridgeAPI.Login(id: "debug-extra-\(i + 1)")
            login.state = .init(stateEvent: String(state))
            return .init(id: login.id, name: "Extra \(i + 1)", health: login.health)
        }

    /// Their rings: palette colours from the end, away from the defaults the real accounts get first.
    static func extraStackIdentity(_ id: String) -> AccountIdentity? {
        guard let i = extraStackAccounts.firstIndex(where: { $0.id == id }) else { return nil }
        let color = AccountColor.allCases[AccountColor.allCases.count - 1 - i % AccountColor.allCases.count]
        return AccountIdentity(name: "Extra \(i + 1)", color: color, mark: "\(i + 1)", order: 100 + i)
    }

    /// Thrown by `AppModel.checkSend` for fixture rooms (the engine holds back the forced room's sends and, under
    /// `FERRY_DEBUG_BLOCK_SENDS`, every send: `IGCore.setDebug`).
    struct Blocked: LocalizedError {
        var errorDescription: String? { "DEBUG: blocked (a fixture room)." }
    }

    /// The hand-made rooms below; none exists on Instagram.
    static func isFixtureRoom(_ id: String) -> Bool { id.hasPrefix("!debug-") }

    /// Three DM requests spread over the logins. The `m.bridge` content is the real DM event from
    /// `FerryTests/Fixtures/state_bridge_dm.json` (bridge v26.09) with only the channel changed and
    /// `com.beeper.message_request: true` added, the way the bridge marks PENDING/SPAM threads (S6). Names and texts
    /// come from the I2 mockup.
    static func requestRooms(logins: [String], now: Date = .now) -> [Room] {
        guard !logins.isEmpty else { return [] }
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let people: [(name: String, fbid: String, minutesAgo: Int64, unread: Int, texts: [String])] = [
            ("Kestrel Bikes", "17841400000000001", 120, 2,
             ["Hi! Loved your last shoot.", "Would you be up for a product day in November?"]),
            ("Lena Ortiz", "17841400000000002", 300, 1, ["Is the studio free for a portrait session the week of the 20th?"]),
            ("crypto.wins.daily", "17841400000000003", 1440, 0, ["Turn $200 into $5,000 this week. DM me to learn the method"]),
        ]
        return people.enumerated().map { i, person in
            let receiver = logins[i % logins.count]
            let ghost = "@instagram_\(person.fbid):igm.home.arpa"
            let bridge = dmBridge(name: person.name, fbid: person.fbid, receiver: receiver, request: true)
            let start = ms - person.minutesAgo * 60_000
            var events = [
                Event(type: "m.bridge", content: bridge, eventID: "$debug-bridge-\(i)", sender: "@instagrambot:igm.home.arpa",
                      stateKey: "igm.home.arpa/instagram", originServerTS: start - 1000),
                Event(type: "m.room.name", content: ["name": .string(person.name)], eventID: "$debug-name-\(i)",
                      sender: "@instagrambot:igm.home.arpa", stateKey: "", originServerTS: start - 1000),
                Event(type: "m.room.member", content: ["membership": "join", "displayname": .string(person.name)],
                      eventID: "$debug-member-\(i)", sender: ghost, stateKey: ghost, originServerTS: start - 1000),
            ]
            for (j, text) in person.texts.enumerated() {
                events.append(Event(type: "m.room.message", content: ["msgtype": "m.text", "body": .string(text)],
                                    eventID: "$debug-msg-\(i)-\(j)", sender: ghost, originServerTS: start + Int64(j) * 40_000))
            }
            let room = Room(id: "!debug-request-\(i + 1)")
            room.apply(JoinedRoom(timeline: .init(events: events, limited: false, prevBatch: "debug-start"),
                                  unreadNotifications: .init(notificationCount: person.unread, highlightCount: 0)))
            room.prepend(MessagesPage(chunk: []), from: "debug-start")  // the start of the chat, no back-pagination
            return room
        }
    }

    /// A DM's `m.bridge` content: the real DM event from `FerryTests/Fixtures/state_bridge_dm.json` (bridge v26.09)
    /// with only the channel changed; a request also gets `com.beeper.message_request: true`.
    private static func dmBridge(name: String, fbid: String, receiver: String, request: Bool) -> JSON {
        var channel: [String: JSON] = ["displayname": .string(name), "fi.mau.receiver": .string(receiver), "id": .string(fbid)]
        if request { channel["com.beeper.message_request"] = true }
        return [
            "bridgebot": "@instagrambot:igm.home.arpa",
            "channel": .object(channel),
            "com.beeper.room_type": "dm",
            "com.beeper.room_type.v2": "dm",
            "creator": "@instagrambot:igm.home.arpa",
            "protocol": [
                "avatar_url": "mxc://maunium.net/JxjlbZUlCPULEeHZSwleUXQv",
                "displayname": "Instagram",
                "external_url": "https://instagram.com",
                "id": "instagramgo",
            ],
        ]
    }

    // MARK: Group (FERRY_DEBUG_GROUP)

    private static let theo = "@instagram_17841400000000101:igm.home.arpa"
    private static let maya = "@instagram_17841400000000102:igm.home.arpa"
    private static let sam = "@instagram_17841400000000103:igm.home.arpa"
    private static let priya = "@instagram_17841400000000104:igm.home.arpa"

    /// The ghosts' profiles, standing in for `/profile` (never asked for fixture rooms). Sam's has no handle, like the
    /// ghosts the bridge hasn't updated since `ghost_extra_profile_info` (FOLLOWUPS #10).
    static let groupProfiles: [String: UserProfile] = [
        theo: UserProfile(name: "Theo Park", handle: "theo.climbs"),
        maya: UserProfile(name: "Maya Chen", handle: "maya.chen"),
        sam: UserProfile(name: "Sam Lee"),
        priya: UserProfile(name: "Priya Nair", handle: "priya.n"),
    ]

    /// One hand-made Instagram group on `receiver`, modelled on real shapes: the `m.bridge` content is the real DM event
    /// (`FerryTests/Fixtures/state_bridge_dm.json`) without `com.beeper.room_type`(`.v2`), which is how the bridge
    /// marks a group (S7.6), with a group's channel; the member events copy the real ghost, bot and double-puppet ones
    /// of `sync_initial.json`. Four senders, runs, a reply, reactions (three people on one emoji), a time gap and two
    /// chat events (Instagram's line for Priya leaving, a poll the app can't show; `IGAdapter`'s shapes). Unread, with
    /// our `m.read` on Sam's last message, so it opens with the "New messages" line, and Maya and Sam have seen the
    /// newest. No avatars, so no media requests (initials). Priya left: a leave is a bare `{"membership": "leave"}`, so
    /// her old message is named from her ghost profile, the thread's fallback for a member event without a name.
    static func groupRoom(receiver: String, me: String, now: Date = .now) -> Room {
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let bot = "@instagrambot:igm.home.arpa"
        let bridge: JSON = [
            "bridgebot": .string(bot),
            "channel": ["displayname": "Saturday Climbs", "fi.mau.receiver": .string(receiver), "id": "340282366841710300949128100000000001"],
            "creator": .string(bot),
            "protocol": [
                "avatar_url": "mxc://maunium.net/JxjlbZUlCPULEeHZSwleUXQv",
                "displayname": "Instagram",
                "external_url": "https://instagram.com",
                "id": "instagramgo",
            ],
        ]
        let start = ms - 60 * 60_000
        func state(_ type: String, _ key: String, _ content: JSON, sender: String = bot, at ts: Int64 = start) -> Event {
            Event(type: type, content: content, eventID: "$debug-group-\(type)-\(key)-\(ts)", sender: sender, stateKey: key, originServerTS: ts)
        }
        var events = [
            state("m.bridge", "igm.home.arpa/instagram", bridge),
            state("m.room.name", "", ["name": "Saturday Climbs"]),
            state("m.room.member", bot, ["membership": "join", "displayname": "Instagram bridge bot"]),
            state("m.room.member", me, ["membership": "join", "displayname": "me", "fi.mau.double_puppet_source": "mautrix-instagram"], sender: me),
        ]
        for id in [theo, maya, sam, priya] {
            events.append(state("m.room.member", id, ["membership": "join", "displayname": .string(groupProfiles[id]?.name ?? "")], sender: id))
        }
        let script: [(sender: String, minutesAgo: Double, text: String, replyTo: Int?)] = [
            (theo, 52, "Who's in for Saturday?", nil),
            (theo, 51.5, "Thinking the north wall at 9", nil),
            (maya, 51, "In! I'll bring the rope", nil),
            (priya, 50, "Can't this week, have fun", nil),
            (me, 49, "Count me in", nil),
            (sam, 48, "Is 9 too early?", 1),
            (sam, 47.5, "I can drive, 3 seats", nil),
            (theo, 12, "9:30 then. See you all there", nil),
        ]
        for (i, line) in script.enumerated() {
            var content: [String: JSON] = ["msgtype": "m.text", "body": .string(line.text)]
            if let target = line.replyTo { content["m.relates_to"] = ["m.in_reply_to": ["event_id": .string("$debug-group-msg-\(target)")]] }
            events.append(Event(type: "m.room.message", content: .object(content), eventID: "$debug-group-msg-\(i)", sender: line.sender,
                                originServerTS: ms - Int64(line.minutesAgo * 60_000)))
        }
        events.insert(contentsOf: [  // before Theo's last message
            Event(type: "m.room.message", content: ["msgtype": "m.notice", "body": "Priya left the group", MessageKind.eventKey: true],
                  eventID: "$debug-group-left", sender: priya, originServerTS: ms - 30 * 60_000),
            Event(type: "m.room.message", content: ["msgtype": "m.notice", "body": "Sent a poll", MessageKind.unsupportedKey: "a poll"],
                  eventID: "$debug-group-poll", sender: sam, originServerTS: ms - 20 * 60_000),
        ], at: events.count - 1)
        // `FERRY_DEBUG_GROUP_EXTRA`: more that's new, after Theo's last message, to overflow the screen by as much.
        let lines = ["On my way", "Bringing chalk and the long rope, plus snacks for after", "👍",
                     "Anyone need a ride from the station? Two seats left in the back, leaving at 8:45 sharp"]
        for i in 0..<groupExtra {
            events.append(Event(type: "m.room.message", content: ["msgtype": "m.text", "body": .string(lines[i % lines.count])],
                                eventID: "$debug-group-extra-\(i)", sender: [maya, sam, theo][i % 3],
                                originServerTS: ms - 11 * 60_000 + Int64(i) * 1000))
        }
        // Three on Instagram's "❤" (no selector) beside a 😂: the squeezed pill hid the heart behind the faces (2026-10-25).
        for (i, (target, key, sender)) in [(2, "❤", theo), (2, "❤", sam), (2, "❤", me), (2, "😂", priya), (4, "❤️", maya),
                                            (4, "🔥", theo), (6, "👍", theo), (6, "👍", maya), (6, "👍", me)].enumerated() {
            events.append(Event(type: "m.reaction", content: ["m.relates_to": ["rel_type": "m.annotation", "event_id": .string("$debug-group-msg-\(target)"), "key": .string(key)]],
                                eventID: "$debug-group-reaction-\(i)", sender: sender, originServerTS: ms - 47 * 60_000))
        }
        events.append(state("m.room.member", priya, ["membership": "leave"], sender: priya, at: ms - 30 * 60_000))
        func read(_ minutesAgo: Double) -> JSON { ["ts": .number(Double(ms) - minutesAgo * 60_000)] }
        let receipts: JSON = [
            "$debug-group-msg-6": ["m.read": .object([me: read(47)])],
            "$debug-group-msg-7": ["m.read": .object([maya: read(10), sam: read(5)])],
        ]

        let room = Room(id: "!debug-group")
        room.ownUserID = me
        room.apply(JoinedRoom(timeline: .init(events: events, limited: false, prevBatch: "debug-start"),
                              ephemeral: EventList(events: [Event(type: "m.receipt", content: receipts)]),
                              unreadNotifications: .init(notificationCount: 1, highlightCount: 0)))
        room.prepend(MessagesPage(chunk: []), from: "debug-start")  // the start of the chat: "You're messaging from X."
        return room
    }

    /// `FERRY_DEBUG_GROUP_INCOMING`: the i-th made-up message to arrive in the group while the app runs, as now.
    static func groupIncomingEvent(_ i: Int, now: Date = .now) -> Event {
        Event(type: "m.room.message", content: ["msgtype": "m.text", "body": .string("Still on for Saturday? (\(i + 1))")],
              eventID: "$debug-group-incoming-\(i)", sender: [sam, theo, maya][i % 3], originServerTS: Int64(now.timeIntervalSince1970 * 1000))
    }

    // MARK: Demo (FERRY_DEBUG_DEMO)

    /// The fixtures' made-up accounts (CLAUDE.md) in place of the Keychain's, personal first: Tamo Veska, then Kivo
    /// Studio. No cookies and no profile picture: `AppModel` never connects them and gives them default identities, in
    /// memory only.
    static let demoSessions: [String: Keychain.Account] = [
        "17841400000000301": .init(cookies: [:], viewer: .init(fbid: "17841400000000301", username: "tamoveska",
                                                               fullName: "Tamo Veska", isProfessionalAccount: false)),
        "17841400000000302": .init(cookies: [:], viewer: .init(fbid: "17841400000000302", username: "kivostudio",
                                                               fullName: "Kivo Studio", isProfessionalAccount: true)),
    ]

    private static let demoChats: [(name: String, handle: String, fbid: String, login: Int, unread: Int,
                                    lines: [(fromMe: Bool, minutesAgo: Int64, text: String)])] = [
        ("Noor Haddad", "noor.haddad", "17841400000000201", 0, 1, [
            (false, 26, "Are we still on for Sunday?"), (true, 25, "Yes! Brunch at 11?"), (false, 4, "Perfect, I'll book a table")]),
        ("Harbor Coffee", "harborcoffee", "17841400000000202", 1, 2, [
            (false, 95, "Hi! Could we book the studio for a product shoot?"), (true, 90, "Of course. Which day works for you?"),
            (false, 41, "Next Thursday, around 9?"), (false, 40, "We'd bring our own props")]),
        ("Jonas Berg", "jonas.berg", "17841400000000203", 0, 0, [
            (true, 300, "Sent you the photos from the hike"), (false, 280, "These are amazing, thank you!")]),
        ("Elena Rossi", "elena.rossi", "17841400000000204", 1, 0, [
            (false, 1500, "Love the new prints. Do you ship to Italy?"), (true, 1440, "We do! Shipping takes 5–7 days.")]),
    ]

    static let demoProfiles: [String: UserProfile] = Dictionary(uniqueKeysWithValues: demoChats.map {
        ("@instagram_\($0.fbid):igm.home.arpa", UserProfile(name: $0.name, handle: $0.handle))
    })

    /// Four DMs, the first and third on `logins[0]`, the others on `logins[1]`: text, and Elena's photo without a URL
    /// (no requests for files). Fixture rooms like the requests: nothing about them leaves the app.
    static func demoRooms(logins: [String], me: String, now: Date = .now) -> [Room] {
        guard !logins.isEmpty else { return [] }
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let bot = "@instagrambot:igm.home.arpa"
        return demoChats.enumerated().map { i, chat in
            let ghost = "@instagram_\(chat.fbid):igm.home.arpa"
            let start = ms - (chat.lines.first?.minutesAgo ?? 0) * 60_000 - 1000
            let bridge = dmBridge(name: chat.name, fbid: chat.fbid, receiver: logins[chat.login % logins.count], request: false)
            var events = [
                Event(type: "m.bridge", content: bridge, eventID: "$debug-demo-bridge-\(i)", sender: bot,
                      stateKey: "igm.home.arpa/instagram", originServerTS: start),
                Event(type: "m.room.name", content: ["name": .string(chat.name)], eventID: "$debug-demo-name-\(i)",
                      sender: bot, stateKey: "", originServerTS: start),
                Event(type: "m.room.member", content: ["membership": "join", "displayname": .string(chat.name)],
                      eventID: "$debug-demo-member-\(i)", sender: ghost, stateKey: ghost, originServerTS: start),
            ]
            if chat.handle == "elena.rossi" {  // a photo from them, for the long-press test: no URL, so nothing loads
                events.append(Event(type: "m.room.message", content: ["msgtype": "m.image", "body": "print.jpg",
                                                                      "info": ["w": 1080, "h": 1350, "mimetype": "image/jpeg"]],
                                    eventID: "$debug-demo-photo", sender: ghost, originServerTS: start + 500))
            }
            for (j, line) in chat.lines.enumerated() {
                events.append(Event(type: "m.room.message", content: ["msgtype": "m.text", "body": .string(line.text)],
                                    eventID: "$debug-demo-msg-\(i)-\(j)", sender: line.fromMe ? me : ghost,
                                    originServerTS: ms - line.minutesAgo * 60_000))
            }
            let room = Room(id: "!debug-demo-\(i + 1)")
            room.ownUserID = me
            room.apply(JoinedRoom(timeline: .init(events: events, limited: false, prevBatch: "debug-start"),
                                  unreadNotifications: .init(notificationCount: chat.unread, highlightCount: 0)))
            room.prepend(MessagesPage(chunk: []), from: "debug-start")  // the start of the chat, no back-pagination
            return room
        }
    }
}
#endif
