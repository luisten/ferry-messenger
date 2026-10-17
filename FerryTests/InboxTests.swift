import XCTest
@testable import Ferry

final class InboxTests: XCTestCase {
    private let bothLogins: Set<String> = [Fixture.tamoLogin, Fixture.kivoLogin]

    // MARK: Inclusion and account mapping (real sync)

    func testRealSyncShowsOnlyThePortals() throws {
        let rooms = try Self.realRooms()
        let shown = Inbox.rooms(rooms, scope: .all, folder: .chats, logins: bothLogins).map(\.id)
        XCTAssertEqual(Set(shown), [Fixture.tamoRoom, Fixture.kivoRoom])  // personal filtering spaces hidden
    }

    func testEachRoomMapsToItsAccount() throws {
        let rooms = try Self.realRooms()
        XCTAssertEqual(Inbox.rooms(rooms, scope: .account(Fixture.tamoLogin), folder: .chats, logins: bothLogins).map(\.id),
                       [Fixture.tamoRoom])
        XCTAssertEqual(Inbox.rooms(rooms, scope: .account(Fixture.kivoLogin), folder: .chats, logins: bothLogins).map(\.id),
                       [Fixture.kivoRoom])
        XCTAssertEqual(Inbox.rooms(rooms, scope: .account("someone-else"), folder: .chats, logins: bothLogins).map(\.id), [])
    }

    func testBeforeWhoamiLoadsEveryPortalShows() throws {
        let shown = Inbox.rooms(try Self.realRooms(), scope: .all, folder: .chats, logins: nil).map(\.id)
        XCTAssertEqual(Set(shown), [Fixture.tamoRoom, Fixture.kivoRoom])
    }

    func testRoomsOfRemovedLoginsAreHidden() throws {
        let shown = Inbox.rooms(try Self.realRooms(), scope: .all, folder: .chats, logins: [Fixture.tamoLogin]).map(\.id)
        XCTAssertEqual(shown, [Fixture.tamoRoom])
    }

    /// The bridge's management room is a plain DM with the bot: no `m.bridge`, so it never shows.
    func testBotManagementRoomIsHidden() {
        let bot = Room(id: "!bot")
        bot.apply(JoinedRoom(timeline: .init(events: [
            Event.state("m.room.create", ["room_version": "12"]),
            Event.message("$help", ts: 5, sender: "@instagrambot:igm.home.arpa", body: "Use !ig help"),
        ], limited: false)))
        XCTAssertEqual(Inbox.rooms([bot], scope: .all, folder: .chats, logins: nil).map(\.id), [])
    }

    // MARK: Folders

    func testRequestShowsOnlyInRequests() throws {
        let request = try Self.portal("!req", receiver: Fixture.tamoLogin, request: true)
        let chat = try Self.portal("!chat", receiver: Fixture.tamoLogin)
        XCTAssertEqual(Inbox.rooms([request, chat], scope: .all, folder: .chats, logins: bothLogins).map(\.id), ["!chat"])
        XCTAssertEqual(Inbox.rooms([request, chat], scope: .all, folder: .requests, logins: bothLogins).map(\.id), ["!req"])
        XCTAssertEqual(Inbox.rooms([request, chat], scope: .all, folder: .archived, logins: bothLogins).map(\.id), [])
    }

    func testArchivedShowsOnlyInArchived() throws {
        let archived = try Self.portal("!arch", receiver: Fixture.kivoLogin, ts: 1000, tags: ["u.archived": [:]])
        XCTAssertEqual(Inbox.rooms([archived], scope: .all, folder: .chats, logins: bothLogins).map(\.id), [])
        XCTAssertEqual(Inbox.rooms([archived], scope: .all, folder: .archived, logins: bothLogins).map(\.id), ["!arch"])
    }

    /// DESIGN §4.5: an archived chat comes back on new activity. The archive tag records when it was set, so this
    /// needs no write: activity after that moment puts the chat back in the list.
    func testArchivedChatReturnsOnNewActivity() throws {
        let tag: JSON = ["u.archived": [Inbox.archivedAtKey: 2000]]
        let quiet = try Self.portal("!quiet", receiver: Fixture.kivoLogin, ts: 1500, tags: tag)
        let active = try Self.portal("!active", receiver: Fixture.kivoLogin, ts: 2500, tags: tag)
        XCTAssertEqual(Inbox.folder(of: quiet), .archived)
        XCTAssertEqual(Inbox.folder(of: active), .chats)
    }

    func testArchivedRequestStaysARequest() throws {
        let room = try Self.portal("!r", receiver: Fixture.kivoLogin, request: true, tags: ["u.archived": [:]])
        XCTAssertEqual(Inbox.folder(of: room), .requests)
    }

    // MARK: Primary/General (M8: patched bridge, D12)

    /// The patched bridge turns each real `SlideUQPPIGMoveThread` (spike S5) into `fi.mau.instagram.inbox_folder` on
    /// the room's `m.bridge` channel, and the chat follows it out of the main list and back.
    func testRealMoveDeltasMoveTheChatToGeneralAndBack() throws {
        let deltas = try Fixture.jsonArray("deltas_s5_ig_move_thread")
        XCTAssertEqual(deltas.map { $0["ig_inbox_folder"]?.string }, ["GENERAL", "PRIMARY"])
        XCTAssertEqual(deltas.map { $0["folder"]?.string }, ["INBOX", "INBOX"])  // the system folder: not a request
        let room = try Self.portal("!k", receiver: Fixture.kivoLogin)
        XCTAssertEqual(room.bridge?.folder, .primary)  // bridge v26.09, or never moved since the patch: no key
        XCTAssertEqual(Inbox.folder(of: room), .chats)

        room.apply(JoinedRoom(state: EventList(events: [try Self.bridgeAfterMove(deltas[0], receiver: Fixture.kivoLogin)])))
        XCTAssertEqual(room.bridge?.folder, .general)
        XCTAssertEqual(Inbox.rooms([room], scope: .all, folder: .chats, logins: bothLogins).map(\.id), [])
        XCTAssertEqual(Inbox.rooms([room], scope: .all, folder: .general, logins: bothLogins).map(\.id), ["!k"])
        XCTAssertEqual(Inbox.rooms([room], scope: .account(Fixture.kivoLogin), folder: .general, logins: bothLogins).map(\.id), ["!k"])

        room.apply(JoinedRoom(state: EventList(events: [try Self.bridgeAfterMove(deltas[1], receiver: Fixture.kivoLogin)])))
        XCTAssertEqual(room.bridge?.folder, .primary)
        XCTAssertEqual(Inbox.folder(of: room), .chats)
    }

