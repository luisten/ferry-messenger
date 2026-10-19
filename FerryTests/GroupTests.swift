import XCTest
@testable import Ferry

/// Group chats (FOLLOWUPS #24): sender labels in the thread, who a user is, and Chat Info's members. No group exists
/// on the dummy accounts, so groups are hand-made from the real DM shapes (`state_bridge_dm.json` without a room type,
/// S7.6) and the real member events of `sync_initial.json` / `messages_dm_backfill.json`; each test says which.
final class GroupTests: XCTestCase {
    private let me = Fixture.me
    private let theo = "@instagram_9:igm.home.arpa"
    private let maya = "@instagram_8:igm.home.arpa"
    private let minute: Int64 = 60_000

    // MARK: Sender labels (DESIGN §6.1)

    /// Hand-made: the name goes above the first bubble of each run, the avatar beside the last; a lone message has both.
    func testGroupRunsGetTheNameFirstAndTheAvatarLast() {
        let events = [
            Event.message("$1", ts: 0, sender: theo),
            Event.message("$2", ts: 1 * minute, sender: theo),
            Event.message("$3", ts: 2 * minute, sender: theo),
            Event.message("$4", ts: 3 * minute, sender: maya),
        ]
        let rows = Timeline.layout(Timeline.reduce(events, me: me), isGroup: true)
        XCTAssertEqual(rows.map { $0.groupSender?.showsName }, [true, false, false, true])
        XCTAssertEqual(rows.map { $0.groupSender?.showsAvatar }, [false, false, true, true])
    }

    /// Hand-made: our own messages (the double puppet, `@me`) are never labelled or indented, in a group either.
    func testOwnMessagesInAGroupHaveNoLabel() {
        let events = [
            Event.message("$1", ts: 0, sender: theo),
            Event.message("$2", ts: 1 * minute, sender: me),
            Event.message("$3", ts: 2 * minute, sender: theo),
        ]
        let rows = Timeline.layout(Timeline.reduce(events, me: me), isGroup: true)
        XCTAssertNotNil(rows[0].groupSender)
        XCTAssertNil(rows[1].groupSender)
        XCTAssertEqual(rows[2].groupSender, .init(showsName: true, showsAvatar: true))  // our message broke Theo's run
    }

    /// Real DM rooms (both directions): DMs stay exactly as they were, no labels at all.
    func testDMsHaveNoSenderLabels() throws {
        for id in [Fixture.tamoRoom, Fixture.kivoRoom] {
            let room = try RoomTests.room(id)
            let rows = Timeline.layout(Timeline.reduce(room, me: me), isGroup: room.bridge?.roomType == .group)
            XCTAssertFalse(rows.isEmpty)
            XCTAssertTrue(rows.allSatisfy { $0.groupSender == nil })
        }
    }

    /// Hand-made: runs break where the layout already breaks them (over 3 minutes, and the hour gap with a time label),
    /// so the name shows again.
    func testTimeGapsStartANewLabelledRun() {
        let events = [
            Event.message("$1", ts: 0, sender: theo),
            Event.message("$2", ts: 4 * minute, sender: theo),  // 4 min: a new run
            Event.message("$3", ts: 70 * minute, sender: theo),  // over an hour: a new run under a time label
        ]
        let rows = Timeline.layout(Timeline.reduce(events, me: me), isGroup: true)
        XCTAssertEqual(rows.map(\.position), [.single, .single, .single])
        XCTAssertEqual(rows.map { $0.groupSender?.showsName }, [true, true, true])
        XCTAssertEqual(rows.map(\.showsTime), [true, false, true])
    }

    /// Hand-made: a tombstone ("Theo unsent a message") already names its sender, so it gets neither label, but it's
    /// still indented like every incoming row of a group.
    func testUnsentMessageInAGroupIsIndentedWithoutLabels() {
        let events = [
            Event.message("$1", ts: 0, sender: theo),
            Event.redaction("$r", of: "$1", ts: 1, sender: theo),
        ]
        let rows = Timeline.layout(Timeline.reduce(events, me: me), isGroup: true)
        XCTAssertEqual(rows.first?.message.kind, .unsent)
        XCTAssertEqual(rows.first?.groupSender, .init(showsName: false, showsAvatar: false))
    }

    // MARK: Who a user is (Room.displayName)

    /// Hand-made group with the real ghost member event shape: the member event's name wins over the ghost profile.
    func testMemberEventNameComesFirst() throws {
        let group = try groupRoom(members: [theo: "Theo Park"])
        XCTAssertEqual(group.displayName(of: theo, profile: UserProfile(name: "Theo P.")), "Theo Park")
        XCTAssertEqual(group.knownName(of: theo), "Theo Park")
    }

