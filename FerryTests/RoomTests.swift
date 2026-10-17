import XCTest
@testable import Ferry

final class RoomTests: XCTestCase {
    // MARK: BridgeInfo

    func testBridgeInfoFromRealDM() throws {
        let info = try XCTUnwrap(BridgeInfo(content: Fixture.event("state_bridge_dm").content))
        XCTAssertEqual(info.receiver, Fixture.kivoLogin)
        XCTAssertEqual(info.channelID, Fixture.tamoLogin)
        XCTAssertEqual(info.roomType, .dm)
        XCTAssertTrue(info.isDM)
        XCTAssertFalse(info.isRequest)  // S6: the key is absent, not false
        XCTAssertEqual(info.displayName, "Tamo Veska")
        XCTAssertEqual(info.avatarURL, "mxc://igm.home.arpa/onvkSvgXgcbowUuvGnImEyPS")
    }

    func testBridgeInfoFromRealPersonalSpace() throws {
        let info = try XCTUnwrap(BridgeInfo(content: Fixture.event("state_bridge_space").content))
        XCTAssertEqual(info.roomType, .personalSpace)
        XCTAssertEqual(info.receiver, Fixture.tamoLogin)
        XCTAssertFalse(info.isDM)
    }

    /// Hand-made from the real DM shape: no request room exists on these accounts (S6, D11).
    func testRequestFlag() throws {
        let dm = try Fixture.event("state_bridge_dm").content
        XCTAssertTrue(try XCTUnwrap(BridgeInfo(content: dm.setting(["channel", "com.beeper.message_request"], .bool(true)))).isRequest)
        XCTAssertFalse(try XCTUnwrap(BridgeInfo(content: dm.setting(["channel", "com.beeper.message_request"], .bool(false)))).isRequest)
    }

    /// Hand-made from the real DM shape: no group exists on these accounts. S7.6: IG groups have room type "",
    /// so both room_type keys are absent, which must read as a group, not as an error.
    func testMissingRoomTypeIsGroup() throws {
        let group = try Fixture.event("state_bridge_dm").content
            .setting(["com.beeper.room_type"], nil).setting(["com.beeper.room_type.v2"], nil)
        let info = try XCTUnwrap(BridgeInfo(content: group))
        XCTAssertEqual(info.roomType, .group)
        XCTAssertFalse(info.isDM)
    }

    /// S7: the bridge reports its Beeper type "instagramgo"; anything else is not ours.
    func testOtherProtocolIsNotInstagram() throws {
        let dm = try Fixture.event("state_bridge_dm").content
        XCTAssertNil(BridgeInfo(content: dm.setting(["protocol", "id"], .string("instagram"))))
        XCTAssertNil(BridgeInfo(content: dm.setting(["protocol"], nil)))
    }

    // MARK: Applying sync

    func testApplyRealRoomMergesStateFromStateAndTimeline() throws {
        let room = try Self.room(Fixture.tamoRoom)
        XCTAssertNotNil(room.stateEvent("m.room.create"))  // from `state`
        XCTAssertEqual(room.bridge?.receiver, Fixture.tamoLogin)  // from the timeline
        // The bridge renamed the room Kivo Studio → Unknown user → Kivo Studio inside this batch; last one wins.
        XCTAssertEqual(room.name, "Kivo Studio")
        XCTAssertEqual(room.avatarURL, "mxc://igm.home.arpa/AKRxSivqzKQzNAwknfzLHZsH")
        XCTAssertEqual(room.events.count, 20)
        XCTAssertEqual(room.prevBatch, "s18_1_0_8_16_1_1_11_0_1_2_1_1_1")
        XCTAssertEqual(room.notificationCount, 0)
        XCTAssertFalse(room.isUnread)
        XCTAssertEqual(room.memberName("@instagram_17841400000000302:igm.home.arpa"), "Kivo Studio")
    }

    /// M8 Hand-off C (2026-10-14): the real m.bridge the patched bridge sent after kivostudio moved the thread
    /// General -> Primary carries the folder key; flipping it to GENERAL must put the room in General.
    func testRealBridgeAfterMoveCarriesFolder() throws {
        let content = try Fixture.event("state_bridge_dm_after_move").content
        XCTAssertEqual(BridgeInfo(content: content)?.folder, .primary)
        XCTAssertEqual(BridgeInfo(content: content.setting(["channel", BridgeInfo.inboxFolderKey], .string("GENERAL")))?.folder, .general)
    }

