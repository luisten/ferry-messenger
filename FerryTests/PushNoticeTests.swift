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
        XCTAssertThrowsError(try IGCore.drained(Data(#"{"pushes":[]}"#.utf8)), "no state must never replace the stored one")
    }

    func testANoticeNamesTheSenderAndTheAccountOnlyWhenThereAreTwo() throws {
        let photo = try drained().pushes[1]
        let one = PushNotice(photo, accountName: nil, now: photo.time)
        XCTAssertEqual(one, PushNotice(title: "@kivostudio", subtitle: "", body: "Sent a photo",
                                       thread: "17841400000000301/340282366841710300000000000000000000301"))
        XCTAssertEqual(PushNotice(photo, accountName: "Tamo", now: photo.time).subtitle, "To Tamo")  // DESIGN §3.3
    }

    /// iOS stamps a notification with the wake, which may be hours late: past 10 minutes, the subtitle says when it
    /// was sent.
    func testALateNoticeSaysWhenItWasSent() throws {
        let text = try drained().pushes[0]
        XCTAssertEqual(PushNotice(text, accountName: nil, now: text.time + 600_000).subtitle, "")
        let late = PushNotice(text, accountName: "Tamo", now: text.time + 3 * 3_600_000).subtitle
        XCTAssertTrue(late.hasPrefix("To Tamo · Sent "), late)
        let alone = PushNotice(text, accountName: nil, now: text.time + 3 * 3_600_000).subtitle
        XCTAssertTrue(alone.hasPrefix("Sent ") && !alone.contains("·"), alone)
    }

    /// A handle gets its "@"; a name (Instagram's fallback) doesn't, and no sender at all isn't dressed up as Instagram.
    func testTheSenderLine() throws {
        var push = try drained().pushes[0]
        push.sender = "Sam Lee"
        XCTAssertEqual(PushNotice(push, accountName: nil, now: push.time).title, "Sam Lee")
        push.sender = ""
        XCTAssertEqual(PushNotice(push, accountName: nil, now: push.time).title, "New message")
        push.group = "Saturday Climbs"
        XCTAssertEqual(PushNotice(push, accountName: nil, now: push.time).body, "Push test 2")
    }

    /// No group on the dummies: Instagram's group name (`aud_gn`) titles it and the sender leads the text.
    func testAGroupsNoticeIsTitledByTheGroup() throws {
        var push = try drained().pushes[0]
        push.group = "Saturday Climbs"
        let notice = PushNotice(push, accountName: nil, now: push.time)
        XCTAssertEqual(notice.title, "Saturday Climbs")
        XCTAssertEqual(notice.body, "@kivostudio: Push test 2")
    }

    func testOneNotificationPerMessageCarryingItsPushForTheTap() throws {
        let voice = try drained().pushes[3]
        let notice = PushNotice(voice, accountName: nil, now: voice.time)
        let request = notice.request(for: voice)
        XCTAssertEqual(request.identifier, "mid.$push-voice-0001")
        let carried = try XCTUnwrap(request.content.userInfo["push"] as? String)
        XCTAssertEqual(try JSONDecoder().decode(IG.Push.self, from: Data(carried.utf8)), voice)
        XCTAssertEqual(request.content.threadIdentifier, notice.thread)
        XCTAssertNotNil(request.content.sound)
        XCTAssertNil(notice.request(for: voice, sound: false).content.sound, "one sound per wake, on its first")
    }
}
