import XCTest
@testable import Ferry

/// PLAN §2.6, one test per rule with its counter-case. Real fixtures where they exist; hand-made events say so.
final class TimelineTests: XCTestCase {
    private let me = Fixture.me
    private let ghost = Fixture.kivoGhost

    // MARK: Base messages

    /// Real initial sync: 3 backfilled messages among ~17 state events. State is ignored, order is the timeline's.
    func testBaseMessagesInTimelineOrderStateIgnored() throws {
        let room = try RoomTests.room(Fixture.tamoRoom)
        let messages = Timeline.reduce(room, me: me)
        XCTAssertEqual(messages.map(\.body).prefix(2), ["test", "hello"])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages.map(\.isOwn), [false, true, false])
        XCTAssertEqual(messages[0].kind, .text)
        XCTAssertEqual(messages[2].kind, .share(.reel, .unresolved))
        XCTAssertEqual(messages[0].id, messages[0].eventID)
    }

    func testUnknownEventTypesAreIgnored() {
        let events = [Event.message("$a", ts: 1), Event(type: "com.example.thing", content: ["body": "x"], eventID: "$b", sender: ghost)]
        XCTAssertEqual(Timeline.reduce(events, me: me).map(\.id), ["$a"])
    }

    // MARK: Edits

    /// Real S3 resolve_media edit: m.image → m.video in place, and no "Edited" because
    /// `com.beeper.dont_render_edited` sits on the edit's top-level content.
    func testResolveEditReplacesMsgtypeWithoutEditedLabel() throws {
        let page = try Fixture.messages("messages_dm_backfill")
        let messages = Timeline.reduce(page.chunk.reversed(), me: me)
        let reel = try XCTUnwrap(messages.last)
        XCTAssertEqual(reel.kind, .share(.reel, .ready))
        XCTAssertEqual(reel.content["msgtype"]?.string, "m.video")
        XCTAssertEqual(reel.content["url"]?.string, "mxc://igm.home.arpa/qfzfnZlXNGlgiHYGVUpxmyYw")
        XCTAssertFalse(reel.isEdited)
        XCTAssertEqual(messages.count, 3)  // the edit itself is not a row
    }

    /// Counter-case: the same flag inside `m.new_content` doesn't count (S3: only top-level is read).
    func testDontRenderEditedInsideNewContentStillShowsEdited() throws {
        var edit = try Fixture.event("event_reel_resolve_edit")
        edit.content = edit.content.setting(["com.beeper.dont_render_edited"], nil)
            .setting(["m.new_content", "com.beeper.dont_render_edited"], true)
        let messages = Timeline.reduce([try Fixture.event("event_reel_unresolved"), edit], me: me)
        XCTAssertTrue(try XCTUnwrap(messages.first).isEdited)
    }

    /// Backfill can deliver an edit before its target: it's held (not rendered) and applies once the target loads.
    func testEditBeforeTargetIsHeldUntilTargetLoads() throws {
        let edit = try Fixture.event("event_reel_resolve_edit")
        let target = try Fixture.event("event_reel_unresolved")
        XCTAssertEqual(Timeline.reduce([edit], me: me), [])
        let messages = Timeline.reduce([edit, target], me: me)
        XCTAssertEqual(messages.map(\.id), [target.eventID])
        XCTAssertEqual(messages.first?.kind, .share(.reel, .ready))
    }

    /// Counter-case: only the original sender can edit; anyone else's replace relation is ignored.
    func testEditFromAnotherSenderIsIgnored() throws {
        var edit = try Fixture.event("event_reel_resolve_edit")
        edit.sender = me
        let messages = Timeline.reduce([try Fixture.event("event_reel_unresolved"), edit], me: me)
        XCTAssertEqual(messages.first?.kind, .share(.reel, .unresolved))
        XCTAssertFalse(try XCTUnwrap(messages.first).isEdited)
    }

    /// Hand-made: the live run made only one distinct edit. The latest by timeline order wins, and each distinct
    /// edit counts toward Instagram's 5-edit limit.
    func testLatestTextEditWinsAndCounts() {
        let events = [
            Event.message("$a", ts: 1, sender: me, body: "helo"),
            Event.edit("$e1", of: "$a", ts: 2, sender: me, body: "hello"),
            Event.edit("$e2", of: "$a", ts: 3, sender: me, body: "hello!"),
        ]
        let message = Timeline.reduce(events, me: me)[0]
        XCTAssertEqual(message.body, "hello!")
        XCTAssertTrue(message.isEdited)
        XCTAssertEqual(message.editCount, 2)
        XCTAssertEqual(message.ts, 1)  // keeps the original's time and place
    }

    /// Real M4 edit: our edit, then Instagram's echo of it bridged back through our double puppet (same text).
    /// That's one edit for the 5-edit limit, not two. The target was unsent later, so its content is restored here
    /// as the app sent it (the server strips content on redaction).
    func testRealEditAndItsDoublePuppetEchoCountOnce() throws {
        let events = try Fixture.events("events_m4_tamo")
        let edits = events.filter { $0.replacesEventID == Self.m4Message }
        XCTAssertEqual(edits.count, 2)
        XCTAssertNotNil(edits[1].content["fi.mau.double_puppet_source"])
        let message = Timeline.reduce([try Self.restoredM4Message()] + edits, me: me)[0]
        XCTAssertEqual(message.body, "M4 check: hello from tamoveska (edited)")
        XCTAssertTrue(message.isEdited)
        XCTAssertEqual(message.editCount, 1)
    }

    func testRedactedEditFallsBackToThePreviousOne() {
        let events = [
            Event.message("$a", ts: 1, sender: me, body: "one"),
            Event.edit("$e1", of: "$a", ts: 2, sender: me, body: "two"),
            Event.edit("$e2", of: "$a", ts: 3, sender: me, body: "three"),
            Event.redaction("$r", of: "$e2", ts: 4),
        ]
        let message = Timeline.reduce(events, me: me)[0]
        XCTAssertEqual(message.body, "two")
        XCTAssertEqual(message.editCount, 1)
    }

    func testEditToARedactedTargetIsIgnored() {
        let events = [
            Event.message("$a", ts: 1, sender: me, body: "one"),
            Event.redaction("$r", of: "$a", ts: 2),
            Event.edit("$e1", of: "$a", ts: 3, sender: me, body: "two"),
        ]
        let message = Timeline.reduce(events, me: me)[0]
        XCTAssertEqual(message.kind, .unsent)
        XCTAssertEqual(message.body, "")
        XCTAssertFalse(message.isEdited)
    }

    func testCanEditOwnTextWithinInstagramLimits() {
        let start: Int64 = 1_000_000
        let now = Date(timeIntervalSince1970: Double(start) / 1000 + 60)
        func message(sender: String = Fixture.me, edits: Int = 0, kind: String = "m.text") -> Message {
            var events = [Event.message("$a", ts: start, sender: sender, msgtype: kind)]
            for i in 0..<edits { events.append(.edit("$e\(i)", of: "$a", ts: start + 1, sender: sender, body: "\(i)")) }
            return Timeline.reduce(events, me: me)[0]
        }
        XCTAssertTrue(Timeline.canEdit(message(), now: now))
        XCTAssertTrue(Timeline.canEdit(message(edits: 4), now: now))
        XCTAssertFalse(Timeline.canEdit(message(edits: 5), now: now))  // edit_max_count 5
        XCTAssertFalse(Timeline.canEdit(message(), now: now.addingTimeInterval(15 * 60)))  // edit_max_age 900 s
        XCTAssertFalse(Timeline.canEdit(message(sender: ghost), now: now))
        XCTAssertFalse(Timeline.canEdit(message(kind: "m.image"), now: now))
    }

    // MARK: Reactions

    /// Hand-made: the live run had one reactor per message.
    func testReactionsGroupByKey() {
        let events = [
            Event.message("$a", ts: 1),
            Event.reaction("$r1", to: "$a", key: "❤️", sender: ghost),
            Event.reaction("$r2", to: "$a", key: "❤️", sender: me),
            Event.reaction("$r3", to: "$a", key: "😂", sender: "@instagram_3:igm.home.arpa"),
        ]
        let reactions = Timeline.reduce(events, me: me)[0].reactions
        XCTAssertEqual(reactions.map(\.key), ["❤️", "😂"])
        XCTAssertEqual(reactions.map(\.count), [2, 1])
        XCTAssertEqual(reactions[0].myEventID, "$r2")
        XCTAssertNil(reactions[1].myEventID)
    }

    /// Instagram allows one reaction per person: only each sender's latest counts, even if the old one wasn't
    /// redacted.
    func testOnlyTheLatestReactionPerSenderCounts() {
        let events = [
            Event.message("$a", ts: 1),
            Event.reaction("$r1", to: "$a", key: "❤️", sender: me),
            Event.reaction("$r2", to: "$a", key: "❤️", sender: ghost),
            Event.reaction("$r3", to: "$a", key: "😂", sender: me),
        ]
        let reactions = Timeline.reduce(events, me: me)[0].reactions
        XCTAssertEqual(reactions.map(\.key), ["❤️", "😂"])
        XCTAssertEqual(reactions.map(\.senders), [[ghost], [me]])
    }

    func testRedactedReactionIsDropped() {
        let events = [
            Event.message("$a", ts: 1),
            Event.reaction("$r1", to: "$a", key: "❤️", sender: me),
            Event.redaction("$x", of: "$r1", ts: 5),
        ]
        XCTAssertEqual(Timeline.reduce(events, me: me)[0].reactions, [])
    }

    /// Real M4 change ❤️ → 😂 in tamoveska's room: the bridge's bot redacted our ❤️, Instagram's echo of the 😂
    /// raced our own event, so the bridge posted its own 😂 through the double puppet and redacted ours. Redacted
    /// reactions are restored to the content the app sent (the server strips it). One 😂 must remain, whichever
    /// way the race orders the duplicate and its replacement.
    func testRealReactionChangeLeavesOneReactionEvenWhenTheBridgeDedupes() throws {
        var events = try Fixture.events("events_m4_tamo")
        let reply = "$ioTZwPw6EpU8U0CoxD32g1RW2tAyxz0SuOz69ZqQEas"
        for (id, key) in [("$pD-zIZv_PfJp-lFje0fIEN85dLvT0Rt63ERB3F6VMlE", "❤️"), ("$-83a67EsVq5pTTNdtJpY4k291xwJxfJn0J_LuTHuOOs", "😂")] {
            let i = try XCTUnwrap(events.firstIndex { $0.eventID == id })
            events[i].content = ["m.relates_to": ["rel_type": "m.annotation", "event_id": .string(reply), "key": .string(key)]]
            events[i].unsigned = nil  // as it was before its redaction arrived
        }
        let expected = [Message.Reaction(key: "😂", senders: [me], myEventID: "$WgeKIHZLqBVREiDs9RnNHi4986Ufij7HmzMok-CLtX8")]
        XCTAssertEqual(Timeline.reduce(events, me: me).first { $0.id == reply }?.reactions, expected)

        // The race the other way: the surviving 😂 lands before the duplicate the bridge then redacts.
        let survivor = try XCTUnwrap(events.firstIndex { $0.eventID == expected[0].myEventID })
        let moved = events.remove(at: survivor)
        events.insert(moved, at: try XCTUnwrap(events.firstIndex { $0.eventID == "$-83a67EsVq5pTTNdtJpY4k291xwJxfJn0J_LuTHuOOs" }))
        XCTAssertEqual(Timeline.reduce(events, me: me).first { $0.id == reply }?.reactions, expected)
    }

    /// Real M4, the other side: kivostudio's own reply carries one 😂 from tamoveska's ghost (its ❤️ arrives
    /// already redacted).
    func testRealReactionOnTheOtherSide() throws {
        let messages = Timeline.reduce(try Fixture.events("events_m4_kivo"), me: me)
        let reply = try XCTUnwrap(messages.first { $0.body == "M4 reply from kivostudio" })
        XCTAssertEqual(reply.reactions.map(\.key), ["😂"])
        XCTAssertEqual(reply.reactions.map(\.senders), [[Fixture.tamoGhost]])
        XCTAssertNil(reply.reactions[0].myEventID)
    }

    func testReactionToAnUnknownEventIsIgnored() {
        let events = [Event.message("$a", ts: 1), Event.reaction("$r1", to: "$elsewhere", key: "❤️", sender: me)]
        XCTAssertEqual(Timeline.reduce(events, me: me).map(\.reactions), [[]])
    }

    // MARK: Redactions

    /// Room v11+ (ours are v12) put the target in `content.redacts`; older versions at the top level.
    func testRedactionFromContentOrTopLevelMakesATombstone() {
        let v12 = Event.redaction("$r", of: "$a", ts: 3)
        let v10 = Event(type: "m.room.redaction", content: [:], eventID: "$r2", sender: me, originServerTS: 4, redacts: "$b")
        let events = [Event.message("$a", ts: 1, sender: ghost), Event.message("$b", ts: 2, sender: me), v12, v10]
        let messages = Timeline.reduce(events, me: me)
        XCTAssertEqual(messages.map(\.kind), [.unsent, .unsent])
        XCTAssertEqual(messages.map(\.sender), [ghost, me])  // the tombstone keeps who unsent it
    }

    /// Real M4 unsend, fetched afterwards: the message arrives already redacted (`unsigned.redacted_because`, empty
    /// content). It's a tombstone, its two edits are ignored, and the reply quoting it says so.
    func testRealUnsentMessageIsATombstoneAndItsQuoteFollows() throws {
        let messages = Timeline.reduce(try Fixture.events("events_m4_tamo"), me: me)
        XCTAssertEqual(messages.map(\.id), [Self.m4Message, "$ioTZwPw6EpU8U0CoxD32g1RW2tAyxz0SuOz69ZqQEas"])
        XCTAssertEqual(messages[0].kind, .unsent)
        XCTAssertTrue(messages[0].isOwn)
        XCTAssertFalse(messages[0].isEdited)
        XCTAssertEqual(messages[1].reply?.kind, .unsent)
        XCTAssertEqual(messages[1].body, "M4 reply from kivostudio")
    }

    /// The same unsend seen live (target loaded with content, then the redaction event): also a tombstone.
    /// Counter-case: without the redaction it's the edited text.
    func testRealUnsendOfALoadedMessage() throws {
        let events = try Fixture.events("events_m4_tamo")
        let unsend = try XCTUnwrap(events.first { $0.redactionTarget == Self.m4Message })
        let edits = events.filter { $0.replacesEventID == Self.m4Message }
        XCTAssertEqual(Timeline.reduce([try Self.restoredM4Message()] + edits + [unsend], me: me).map(\.kind), [.unsent])
        XCTAssertEqual(Timeline.reduce([try Self.restoredM4Message()] + edits, me: me).map(\.kind), [.text])
    }

    func testTombstoneDropsItsReactions() {
        let events = [
            Event.message("$a", ts: 1),
            Event.reaction("$r1", to: "$a", key: "❤️", sender: me),
            Event.redaction("$x", of: "$a", ts: 5),
        ]
        XCTAssertEqual(Timeline.reduce(events, me: me)[0].reactions, [])
    }

    func testRedactionOfAnUnknownEventChangesNothing() {
        let events = [Event.message("$a", ts: 1), Event.redaction("$x", of: "$nope", ts: 5)]
        XCTAssertEqual(Timeline.reduce(events, me: me).map(\.kind), [.text])
    }

    // MARK: Replies

    /// Hand-made: the bridge's real replies carry no fallback (MSC2781), but the spec still says to strip one.
    func testReplyQuotesTheLoadedTargetAndStripsTheFallback() {
        let events = [
            Event.message("$a", ts: 1, sender: ghost, body: "see you there"),
            Event.message("$b", ts: 2, sender: me, body: "> <\(ghost)> see you there\n\nyes!",
                          extra: ["m.relates_to": ["m.in_reply_to": ["event_id": "$a"]]]),
        ]
        let reply = Timeline.reduce(events, me: me)[1]
        XCTAssertEqual(reply.body, "yes!")
        XCTAssertEqual(reply.reply, Message.Reply(eventID: "$a", sender: ghost, kind: .text, body: "see you there"))
    }

    /// Real M4 reply in tamoveska's room (kivostudio replying to our message), quoting the target as edited.
    func testRealReplyQuotesItsTarget() throws {
        let events = try Fixture.events("events_m4_tamo")
        let reply = try XCTUnwrap(events.first { $0.eventID == "$ioTZwPw6EpU8U0CoxD32g1RW2tAyxz0SuOz69ZqQEas" })
        let edits = events.filter { $0.replacesEventID == Self.m4Message }
        let message = try XCTUnwrap(Timeline.reduce([try Self.restoredM4Message(), reply] + edits, me: me).last)
        XCTAssertEqual(message.sender, Fixture.kivoGhost)
        XCTAssertEqual(message.reply, Message.Reply(eventID: Self.m4Message, sender: me, kind: .text,
                                                    body: "M4 check: hello from tamoveska (edited)"))
    }

    /// Not loaded: a placeholder (the view fetches `/event/{id}`), filled from `related` once fetched.
    func testReplyToAnUnloadedTargetIsAPlaceholderUntilFetched() {
        let reply = Event.message("$b", ts: 2, sender: me, body: "yes!", extra: ["m.relates_to": ["m.in_reply_to": ["event_id": "$old"]]])
        let placeholder = Timeline.reduce([reply], me: me)[0].reply
        XCTAssertEqual(placeholder?.eventID, "$old")
        XCTAssertEqual(placeholder?.isLoaded, false)

        let fetched = Event.message("$old", ts: 1, sender: ghost, body: "from last week")
        let loaded = Timeline.reduce([reply], me: me, related: ["$old": fetched])[0].reply
        XCTAssertEqual(loaded?.body, "from last week")
        XCTAssertEqual(loaded?.isLoaded, true)
    }

    /// The quote shows the target as it is now: edited text, or unsent.
    func testReplyQuoteFollowsEditsAndUnsend() {
        let replyTo = { (id: String) in Event.message("$b\(id)", ts: 5, sender: self.me, body: "ok",
                                                       extra: ["m.relates_to": ["m.in_reply_to": ["event_id": .string(id)]]]) }
        let events = [
            Event.message("$a", ts: 1, sender: ghost, body: "helo"),
            Event.edit("$e", of: "$a", ts: 2, sender: ghost, body: "hello"),
            Event.message("$c", ts: 3, sender: ghost, body: "oops"),
            Event.redaction("$r", of: "$c", ts: 4),
            replyTo("$a"), replyTo("$c"),
        ]
        let messages = Timeline.reduce(events, me: me)
        XCTAssertEqual(messages[2].reply?.body, "hello")
        XCTAssertEqual(messages[3].reply?.kind, .unsent)
    }

    /// Counter-case: a message that merely starts with "> " (a quote someone typed) keeps it.
    func testQuoteWithoutReplyRelationIsKept() {
        let events = [Event.message("$a", ts: 1, body: "> famous words\n\nindeed")]
        XCTAssertEqual(Timeline.reduce(events, me: me)[0].body, "> famous words\n\nindeed")
        XCTAssertNil(Timeline.reduce(events, me: me)[0].reply)
    }

    // MARK: Local echo

    func testPendingSendsComeAfterServerEvents() {
        let pending = [
            PendingMessage(txnID: "t1", content: ["msgtype": "m.text", "body": "on its way"], ts: 0, state: .sending),
            PendingMessage(txnID: "t2", content: ["msgtype": "m.text", "body": "sent"], ts: 0, state: .sent("$t2")),
            PendingMessage(txnID: "t3", content: ["msgtype": "m.text", "body": "nope"], ts: 0, state: .failed("offline")),
        ]
        let messages = Timeline.reduce([Event.message("$a", ts: 9)], me: me, pending: pending)
        XCTAssertEqual(messages.map(\.id), ["$a", "txn:t1", "txn:t2", "txn:t3"])
        XCTAssertEqual(messages.dropFirst().map(\.status), [.sending, .sent, .failed("offline")])
        XCTAssertEqual(messages[2].eventID, "$t2")
        XCTAssertTrue(messages[1].isOwn)
        XCTAssertEqual(messages[1].body, "on its way")
    }

    /// Real M3 CLI send: the echo carries `unsigned.transaction_id`, which retires the pending item.
    func testPendingIsReplacedByItsEcho() throws {
        let events = try Fixture.events("events_send_status")
        let txn = try XCTUnwrap(events[0].unsigned?.transactionID)
        let pending = [PendingMessage(txnID: txn, content: ["msgtype": "m.text", "body": "igm test (M3)"], ts: 0, state: .sending)]
        let messages = Timeline.reduce(events, me: me, pending: pending)
        XCTAssertEqual(messages.map(\.id), [events[0].eventID])
        // Counter-case: another transaction stays pending.
        let other = [PendingMessage(txnID: "other", content: ["msgtype": "m.text", "body": "x"], ts: 0, state: .sending)]
        XCTAssertEqual(Timeline.reduce(events, me: me, pending: other).count, 2)
    }

    // MARK: Send status

    /// Real M3 send: the bridge's SUCCESS status (an m.reference to our event) means Instagram has it.
    func testSendStatusSuccessMeansDelivered() throws {
        let events = try Fixture.events("events_send_status")
        let messages = Timeline.reduce(events, me: me)
        XCTAssertEqual(messages.map(\.status), [.delivered])
        // Counter-case: before the status arrives it's only on our server.
        XCTAssertEqual(Timeline.reduce([events[0]], me: me).map(\.status), [.sent])
    }

    /// Hand-made from the real status shape: no failed send has happened (mautrix statuses FAIL_RETRIABLE /
    /// FAIL_PERMANENT carry a human `message`).
    func testSendStatusFailureMarksFailedAndLatestWins() throws {
        let events = try Fixture.events("events_send_status")
        var failed = events[1]
        failed.eventID = "$fail"
        failed.content = failed.content.setting(["status"], "FAIL_PERMANENT").setting(["message"], "Instagram said no")
        XCTAssertEqual(Timeline.reduce([events[0], failed], me: me).map(\.status), [.failed("Instagram said no")])
        XCTAssertEqual(Timeline.reduce([events[0], failed, events[1]], me: me).map(\.status), [.delivered])
    }

    /// Real backfill: our own message sent from the Instagram app arrives through the double puppet, so Instagram
    /// has it by definition, with no send status. Counter-case: a Matrix send without a status is only "sent".
    func testOwnMessageFromInstagramIsDelivered() throws {
        XCTAssertEqual(Timeline.reduce([try Fixture.event("event_text_own")], me: me).map(\.status), [.delivered])
        XCTAssertEqual(Timeline.reduce([Event.message("$a", ts: 1, sender: me)], me: me).map(\.status), [.sent])
    }

    func testIncomingMessagesIgnoreSendStatus() throws {
        let events = try Fixture.events("events_send_status")
        var incoming = events[0]
        incoming.sender = ghost
        XCTAssertFalse(Timeline.reduce([incoming, events[1]], me: me)[0].isOwn)
    }

    // MARK: Seen

    /// Real sync: kivostudio's ghost read up to its reel, which comes after our "hello", so "hello" is Seen.
    func testSeenFromGhostReceiptAtOrAfterOurLastMessage() throws {
        let room = try RoomTests.room(Fixture.tamoRoom)
        let messages = Timeline.reduce(room, me: me)
        XCTAssertEqual(messages.filter(\.isSeen).map(\.body), ["hello"])
    }

    /// Real sync, counter-case: in kivostudio's room only our own receipt exists, so nothing is Seen.
    func testOwnReceiptIsNotSeen() throws {
        let room = try RoomTests.room(Fixture.kivoRoom)
        XCTAssertEqual(Timeline.reduce(room, me: me).filter(\.isSeen), [])
    }

    func testReceiptBeforeOurLastMessageIsNotSeen() {
        let events = [Event.message("$a", ts: 1, sender: ghost), Event.message("$b", ts: 2, sender: me), Event.message("$c", ts: 3, sender: me)]
        let early = Timeline.reduce(events, me: me, receipts: [ghost: .init(eventID: "$b", ts: 9)])
        XCTAssertEqual(early.filter(\.isSeen), [])
        let late = Timeline.reduce(events, me: me, receipts: [ghost: .init(eventID: "$c", ts: 9)])
        XCTAssertEqual(late.filter(\.isSeen).map(\.id), ["$c"])
        let unknown = Timeline.reduce(events, me: me, receipts: [ghost: .init(eventID: "$gone", ts: 9)])
        XCTAssertEqual(unknown.filter(\.isSeen), [])
    }

    // MARK: Read receipt target

    /// We mark read the newest message from someone else, only when our receipt isn't already at or past it.
    func testReceiptTarget() throws {
        let tamo = try RoomTests.room(Fixture.tamoRoom)
        XCTAssertNil(Timeline.receiptTarget(tamo, me: me))  // real: our receipt sits on the newest incoming
        let kivo = try RoomTests.room(Fixture.kivoRoom)
        XCTAssertNil(Timeline.receiptTarget(kivo, me: me))  // real: our receipt is on our own later reel

        kivo.apply(JoinedRoom(timeline: .init(events: [
            Event.message("$new", ts: 1_900_000_000_000, sender: Fixture.tamoGhost),
            Event.edit("$edit", of: "$new", ts: 1_900_000_000_001, sender: Fixture.tamoGhost, body: "edited"),
            Event.message("$mine", ts: 1_900_000_000_002, sender: me),
        ], limited: false)))
        XCTAssertEqual(Timeline.receiptTarget(kivo, me: me), "$new")  // not the edit, not our own message
    }

    // MARK: Classification (minimal; M5 extends it)

    func testClassification() throws {
        func kind(_ msgtype: String, _ extra: [String: JSON] = [:], type: String = "m.room.message") -> MessageKind {
            var content: [String: JSON] = ["msgtype": .string(msgtype), "body": "x"]
            content.merge(extra) { $1 }
            return MessageKind(type: type, content: .object(content))
        }
        let reel: JSON = "https://www.instagram.com/reel/DSampleRl01/?id=1"
        XCTAssertEqual(MessageKind(type: "m.room.message", content: try Fixture.event("event_reel_unresolved").content), .share(.reel, .unresolved))
        XCTAssertEqual(kind("m.video", ["external_url": reel]), .share(.reel, .ready))
        XCTAssertEqual(kind("m.image", ["external_url": "https://www.instagram.com/p/abc/"]), .share(.post, .ready))
        XCTAssertEqual(kind("m.image", ["external_url": "https://www.instagram.com/stories/maya/123/"]), .share(.story, .ready))
        XCTAssertEqual(kind("m.image", ["external_url": reel, "fi.mau.instagram.xma_fetch_status": "fetch fail"]), .share(.reel, .unavailable))
        XCTAssertEqual(kind("m.image", ["external_url": reel, "fi.mau.instagram.xma_fetch_status": "reupload fail"]), .share(.reel, .tooLarge))
        XCTAssertEqual(kind("m.audio", ["org.matrix.msc3245.voice": [:]]), .voice)
        XCTAssertEqual(kind("m.audio"), .audio)
        XCTAssertEqual(kind("m.image"), .image)
        XCTAssertEqual(kind("m.text", ["external_url": reel]), .text)  // a link in text is text (link card: M5)
        XCTAssertEqual(kind("m.notice"), .notice)
        XCTAssertEqual(kind("m.whatever"), .text)  // unknown msgtypes fall back to their body
        XCTAssertEqual(MessageKind(type: "m.sticker", content: ["body": "x"]), .sticker)
    }

    // MARK: Layout (DESIGN §6.1 grouping)

    func testGroupingBySenderWithinThreeMinutes() {
        let minute: Int64 = 60_000
        let events = [
            Event.message("$1", ts: 0, sender: ghost),
            Event.message("$2", ts: 1 * minute, sender: ghost),
            Event.message("$3", ts: 2 * minute, sender: ghost),
            Event.message("$4", ts: 3 * minute, sender: me),
            Event.message("$5", ts: 7 * minute, sender: me),  // 4 min later: new group
            Event.message("$6", ts: 70 * minute, sender: me),  // over an hour: new group with a time
        ]
        let rows = Timeline.layout(Timeline.reduce(events, me: me))
        XCTAssertEqual(rows.map(\.position), [.first, .middle, .last, .single, .single, .single])
        XCTAssertEqual(rows.map(\.showsTime), [true, false, false, false, false, true])
        XCTAssertEqual(rows.map(\.spacing), [0, 2, 2, 10, 10, 16])
    }
}

