import UserNotifications
import XCTest
@testable import Ferry

/// Catch-up notifications (docs/PLAN-push.md): what the engine read from step 1's captures (`engine_push.json`, written
/// by `go test ./push -update` from core/testdata/push_*_kivo.json), as `IGPushDrain` answers it, and what each shows.
final class PushNoticeTests: XCTestCase {
    private func drained() throws -> (state: String, pushes: [IG.Push]) {
        try IGCore.drained(Fixture.data("engine_push"))
    }

    func testTheDrainsAnswerKeepsTheStateAndReadsThePushes() throws {
        let (state, pushes) = try drained()
        XCTAssertEqual(state, #"{"uaid":"sample"}"#)
        XCTAssertEqual(pushes.map(\.text), ["Push test 2", "Sent a photo", "Sent a video", "Sent a voice message"])
        XCTAssertEqual(pushes.map(\.notify), [false, true, true, true], "only what came after the app was last open")
        let empty = try IGCore.drained(Data(#"{"state":{"uaid":"x"},"pushes":null}"#.utf8))
        XCTAssertTrue(empty.pushes.isEmpty)
    }

    func testANoticeNamesTheSenderAndTheAccountOnlyWhenThereAreTwo() throws {
        let photo = try drained().pushes[1]
        let one = PushNotice(photo, accountName: nil)
        XCTAssertEqual(one, PushNotice(title: "@kivostudio", subtitle: "", body: "Sent a photo",
                                       thread: "17841400000000301/340282366841710300000000000000000000301"))
        XCTAssertEqual(PushNotice(photo, accountName: "Tamo").subtitle, "Tamo")
    }

    /// No group on the dummies: Instagram's group name (`aud_gn`) titles it and the sender leads the text.
    func testAGroupsNoticeIsTitledByTheGroup() throws {
        var push = try drained().pushes[0]
        push.group = "Saturday Climbs"
        let notice = PushNotice(push, accountName: nil)
        XCTAssertEqual(notice.title, "Saturday Climbs")
        XCTAssertEqual(notice.body, "@kivostudio: Push test 2")
    }

    func testOneNotificationPerMessageCarryingItsPushForTheTap() throws {
        let voice = try drained().pushes[3]
        let request = PushNotice(voice, accountName: nil).request(for: voice)
        XCTAssertEqual(request.identifier, "mid.$push-voice-0001")
        let carried = try XCTUnwrap(request.content.userInfo["push"] as? String)
        XCTAssertEqual(try JSONDecoder().decode(IG.Push.self, from: Data(carried.utf8)), voice)
        XCTAssertEqual(request.content.threadIdentifier, PushNotice(voice, accountName: nil).thread)
    }
}
