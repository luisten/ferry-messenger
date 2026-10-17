import XCTest
@testable import Ferry

/// Decoding of real payloads captured in M2 (docs/spikes/2026-10-12-live-bridge.md, S2).
final class SyncDecodingTests: XCTestCase {
    func testInitialSyncDecodes() throws {
        let sync = try Fixture.sync()
        XCTAssertFalse(sync.nextBatch.isEmpty)
        let join = try XCTUnwrap(sync.rooms?.join)
        XCTAssertEqual(join.count, 4)  // 2 DM portals (one IG thread, one room per account) + 2 personal spaces
        XCTAssertNil(sync.rooms?.invite)  // S7: double puppeting joins directly, no invites

        let dm = try XCTUnwrap(join[Fixture.tamoRoom])
        XCTAssertEqual(dm.state?.events?.count, 6)
        XCTAssertEqual(dm.timeline?.events?.count, 20)
        XCTAssertEqual(dm.timeline?.limited, true)
        XCTAssertNotNil(dm.timeline?.prevBatch)
        XCTAssertEqual(dm.unreadNotifications?.notificationCount, 0)
        XCTAssertEqual(dm.ephemeral?.events?.first?.type, "m.receipt")
        XCTAssertEqual(dm.accountData?.events?.count, 0)

        let kivo = try XCTUnwrap(join[Fixture.kivoRoom])
        XCTAssertEqual(kivo.timeline?.limited, false)
        XCTAssertNil(kivo.state?.events?.first)  // all of this room's state arrived inside the timeline
    }

    func testStateAndMessageEventsDecode() throws {
        let events = try XCTUnwrap(Fixture.sync().rooms?.join?[Fixture.tamoRoom]?.timeline?.events)
        let bridge = try XCTUnwrap(events.last { $0.type == "m.bridge" })
        XCTAssertEqual(bridge.stateKey, "igm.home.arpa/instagram")
        XCTAssertEqual(bridge.content["protocol"]?["id"]?.string, "instagramgo")

        let hello = try XCTUnwrap(events.first { $0.content["body"]?.string == "hello" })
        XCTAssertEqual(hello.sender, "@me:igm.home.arpa")
        XCTAssertEqual(hello.originServerTS, 1_781_264_377_286)
        XCTAssertNil(hello.stateKey)  // message events have no state key; "" would mean state
        XCTAssertEqual(hello.content["msgtype"]?.string, "m.text")
    }

    func testReceiptContentDecodes() throws {
        let receipt = try XCTUnwrap(Fixture.sync().rooms?.join?[Fixture.tamoRoom]?.ephemeral?.events?.first)
        let reads = try XCTUnwrap(receipt.content["$mGkNbgrbORGhHJdU6tATIr2ywcDOXl0Rs32LA4iAipw"]?["m.read"]?.object)
        XCTAssertEqual(Set(reads.keys), ["@me:igm.home.arpa", "@instagram_17841400000000302:igm.home.arpa"])
        XCTAssertEqual(reads["@me:igm.home.arpa"]?["ts"]?.int64, 1_791_816_586_881)
    }

    func testEditEventExposesTarget() throws {
        let edit = try Fixture.event("event_reel_resolve_edit")
        let original = try Fixture.event("event_reel_unresolved")
        XCTAssertEqual(edit.replacesEventID, original.eventID)
        XCTAssertEqual(edit.content["m.new_content"]?["msgtype"]?.string, "m.video")
        XCTAssertNil(original.replacesEventID)
    }

    func testRedactionTargetFromContentOrTopLevel() throws {
        let v11 = Event(type: "m.room.redaction", content: .object(["redacts": .string("$a")]))
        let v10 = Event(type: "m.room.redaction", content: .object([:]), redacts: "$b")
        XCTAssertEqual(v11.redactionTarget, "$a")
        XCTAssertEqual(v10.redactionTarget, "$b")
        XCTAssertNil(Event(type: "m.room.message", content: .object(["redacts": .string("$c")])).redactionTarget)
    }

    /// M5 passes `com.beeper.unresolved_media` back verbatim, so JSON must survive a round trip unchanged.
    func testJSONRoundTripsBridgePayload() throws {
        let content = try Fixture.event("event_reel_unresolved").content
        let media = try XCTUnwrap(content["com.beeper.unresolved_media"])
        let again = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(media))
        XCTAssertEqual(again, media)
        XCTAssertEqual(media["fi.mau.instagram.base_part"]?["info"]?["size"]?.int64, 265_845)
    }

    func testEventWithoutContentStillDecodes() throws {
        let event = try JSONDecoder().decode(Event.self, from: Data(#"{"type":"m.typing"}"#.utf8))
        XCTAssertEqual(event.content, .object([:]))
    }
}