    /// Only GENERAL leaves the main list: a value this app doesn't know stays where the chat is today.
    func testUnknownFolderValueIsPrimary() throws {
        let dm = try Fixture.event("state_bridge_dm").content
        XCTAssertEqual(BridgeInfo(content: dm.setting(["channel", BridgeInfo.inboxFolderKey], "OTHER"))?.folder, .primary)
        XCTAssertEqual(BridgeInfo(content: dm.setting(["channel", BridgeInfo.inboxFolderKey], "PRIMARY"))?.folder, .primary)
        XCTAssertEqual(BridgeInfo(content: dm.setting(["channel", BridgeInfo.inboxFolderKey], "GENERAL"))?.folder, .general)
    }

    /// Real whoami from the patched bridge: kivostudio (business) is professional, tamoveska (personal) isn't,
    /// and v26.09's whoami had no flag at all.
    func testProfessionalFlagFromRealWhoami() throws {
        let logins = try XCTUnwrap(Fixture.whoami("provisioning_whoami_m8").logins)
        XCTAssertEqual(logins.map(\.id), [Fixture.tamoLogin, Fixture.kivoLogin])
        XCTAssertEqual(logins.map(\.isProfessional), [false, true])
        XCTAssertEqual(try XCTUnwrap(Fixture.whoami().logins).map(\.isProfessional), [false, false])
    }

    /// DESIGN §4.2/§4.3: the General tile is in front of Requests in any scope that holds a professional account
    /// (All included: it's the only way to General there), never for a personal account alone.
    func testGeneralTileShowsForScopesWithAProfessionalAccount() throws {
        let logins = try XCTUnwrap(Fixture.whoami("provisioning_whoami_m8").logins)
        let rooms = try Self.realRooms()
        XCTAssertTrue(Inbox.showsGeneral(rooms, scope: .account(Fixture.kivoLogin), accounts: logins, logins: bothLogins))
        XCTAssertTrue(Inbox.showsGeneral(rooms, scope: .all, accounts: logins, logins: bothLogins))
        XCTAssertFalse(Inbox.showsGeneral(rooms, scope: .account(Fixture.tamoLogin), accounts: logins, logins: bothLogins))
        // Bridge v26.09 (no flag, no folder): no tile anywhere, as in v1.0.
        let v1 = try XCTUnwrap(Fixture.whoami().logins)
        XCTAssertFalse(Inbox.showsGeneral(rooms, scope: .all, accounts: v1, logins: bothLogins))
    }

    /// DESIGN §4.4: "data wins". A General chat shows its tile even when the account's type isn't known (yet).
    func testAGeneralChatShowsTheTileWithoutTheFlag() throws {
        let general = try Self.portal("!g", receiver: Fixture.tamoLogin, inboxFolder: "GENERAL")
        let v1 = try XCTUnwrap(Fixture.whoami().logins)
        XCTAssertTrue(Inbox.showsGeneral([general], scope: .account(Fixture.tamoLogin), accounts: v1, logins: bothLogins))
        XCTAssertFalse(Inbox.showsGeneral([general], scope: .account(Fixture.kivoLogin), accounts: v1, logins: bothLogins))
    }

    /// DESIGN §4.5: chips count the main list (Primary); General's unread shows only on its tile.
    func testGeneralUnreadCountsOnlyOnItsTile() throws {
        let rooms = [
            try Self.portal("!p", receiver: Fixture.kivoLogin, unread: 1),
            try Self.portal("!g1", receiver: Fixture.kivoLogin, unread: 2, inboxFolder: "GENERAL"),
            try Self.portal("!g2", receiver: Fixture.kivoLogin, inboxFolder: "GENERAL"),
        ]
        XCTAssertEqual(Inbox.unreadChats(rooms, scope: .account(Fixture.kivoLogin), logins: bothLogins), 1)
        XCTAssertEqual(Inbox.unreadChats(rooms, scope: .all, folder: .general, logins: bothLogins), 1)
        XCTAssertEqual(Inbox.rooms(rooms, scope: .all, folder: .general, logins: bothLogins).count, 2)
    }

    /// Archive and requests come first: an archived General chat is in Archived, and comes back to General (not the
    /// main list) on new activity; a request stays in Requests whatever its tab.
    func testArchiveAndRequestsWinOverTheTab() throws {
        let tag: JSON = ["u.archived": [Inbox.archivedAtKey: 2000]]
        let quiet = try Self.portal("!q", receiver: Fixture.kivoLogin, ts: 1500, tags: tag, inboxFolder: "GENERAL")
        let active = try Self.portal("!a", receiver: Fixture.kivoLogin, ts: 2500, tags: tag, inboxFolder: "GENERAL")
        XCTAssertEqual(Inbox.folder(of: quiet), .archived)
        XCTAssertEqual(Inbox.folder(of: active), .general)
        let request = try Self.portal("!r", receiver: Fixture.kivoLogin, request: true, inboxFolder: "GENERAL")
        XCTAssertEqual(Inbox.folder(of: request), .requests)
    }

