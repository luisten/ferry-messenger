import SwiftUI
import XCTest
@testable import Ferry

/// #17: the thread's distance from its newest message, from scroll geometry logged on iOS 26.4 (iPhone 17, Kivo Studio
/// chat): a 116 pt navigation bar and a 92 pt composer as insets, `containerSize` the 666 pt between them.
final class ThreadScrollTests: XCTestCase {
    private let bars = EdgeInsets(top: 116, leading: 0, bottom: 92, trailing: 0)

    private func geometry(offset: CGFloat, content: CGFloat, container: CGFloat, insets: EdgeInsets) -> ScrollGeometry {
        ScrollGeometry(contentOffset: CGPoint(x: 0, y: offset), contentSize: CGSize(width: 378, height: content),
                       contentInsets: insets, containerSize: CGSize(width: 402, height: container))
    }

    /// Settled on the newest message: the end, give or take the list's 8 pt bottom padding. The M4 formula
    /// (`containerSize` as the whole frame) read 208 here, so its "within 60 pt of the end" re-pin never ran.
    func testAtTheEndWithBarsAndComposer() {
        let end = geometry(offset: 2763, content: 3545, container: 666, insets: bars)
        XCTAssertEqual(ThreadView.ScrollEdge(end).distanceFromEnd, 0)
        XCTAssertEqual(ThreadView.ScrollEdge(geometry(offset: 2754, content: 3545, container: 666, insets: bars)).distanceFromEnd, 9)
    }

    /// The jump on the first push after launch: back at the top (offset = −top inset) of a 3130 pt thread.
    func testJumpedToTheTop() {
        XCTAssertEqual(ThreadView.ScrollEdge(geometry(offset: -116, content: 3130, container: 666, insets: bars)).distanceFromEnd, 2464)
    }

    /// Mid-push, before the bars exist: the frame is the container.
    func testWithoutInsets() {
        XCTAssertEqual(ThreadView.ScrollEdge(geometry(offset: 1948, content: 2764, container: 816, insets: EdgeInsets())).distanceFromEnd, 0)
    }

    /// A thread shorter than the screen is always at its end.
    func testShortThreadIsAtTheEnd() {
        XCTAssertLessThan(ThreadView.ScrollEdge(geometry(offset: -116, content: 300, container: 666, insets: bars)).distanceFromEnd, 0)
    }
}

/// The thread appears only once it rests at its end under the bars (`ThreadView.revealWhenSettled`). Geometry logged
/// on the first open after a cold launch (iOS 26.4, iPhone 17, Kivo Studio chat, 2026-10-15): the push lays it out at
/// its end without insets, the insets arrive and it jumps to the top, the re-pin lands, then an older page lands
/// above the end and the re-pin follows it.
final class ThreadRevealTests: XCTestCase {
    private let bars = EdgeInsets(top: 116, leading: 0, bottom: 92, trailing: 0)

    private func edge(offset: CGFloat, content: CGFloat, container: CGFloat, insets: EdgeInsets) -> ThreadView.ScrollEdge {
        ThreadView.ScrollEdge(ScrollGeometry(contentOffset: CGPoint(x: 0, y: offset), contentSize: CGSize(width: 378, height: content),
                                             contentInsets: insets, containerSize: CGSize(width: 402, height: container)))
    }

    func testMidPushAtTheEndWithoutInsetsIsNotYet() {
        XCTAssertFalse(edge(offset: 1306, content: 2122, container: 816, insets: EdgeInsets()).restsAtEnd)
    }

    func testJumpedToTheTopIsNot() {
        XCTAssertFalse(edge(offset: -116, content: 2236, container: 666, insets: bars).restsAtEnd)
    }

    func testRepinnedRestsAtTheEnd() {
        XCTAssertTrue(edge(offset: 1078, content: 1869, container: 666, insets: bars).restsAtEnd)  // 9 pt: the padding
        XCTAssertTrue(edge(offset: 3547.33, content: 4338, container: 666, insets: bars).restsAtEnd)  // after the page
    }