    /// Hand-made: a member event without a name (a left member's is just `{"membership": "leave"}`) or with an empty
    /// one falls back to the ghost profile, then to the ID's localpart. Never the raw `@…:server` ID.
    func testNameFallsBackToTheProfileThenTheLocalpart() throws {
        let group = try groupRoom(members: [theo: ""])
        group.apply(JoinedRoom(state: EventList(events: [Event.state("m.room.member", ["membership": "leave"], key: maya)])))
        XCTAssertEqual(group.displayName(of: theo, profile: UserProfile(name: "Theo Park")), "Theo Park")
        XCTAssertEqual(group.displayName(of: maya, profile: UserProfile(name: "Maya Chen")), "Maya Chen")
        XCTAssertEqual(group.displayName(of: maya), "instagram_8")
        XCTAssertEqual(group.displayName(of: "@instagram_7:igm.home.arpa", profile: UserProfile(name: "")), "instagram_7")
        XCTAssertNil(group.knownName(of: maya))  // the inbox preview then leaves the sender out
    }

    /// Real DM: someone without a member event is the contact, so the DM's name stands in before the localpart (what
    /// the thread did before groups); we never become the contact.
    func testInADMTheRoomNameStandsIn() throws {
        let room = try RoomTests.room(Fixture.tamoRoom)
        room.ownUserID = me
        XCTAssertEqual(room.displayName(of: "@instagram_123:igm.home.arpa"), "Kivo Studio")
        XCTAssertEqual(room.displayName(of: Fixture.kivoGhost), "Kivo Studio")
        XCTAssertEqual(room.displayName(of: me), "me")  // the real double-puppet member event
    }

    /// Real member event (Kivo's ghost in tamoveska's room): its avatar, else the profile's.
    func testAvatarFromTheMemberEventThenTheProfile() throws {
        let room = try RoomTests.room(Fixture.tamoRoom)
        XCTAssertEqual(room.avatarURL(of: Fixture.kivoGhost), "mxc://igm.home.arpa/AKRxSivqzKQzNAwknfzLHZsH")
        XCTAssertEqual(room.avatarURL(of: theo, profile: UserProfile(avatarURL: "mxc://x/y")), "mxc://x/y")
        XCTAssertNil(room.avatarURL(of: theo))
    }

    /// Real profile (`profile_ghost_extra.json`): name, avatar and the `instagram:<handle>` identifier.
    func testUserProfileFromTheRealGhostProfile() throws {
        let profile = UserProfile(try JSONDecoder().decode(JSON.self, from: Fixture.data("profile_ghost_extra")))
        XCTAssertEqual(profile, UserProfile(name: "Kivo Studio", avatarURL: "mxc://igm.home.arpa/AKRxSivqzKQzNAwknfzLHZsH", handle: "kivostudio"))
    }

    /// Hand-made group: the inbox preview names the sender from the profile when the member event lacks a name, and
    /// leaves the name out rather than show an ID.
    func testGroupPreviewUsesTheProfileAndNeverAnID() throws {
        let group = try InboxTests.portal("!g", receiver: Fixture.tamoLogin, group: true)
        group.apply(JoinedRoom(timeline: .init(events: [Event.message("$t", ts: 20, sender: theo, body: "on my way")], limited: false)))
        XCTAssertEqual(Inbox.preview(of: group, me: me, profiles: [theo: UserProfile(name: "Theo Park")])?.text, "Theo: on my way")
        XCTAssertEqual(Inbox.preview(of: group, me: me)?.text, "on my way")
    }

    // MARK: Lazy-loaded members from /messages

    /// Real events: a page from `/messages` with `lazy_load_members` carries its senders' member events in `state`
    /// (live check on the dev stack 2026-10-15: bot, ghost and `@me`). A room that didn't know the sender learns their
    /// name from it, so older senders don't show as IDs. Kivo's real join event from `sync_initial.json`.
    func testPrependMergesTheLazyLoadedMembers() throws {
        let kivoJoin = try XCTUnwrap(Fixture.sync().rooms?.join?[Fixture.tamoRoom]?.timeline?.events?.last {
            $0.type == "m.room.member" && $0.stateKey == Fixture.kivoGhost
        })
        let room = try groupRoom(members: [:], prevBatch: "t1")
        let page = MessagesPage(chunk: [Event.message("$old", ts: 1, sender: Fixture.kivoGhost)], start: "t1", end: "t0", state: [kivoJoin])
        XCTAssertEqual(room.displayName(of: Fixture.kivoGhost), "instagram_17841400000000302")
        room.prepend(page, from: "t1")
        XCTAssertEqual(room.displayName(of: Fixture.kivoGhost), "Kivo Studio")
    }