    func testSearchFindsGeneralChats() throws {
        let general = try Self.named("!g", "Ana", receiver: Fixture.kivoLogin, inboxFolder: "GENERAL")
        XCTAssertEqual(Inbox.search([general], query: "ana", scope: .all, logins: bothLogins).map(\.id), ["!g"])
    }

    // MARK: Archive (M7: the u.archived tag the app writes)

    func testArchiveTagRecordsWhenAndArchivesTheChat() throws {
        let room = try Self.portal("!a", receiver: Fixture.kivoLogin, ts: 1_000_000)
        let now = Date(timeIntervalSince1970: 2_000)
        let tag = Inbox.archiveTag(for: room, now: now)
        XCTAssertEqual(tag, [Inbox.archivedAtKey: 2_000_000])
        room.setTags([Inbox.archivedTag: tag])
        XCTAssertEqual(Inbox.folder(of: room), .archived)
        XCTAssertEqual(Inbox.rooms([room], scope: .all, folder: .archived, logins: bothLogins).map(\.id), ["!a"])
        // Unarchive removes the tag.
        room.setTags([:])
        XCTAssertEqual(Inbox.folder(of: room), .chats)
    }

    /// A phone clock behind the server mustn't date the archive before the last message, or the chat would come
    /// straight back.
    func testArchiveTimeIsNeverBeforeTheLastMessage() throws {
        let room = try Self.portal("!a", receiver: Fixture.kivoLogin, ts: 5_000_000)
        let tag = Inbox.archiveTag(for: room, now: Date(timeIntervalSince1970: 1_000))  // clock 4000 s behind
        XCTAssertEqual(tag[Inbox.archivedAtKey]?.int64, 5_000_000)
        room.setTags([Inbox.archivedTag: tag])
        XCTAssertEqual(Inbox.folder(of: room), .archived)
        room.apply(JoinedRoom(timeline: .init(events: [Event.message("$next", ts: 5_000_001)], limited: false)))
        XCTAssertEqual(Inbox.folder(of: room), .chats)  // and the next message does bring it back
    }

    // MARK: Search (I5)

    func testSearchMatchesNameIgnoringCaseAndAccentsWithinScope() throws {
        let kivo = try Self.named("!k", "Kivo Studio", receiver: Fixture.tamoLogin, ts: 3)
        let joana = try Self.named("!l", "Joana Simões", receiver: Fixture.tamoLogin, ts: 2)
        let other = try Self.named("!o", "Kim Lee", receiver: Fixture.kivoLogin, ts: 1)
        let rooms = [kivo, joana, other]
        XCTAssertEqual(Inbox.search(rooms, query: "kiv", scope: .all, logins: bothLogins).map(\.id), ["!k"])
        XCTAssertEqual(Inbox.search(rooms, query: "SIMOES", scope: .all, logins: bothLogins).map(\.id), ["!l"])
        XCTAssertEqual(Inbox.search(rooms, query: "k", scope: .all, logins: bothLogins).map(\.id), ["!k", "!o"])  // newest first
        XCTAssertEqual(Inbox.search(rooms, query: "k", scope: .account(Fixture.kivoLogin), logins: bothLogins).map(\.id), ["!o"])
        XCTAssertEqual(Inbox.search(rooms, query: "  ", scope: .all, logins: bothLogins).map(\.id), [])
    }

    /// Archived chats are found (search is a way back to them); requests aren't (they stay in Requests).
    func testSearchFindsArchivedChatsButNotRequests() throws {
        let archived = try Self.named("!a", "Ana", receiver: Fixture.tamoLogin, tags: ["u.archived": [:]])
        let request = try Self.named("!r", "Anabel", receiver: Fixture.tamoLogin, request: true)
        XCTAssertEqual(Inbox.search([archived, request], query: "ana", scope: .all, logins: bothLogins).map(\.id), ["!a"])
    }

    // MARK: Chat info (T3)

    /// Only a DM with another of our own accounts has a known @handle: its channel ID is that login.
    func testContactHandleIsKnownOnlyForOurOtherAccounts() throws {
        let logins = try XCTUnwrap(Fixture.whoami().logins)
        let tamoName = try XCTUnwrap(logins.first { $0.id == Fixture.tamoLogin }?.profile?.username)
        let kivoName = try XCTUnwrap(logins.first { $0.id == Fixture.kivoLogin }?.profile?.username)
        XCTAssertEqual(Inbox.contactHandle(try RoomTests.room(Fixture.kivoRoom), accounts: logins), tamoName)
        XCTAssertEqual(Inbox.contactHandle(try RoomTests.room(Fixture.tamoRoom), accounts: logins), kivoName)
        XCTAssertNil(Inbox.contactHandle(try RoomTests.room(Fixture.kivoRoom), accounts: []))
        XCTAssertNil(Inbox.contactHandle(try Self.portal("!g", receiver: Fixture.tamoLogin, group: true), accounts: logins))
    }

    // MARK: Sort and counts

    func testSortedByLastActivityNewestFirst() throws {
        let rooms = try Self.realRooms()
        let kivo = try XCTUnwrap(rooms.first { $0.id == Fixture.kivoRoom })
        kivo.apply(JoinedRoom(timeline: .init(events: [Event.message("$new", ts: 1_800_000_000_000)], limited: false)))
        XCTAssertEqual(Inbox.rooms(rooms, scope: .all, folder: .chats, logins: bothLogins).map(\.id),
                       [Fixture.kivoRoom, Fixture.tamoRoom])
    }

