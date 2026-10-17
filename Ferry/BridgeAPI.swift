import Foundation

/// The shapes the bridge's provisioning API used (research/matrix-bridge.md §5), kept as the app's account and contact
/// types: `IGAdapter.login` builds `Login` from Instagram's viewer, so `Health`, the stack, banners and A1–A3 stay.
enum BridgeAPI {

    nonisolated struct Login: Decodable, Identifiable, Sendable {
        var id: String
        var name: String?
        var profile: Profile?
        var state: State?
        /// When this app first saw the current TRANSIENT_DISCONNECT. The bridge re-stamps that state on every
        /// reconnect attempt, so its own timestamp can't say how long it has lasted. Set by AppModel, not decoded.
        var transientSince: Date?

        enum CodingKeys: String, CodingKey { case id, name, profile, state }

        struct Profile: Decodable, Sendable {
            var name: String?
            var username: String?
            var avatar: String?
        }

        struct State: Decodable, Sendable {
            var stateEvent: String?
            var message: String?
            /// Unix seconds of the last state change (A2 shows it).
            var timestamp: Double?
            var info: Info?

            enum CodingKeys: String, CodingKey { case stateEvent = "state_event", message, timestamp, info }

            struct Info: Decodable, Sendable {
                /// Business or creator account, from our bridge patch (M8); absent on bridge v26.09.
                var isProfessionalAccount: Bool?

                enum CodingKeys: String, CodingKey { case isProfessionalAccount = "is_professional_account" }
            }
        }

        /// Professional accounts have Instagram's Primary/General tabs, so the inbox shows the General tile for them.
        var isProfessional: Bool { state?.info?.isProfessionalAccount == true }

        /// whoami `state_event` → what the UI shows (PLAN §2.10, DESIGN §7.1).
        enum Health: Equatable, Sendable {
            case connected
            /// CONNECTING, no state yet, or a TRANSIENT_DISCONNECT under 2 minutes (most last under a second, S7.10).
            case connecting
            /// BACKFILLING
            case syncing
            /// A TRANSIENT_DISCONNECT that has lasted over 2 minutes: still automatic, now worth a banner.
            case reconnecting
            case needsLogin
            /// UNKNOWN_ERROR or a state this app doesn't know; the bridge's message, if any.
            case error(String?)

            /// The user has to act: orange glyph, inline "Log in" on the account row.
            var needsUser: Bool {
                switch self {
                case .needsLogin, .error: true
                default: false
                }
            }

            /// Worth an inbox banner (PLAN §2.10).
            var raisesBanner: Bool { needsUser || self == .reconnecting }

            var isBusy: Bool { self == .connecting || self == .syncing || self == .reconnecting }

            var label: String {
                switch self {
                case .connected: "Connected"
                case .connecting: "Connecting…"
                case .syncing: "Syncing history…"
                case .reconnecting: "Reconnecting…"
                case .needsLogin: "Signed out"
                case .error: "Can't connect"
                }
            }
        }

        var health: Health { health(at: .now) }

        func health(at now: Date) -> Health {
            switch state?.stateEvent {
            case "CONNECTED": return .connected
            case "CONNECTING", nil: return .connecting
            case "TRANSIENT_DISCONNECT":
                guard let transientSince, now.timeIntervalSince(transientSince) > 120 else { return .connecting }
                return .reconnecting
            case "BACKFILLING": return .syncing
            case "BAD_CREDENTIALS", "LOGGED_OUT": return .needsLogin
            default: return .error(state?.message)
            }
        }

        /// The name Instagram shows for this account; identity defaults start from it.
        var displayName: String { profile?.name ?? name ?? profile?.username ?? id }
    }

    /// One Instagram user from `search_users` or `create_dm` (mautrix-go `RespResolveIdentifier`; live sample in
    /// `Fixtures/provisioning_search_users.json`). Only `id` is always there.
    nonisolated struct Contact: Decodable, Identifiable, Hashable, Sendable {
        /// The user's ID on the bridge; a DM's `m.bridge` channel ID is the other person's ID.
        var id: String
        var name: String?
        var avatarURL: String?
        /// `["instagram:<handle>"]`.
        var identifiers: [String]?
        var mxid: String?
        /// The DM's room once the bridge has one. Search leaves it out even for an existing DM (M7b live sample), so
        /// the app looks for its own room first (`Inbox.existingDM`).
        var dmRoomID: String?

        enum CodingKeys: String, CodingKey { case id, name, avatarURL = "avatar_url", identifiers, mxid, dmRoomID = "dm_room_mxid" }

        var handle: String? { Self.handle(in: identifiers) }

        /// The Instagram username in a bridge identifier list (search results, ghost profiles).
        static func handle(in identifiers: [String]?) -> String? {
            identifiers?.lazy.compactMap { $0.hasPrefix("instagram:") ? String($0.dropFirst("instagram:".count)) : nil }
                .first { !$0.isEmpty }
        }
    }
}