    /// Regression (2026-10-14): after an inbox reload the bridge set the DM's implicit name to "Unknown user", then fixed
    /// the contact's member event but never the name. Implicit DM names follow the member; explicit names win.
    func testImplicitDMNameFollowsContactMemberEvent() throws {
        let room = try Self.room(Fixture.tamoRoom)
        let stale: [String: JSON] = ["name": .string("Unknown user"), "fi.mau.implicit_name": .bool(true)]
        room.apply(JoinedRoom(state: EventList(events: [Event.state("m.room.name", stale)])))
        XCTAssertEqual(room.name, "Unknown user")  // without our user ID we can't pick the contact
        room.ownUserID = Fixture.me
        XCTAssertEqual(room.name, "Kivo Studio")
        room.apply(JoinedRoom(state: EventList(events: [Event.state("m.room.name", ["name": .string("Weekend crew")])])))
        XCTAssertEqual(room.name, "Weekend crew")  // a real (explicit) name is kept
    }

    func testRoomWithAllStateInTimeline() throws {
        let room = try Self.room(Fixture.kivoRoom)
        XCTAssertEqual(room.bridge?.receiver, Fixture.kivoLogin)
        XCTAssertEqual(room.name, "Tamo Veska")
    }

    func testNameAndAvatarFallBackToBridgeChannel() throws {
        let room = Room(id: "!r")
        room.apply(JoinedRoom(state: EventList(events: [try Fixture.event("state_bridge_dm")])))
        XCTAssertEqual(room.name, "Tamo Veska")
        XCTAssertEqual(room.avatarURL, "mxc://igm.home.arpa/onvkSvgXgcbowUuvGnImEyPS")

        let bare = Room(id: "!bare")
        XCTAssertEqual(bare.name, "Instagram chat")
        XCTAssertNil(bare.avatarURL)
    }

    func testEmptyRoomNameIsIgnored() throws {
        let room = Room(id: "!r")
        room.apply(JoinedRoom(state: EventList(events: [
            try Fixture.event("state_bridge_dm"),
            Event.state("m.room.name", ["name": .string("")]),
        ])))
        XCTAssertEqual(room.name, "Tamo Veska")
    }

    func testNonLimitedBatchAppendsAndKeepsPrevBatch() throws {
        let room = try Self.room(Fixture.tamoRoom)
        room.apply(JoinedRoom(timeline: .init(events: [Event.message("$new", ts: 1_800_000_000_000)], limited: false, prevBatch: "later")))
        XCTAssertEqual(room.events.count, 21)
        XCTAssertEqual(room.events.last?.eventID, "$new")
        XCTAssertEqual(room.prevBatch, "s18_1_0_8_16_1_1_11_0_1_2_1_1_1")
    }

    /// PLAN §2.4: no gap tracking. A limited batch replaces the window and its prev_batch becomes ours.
    func testLimitedBatchResetsWindow() throws {
        let room = try Self.room(Fixture.tamoRoom)
        room.apply(JoinedRoom(timeline: .init(events: [Event.message("$new", ts: 1_800_000_000_000)], limited: true, prevBatch: "gap")))
        XCTAssertEqual(room.events.map(\.eventID), ["$new"])
        XCTAssertEqual(room.prevBatch, "gap")
        XCTAssertEqual(room.name, "Kivo Studio")  // state survives a reset
    }

    func testUnreadCounts() throws {
        let room = try Self.room(Fixture.kivoRoom)
        room.apply(JoinedRoom(unreadNotifications: .init(notificationCount: 2, highlightCount: 0)))
        XCTAssertEqual(room.notificationCount, 2)
        XCTAssertTrue(room.isUnread)
        room.apply(JoinedRoom(timeline: .init(events: [], limited: false)))  // counts absent: unchanged
        XCTAssertTrue(room.isUnread)
        room.apply(JoinedRoom(unreadNotifications: .init(notificationCount: 0, highlightCount: 0)))
        XCTAssertFalse(room.isUnread)
    }

    func testTypingIsReplacedNotMerged() {
        let room = Room(id: "!r")
        room.apply(JoinedRoom(ephemeral: EventList(events: [Event(type: "m.typing", content: ["user_ids": ["@a", "@b"]])])))
        XCTAssertEqual(room.typing, ["@a", "@b"])
        room.apply(JoinedRoom(ephemeral: EventList(events: [Event(type: "m.typing", content: ["user_ids": []])])))
        XCTAssertEqual(room.typing, [])
    }

