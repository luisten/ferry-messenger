import XCTest
@testable import Ferry

/// Message requests (PLAN §2.8, M6). These accounts have no request room (S6, D11), so every request here is the real
/// DM `m.bridge` with `com.beeper.message_request: true` added (`InboxTests.portal`). The bridge marks a chat read on
/// Instagram before handling *any* event we send (mautrix-go v0.31.0 `bridgev2/portal.go:874`, implicit read
/// receipts), so in a request only Accept, Delete and a reply may send anything.
final class RequestTests: XCTestCase {
    private let logins: Set<String> = [Fixture.tamoLogin, Fixture.kivoLogin]

    // MARK: Nothing is sent before Accept or a reply

    func testOpeningARequestAllowsNoReceiptsTypingOrReactions() throws {
        let request = try InboxTests.portal("!req", receiver: Fixture.kivoLogin, request: true, unread: 2)
        XCTAssertTrue(Inbox.isRequest(request))
        XCTAssertFalse(Inbox.allowsReceipts(request))  // m.read, typing, reactions, edits, unsends all check this
        XCTAssertNotNil(Timeline.receiptTarget(request, me: Fixture.me), "there is something to mark read; the rule must stop it")
        XCTAssertEqual(Inbox.threadBar(request, health: .connected, replyingInstead: false), .request)
    }

    // MARK: Folders and counts

    func testRequestsCountOnlyOnTheTileNeverInChatUnread() throws {
        let rooms = [
            try InboxTests.portal("!r1", receiver: Fixture.kivoLogin, request: true, unread: 3),
            try InboxTests.portal("!r2", receiver: Fixture.tamoLogin, request: true),
            try InboxTests.portal("!c", receiver: Fixture.kivoLogin, unread: 1),
        ]
        XCTAssertEqual(Inbox.requestCount(rooms, scope: .all, logins: logins), 2)
        XCTAssertEqual(Inbox.requestCount(rooms, scope: .account(Fixture.tamoLogin), logins: logins), 1)
        XCTAssertEqual(Inbox.unreadChats(rooms, scope: .all, logins: logins), 1)
        XCTAssertEqual(Inbox.rooms(rooms, scope: .all, folder: .requests, logins: logins).map(\.id), ["!r1", "!r2"])
    }

    // MARK: The request bar (T2, review 2026-10-15 #5)

    /// The account's tag follows the title on screen, so the words stop at "message"; VoiceOver hears one sentence
    /// with the account's name. Without an identity the bar has no tag and says "you".
    func testRequestTitleLeavesTheAccountToTheTag() {
        XCTAssertEqual(Inbox.requestTitle(requester: "@lena.ortiz", account: "Alex Studio"),
                       Inbox.RequestTitle(shown: "@lena.ortiz wants to message", spoken: "@lena.ortiz wants to message Alex Studio."))
        XCTAssertEqual(Inbox.requestTitle(requester: "Lena Ortiz", account: nil),
                       Inbox.RequestTitle(shown: "Lena Ortiz wants to message you.", spoken: "Lena Ortiz wants to message you."))
    }

    // MARK: Accept

    /// Accept moves the chat at once (optimistic), but receipts wait for the bridge: until it re-sends `m.bridge`
    /// without the flag, Instagram may still treat the thread as a request.
    func testAcceptMovesTheChatAtOnceAndReceiptsWaitForTheBridge() throws {
        let room = try InboxTests.portal("!req", receiver: Fixture.kivoLogin, request: true, unread: 1)
        room.setRequestAction(.init(kind: .accept))

        XCTAssertFalse(Inbox.isRequest(room))
        XCTAssertEqual(Inbox.folder(of: room), .chats)
        XCTAssertEqual(Inbox.requestCount([room], scope: .all, logins: logins), 0)
        XCTAssertEqual(Inbox.unreadChats([room], scope: .all, logins: logins), 1)  // now it counts with the chats
        XCTAssertEqual(Inbox.threadBar(room, health: .connected, replyingInstead: false), .composer)
        XCTAssertFalse(Inbox.allowsReceipts(room), "not before the bridge confirms")

        // The bridge accepts on Instagram and re-sends m.bridge; the key is dropped, not set to false (`omitzero`,
        // go/event/state.go:254). That is exactly the real DM event.
        room.apply(JoinedRoom(timeline: .init(events: [try Fixture.event("state_bridge_dm").withReceiver(Fixture.kivoLogin)],
                                              limited: false)))
        XCTAssertTrue(Inbox.allowsReceipts(room))
        XCTAssertFalse(Inbox.isRequest(room))
        XCTAssertNil(room.requestAction, "done once the flag is gone")
    }

    /// The bridge answers a failed accept with a failure status on our accept event (EventHandlingResultFailed
    /// .WithMSSError, portal.go:1941); the chat goes back to Requests and the bar says why.
    func testFailedAcceptGoesBackToRequests() throws {
        let room = try InboxTests.portal("!req", receiver: Fixture.kivoLogin, request: true)
        room.setRequestAction(.init(kind: .accept, eventID: "$accept"))
        XCTAssertEqual(Inbox.folder(of: room), .chats)
        XCTAssertNil(Inbox.requestActionFailure(room))

        room.apply(JoinedRoom(timeline: .init(events: [Self.sendStatus(for: "$other", "FAIL_PERMANENT")], limited: false)))
        XCTAssertEqual(Inbox.folder(of: room), .chats, "someone else's failure isn't ours")

        room.apply(JoinedRoom(timeline: .init(events: [Self.sendStatus(for: "$accept", "FAIL_RETRIABLE", message: "Instagram said no")],
                                              limited: false)))
        XCTAssertTrue(Inbox.isRequest(room))
        XCTAssertEqual(Inbox.folder(of: room), .requests)
        XCTAssertEqual(Inbox.requestActionFailure(room), "Instagram said no")
        XCTAssertEqual(Inbox.threadBar(room, health: .connected, replyingInstead: false), .request)
    }