    func testEqualActivityHasStableOrder() throws {
        // Both real rooms' last message is the same IG message (same timestamp): order must not flicker.
        let a = Inbox.rooms(try Self.realRooms(), scope: .all, folder: .chats, logins: bothLogins).map(\.id)
        let b = Inbox.rooms(try Self.realRooms().reversed(), scope: .all, folder: .chats, logins: bothLogins).map(\.id)
        XCTAssertEqual(a, b)
    }

    func testUnreadCountsExcludeRequestsAndArchived() throws {
        let rooms = [
            try Self.portal("!t1", receiver: Fixture.tamoLogin, unread: 3),
            try Self.portal("!t2", receiver: Fixture.tamoLogin, unread: 1),
            try Self.portal("!t3", receiver: Fixture.tamoLogin),
            try Self.portal("!k1", receiver: Fixture.kivoLogin, unread: 1),
            try Self.portal("!kreq", receiver: Fixture.kivoLogin, request: true, unread: 1),
            try Self.portal("!karch", receiver: Fixture.kivoLogin, unread: 1, tags: ["u.archived": [:]]),
        ]
        XCTAssertEqual(Inbox.unreadChats(rooms, scope: .all, logins: bothLogins), 3)  // chats, not messages
        XCTAssertEqual(Inbox.unreadChats(rooms, scope: .account(Fixture.tamoLogin), logins: bothLogins), 2)
        XCTAssertEqual(Inbox.unreadChats(rooms, scope: .account(Fixture.kivoLogin), logins: bothLogins), 1)
    }

    /// The tile shows how many requests are waiting in scope (PLAN M3 exit; mockups I1).
    func testRequestCountPerScope() throws {
        XCTAssertEqual(Inbox.requestCount(try Self.realRooms(), scope: .all, logins: bothLogins), 0)  // S6: none live
        let rooms = [
            try Self.portal("!a", receiver: Fixture.tamoLogin, request: true),
            try Self.portal("!b", receiver: Fixture.kivoLogin, request: true, unread: 1),
            try Self.portal("!c", receiver: Fixture.kivoLogin),
        ]
        XCTAssertEqual(Inbox.requestCount(rooms, scope: .all, logins: bothLogins), 2)
        XCTAssertEqual(Inbox.requestCount(rooms, scope: .account(Fixture.kivoLogin), logins: bothLogins), 1)
    }

    // MARK: Folders menu and Requests card (D14)

    /// The DEBUG request rooms at a fixed time: Kestrel Bikes (Tamo, 2 h ago), Lena Ortiz (Kivo, 5 h ago),
    /// crypto.wins.daily (Tamo, 1 day ago). Real DM `m.bridge` shape (RequestTests checks it).
    private static let now = Date(timeIntervalSince1970: 1_791_900_000)
    private static var nowMS: Int64 { Int64(now.timeIntervalSince1970 * 1000) }
    private static func debugRequests() -> [Room] {
        DebugFixtures.requestRooms(logins: [Fixture.tamoLogin, Fixture.kivoLogin], now: now)
    }

    /// Never opened: every request is new, in every scope that shows it.
    func testEveryRequestIsNewBeforeRequestsIsOpened() {
        let rooms = Self.debugRequests()
        XCTAssertEqual(Inbox.newRequests(rooms, scope: .all, logins: bothLogins, seen: [:]).map(\.name),
                       ["Kestrel Bikes", "Lena Ortiz", "crypto.wins.daily"])  // newest first
        XCTAssertEqual(Inbox.newRequests(rooms, scope: .account(Fixture.kivoLogin), logins: bothLogins, seen: [:]).map(\.name),
                       ["Lena Ortiz"])
    }

    /// The card goes once Requests has been opened in a scope that showed the request: All covers every account, an
    /// account covers its own. A request (or a new message in one) after that brings it back.
    func testRequestsAreNewOnlyAfterTheMarkerOfTheirScope() throws {
        let rooms = Self.debugRequests()
        let fourHoursAgo = Self.nowMS - 4 * 3_600_000
        // Opened in All 4 h ago: only Kestrel (2 h ago) is newer, in All and in Tamo's scope.
        let seenAll = ["": fourHoursAgo]
        XCTAssertEqual(Inbox.newRequests(rooms, scope: .all, logins: bothLogins, seen: seenAll).map(\.name), ["Kestrel Bikes"])
        XCTAssertEqual(Inbox.newRequests(rooms, scope: .account(Fixture.tamoLogin), logins: bothLogins, seen: seenAll).map(\.name),
                       ["Kestrel Bikes"])
        XCTAssertEqual(Inbox.newRequests(rooms, scope: .account(Fixture.kivoLogin), logins: bothLogins, seen: seenAll).map(\.name), [])
        // Opened in Kivo's scope just now: Kivo's request is no longer new in All either; Tamo's still are.
        let seenKivo = [Fixture.kivoLogin: Self.nowMS]
        XCTAssertEqual(Inbox.newRequests(rooms, scope: .all, logins: bothLogins, seen: seenKivo).map(\.name),
                       ["Kestrel Bikes", "crypto.wins.daily"])
        XCTAssertEqual(Inbox.newRequests(rooms, scope: .account(Fixture.kivoLogin), logins: bothLogins, seen: seenKivo).map(\.name), [])
        // Opened in All just now: nothing is new anywhere.
        XCTAssertEqual(Inbox.newRequests(rooms, scope: .all, logins: bothLogins, seen: ["": Self.nowMS]).map(\.name), [])
        // Lena writes again: her request is new again.
        let lena = try XCTUnwrap(rooms.first { $0.name == "Lena Ortiz" })
        lena.apply(JoinedRoom(timeline: .init(events: [Event.message("$again", ts: Self.nowMS + 60_000, sender: "@instagram_17841400000000002:igm.home.arpa")],
                                              limited: false)))
        XCTAssertEqual(Inbox.newRequests(rooms, scope: .all, logins: bothLogins, seen: ["": Self.nowMS]).map(\.name), ["Lena Ortiz"])
    }