    /// Real back-pagination page (`messages_dm_backfill.json`, newest first): Kivo's ghost has an invite and several
    /// joins in it. A room that didn't know the ghost keeps the newest of them, not the invite (it took the oldest).
    func testPrependFillsAnUnknownMemberWithItsNewestEvent() throws {
        let page = try Fixture.messages("messages_dm_backfill")
        let room = try groupRoom(members: [:], prevBatch: "t1")
        room.prepend(page, from: "t1")
        let member = try XCTUnwrap(room.stateEvent("m.room.member", Fixture.kivoGhost))
        XCTAssertEqual(member.content["membership"]?.string, "join")
        XCTAssertEqual(member.content["displayname"]?.string, "Kivo Studio")
    }

    // MARK: Members (T3)

    /// The bot is left out, we're "You" and last, the rest sorted by name ignoring case, handles from profiles, and an
    /// empty member name falls back to the profile's.
    func testMembersSortedWithYouLast() throws {
        let zoe = "@instagram_7:igm.home.arpa"
        let group = try groupRoom(members: [theo: "theo park", maya: "Maya Chen", zoe: ""])
        let profiles = [theo: UserProfile(handle: "theo.climbs"), zoe: UserProfile(name: "Zoë Ruiz")]
        let members = Inbox.members(of: group, me: me, profiles: profiles)
        XCTAssertEqual(members.map(\.name), ["Maya Chen", "theo park", "Zoë Ruiz", "You"])
        XCTAssertEqual(members.map(\.isMe), [false, false, false, true])
        XCTAssertEqual(members.map(\.handle), [nil, "theo.climbs", nil, nil])
        XCTAssertFalse(members.contains { $0.id == "@instagrambot:igm.home.arpa" })
    }

    /// Real DM state (`sync_initial.json`): the room's joined member events; the bot (named by `m.bridge`) never shows.
    func testMembersFallBackToTheRoomsJoinedMemberEvents() throws {
        let room = try RoomTests.room(Fixture.tamoRoom)
        let members = Inbox.members(of: room, me: me, profiles: [:])
        XCTAssertEqual(members.map(\.id), [Fixture.kivoGhost, me])
        XCTAssertEqual(members.map(\.name), ["Kivo Studio", "You"])
        XCTAssertEqual(members.first?.avatarURL, "mxc://igm.home.arpa/AKRxSivqzKQzNAwknfzLHZsH")
    }

    /// Hand-made: a member who left isn't listed from state.
    func testLeftMembersAreNotListed() throws {
        let group = try groupRoom(members: [theo: "Theo Park", maya: "Maya Chen"])
        group.apply(JoinedRoom(state: EventList(events: [Event.state("m.room.member", ["membership": "leave"], key: maya)])))
        XCTAssertEqual(Inbox.members(of: group, me: me, profiles: [:]).map(\.name), ["Theo Park", "You"])
    }

    // MARK: Start block (DESIGN T1, review 2026-10-15 #3)

    /// Real DM rooms (`sync_initial.json`): the room summary counts 3 joined, us, the contact's ghost and the bridge
    /// bot; the bot isn't someone to count.
    func testMemberCountFromTheRealRoomSummaryLeavesOutTheBot() throws {
        let room = try RoomTests.room(Fixture.tamoRoom)
        XCTAssertEqual(room.joinedMemberCount, 3)
        XCTAssertEqual(Inbox.memberCount(of: room), 2)
    }

    /// Without a summary the joined member events count (lazy loading may leave some out, hence the summary first);
    /// the DEBUG group has none: three ghosts and us, not the one who left.
    func testMemberCountFallsBackToTheJoinedMemberEvents() {
        let room = DebugFixtures.groupRoom(receiver: Fixture.tamoLogin, me: me)
        XCTAssertNil(room.joinedMemberCount)
        XCTAssertEqual(Inbox.memberCount(of: room), 4)
    }

    /// Synapse sends the summary only when it changes: a sync without one keeps the last count.
    func testSummaryCountUpdatesOnlyWhenSent() throws {
        let room = try RoomTests.room(Fixture.tamoRoom)
        room.apply(JoinedRoom(summary: .init(joinedMemberCount: 5)))
        XCTAssertEqual(Inbox.memberCount(of: room), 4)
        room.apply(JoinedRoom(timeline: .init(events: [Event.message("$new", ts: 9)], limited: false)))
        XCTAssertEqual(Inbox.memberCount(of: room), 4)
    }