    func testOlderPageJustLandedIsNot() {
        XCTAssertFalse(edge(offset: 1078, content: 4344, container: 666, insets: bars).restsAtEnd)
    }

    func testShortThreadRestsAtTheEnd() {
        XCTAssertTrue(edge(offset: -116, content: 300, container: 666, insets: bars).restsAtEnd)
    }

    /// A chat that opens unread holds its "New messages" line at the top only when what's new overflows by more than a
    /// quarter of the screen; otherwise it opens at the end, the newest message whole (2026-10-20: the user saw it cut
    /// off by the composer). Geometry logged with the line held (`FERRY_DEBUG_GROUP_EXTRA=7`: 207 pt below).
    func testHeldLineGivesWayWhenLittleIsBelow() {
        XCTAssertFalse(edge(offset: 564.67, content: 1554, container: 666, insets: bars).endIsNear(above: 0))  // 207 pt: holds
        XCTAssertTrue(edge(offset: 607, content: 1554, container: 666, insets: bars).endIsNear(above: 0))  // 165 pt: the end
        XCTAssertTrue(edge(offset: 757, content: 1554, container: 666, insets: bars).endIsNear(above: 0))  // 15 pt: the end
        XCTAssertTrue(edge(offset: -116, content: 300, container: 666, insets: bars).endIsNear(above: 0))  // it all fits
        // Held under the last message read (70 pt) for context: 207 pt below, of which 137 is new, opens at the end.
        XCTAssertTrue(edge(offset: 564.67, content: 1554, container: 666, insets: bars).endIsNear(above: 70))
    }
}

/// Only a send from this device takes the thread to its end (`Message.isLocalEcho`): our own message sent from
/// Instagram's app arrives as an event (with its offline threading ID, like any of ours) and leaves the scroll alone.
final class LocalEchoTests: XCTestCase {
    func testOnlyWhatWeSendFromHereIsALocalEcho() {
        let elsewhere = Event(type: "m.room.message", content: ["msgtype": "m.text", "body": "from the Instagram app"],
                              eventID: "$own", sender: "@me", originServerTS: 1, unsigned: Event.Unsigned(transactionID: "751"))
        let messages = Timeline.reduce([elsewhere], me: "@me", pending: [
            PendingMessage(txnID: "t1", content: ["msgtype": "m.text", "body": "sending"], ts: 2, state: .sending),
            PendingMessage(txnID: "t2", content: ["msgtype": "m.text", "body": "sent, not back yet"], ts: 3, state: .sent("$t2")),
        ])
        XCTAssertEqual(messages.map(\.isOwn), [true, true, true])
        XCTAssertEqual(messages.map(\.isLocalEcho), [false, true, true])
    }
}

/// The jump-to-newest button's count (`Timeline.newCount`): what others sent after it appeared, never our own,
/// Instagram's lines about the chat or an unsent message.
final class JumpCountTests: XCTestCase {
    private func message(_ id: String, ts: Int64, own: Bool = false, kind: MessageKind = .text) -> Message {
        Message(id: id, sender: own ? "@me" : "@ig_1", ts: ts, kind: kind, body: id, content: [:], isOwn: own)
    }

    func testCountsOnlyWhatOthersSentSince() {
        let messages = [
            message("before", ts: 100), message("since", ts: 200), message("mine", ts: 300, own: true),
            message("left the group", ts: 400, kind: .event), message("poll", ts: 500, kind: .unsupported("a poll")),
            message("unsent", ts: 600, kind: .unsent), message("photo", ts: 700, kind: .image),
        ]
        XCTAssertEqual(Timeline.newCount(messages, after: 100), 2)  // "since" and the photo
        XCTAssertEqual(Timeline.newCount(messages, after: 700), 0)
    }
}
