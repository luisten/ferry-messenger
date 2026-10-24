import Foundation

/// What `core/` hands the app (docs/PLAN-android.md stage 1): the account, and chats as Matrix-shaped room updates the
/// engine made from Instagram's data (core/chat).
nonisolated enum IG {
    /// `IGLogin`, `IGResume`: the account and its viewer (its first mailbox page's chats arrive as updates, up to `seq`;
    /// the engine loads the other folders by itself).
    struct Login: Decodable, Sendable {
        var account: String
        var viewer: Viewer
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

    /// What `IGNextEvent` hands over, in order: an account's event (`Connected`, `Disconnected`, `AuthError`, and a
    /// retried connection's `Login` or `LoginFailed`) or a chat's change (`Room`: an update with the people and reply
    /// targets that came with it; `RoomRemoved`; New Message's `Draft`; `RoomMoved` from a draft `to` its chat).
    struct Update: Decodable, Sendable {
        var account: String?
        var kind: String
        /// Its place in the engine's order: a call that changes chats returns the last one's (`AppModel.applied`).
        var seq: Int?
        var error: String?
        var code: String?
        var reason: String?
        var room: String?
        var update: JoinedRoom?
        var profiles: [String: UserProfile]?
        var related: [Event]?
        var to: String?
        /// `Login`: Instagram's viewer, in its own snake_case (`IG.decode` reads it).
        var viewer: JSON?
    }

    /// The small answers: a chat's `room` (opened or read), a sent message's `id`, and the `seq` of the call's last
    /// update.
    struct Result: Decodable, Sendable {
        var room: String?
        var id: String?
        var seq: Int?
    }

    /// A push Mozilla held for the phone (`IGPushDrain`, docs/PLAN-push.md): who sent what, in which chat, and whether
    /// it notifies (a message newer than the last time the app was open).
    struct Push: Codable, Equatable, Sendable {
        var account: String
        /// Instagram's type: `direct_v2_text`, `direct_v2_media`, `direct_v2_voice_message`, or one that isn't a message.
        var kind: String
        /// Their handle.
        var sender: String
        /// A group's name (never captured: no group on the dummies).
        var group: String?
        /// The message, or Instagram's line for media ("Sent a photo").
        var text: String
        /// The thread's long ID and the sender's Instagram user ID, for `IGCore.pushRoom`.
        var thread: String
        var user: String
        /// Instagram's message ID: one notification per message.
        var message: String
        var time: Int64
        var notify: Bool
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
/// row, and applying an update.
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
}