    func testReceiptsFromRealFixtureThenNewerOneWins() throws {
        let room = try Self.room(Fixture.tamoRoom)
        let reel = "$mGkNbgrbORGhHJdU6tATIr2ywcDOXl0Rs32LA4iAipw"
        XCTAssertEqual(room.receipts[Fixture.me]?.eventID, reel)
        XCTAssertEqual(room.receipts["@instagram_17841400000000302:igm.home.arpa"]?.eventID, reel)

        let newer: JSON = ["$x": ["m.read": [Fixture.me: ["ts": 1_900_000_000_000]]]]
        let older: JSON = ["$old": ["m.read": [Fixture.me: ["ts": 1]]]]
        room.apply(JoinedRoom(ephemeral: EventList(events: [Event(type: "m.receipt", content: newer), Event(type: "m.receipt", content: older)])))
        XCTAssertEqual(room.receipts[Fixture.me]?.eventID, "$x")
    }

    func testTagsFromRoomAccountData() {
        let room = Room(id: "!r")
        room.apply(JoinedRoom(accountData: EventList(events: [Event(type: "m.tag", content: ["tags": ["u.archived": [:]]])])))
        XCTAssertNotNil(room.tags["u.archived"])
        room.apply(JoinedRoom(accountData: EventList(events: [Event(type: "m.tag", content: ["tags": [:]])])))
        XCTAssertTrue(room.tags.isEmpty)
    }

    // MARK: Last activity

    /// Real data: backfilled messages keep their IG timestamps (June), while the bridge's later state events
    /// (renames, joins) are stamped October. Sorting by the newest event would float every freshly bridged room.
    func testLastActivityIsLastMessageNotLastStateEvent() throws {
        let room = try Self.room(Fixture.tamoRoom)
        XCTAssertEqual(room.lastMessage?.content["msgtype"]?.string, "m.image")
        XCTAssertEqual(room.lastActivity, 1_781_313_332_465)
        XCTAssertGreaterThan(room.events.last?.originServerTS ?? 0, room.lastActivity)
    }

    /// The real resolve_media edit is stamped when it was resolved; an edit must not bump the chat.
    func testEditDoesNotBumpButChangesCurrentContent() throws {
        let room = try Self.room(Fixture.tamoRoom)
        let edit = try Fixture.event("event_reel_resolve_edit")
        room.apply(JoinedRoom(timeline: .init(events: [edit], limited: false)))
        XCTAssertEqual(room.lastActivity, 1_781_313_332_465)
        let last = try XCTUnwrap(room.lastMessage)
        XCTAssertEqual(room.currentContent(of: last)["msgtype"]?.string, "m.video")
    }

    func testRedactedMessageIsSkipped() throws {
        let room = Room(id: "!r")
        room.apply(JoinedRoom(timeline: .init(events: [
            Event.message("$a", ts: 10), Event.message("$b", ts: 20),
            Event(type: "m.room.redaction", content: ["redacts": "$b"], eventID: "$r", sender: "@x", originServerTS: 30),
        ], limited: false)))
        XCTAssertEqual(room.lastMessage?.eventID, "$a")
        XCTAssertEqual(room.lastActivity, 10)
    }

    func testRoomWithoutMessagesFallsBackToLatestEvent() throws {
        let room = try Self.room(Fixture.tamoSpace)
        XCTAssertNil(room.lastMessage)
        XCTAssertEqual(room.lastActivity, 1_791_816_585_510)
    }

    // MARK: Helpers

    static func room(_ id: String) throws -> Room {
        let room = Room(id: id)
        room.apply(try XCTUnwrap(Fixture.sync().rooms?.join?[id]))
        return room
    }
}

extension JSON {
    /// A copy with the value at `path` replaced (nil removes it). For deriving hand-made cases from real fixtures.
    func setting(_ path: [String], _ value: JSON?) -> JSON {
        guard let key = path.first, case .object(var object) = self else { return self }
        object[key] = path.count == 1 ? value : (object[key] ?? .object([:])).setting(Array(path.dropFirst()), value)
        return .object(object)
    }
}

extension Event {
    static func message(_ id: String, ts: Int64, sender: String = "@instagram_1:igm.home.arpa", body: String = "hi",
                        msgtype: String = "m.text", extra: [String: JSON] = [:]) -> Event {
        var content: [String: JSON] = ["msgtype": .string(msgtype), "body": .string(body)]
        content.merge(extra) { _, new in new }
        return Event(type: "m.room.message", content: .object(content), eventID: id, sender: sender, originServerTS: ts)
    }

    static func state(_ type: String, _ content: [String: JSON], key: String = "", ts: Int64 = 1) -> Event {
        Event(type: type, content: .object(content), eventID: "$\(type)\(key)", sender: "@instagrambot:igm.home.arpa",
              stateKey: key, originServerTS: ts)
    }
}
