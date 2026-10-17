import XCTest
@testable import Ferry

/// N1 and the contact handle (M7b): the bridge's search shape, matching a result to a DM we already have, and the
/// handle from a ghost profile (`ghost_extra_profile_info`). Fixtures are live responses from M7b.
final class NewMessageTests: XCTestCase {
    /// Live `search_users` from tamoveska for "kivostudio": `results`, the handle in `identifiers`, and no
    /// `dm_room_mxid` although the DM exists (so the app must match its own rooms).
    func testSearchResultsDecode() throws {
        struct Results: Decodable { var results: [BridgeAPI.Contact] }
        let results = try JSONDecoder().decode(Results.self, from: Fixture.data("provisioning_search_users")).results
        XCTAssertEqual(results.count, 1)
        let kivo = try XCTUnwrap(results.first)
        XCTAssertEqual(kivo.id, Fixture.kivoLogin)
        XCTAssertEqual(kivo.name, "Kivo Studio")
        XCTAssertEqual(kivo.handle, "kivostudio")
        XCTAssertEqual(kivo.mxid, Fixture.kivoGhost)
        XCTAssertTrue(kivo.avatarURL?.hasPrefix("mxc://") == true)
        XCTAssertNil(kivo.dmRoomID)
    }

    /// `create_dm` answers with the same shape plus the room (mautrix-go `RespResolveIdentifier`; not called live, so
    /// this is the documented shape).
    func testCreateDMResponseDecodes() throws {
        let json = #"{"id":"17841400000000009","name":"Someone","mxid":"@instagram_17841400000000009:igm.home.arpa","dm_room_mxid":"!new"}"#
        let contact = try JSONDecoder().decode(BridgeAPI.Contact.self, from: Data(json.utf8))
        XCTAssertEqual(contact.dmRoomID, "!new")
        XCTAssertNil(contact.handle)
    }

    func testHandleComesOnlyFromInstagramIdentifiers() {
        XCTAssertEqual(BridgeAPI.Contact.handle(in: ["instagram:kivostudio"]), "kivostudio")
        XCTAssertEqual(BridgeAPI.Contact.handle(in: ["tel:+1555", "instagram:a.b_c"]), "a.b_c")
        XCTAssertNil(BridgeAPI.Contact.handle(in: ["tel:+1555"]))
        XCTAssertNil(BridgeAPI.Contact.handle(in: ["instagram:"]))
        XCTAssertNil(BridgeAPI.Contact.handle(in: nil))
    }

    /// A result opens the DM we already have on *that* account (channel ID = the other person's ID), never the same
    /// person's DM on another account.
    func testExistingDMIsFoundPerAccount() throws {
        let rooms = try InboxTests.realRooms()
        XCTAssertEqual(Inbox.existingDM(with: Fixture.kivoLogin, account: Fixture.tamoLogin, in: rooms)?.id, Fixture.tamoRoom)
        XCTAssertEqual(Inbox.existingDM(with: Fixture.tamoLogin, account: Fixture.kivoLogin, in: rooms)?.id, Fixture.kivoRoom)
        XCTAssertNil(Inbox.existingDM(with: Fixture.kivoLogin, account: Fixture.kivoLogin, in: rooms))
        XCTAssertNil(Inbox.existingDM(with: "17841400000000009", account: Fixture.tamoLogin, in: rooms))
    }

    /// A group with that person isn't "the DM".
    func testGroupIsNotAnExistingDM() throws {
        let group = try InboxTests.portal("!g", receiver: Fixture.tamoLogin, group: true)
        let channel = try XCTUnwrap(group.bridge?.channelID)
        XCTAssertNil(Inbox.existingDM(with: channel, account: Fixture.tamoLogin, in: [group]))
    }

    /// The contact is the joined member who is neither us nor the bridge bot (real DM state).
    func testContactUserIDIsTheGhost() throws {
        let rooms = try InboxTests.realRooms()
        let tamo = try XCTUnwrap(rooms.first { $0.id == Fixture.tamoRoom })
        XCTAssertEqual(Inbox.contactUserID(tamo, me: Fixture.me), Fixture.kivoGhost)
        let space = try XCTUnwrap(rooms.first { $0.id == Fixture.tamoSpace })
        XCTAssertNil(Inbox.contactUserID(space, me: Fixture.me))
    }

    /// Live ghost profile after the bridge updated the contact with `ghost_extra_profile_info: true`; a profile
    /// without the extra fields (every ghost before its next update) has no handle.
    func testProfileHandle() throws {
        let profile = try JSONDecoder().decode(JSON.self, from: Fixture.data("profile_ghost_extra"))
        XCTAssertEqual(Inbox.profileHandle(profile), "kivostudio")
        XCTAssertNil(Inbox.profileHandle(["displayname": "Kivo Studio", "avatar_url": "mxc://igm.home.arpa/x"]))
    }
}