    // MARK: Reply instead

    /// The bridge accepts the request itself before sending our first message (autoAcceptMessageRequest,
    /// portal.go:1345; Instagram's AcceptWithMessage isn't set, capabilities.go:151), so a reply is an Accept.
    func testReplyInsteadShowsTheComposerWithTheWarning() throws {
        let request = try InboxTests.portal("!req", receiver: Fixture.kivoLogin, request: true)
        XCTAssertEqual(Inbox.threadBar(request, health: .connected, replyingInstead: true), .replyAccepts)
        XCTAssertFalse(Inbox.allowsReceipts(request), "typing while writing the reply still isn't sent")

        let chat = try InboxTests.portal("!chat", receiver: Fixture.kivoLogin)
        XCTAssertEqual(Inbox.threadBar(chat, health: .connected, replyingInstead: true), .composer)
        XCTAssertEqual(Inbox.threadBar(chat, health: nil, replyingInstead: false), .composer)  // whoami not loaded yet
    }

    /// A signed-out account can't accept or send; its recovery bar wins (DESIGN §7.2).
    func testSignedOutAccountShowsTheRecoveryBar() throws {
        let request = try InboxTests.portal("!req", receiver: Fixture.kivoLogin, request: true)
        let chat = try InboxTests.portal("!chat", receiver: Fixture.kivoLogin)
        XCTAssertEqual(Inbox.threadBar(request, health: .needsLogin, replyingInstead: true), .signedOut)
        XCTAssertEqual(Inbox.threadBar(chat, health: .needsLogin, replyingInstead: false), .signedOut)
        XCTAssertEqual(Inbox.threadBar(chat, health: .connecting, replyingInstead: false), .composer)
    }

    // MARK: Delete

    /// The bridge deletes the thread on Instagram, then the portal and its Matrix room (portal.go:1988-2032), which
    /// reaches us as a `leave`. Until then the request is hidden; a failure status brings it back.
    func testDeleteHidesTheRequestUntilTheBridgeAnswers() throws {
        let room = try InboxTests.portal("!req", receiver: Fixture.tamoLogin, request: true, unread: 1)
        room.setRequestAction(.init(kind: .delete, eventID: "$delete"))
        for folder in [Inbox.Folder.chats, .requests, .archived] {
            XCTAssertEqual(Inbox.rooms([room], scope: .all, folder: folder, logins: logins).map(\.id), [])
        }
        XCTAssertEqual(Inbox.requestCount([room], scope: .all, logins: logins), 0)

        room.apply(JoinedRoom(timeline: .init(events: [Self.sendStatus(for: "$delete", "FAIL_PERMANENT")], limited: false)))
        XCTAssertEqual(Inbox.rooms([room], scope: .all, folder: .requests, logins: logins).map(\.id), ["!req"])
        XCTAssertEqual(Inbox.requestActionFailure(room), "Instagram didn't accept that.")  // no message in the status
    }

    func testUnknownRoomIsNeverARequestAndNeverGetsReceipts() {
        let room = Room(id: "!unknown")
        XCTAssertFalse(Inbox.isRequest(room))
        XCTAssertFalse(Inbox.allowsReceipts(room))
    }

    // MARK: DEBUG fixtures (what the simulator shows for I2/T2)

    /// The hand-made request rooms are the real DM `m.bridge` with only the channel and the flag changed.
    func testDebugRequestFixturesMatchTheRealBridgeShape() throws {
        let rooms = DebugFixtures.requestRooms(logins: [Fixture.tamoLogin, Fixture.kivoLogin], now: Date(timeIntervalSince1970: 1_791_900_000))
        XCTAssertEqual(rooms.count, 3)
        let real = try Fixture.event("state_bridge_dm")
        for room in rooms {
            let event = try XCTUnwrap(room.stateEvent("m.bridge", real.stateKey ?? ""))
            XCTAssertEqual(event.content.setting(["channel"], nil), real.content.setting(["channel"], nil))
            XCTAssertTrue(Inbox.isRequest(room))
            XCTAssertTrue(Inbox.isVisible(room, logins: logins))
            XCTAssertNotNil(Inbox.preview(of: room, me: Fixture.me))
        }
        XCTAssertEqual(Set(rooms.compactMap(\.bridge?.receiver)), logins)
    }

    // MARK: Helpers

    /// Shaped like the real status in `events_send_status.json`.
    static func sendStatus(for eventID: String, _ status: String, message: String? = nil) -> Event {
        var content: [String: JSON] = ["status": .string(status), "m.relates_to": ["rel_type": "m.reference", "event_id": .string(eventID)]]
        if let message { content["message"] = .string(message) }
        return Event(type: "com.beeper.message_send_status", content: .object(content), eventID: "$mss\(eventID)",
                     sender: "@instagrambot:igm.home.arpa", originServerTS: 5000)
    }
}

extension Event {
    func withReceiver(_ receiver: String) -> Event {
        var copy = self
        copy.content = content.setting(["channel", "fi.mau.receiver"], .string(receiver))
        return copy
    }
}
