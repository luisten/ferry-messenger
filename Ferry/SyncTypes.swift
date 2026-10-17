import Foundation

/// `GET /_matrix/client/v3/sync` response, only the parts the app reads (PLAN §2.4). Everything is optional because
/// Synapse omits empty sections in incremental syncs.
nonisolated struct SyncResponse: Decodable, Sendable {
    var nextBatch: String
    var rooms: Rooms?

    struct Rooms: Decodable, Sendable {
        var join: [String: JoinedRoom]?
        var invite: [String: JSON]?
        var leave: [String: JSON]?
    }

    enum CodingKeys: String, CodingKey { case nextBatch = "next_batch", rooms }
}

nonisolated struct JoinedRoom: Decodable, Sendable {
    var state: EventList?
    var timeline: Timeline?
    var ephemeral: EventList?
    var accountData: EventList?
    var unreadNotifications: UnreadCounts?
    /// Lazy loading's room summary; Synapse sends it only when it changes.
    var summary: Summary?

    struct Timeline: Decodable, Sendable {
        var events: [Event]?
        var limited: Bool?
        var prevBatch: String?

        enum CodingKeys: String, CodingKey { case events, limited, prevBatch = "prev_batch" }
    }

    struct UnreadCounts: Decodable, Sendable {
        var notificationCount: Int?
        var highlightCount: Int?

        enum CodingKeys: String, CodingKey { case notificationCount = "notification_count", highlightCount = "highlight_count" }
    }

    struct Summary: Decodable, Sendable {
        var joinedMemberCount: Int?

        enum CodingKeys: String, CodingKey { case joinedMemberCount = "m.joined_member_count" }
    }

    enum CodingKeys: String, CodingKey {
        case state, timeline, ephemeral, accountData = "account_data", unreadNotifications = "unread_notifications", summary
    }
}

nonisolated struct EventList: Decodable, Sendable {
    var events: [Event]?
}

/// Any Matrix event: room timeline/state, ephemeral (no id, no sender) or account data (type + content only).
nonisolated struct Event: Decodable, Hashable, Sendable {
    var type: String
    var content: JSON
    var eventID: String?
    var sender: String?
    var stateKey: String?
    var originServerTS: Int64?
    /// Room v1–v10 redactions put the target here; v11+ (our rooms are v12) use `content.redacts`.
    var redacts: String?
    var unsigned: Unsigned?

    struct Unsigned: Decodable, Hashable, Sendable {
        var transactionID: String?
        var redactedBecause: JSON?

        enum CodingKeys: String, CodingKey { case transactionID = "transaction_id", redactedBecause = "redacted_because" }
    }

    enum CodingKeys: String, CodingKey {
        case type, content, eventID = "event_id", sender, stateKey = "state_key"
        case originServerTS = "origin_server_ts", redacts, unsigned
    }

    init(type: String, content: JSON, eventID: String? = nil, sender: String? = nil, stateKey: String? = nil,
         originServerTS: Int64? = nil, redacts: String? = nil, unsigned: Unsigned? = nil) {
        self.type = type
        self.content = content
        self.eventID = eventID
        self.sender = sender
        self.stateKey = stateKey
        self.originServerTS = originServerTS
        self.redacts = redacts
        self.unsigned = unsigned
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        // Spec says content is always present; don't let one odd event fail a whole sync if it isn't.
        content = try c.decodeIfPresent(JSON.self, forKey: .content) ?? .object([:])
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID)
        sender = try c.decodeIfPresent(String.self, forKey: .sender)
        stateKey = try c.decodeIfPresent(String.self, forKey: .stateKey)
        originServerTS = try c.decodeIfPresent(Int64.self, forKey: .originServerTS)
        redacts = try c.decodeIfPresent(String.self, forKey: .redacts)
        unsigned = try c.decodeIfPresent(Unsigned.self, forKey: .unsigned)
    }

    /// The target of an `m.replace` edit, if this is one.
    var replacesEventID: String? {
        guard content["m.relates_to"]?["rel_type"]?.string == "m.replace" else { return nil }
        return content["m.relates_to"]?["event_id"]?.string
    }

    /// A message or sticker that isn't an edit: one row in a thread.
    var isBaseMessage: Bool { (type == "m.room.message" || type == "m.sticker") && replacesEventID == nil }

    var redactionTarget: String? { type == "m.room.redaction" ? (redacts ?? content["redacts"]?.string) : nil }
}

/// `GET /rooms/{id}/messages` (back-pagination). `chunk` is newest first for `dir=b`; `end` is absent at the
/// start of the room; `state` holds the lazy-loaded members of the chunk's senders.
nonisolated struct MessagesPage: Decodable, Sendable {
    var chunk: [Event]
    var start: String?
    var end: String?
    var state: [Event]?
}
