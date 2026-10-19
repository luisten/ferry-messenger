import Foundation

/// What `core/` hands the app (docs/PLAN-android.md stage 1): the account, and chats as Matrix-shaped room updates the
/// engine made from Instagram's data (core/chat).
nonisolated enum IG {
    /// `IGLogin`: the account, its viewer, and where the mailbox's next page starts (its first page's chats arrive as
    /// updates, up to `seq`).
    struct Login: Decodable, Sendable {
        var account: String
        var viewer: Viewer
        var next: String?
        var seq: Int?
    }

    /// The account itself; also kept in the Keychain with its cookies, for the account list at launch.
    struct Viewer: Codable, Equatable, Sendable {
        var id: String?
        var fbid: String?
        var username: String?
        var fullName: String?
        var profilePicUrl: String?
        var isProfessionalAccount: Bool?
    }

    /// What `IGNextEvent` hands over, in order: an account's event (`Connected`, `Disconnected`, `AuthError`) or a
    /// chat's change (`Room`: an update with the people and reply targets that came with it; `RoomRemoved`).
    struct Update: Decodable, Sendable {
        var account: String?
        var kind: String
        /// Its place in the engine's order: a call that changes chats returns the last one's (`AppModel.applied`).
        var seq: Int?
        var error: String?
        var code: String?
        var room: String?
        var update: JoinedRoom?
        var profiles: [String: UserProfile]?
        var related: [Event]?
    }

    /// The small answers: a mailbox page's `next`, a chat's `room` (found or read), a sent message's `id`, and the
    /// `seq` of the call's last update.
    struct Result: Decodable, Sendable {
        var next: String?
        var room: String?
        var found: Bool?
        var id: String?
        var seq: Int?
    }

    /// The login's viewer is Instagram's snake_case JSON.
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
}

/// `UserProfile` as the engine sends it.
nonisolated extension UserProfile: Decodable {
    private enum CodingKeys: String, CodingKey { case name, avatarURL = "avatar_url", handle }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decodeIfPresent(String.self, forKey: .name), avatarURL: try c.decodeIfPresent(String.self, forKey: .avatarURL),
                  handle: try c.decodeIfPresent(String.self, forKey: .handle))
    }
}

/// What's left on this side of Instagram's data (the rest is core/chat): the engine's names the views use, the account
/// row, and New Message's draft (stage 2 takes it).
nonisolated enum IGAdapter {
    /// The one user the views treat as "us" in every account's chats, as Ferry's double puppet was (core/chat `Me`).
    static let me = "@me"
    /// A room's first page when Instagram has no older one: the thread view shows the start of the chat.
    static let startToken = "ig-start"

    static func user(_ fbid: String) -> String { "@ig_\(fbid)" }

    /// The account in the bridge's whoami shape, so `Health`, the stack, banners and A1–A3 read it as before.
    static func login(account: String, viewer: IG.Viewer?, state: String, message: String? = nil, since: Date,
                      transientSince: Date? = nil) -> BridgeAPI.Login {
        var login = BridgeAPI.Login(id: account)
        login.name = viewer?.username
        login.profile = .init(name: viewer?.fullName, username: viewer?.username, avatar: viewer?.profilePicUrl)
        login.state = .init(stateEvent: state, message: message, timestamp: since.timeIntervalSince1970,
                            info: .init(isProfessionalAccount: viewer?.isProfessionalAccount))
        login.transientSince = transientSince
        return login
    }

    /// An engine update applied to its room: the change, then the reply targets that came with it.
    static func apply(_ update: IG.Update, to room: Room) {
        if let joined = update.update { room.apply(joined) }
        for event in update.related ?? [] { room.addRelated(event) }
    }

    /// The local chat with someone we've never messaged: Instagram has no thread until the first message. Its room ID
    /// says whom it's for; once the real thread arrives, `AppModel.room(_:)` leads there.
    static func draftID(account: String, user: String) -> String { "!ig-\(account)-new-\(user)" }

    static func draft(account: String, contact: BridgeAPI.Contact, viewer: IG.Viewer?) -> IG.Update {
        let name = contact.name ?? contact.handle ?? "New chat"
        let bridge: JSON = ["protocol": ["id": .string(BridgeInfo.protocolID), "displayname": "Instagram"], "com.beeper.room_type": "dm",
                            "channel": ["id": .string(contact.id), "displayname": .string(name), "fi.mau.receiver": .string(account)]]
        var state = [stateEvent("m.bridge", key: "instagram", bridge), stateEvent("m.room.name", ["name": .string(name)]),
                     member(me, name: viewer?.fullName ?? viewer?.username, avatar: viewer?.profilePicUrl),
                     member(user(contact.id), name: name, avatar: contact.avatarURL)]
        if let avatar = nonEmpty(contact.avatarURL) { state.append(stateEvent("m.room.avatar", ["url": .string(avatar)])) }
        return IG.Update(kind: "Room", room: draftID(account: account, user: contact.id),
                         update: JoinedRoom(state: EventList(events: state), timeline: .init(events: [], limited: true, prevBatch: startToken)),
                         profiles: [user(contact.id): UserProfile(name: contact.name, avatarURL: contact.avatarURL, handle: contact.handle)])
    }

    private static func stateEvent(_ type: String, key: String = "", _ content: JSON) -> Event {
        Event(type: type, content: content, eventID: "$ig-\(type)-\(key)", sender: me, stateKey: key)
    }

    private static func member(_ id: String, name: String?, avatar: String?) -> Event {
        var content: [String: JSON] = ["membership": "join"]
        if let name = nonEmpty(name) { content["displayname"] = .string(name) }
        if let avatar = nonEmpty(avatar) { content["avatar_url"] = .string(avatar) }
        return Event(type: "m.room.member", content: .object(content), eventID: "$ig-member-\(id)", sender: id, stateKey: id)
    }

    private static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
}