    /// The start block says who the chat is with ("4 members", "@handle"); "You're messaging from …" only while the
    /// thread is empty, where it's the only cue (with messages the composer says it).
    func testStartBlockNamesWhoAndOnlyAnEmptyThreadSaysWhichAccount() {
        XCTAssertEqual(Inbox.startBlock(isGroup: true, members: 4, handle: nil, account: "Alex", isEmpty: false),
                       Inbox.StartBlock(subtitle: "4 members", messagingFrom: nil))
        XCTAssertEqual(Inbox.startBlock(isGroup: true, members: 1, handle: "x", account: "Alex", isEmpty: true),
                       Inbox.StartBlock(subtitle: "1 member", messagingFrom: "You're messaging from Alex."))
        XCTAssertEqual(Inbox.startBlock(isGroup: true, members: 0, handle: nil, account: "Alex", isEmpty: false).subtitle, nil)
        XCTAssertEqual(Inbox.startBlock(isGroup: false, members: 2, handle: "maya.chen", account: "Alex Studio", isEmpty: true),
                       Inbox.StartBlock(subtitle: "@maya.chen", messagingFrom: "You're messaging from Alex Studio."))
        XCTAssertEqual(Inbox.startBlock(isGroup: false, members: 2, handle: nil, account: "Alex", isEmpty: false),
                       Inbox.StartBlock(subtitle: nil, messagingFrom: nil))
        XCTAssertNil(Inbox.startBlock(isGroup: false, members: 2, handle: nil, account: nil, isEmpty: true).messagingFrom)
    }

    // MARK: The DEBUG group (FERRY_DEBUG_GROUP)

    /// The hand-made fixture group reads as a group with four senders, labels them, and lists its joined members.
    func testDebugGroupFixture() throws {
        let room = DebugFixtures.groupRoom(receiver: Fixture.tamoLogin, me: me, now: Date(timeIntervalSince1970: 1_791_900_000))
        room.ownUserID = me
        XCTAssertEqual(room.bridge?.roomType, .group)
        XCTAssertEqual(room.bridge?.receiver, Fixture.tamoLogin)
        XCTAssertTrue(room.reachedStart)
        let rows = Timeline.layout(Timeline.reduce(room, me: me), isGroup: true)
        let senders = Set(rows.map(\.message.sender)).subtracting([me])
        XCTAssertEqual(senders.count, 4)
        XCTAssertTrue(rows.contains { $0.message.reply != nil && $0.groupSender?.showsName == true })
        let profiles = DebugFixtures.groupProfiles
        XCTAssertTrue(senders.allSatisfy { !room.displayName(of: $0, profile: profiles[$0]).hasPrefix("instagram_") })
        let members = Inbox.members(of: room, me: me, profiles: profiles)
        XCTAssertEqual(members.count, 4)  // three ghosts and us; the one who left isn't listed
        XCTAssertEqual(members.last?.isMe, true)
        XCTAssertTrue(DebugFixtures.isFixtureRoom(room.id))

        // Unread past Sam's ride: the line goes above Priya leaving; Maya and Sam have seen Theo's newest; 👍 is three people.
        XCTAssertTrue(room.isUnread)
        let messages = Timeline.reduce(room, me: me)
        let marked = Timeline.layout(messages, isGroup: true, unreadAfter: room.receipts[me]?.ts)
        XCTAssertEqual(marked.filter(\.startsUnread).map(\.id), ["$debug-group-left"])
        XCTAssertEqual(messages.last?.seenBy.map { room.displayName(of: $0, profile: profiles[$0]) }, ["Maya Chen", "Sam Lee"])
        XCTAssertEqual(messages.first { $0.reactions.contains { $0.count == 3 } }?.reactions.first?.senders.count, 3)
        XCTAssertEqual(Inbox.faces(of: room).count, 2)
    }

    // MARK: Seen by, the "New messages" line, two faces

    /// Hand-made: the newest message lists everyone else whose receipt is at or after it, first reader first; not
    /// its sender, not us, not someone whose receipt is older. Only the newest message says it.
    func testSeenByNamesWhoReadTheNewestMessage() {
        let sam = "@instagram_7:igm.home.arpa", zoe = "@instagram_6:igm.home.arpa"
        let events = [Event.message("$1", ts: 1, sender: theo), Event.message("$2", ts: 2, sender: maya)]
        let receipts: [String: Room.Receipt] = [sam: .init(eventID: "$2", ts: 9), theo: .init(eventID: "$2", ts: 5),
                                                maya: .init(eventID: "$2", ts: 3), me: .init(eventID: "$2", ts: 4),
                                                zoe: .init(eventID: "$1", ts: 1)]
        XCTAssertEqual(Timeline.reduce(events, me: me, receipts: receipts).map(\.seenBy), [[], [theo, sam]])
    }