    /// The marker is "now", or the newest request in scope when the phone's clock is behind the server's (otherwise
    /// opening Requests wouldn't clear the card).
    func testSeenMarkerIsNeverBeforeTheNewestRequestInScope() {
        let rooms = Self.debugRequests()
        let kestrel = Self.nowMS - 120 * 60_000 + 40_000  // its second message
        XCTAssertEqual(Inbox.requestsSeenMarker(rooms, scope: .all, logins: bothLogins, now: Self.now), Self.nowMS)
        let behind = Self.now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(Inbox.requestsSeenMarker(rooms, scope: .all, logins: bothLogins, now: behind), kestrel)
        XCTAssertEqual(Inbox.requestsSeenMarker(rooms, scope: .account(Fixture.kivoLogin), logins: bothLogins, now: behind),
                       Int64(behind.timeIntervalSince1970 * 1000))  // Lena (5 h ago) is older than the clock
        XCTAssertEqual(Inbox.newRequests(rooms, scope: .all, logins: bothLogins,
                                         seen: ["": Inbox.requestsSeenMarker(rooms, scope: .all, logins: bothLogins, now: behind)]).map(\.name), [])
    }

    func testSeenMarkersRoundTripThroughUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "InboxTests.seen"))
        defaults.removePersistentDomain(forName: "InboxTests.seen")
        XCTAssertEqual(Inbox.loadRequestsSeen(from: defaults), [:])
        Inbox.saveRequestsSeen(["": 1_791_900_000_000, Fixture.kivoLogin: 5], to: defaults)
        XCTAssertEqual(Inbox.loadRequestsSeen(from: defaults), ["": 1_791_900_000_000, Fixture.kivoLogin: 5])
        defaults.removePersistentDomain(forName: "InboxTests.seen")
    }

    /// Badge = new requests in scope + unread General chats in scope; 0 (hidden) on a quiet day like the real sync.
    /// The General chat is moved there by the real S5 delta and back by the real `m.bridge` after the move.
    func testBadgeCountsNewRequestsAndUnreadGeneralChats() throws {
        let accounts = try XCTUnwrap(Fixture.whoami("provisioning_whoami_m8").logins)
        XCTAssertEqual(Inbox.foldersMenu(try Self.realRooms(), scope: .all, accounts: accounts, logins: bothLogins, seen: [:]).badge, 0)

        let general = try Self.portal("!k", receiver: Fixture.kivoLogin, unread: 2)
        let deltas = try Fixture.jsonArray("deltas_s5_ig_move_thread")
        general.apply(JoinedRoom(state: EventList(events: [try Self.bridgeAfterMove(deltas[0], receiver: Fixture.kivoLogin)])))
        let rooms = Self.debugRequests() + [general]
        let menu = { (scope: Inbox.Scope, seen: [String: Int64]) in
            Inbox.foldersMenu(rooms, scope: scope, accounts: accounts, logins: self.bothLogins, seen: seen)
        }
        XCTAssertEqual(menu(.all, [:]).badge, 4)  // 3 new requests + 1 unread General chat (chats, not messages)
        XCTAssertEqual(menu(.account(Fixture.kivoLogin), [:]).badge, 2)
        XCTAssertEqual(menu(.account(Fixture.tamoLogin), [:]).badge, 2)
        XCTAssertEqual(menu(.all, ["": Self.nowMS]).badge, 1)  // requests looked at; General's unread stays
        XCTAssertEqual(menu(.account(Fixture.tamoLogin), ["": Self.nowMS]).badge, 0)

        // Moved back to Primary (the real m.bridge after the move): it's a main-list chat again.
        general.apply(JoinedRoom(state: EventList(events: [try Fixture.event("state_bridge_dm_after_move")])))
        XCTAssertEqual(menu(.account(Fixture.kivoLogin), [Fixture.kivoLogin: Self.nowMS]).badge, 0)
    }

    /// General stays quiet: an unread General chat feeds the badge and the menu, never the Requests card.
    func testUnreadGeneralChatNeverShowsTheCard() throws {
        let general = try Self.portal("!g", receiver: Fixture.kivoLogin, unread: 1, inboxFolder: "GENERAL")
        XCTAssertEqual(Inbox.newRequests([general], scope: .all, logins: bothLogins, seen: [:]).map(\.name), [])
        let accounts = try XCTUnwrap(Fixture.whoami("provisioning_whoami_m8").logins)
        XCTAssertEqual(Inbox.foldersMenu([general], scope: .all, accounts: accounts, logins: bothLogins, seen: [:]).badge, 1)
    }

    /// General is an item only where a professional account is in scope (or a General chat: data wins).
    func testGeneralItemOnlyInScopesWithAProfessionalAccount() throws {
        let m8 = try XCTUnwrap(Fixture.whoami("provisioning_whoami_m8").logins)
        let rooms = try Self.realRooms()
        let items = { (scope: Inbox.Scope, accounts: [BridgeAPI.Login]) in
            Inbox.foldersMenu(rooms, scope: scope, accounts: accounts, logins: self.bothLogins, seen: [:]).items
        }
        XCTAssertEqual(items(.account(Fixture.kivoLogin), m8), [.general, .requests, .archived])
        XCTAssertEqual(items(.all, m8), [.general, .requests, .archived])
        XCTAssertEqual(items(.account(Fixture.tamoLogin), m8), [.requests, .archived])
        XCTAssertEqual(items(.all, try XCTUnwrap(Fixture.whoami().logins)), [.requests, .archived])  // bridge v26.09
    }

    /// Subtitles only when non-zero: "2 waiting" counts every request in scope (new or not), "1 unread" General's
    /// unread chats; never "0", and Archived has none.
    func testMenuSubtitlesOnlyWhenNonZero() throws {
        let accounts = try XCTUnwrap(Fixture.whoami("provisioning_whoami_m8").logins)
        let general = try Self.portal("!g", receiver: Fixture.kivoLogin, unread: 1, inboxFolder: "GENERAL")
        let quiet = Inbox.foldersMenu(try Self.realRooms(), scope: .all, accounts: accounts, logins: bothLogins, seen: [:])
        XCTAssertEqual(quiet.items.map(quiet.subtitle), [nil, nil, nil])
        let busy = Inbox.foldersMenu(Self.debugRequests() + [general], scope: .all, accounts: accounts, logins: bothLogins,
                                     seen: ["": Self.nowMS])  // looked at: no badge for them, still waiting
        XCTAssertEqual(busy.items.map(busy.subtitle), ["1 unread", "3 waiting", nil])
        let tamo = Inbox.foldersMenu(Self.debugRequests(), scope: .account(Fixture.tamoLogin), accounts: accounts,
                                       logins: bothLogins, seen: [:])
        XCTAssertEqual(tamo.items.map(tamo.subtitle), ["2 waiting", nil])
    }

    /// VoiceOver: the button says what its badge counts; the card names who's waiting (review §c).
    func testFoldersAndCardAccessibilityLabels() throws {
        let accounts = try XCTUnwrap(Fixture.whoami("provisioning_whoami_m8").logins)
        let general = try Self.portal("!g", receiver: Fixture.kivoLogin, unread: 1, inboxFolder: "GENERAL")
        let label = { (rooms: [Room], seen: [String: Int64]) in
            Inbox.foldersMenu(rooms, scope: .all, accounts: accounts, logins: self.bothLogins, seen: seen).accessibilityLabel
        }
        XCTAssertEqual(label(try Self.realRooms(), [:]), "Folders")
        XCTAssertEqual(label(Self.debugRequests(), [:]), "Folders, 3 new requests")
        XCTAssertEqual(label(Self.debugRequests() + [general], [Fixture.tamoLogin: Self.nowMS]), "Folders, 1 new request, 1 unread in General")

        XCTAssertEqual(Inbox.requestsCardTitle(count: 1), "1 message request")
        XCTAssertEqual(Inbox.requestsCardTitle(count: 2), "2 message requests")
        XCTAssertEqual(Inbox.requestsCardLabel(names: ["Lena Ortiz", "crypto.wins.daily"]),
                       "2 message requests, from Lena Ortiz and crypto.wins.daily. Opens Requests.")
        XCTAssertEqual(Inbox.requestsCardLabel(names: ["Kestrel Bikes", "Lena Ortiz", "crypto.wins.daily"]),
                       "3 message requests, from Kestrel Bikes, Lena Ortiz and crypto.wins.daily. Opens Requests.")
    }

    // MARK: Request privacy rule (PLAN §2.8)

    func testReceiptsAndTypingNeverAllowedInRequests() throws {
        XCTAssertFalse(Inbox.allowsReceipts(try Self.portal("!req", receiver: Fixture.tamoLogin, request: true)))
        XCTAssertTrue(Inbox.allowsReceipts(try RoomTests.room(Fixture.tamoRoom)))
        XCTAssertFalse(Inbox.allowsReceipts(Room(id: "!unknown")))  // no bridge info yet: don't risk a "Seen"
    }

    // MARK: Demo data (FERRY_DEBUG_DEMO: the README's screenshots, a public repo)

    /// Made-up accounts with no cookies (never connected, C8) and no profile picture, personal first; four fixture DMs
    /// in the main list, spread over both accounts, with our own messages as ours.
    func testDemoDataIsMadeUp() throws {
        let sessions = DebugFixtures.demoSessions
        XCTAssertTrue(sessions.values.allSatisfy { $0.cookies.isEmpty })
        let logins = sessions.keys.sorted().map { IGAdapter.login(account: $0, viewer: sessions[$0]?.viewer, state: "CONNECTED", since: Self.now) }
        XCTAssertEqual(logins.map(\.id), [Fixture.tamoLogin, Fixture.kivoLogin])
        XCTAssertEqual(logins.map(\.isProfessional), [false, true])
        XCTAssertEqual(logins.map(\.displayName), ["Tamo Veska", "Kivo Studio"])
        XCTAssertEqual(logins.map(\.profile?.avatar), [nil, nil])
        XCTAssertEqual(AccountIdentity.withDefaults([:], for: logins)[Fixture.tamoLogin]?.name, "Tamo Veska")

        let rooms = DebugFixtures.demoRooms(logins: logins.map(\.id), me: Fixture.me, now: Self.now)
        XCTAssertEqual(rooms.count, 4)
        XCTAssertTrue(rooms.allSatisfy { DebugFixtures.isFixtureRoom($0.id) })
        XCTAssertEqual(Inbox.rooms(rooms, scope: .all, folder: .chats, logins: bothLogins).map(\.name),
                       ["Noor Haddad", "Harbor Coffee", "Jonas Berg", "Elena Rossi"])  // newest first
        XCTAssertEqual(Inbox.rooms(rooms, scope: .account(Fixture.kivoLogin), folder: .chats, logins: bothLogins).map(\.name),
                       ["Harbor Coffee", "Elena Rossi"])
        let noor = try XCTUnwrap(rooms.first)
        XCTAssertEqual(Inbox.preview(of: noor, me: Fixture.me)?.text, "Perfect, I'll book a table")
        XCTAssertEqual(noor.events.filter { $0.sender == Fixture.me }.count, 1)
    }

    // MARK: Identity defaults

    func testDefaultIdentitiesFollowPaletteOrder() throws {
        let logins = try XCTUnwrap(Fixture.whoami().logins)
        let ids = AccountIdentity.withDefaults([:], for: logins)
        XCTAssertEqual(ids[Fixture.tamoLogin], AccountIdentity(name: "Tamo Veska", color: .ocean, mark: "T", order: 0))
        XCTAssertEqual(ids[Fixture.kivoLogin], AccountIdentity(name: "Kivo Studio", color: .ember, mark: "K", order: 1))
    }

    func testDefaultsKeepExistingAndAvoidTakenColorAndMark() throws {
        let logins = try XCTUnwrap(Fixture.whoami().logins)
        let mine = AccountIdentity(name: "Studio", color: .ocean, mark: "K", order: 5)
        let ids = AccountIdentity.withDefaults([Fixture.tamoLogin: mine], for: logins)
        XCTAssertEqual(ids[Fixture.tamoLogin], mine)
        // "K" is taken, so the next distinct letter of "Kivo Studio"; Ocean is taken, so Ember.
        XCTAssertEqual(ids[Fixture.kivoLogin], AccountIdentity(name: "Kivo Studio", color: .ember, mark: "I", order: 6))
    }

    func testDuplicateDisplayNameFallsBackToUsername() throws {
        var logins = try XCTUnwrap(Fixture.whoami().logins)
        logins[1].profile?.name = "Tamo Veska"
        let ids = AccountIdentity.withDefaults([:], for: logins)
        XCTAssertEqual(ids[Fixture.kivoLogin]?.name, "kivostudio")
    }

    // MARK: Row preview

    func testPreviewFromRealRooms() throws {
        // The last message in both real rooms is the backfilled reel (an m.image with a /reel/ external_url).
        let incoming = Inbox.preview(of: try RoomTests.room(Fixture.tamoRoom), me: Fixture.me)
        XCTAssertEqual(incoming, Inbox.Preview(symbol: "play.rectangle.on.rectangle", text: "Sent a reel"))
        let own = Inbox.preview(of: try RoomTests.room(Fixture.kivoRoom), me: Fixture.me)
        XCTAssertEqual(own?.text, "You sent a reel")
    }

    func testPreviewText() throws {
        let room = try Self.portal("!p", receiver: Fixture.tamoLogin)
        room.apply(JoinedRoom(timeline: .init(events: [Event.message("$1", ts: 9, sender: Fixture.me, body: "see you\nthere")], limited: false)))
        XCTAssertEqual(Inbox.preview(of: room, me: Fixture.me), Inbox.Preview(symbol: nil, text: "You: see you there"))
        room.apply(JoinedRoom(timeline: .init(events: [Event.message("$2", ts: 10, msgtype: "m.image")], limited: false)))
        XCTAssertEqual(Inbox.preview(of: room, me: Fixture.me), Inbox.Preview(symbol: "photo", text: "Photo"))
        XCTAssertNil(Inbox.preview(of: Room(id: "!empty"), me: Fixture.me))
    }

    /// M3 had its own media wording and showed reply fallbacks ("> <@…> …") verbatim; it now shares the thread's
    /// classifier and body.
    func testReplyPreviewStripsTheFallback() throws {
        let room = try Self.portal("!p", receiver: Fixture.tamoLogin)
        room.apply(JoinedRoom(timeline: .init(events: [
            Event.message("$r", ts: 9, sender: Fixture.kivoGhost, body: "> <@x> hi\n\nhello back",
                          extra: ["m.relates_to": ["m.in_reply_to": ["event_id": "$m!p"]]]),
        ], limited: false)))
        XCTAssertEqual(Inbox.preview(of: room, me: Fixture.me), Inbox.Preview(symbol: nil, text: "hello back"))
    }

    func testGroupPreviewNamesTheSender() throws {
        let group = try Self.portal("!g", receiver: Fixture.tamoLogin, group: true)
        group.apply(JoinedRoom(timeline: .init(events: [
            Event.state("m.room.member", ["membership": "join", "displayname": "Theo Park"], key: "@instagram_9:igm.home.arpa"),
            Event.message("$v", ts: 20, sender: "@instagram_9:igm.home.arpa", msgtype: "m.audio", extra: ["org.matrix.msc3245.voice": [:]]),
        ], limited: false)))
        XCTAssertEqual(Inbox.preview(of: group, me: Fixture.me), Inbox.Preview(symbol: "waveform", text: "Theo: Voice message"))
    }

    // MARK: Time and banners

    func testTimeLabel() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_900_000)  // 2026-10-13 ~13:20 UTC
        let ms = { (date: Date) in Int64(date.timeIntervalSince1970 * 1000) }
        XCTAssertEqual(Inbox.timeLabel(ms(now.addingTimeInterval(-86_400)), now: now, calendar: calendar), "Yesterday")
        XCTAssertNotEqual(Inbox.timeLabel(ms(now.addingTimeInterval(-3 * 86_400)), now: now, calendar: calendar), "Yesterday")
        XCTAssertNotEqual(Inbox.timeLabel(ms(now.addingTimeInterval(-60)), now: now, calendar: calendar), "Yesterday")
    }

    func testHealthFromWhoamiState() throws {
        XCTAssertEqual(try XCTUnwrap(Fixture.whoami().logins).map(\.health), [.connected, .connected])
        XCTAssertEqual(Self.login("BAD_CREDENTIALS").health, .needsLogin)
        XCTAssertEqual(Self.login("LOGGED_OUT").health, .needsLogin)
        XCTAssertEqual(Self.login("BACKFILLING").health, .syncing)
        XCTAssertEqual(Self.login("TRANSIENT_DISCONNECT").health, .connecting)  // just seen: not news yet
        XCTAssertEqual(Self.login("UNKNOWN_ERROR", message: "boom").health, .error("boom"))
        XCTAssertEqual(Self.login("CONNECTING").health, .connecting)
        XCTAssertEqual(Self.login("SOMETHING_NEW").health, .error(nil))
    }

    func testBannerPriority() {
        let ok = Self.login("CONNECTED"), out = Self.login("BAD_CREDENTIALS", id: "1"), out2 = Self.login("LOGGED_OUT", id: "2")
        XCTAssertNil(Inbox.banner(syncFailures: 1, accounts: [ok]))  // one blip isn't news
        XCTAssertEqual(Inbox.banner(syncFailures: 2, accounts: [out]), .offline)  // the network first: nothing else can be known
        XCTAssertEqual(Inbox.banner(syncFailures: 0, accounts: [ok, out]), .account("1"))
        XCTAssertEqual(Inbox.banner(syncFailures: 0, accounts: [out, out2]), .accounts(2))
        XCTAssertNil(Inbox.banner(syncFailures: 0, accounts: [Self.login("CONNECTING")]))
        XCTAssertNil(Inbox.banner(syncFailures: 0, accounts: [Self.login("BACKFILLING")]))
        XCTAssertEqual(Inbox.banner(syncFailures: 0, accounts: [Self.login("UNKNOWN_ERROR", id: "3")]), .account("3"))
    }

    /// PLAN §2.10: a TRANSIENT_DISCONNECT is a quiet spinner, and a banner only once it has lasted over 2 minutes.
    func testTransientDisconnectRaisesABannerAfterTwoMinutes() {
        let now = Date(timeIntervalSince1970: 1_791_900_000)
        var login = Self.login("TRANSIENT_DISCONNECT", id: "7")
        login.transientSince = now.addingTimeInterval(-119)
        XCTAssertEqual(login.health(at: now), .connecting)
        XCTAssertNil(Inbox.banner(syncFailures: 0, accounts: [login], now: now))
        login.transientSince = now.addingTimeInterval(-121)
        XCTAssertEqual(login.health(at: now), .reconnecting)
        XCTAssertEqual(Inbox.banner(syncFailures: 0, accounts: [login], now: now), .account("7"))
    }

    /// DESIGN A3: "Personal and Band keep working." names the other connected accounts.
    func testReloginNamesTheAccountsThatKeepWorking() {
        XCTAssertNil(Inbox.othersKeepWorking([]))
        XCTAssertEqual(Inbox.othersKeepWorking(["Personal"]), "Personal keeps working.")
        XCTAssertEqual(Inbox.othersKeepWorking(["Personal", "Band"]), "Personal and Band keep working.")
        XCTAssertEqual(Inbox.othersKeepWorking(["A", "B", "C"]), "A, B and C keep working.")
    }

    // MARK: Helpers

    static func realRooms() throws -> [Room] {
        try XCTUnwrap(Fixture.sync().rooms?.join).keys.sorted().map { try RoomTests.room($0) }
    }

    /// A portal derived from the real DM `m.bridge` event. Request and group variants are hand-made because these
    /// accounts have neither (S6, S7.6).
    static func portal(_ id: String, receiver: String, request: Bool = false, group: Bool = false, ts: Int64 = 1000,
                       unread: Int = 0, tags: JSON = [:], inboxFolder: String? = nil) throws -> Room {
        var bridge = try Fixture.event("state_bridge_dm")
        bridge.content = bridge.content.setting(["channel", "fi.mau.receiver"], .string(receiver))
        if request { bridge.content = bridge.content.setting(["channel", "com.beeper.message_request"], true) }
        if let inboxFolder { bridge.content = bridge.content.setting(["channel", BridgeInfo.inboxFolderKey], .string(inboxFolder)) }
        if group {
            bridge.content = bridge.content.setting(["com.beeper.room_type"], nil).setting(["com.beeper.room_type.v2"], nil)
        }
        let room = Room(id: id)
        room.apply(JoinedRoom(
            state: EventList(events: [bridge]),
            timeline: .init(events: [Event.message("$m\(id)", ts: ts)], limited: false, prevBatch: "p"),
            accountData: EventList(events: [Event(type: "m.tag", content: ["tags": tags])]),
            unreadNotifications: .init(notificationCount: unread, highlightCount: 0)))
        return room
    }

    /// A portal with its own `m.room.name` (the DM fixture's channel name is the same for every portal).
    /// The real DM `m.bridge` as the patched bridge re-sends it after a move: `FillPortalBridgeInfo` copies the
    /// delta's `ig_inbox_folder` into the channel (server/bridge/inbox-folder.patch).
    static func bridgeAfterMove(_ delta: JSON, receiver: String) throws -> Event {
        var bridge = try Fixture.event("state_bridge_dm")
        bridge.content = bridge.content.setting(["channel", "fi.mau.receiver"], .string(receiver))
            .setting(["channel", BridgeInfo.inboxFolderKey], try XCTUnwrap(delta["ig_inbox_folder"]))
        return bridge
    }

    static func named(_ id: String, _ name: String, receiver: String, request: Bool = false, ts: Int64 = 1000,
                      tags: JSON = [:], inboxFolder: String? = nil) throws -> Room {
        let room = try portal(id, receiver: receiver, request: request, ts: ts, tags: tags, inboxFolder: inboxFolder)
        room.apply(JoinedRoom(state: EventList(events: [Event.state("m.room.name", ["name": .string(name)])])))
        return room
    }

    static func login(_ state: String, id: String = "0", message: String? = nil) -> BridgeAPI.Login {
        BridgeAPI.Login(id: id, name: nil, profile: nil, state: .init(stateEvent: state, message: message))
    }
}
