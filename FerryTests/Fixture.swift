import XCTest
@testable import Ferry

/// Scrubbed real payloads in `Fixtures/` (M2 spike S2, M4/M5 live checks) and the IDs they contain.
enum Fixture {
    /// The shared tamoveska↔kivostudio IG thread: tamoveska's room and kivostudio's room (S7.3).
    static let tamoRoom = "!ehE0v9MxOfM_NXqxrNmHqfZ048PGl7MYoaGvwMU_5XA"
    static let kivoRoom = "!o6PqSlIHi7dXejqWKC9ZeSMhEMiPbIxW90UtmMjw8PU"
    static let tamoSpace = "!8B3W21v2O_DdWOmLU2US75eotLLpkE2-BhMsjpPbvZ0"
    static let kivoSpace = "!w2RKZ-QLiwkbgCeUhoEJr3kpDQCPGEIJI0U61VeWL1Q"
    static let tamoLogin = "17841400000000301"
    static let kivoLogin = "17841400000000302"
    static let me = "@me:igm.home.arpa"
    /// The ghosts: each account as seen from the other account's room.
    static let tamoGhost = "@instagram_17841400000000301:igm.home.arpa"
    static let kivoGhost = "@instagram_17841400000000302:igm.home.arpa"

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func url(_ name: String, ext: String = "json") throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"), "missing fixture \(name).\(ext)")
    }

    static func sync() throws -> SyncResponse {
        try JSONDecoder().decode(SyncResponse.self, from: data("sync_initial"))
    }

    static func event(_ name: String) throws -> Event {
        try JSONDecoder().decode(Event.self, from: data(name))
    }

    /// A fixture holding a JSON array of events, in timeline order.
    static func events(_ name: String) throws -> [Event] {
        try JSONDecoder().decode([Event].self, from: data(name))
    }

    static func messages(_ name: String) throws -> MessagesPage {
        try JSONDecoder().decode(MessagesPage.self, from: data(name))
    }

    /// Ferry's bridge provisioning answer, whose account shape the app keeps (`IGAdapter.login`):
    /// `provisioning_whoami` is bridge v26.09 (M2), `provisioning_whoami_m8` the patched bridge (M8).
    struct Whoami: Decodable {
        var logins: [BridgeAPI.Login]?
    }

    static func whoami(_ name: String = "provisioning_whoami") throws -> Whoami {
        try JSONDecoder().decode(Whoami.self, from: data(name))
    }

    /// A fixture holding a JSON array of arbitrary objects (e.g. the bridge's raw Instagram deltas).
    static func jsonArray(_ name: String) throws -> [JSON] {
        try JSONDecoder().decode([JSON].self, from: data(name))
    }

    /// A fixture holding one JSON object.
    static func jsonObject(_ name: String) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data(name))
    }

    /// What the engine makes of P0's Instagram captures (`engine_<name>.json`, written by core/chat's tests).
    static func engine<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data("engine_\(name)"))
    }

    private final class BundleToken {}
}