    /// Instagram's web app: two names, then a count; "everyone" once all of three or more have.
    func testSeenByLine() {
        XCTAssertNil(Timeline.seenByLine([], everyone: false))
        XCTAssertEqual(Timeline.seenByLine(["Maya"], everyone: true), "Seen by Maya")
        XCTAssertEqual(Timeline.seenByLine(["Maya", "Sam"], everyone: true), "Seen by Maya and Sam")
        XCTAssertEqual(Timeline.seenByLine(["Maya", "Sam", "Theo"], everyone: false), "Seen by Maya, Sam + 1")
        XCTAssertEqual(Timeline.seenByLine(["Maya", "Sam", "Theo"], everyone: true), "Seen by everyone")
    }

    /// Hand-made: the line goes above the first message from someone else after how far we'd read, and after our own
    /// last message (we'd read what came before it). It starts a new run, so a group names the sender again.
    func testUnreadLineStartsAfterWhatWeRead() {
        let run = [Event.message("$1", ts: 0, sender: theo), Event.message("$2", ts: minute, sender: theo), Event.message("$3", ts: 2 * minute, sender: theo)]
        let rows = Timeline.layout(Timeline.reduce(run, me: me), isGroup: true, unreadAfter: 0)
        XCTAssertEqual(rows.map(\.startsUnread), [false, true, false])
        XCTAssertEqual(rows.map(\.position), [.single, .first, .last])
        XCTAssertEqual(rows.map { $0.groupSender?.showsName }, [true, true, false])
        XCTAssertEqual(rows[1].spacing, 16)

        let replied = run + [Event.message("$4", ts: 3 * minute, sender: me), Event.message("$5", ts: 4 * minute, sender: maya)]
        let messages = Timeline.reduce(replied, me: me)
        XCTAssertEqual(Timeline.layout(messages, unreadAfter: 0).filter(\.startsUnread).map(\.id), ["$5"])
        XCTAssertFalse(Timeline.layout(messages, unreadAfter: 4 * minute).contains(where: \.startsUnread))
        XCTAssertFalse(Timeline.layout(messages).contains(where: \.startsUnread))  // opened read
    }

    /// A group without its own picture shows two of its people, those with a picture first, never us; with fewer than
    /// two others it keeps the people glyph.
    func testGroupFacesPreferPictures() throws {
        let zoe = "@instagram_7:igm.home.arpa"
        let group = try groupRoom(members: [theo: "Theo Park", maya: "Maya Chen", zoe: "Zoë Ruiz"])
        group.ownUserID = me
        group.apply(JoinedRoom(state: EventList(events: [
            Event.state("m.room.member", ["membership": "join", "displayname": "Zoë Ruiz", "avatar_url": "https://scontent.example.invalid/z.jpg"], key: zoe),
        ])))
        XCTAssertEqual(Inbox.faces(of: group).map(\.name), ["Zoë Ruiz", "Maya Chen"])
        let pair = try groupRoom(members: [theo: "Theo Park"])
        pair.ownUserID = me
        XCTAssertEqual(Inbox.faces(of: pair), [])
    }

    // MARK: Helpers

    /// A group derived from the real DM `m.bridge` (room type keys removed, S7.6) with members shaped like the real
    /// ghost member event (`{"membership": "join", "displayname": …}`, sent by the ghost itself) plus the real bot
    /// and double-puppet ones.
    private func groupRoom(members: [String: String], prevBatch: String? = nil) throws -> Room {
        var bridge = try Fixture.event("state_bridge_dm")
        bridge.content = bridge.content.setting(["com.beeper.room_type"], nil).setting(["com.beeper.room_type.v2"], nil)
        let joined = try XCTUnwrap(Fixture.sync().rooms?.join?[Fixture.tamoRoom])
        let real = (joined.state?.events ?? []) + (joined.timeline?.events ?? [])
        let botAndMe = real.filter { $0.type == "m.room.member" && [me, "@instagrambot:igm.home.arpa"].contains($0.stateKey)
            && $0.content["membership"]?.string == "join" }
        let ghosts = members.map { id, name in
            Event(type: "m.room.member", content: ["membership": "join", "displayname": .string(name)], eventID: "$m\(id)", sender: id,
                  stateKey: id, originServerTS: 1)
        }
        let room = Room(id: "!group")
        room.apply(JoinedRoom(state: EventList(events: [bridge] + botAndMe + ghosts),
                              timeline: .init(events: [], limited: false, prevBatch: prevBatch)))
        return room
    }
}