extension TimelineTests {
    /// Our "M4 check" message in tamoveska's room (unsent at the end of the live run).
    static let m4Message = "$0rZGiVgg_YxNGWc8Fb7DUKHdZg0WD2gkM6Bo-Gon44Y"

    /// The real pre-redacted event with the content the app sent restored (the server stripped it on unsend).
    static func restoredM4Message() throws -> Event {
        var event = try XCTUnwrap(Fixture.events("events_m4_tamo").first { $0.eventID == m4Message })
        event.content = ["msgtype": "m.text", "body": "M4 check: hello from tamoveska"]
        event.unsigned = nil
        return event
    }
}

extension Event {
    static func edit(_ id: String, of target: String, ts: Int64, sender: String, body: String) -> Event {
        Event(type: "m.room.message", content: [
            "msgtype": "m.text", "body": .string("* \(body)"),
            "m.new_content": ["msgtype": "m.text", "body": .string(body)],
            "m.relates_to": ["rel_type": "m.replace", "event_id": .string(target)],
        ], eventID: id, sender: sender, originServerTS: ts)
    }

    static func reaction(_ id: String, to target: String, key: String, sender: String, ts: Int64 = 2) -> Event {
        Event(type: "m.reaction", content: ["m.relates_to": ["rel_type": "m.annotation", "event_id": .string(target), "key": .string(key)]],
              eventID: id, sender: sender, originServerTS: ts)
    }

    static func redaction(_ id: String, of target: String, ts: Int64, sender: String = "@me:igm.home.arpa") -> Event {
        Event(type: "m.room.redaction", content: ["redacts": .string(target)], eventID: id, sender: sender, originServerTS: ts)
    }
}
