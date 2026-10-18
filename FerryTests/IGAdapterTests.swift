import XCTest
@testable import Ferry

/// `IGAdapter` on P0's captures (`ig_*.json`, docs/PLAN-core.md P0): Instagram's threads, messages and deltas become
/// the rooms and events the app already shows, one rule per test.
final class IGAdapterTests: XCTestCase {
    private let tamo = Fixture.tamoLogin, kivo = Fixture.kivoLogin
    private let me = IGAdapter.me

    private func login(_ name: String) throws -> IG.Login { try Fixture.ig(IG.Login.self, name) }

    private func dm(_ login: IG.Login) throws -> IG.Thread {
        try XCTUnwrap(login.mailbox?.threadsByFolder?.nodes.first?.asIgDirectThread)
    }

    /// The DM after P0's script, as `IGThread` returned it (tamoveska's side).
    private func thread() throws -> IG.Thread {
        try XCTUnwrap(Fixture.ig(IG.ThreadResponse.self, "ig_thread_tamo").getSlideThreadNullable?.asIgDirectThread)
    }

    private func room(_ thread: IG.Thread, account: String, viewer: IG.Viewer? = nil) -> Room {
        let snapshot = IGAdapter.room(thread, account: account, viewer: viewer)
        let room = Room(id: snapshot.id)
        room.ownUserID = me
        IGAdapter.apply(snapshot, to: room)
        return room
    }

    private func deltas() throws -> [IG.Delta] {
        try Fixture.ig([IG.Event].self, "ig_events_tamo").compactMap(\.delta)
    }

    func testLoginAndAccount() throws {
        let tamoLogin = try login("ig_login_tamo"), kivoLogin = try login("ig_login_kivo")
        XCTAssertEqual(tamoLogin.account, tamo)
        XCTAssertEqual(tamoLogin.viewer.username, "tamoveska")
        XCTAssertEqual(tamoLogin.viewer.isProfessionalAccount, false)
        let account = IGAdapter.login(account: kivo, viewer: kivoLogin.viewer, state: "CONNECTED", since: .now)
        XCTAssertTrue(account.isProfessional)
        XCTAssertEqual(account.profile?.username, "kivostudio")
        XCTAssertEqual(account.displayName, "Kivo Studio")
        XCTAssertEqual(account.health, .connected)
        let reconnecting = IGAdapter.login(account: kivo, viewer: kivoLogin.viewer, state: "TRANSIENT_DISCONNECT", since: .now,
                                           transientSince: .now.addingTimeInterval(-300))
        XCTAssertEqual(reconnecting.health, .reconnecting)
    }

    /// One Instagram thread seen by both dummies is two chats, each in its own account's scope (as `split_portals`).
    func testTheDummiesDMIsOneChatPerAccount() throws {
        let tamoLogin = try login("ig_login_tamo"), kivoLogin = try login("ig_login_kivo")
        let a = room(try dm(tamoLogin), account: tamo, viewer: tamoLogin.viewer)
        let b = room(try dm(kivoLogin), account: kivo, viewer: kivoLogin.viewer)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.bridge?.receiver, tamo)
        XCTAssertEqual(b.bridge?.receiver, kivo)
        XCTAssertEqual(a.bridge?.isDM, true)
        XCTAssertEqual(a.bridge?.channelID, kivo)  // the other person, here our other account
        XCTAssertEqual(a.name, "Kivo Studio")
        XCTAssertEqual(b.name, "Tamo Veska")
        XCTAssertEqual(Inbox.folder(of: a), .chats)
        XCTAssertEqual(Inbox.rooms([a, b], scope: .account(tamo), folder: .chats, logins: [tamo, kivo]).map(\.id), [a.id])
        XCTAssertEqual(Inbox.rooms([a, b], scope: .all, folder: .chats, logins: [tamo]).map(\.id), [a.id])  // a removed account's chats hide
        let accounts = [tamoLogin, kivoLogin].map { IGAdapter.login(account: $0.account, viewer: $0.viewer, state: "CONNECTED", since: .now) }
        XCTAssertEqual(Inbox.contactHandle(a, accounts: accounts), "kivostudio")
    }

    /// Names and @handles come with the thread: no profile lookups, no localparts.
    func testPeopleCarryNamesAndHandles() throws {
        let snapshot = IGAdapter.room(try dm(try login("ig_login_tamo")), account: tamo, viewer: nil)
        let contact = IGAdapter.user(kivo)
        XCTAssertEqual(snapshot.profiles[contact]?.handle, "kivostudio")
        XCTAssertEqual(snapshot.profiles[contact]?.name, "Kivo Studio")
        let room = room(try dm(try login("ig_login_tamo")), account: tamo)
        XCTAssertEqual(Inbox.contactUserID(room, me: me), contact)
        XCTAssertEqual(room.displayName(of: contact), "Kivo Studio")
        XCTAssertNotNil(room.avatarURL)  // the contact's picture, a CDN link
        XCTAssertEqual(Inbox.memberCount(of: room), 2)
    }

    /// Instagram's folders (P0): `system_folder` PENDING/SPAM is a request, `folder` GENERAL is General.
    func testRequestsAndGeneralComeFromTheFolders() throws {
        var thread = try dm(try login("ig_login_kivo"))
        XCTAssertEqual(room(thread, account: kivo).bridge?.folder, .primary)
        thread.folder = "GENERAL"
        XCTAssertEqual(Inbox.folder(of: room(thread, account: kivo)), .general)
        thread.folder = "PRIMARY"
        thread.systemFolder = "PENDING"
        let request = room(thread, account: kivo)
        XCTAssertEqual(Inbox.folder(of: request), .requests)
        XCTAssertFalse(Inbox.allowsReceipts(request))  // opening it must send nothing
        thread.systemFolder = "SPAM"
        XCTAssertTrue(Inbox.isRequest(room(thread, account: kivo)))
    }

    /// `IGThread` answers with no tab (P0's thread capture): a re-read of a General chat keeps it in General.
    func testARereadKeepsTheTab() throws {
        let reread = try thread()
        XCTAssertEqual(reread.folder, "")
        var listed = try dm(try login("ig_login_tamo"))
        listed.folder = "GENERAL"
        let general = room(listed, account: tamo)
        XCTAssertEqual(Inbox.folder(of: room(IGAdapter.keepingFolder(reread, of: general), account: tamo)), .general)
        XCTAssertEqual(IGAdapter.keepingFolder(reread, of: nil).folder, "")  // a new thread: Instagram's default
        listed.folder = "PRIMARY"  // a listing always wins
        XCTAssertEqual(IGAdapter.keepingFolder(listed, of: general).folder, "PRIMARY")
    }

    /// Unread: the newest message is someone else's and newer than our read watermark, or the chat is marked unread.
    func testUnreadIsAnIncomingMessagePastOurWatermark() throws {
        var thread = try thread()
        XCTAssertFalse(room(thread, account: tamo).isUnread)  // the newest is our own
        XCTAssertTrue(room(thread, account: kivo).isUnread)  // from the other side: kivostudio's watermark is older
        thread.markedAsUnread = true
        XCTAssertTrue(room(thread, account: tamo).isUnread)
    }

    func testTheThreadReducesToItsMessages() throws {
        let room = room(try thread(), account: tamo)
        let messages = Timeline.reduce(room, me: me)
        XCTAssertEqual(messages.count, 17)
        let back = try XCTUnwrap(messages.last)
        XCTAssertEqual(back.body, "P0 capture: back")
        XCTAssertTrue(back.isOwn)
        XCTAssertNil(back.reply)  // Instagram sends `replied_to_message_id: ""` on every message that isn't a reply
        XCTAssertFalse(back.isSeen)  // kivostudio hadn't read it when this was captured
        let edited = try XCTUnwrap(messages.first { $0.body == "P0 capture: a reply, edited" })
        XCTAssertTrue(edited.isEdited)
        XCTAssertFalse(edited.isOwn)
        XCTAssertEqual(edited.reactions, [Message.Reaction(key: "😂", senders: [me], myEventID: edited.reactions.first?.myEventID)])
        XCTAssertEqual(edited.reply?.kind, .unsent)  // its target was unsent: Instagram sends no quote, the quote says so
        XCTAssertTrue(messages.contains { $0.kind == .voice })
        XCTAssertTrue(messages.contains { $0.kind == .video })
        XCTAssertTrue(messages.contains { $0.kind == .viewOnce })
        XCTAssertEqual(Inbox.preview(of: room, me: me)?.text, "You: P0 capture: back")
    }

    /// "Reacted 😂 to your message" is a log entry for a reaction the message already shows: no row, no unread.
    func testReactionLogEntriesAreNotRows() throws {
        var thread = try thread()
        var log = try XCTUnwrap(thread.slideMessages?.edges?.first?.node)
        log.id = "mid.reactionlog"
        log.contentType = "REACTION_LOG_XMAT"
        log.senderFbid = kivo
        log.timestampMs = "1792172900000"
        thread.slideMessages?.edges?.insert(IG.Node(node: log), at: 0)  // newest first
        let room = room(thread, account: tamo)
        XCTAssertNil(room.events.first { $0.eventID == log.id })
        XCTAssertFalse(room.isUnread)
        XCTAssertEqual(Timeline.reduce(room, me: me).last?.body, "P0 capture: back")
    }

    /// Our own messages carry the offline threading ID we sent with, which clears the local echo.
    func testOwnMessagesCarryTheirOfflineThreadingID() throws {
        let room = room(try thread(), account: tamo)
        let back = try XCTUnwrap(room.events.last { $0.isBaseMessage })
        XCTAssertNotNil(back.unsigned?.transactionID)
        XCTAssertNil(room.events.first { $0.isBaseMessage && $0.sender != me }?.unsigned)
    }

    /// P0's send answer names the message, which the local echo's "sent" state keeps (`AppModel.deliver`).
    func testSendAnswerNamesTheMessage() throws {
        struct Responses: Decodable { var send: IG.SendResponse }
        let send = try Fixture.ig(Responses.self, "ig_responses").send
        XCTAssertEqual(send.xigDirectTextSendWithSlideMessagingResponse?.id, "mid.$cAAAy8NQIKzyndxflxGhRdKarJRAq")
    }

    func testOlderPagesPrependUntilTheStart() throws {
        let room = room(try thread(), account: tamo)
        let token = try XCTUnwrap(room.prevBatch)
        XCTAssertNotEqual(token, IGAdapter.startToken)
        let oldest = try XCTUnwrap(room.events.first { $0.isBaseMessage }?.originServerTS)
        let older = try Fixture.ig(IG.OlderResponse.self, "ig_older_tamo").fetchSlidethread?.asIgDirectThread
        room.prepend(IGAdapter.page(older, account: tamo), from: token)
        XCTAssertGreaterThan(Timeline.reduce(room, me: me).count, 17)
        XCTAssertLessThan(try XCTUnwrap(room.events.first { $0.isBaseMessage }?.originServerTS), oldest)
        XCTAssertTrue(room.reachedStart)  // that page is the rest of the dummies' DM: Instagram reports nothing older

        var last = try thread()
        last.slideMessages?.pageInfo?.hasNextPage = false
        XCTAssertEqual(self.room(last, account: tamo).prevBatch, IGAdapter.startToken)  // nothing older: the chat's start
    }

    /// A GIF from the other dummy (live, after P7: Instagram turned an uploaded GIF into one): its WebP, marked so the
    /// card plays it; this one came with no still preview.
    func testAGIFIsAnAnimatedImage() throws {
        let delta = try XCTUnwrap(Fixture.ig(IG.Event.self, "ig_event_gif_kivo").delta)
        let event = try XCTUnwrap(IGAdapter.update(delta, account: kivo)?.timeline?.events?.first)
        XCTAssertEqual(MessageKind(type: event.type, content: event.content), .gif)
        let info = MediaInfo(content: event.content)
        XCTAssertEqual(info.url, "https://scontent.example.invalid/v/g001.webp")
        XCTAssertEqual(info.mimetype, "image/webp")
        XCTAssertEqual([info.width, info.height], [240, 240])
        XCTAssertNil(info.thumbnailURL)
        XCTAssertEqual(MessageKind.gif.media?.label, "GIF")

        // The mailbox's copy (live): no media, still a GIF, so the inbox says so; opening the chat reads the rest.
        var bare = try XCTUnwrap(delta.message)
        bare.content = ["animated_media": .null]
        let content = IGAdapter.content(bare)
        XCTAssertEqual(MessageKind(type: "m.room.message", content: content), .gif)
        XCTAssertNil(MediaInfo(content: content).url)
    }

    /// Three photos sent at once from the Instagram app (live 2026-10-18): one message with every photo, in order,
    /// so it keeps one menu, one row of reactions and one unsend. Ferry showed only the first.
    func testPhotosSentTogetherAreOneMessageWithAll() throws {
        let photos = try Fixture.ig(IG.Message.self, "ig_message_photos_tamo")
        let messages = Timeline.reduce(IGAdapter.events(photos, account: tamo), me: me)
        XCTAssertEqual(messages.count, 1)
        let info = MediaInfo(content: try XCTUnwrap(messages.first).content)
        XCTAssertEqual(messages.first?.kind, .image)
        XCTAssertEqual(info.url, "https://scontent.example.invalid/v/f040.jpg")  // the first: inbox, quotes
        XCTAssertEqual(info.album.map { MediaInfo(content: $0).url }, (0..<3).map { "https://scontent.example.invalid/v/f0\(40 + 2 * $0).jpg" })
        XCTAssertEqual(info.album.map { MessageKind(type: "m.room.message", content: $0) }, [.image, .image, .image])
        XCTAssertEqual(MediaInfo(content: info.album[2]).aspect, 468.0 / 750)

        // The mailbox's copy (live): no attachments, still a photo, and no album to stack.
        var bare = photos
        bare.content = ["attachments": .null]
        XCTAssertEqual(MessageKind(type: "m.room.message", content: IGAdapter.content(bare)), .image)
        XCTAssertTrue(MediaInfo(content: IGAdapter.content(bare)).album.isEmpty)

        // Photos and videos together (upstream's `ordered_photo_video_attachments`, not seen live): each item says which.
        var mixed = photos
        mixed.contentType = "MULTIMEDIA"  // a guess; the content's field decides
        mixed.content = ["ordered_photo_video_attachments": [
            photos.content?["attachments"]?.array?.first ?? .null,
            ["__typename": "XFBSlideVideoAttachment", "attachment_cdn_url": "https://scontent.example.invalid/v/f046.mp4",
             "preview_cdn_url": "https://scontent.example.invalid/v/f047.jpg", "preview_width": 360, "preview_height": 640],
        ]]
        let album = MediaInfo(content: IGAdapter.content(mixed)).album
        XCTAssertEqual(album.map { MessageKind(type: "m.room.message", content: $0) }, [.image, .video])
        XCTAssertEqual(MediaInfo(content: album[1]).thumbnailURL, "https://scontent.example.invalid/v/f047.jpg")
    }

    /// Instagram's own lines (upstream's `SlideMessageAdminText`, `text_fragments`; none captured: a group needs three
    /// people) and content the app doesn't know are lines across the thread, never a bubble saying "not supported".
    func testChatEventsAndUnknownContentAreLines() throws {
        func message(_ id: String, _ sender: String, _ type: String, _ content: JSON, at ms: Int64) throws -> [Event] {
            let json = try JSONEncoder().encode(JSON.object(["id": .string(id), "sender_fbid": .string(sender), "content_type": .string(type),
                                                             "timestamp_ms": .string(String(ms)), "igd_snippet": "", "content": content,
                                                             "text_body": content["text_body"] ?? .null]))
            return IGAdapter.events(try IG.decode(IG.Message.self, json), account: tamo)
        }
        let renamed: JSON = ["text_fragments": [["plaintext": "Kivo", "link_fragment": ["uri": "instagram://user?username=kivostudio"]],
                                                ["plaintext": " named the group Weekend", "link_fragment": .null]]]
        let events = try message("mid.1", kivo, "TEXT", ["text_body": "hi"], at: 1_000) + message("mid.1b", kivo, "TEXT", ["text_body": "there"], at: 1_100)
            + message("mid.2", kivo, "ACTION_LOG", renamed, at: 2_000)  // a made-up type: the content's fields decide
            + message("mid.3", kivo, "SOMETHING_NEW", ["__typename": "SlideMessageSomethingNewContent"], at: 3_000)
            + message("mid.4", kivo, "POLL_XMAT", ["__typename": "SlideMessagePollContent"], at: 4_000)  // a guess at a poll
            + message("mid.5", tamo, "TEXT", ["text_body": "mine"], at: 5_000)
            + message("mid.6", tamo, "ACTION_LOG", ["text_fragments": [["plaintext": "You left the group"]]], at: 6_000)
            + message("mid.7", tamo, "ACTION_LOG", ["text_fragments": []], at: 7_000)  // nothing to say: can't show it
        let messages = Timeline.reduce(events, me: me, receipts: [IGAdapter.user(kivo): .init(eventID: "mid.7", ts: 7_000)])
        XCTAssertEqual(messages.map(\.kind), [.text, .text, .event, .unsupported("a message Ferry can't show"), .unsupported("a poll"),
                                              .text, .event, .unsupported("a message Ferry can't show")])
        XCTAssertEqual(messages[2].body, "Kivo named the group Weekend")
        XCTAssertEqual(messages.filter(\.isSeen).map(\.id), ["mid.5"])  // "Seen" stays on our last real message

        // In a group: a line takes no sender name or avatar, and splits the run it lands in.
        let rows = Timeline.layout(messages, isGroup: true)
        XCTAssertEqual(rows.map { $0.groupSender != nil }, [true, true, false, false, false, false, false, false])
        XCTAssertEqual(rows[1].position, .last)

        // The inbox: an event names who did it; what the app can't show says who sent what.
        func preview(_ count: Int) -> String? {
            let room = Room(id: "!ig-test")
            room.apply(JoinedRoom(timeline: .init(events: Array(events.prefix(count)), limited: false)))
            return Inbox.preview(of: room, me: me)?.text
        }
        XCTAssertEqual(preview(3), "Kivo named the group Weekend")
        XCTAssertEqual(preview(5), "Sent a poll")
        XCTAssertEqual(preview(8), "You sent a message Ferry can't show")
    }

    func testLiveMessagesReadsAndReceipts() throws {
        let deltas = try deltas()
        let room = room(try thread(), account: tamo)
        let incoming = try XCTUnwrap(deltas.first { $0.typename == "SlideUQPPNewMessage" })
        room.apply(try XCTUnwrap(IGAdapter.update(incoming, account: tamo)))
        XCTAssertTrue(room.isUnread)
        XCTAssertEqual(room.lastMessage?.eventID, incoming.message?.id)
        room.apply(try XCTUnwrap(IGAdapter.update(try XCTUnwrap(deltas.first { $0.typename == "SlideUQPPMarkRead" }), account: tamo)))
        XCTAssertFalse(room.isUnread)  // read here or on another device

        let own = try XCTUnwrap(deltas.last { $0.typename == "SlideUQPPNewMessage" })
        let update = try XCTUnwrap(IGAdapter.update(own, account: tamo))
        XCTAssertEqual(update.timeline?.events?.first?.unsigned?.transactionID, own.message?.offlineThreadingId)
        XCTAssertEqual(update.unreadNotifications?.notificationCount, 0)
        room.apply(update)
        // kivostudio read it on another device three minutes later: "Seen" on our message.
        let seen = try XCTUnwrap(deltas.last { $0.typename == "SlideUQPPReadReceipt" })
        room.apply(try XCTUnwrap(IGAdapter.receipt(seen, account: tamo, events: room.events)))
        XCTAssertEqual(room.receipts[IGAdapter.user(kivo)]?.eventID, own.message?.id)
        XCTAssertTrue(Timeline.reduce(room, me: me).last?.isSeen == true)
    }

    /// P0's run replayed live on tamoveska's chat as the mailbox had it before: kivostudio's text and its reply
    /// (with the quoted message), our ❤️ then 😂, the edit, the unsend, our "Seen", our reply and their "Seen".
    func testP0RunReplaysLive() throws {
        let room = room(try dm(try login("ig_login_tamo")), account: tamo)
        let deltas = try deltas()
        let sent = deltas.filter { $0.typename == "SlideUQPPNewMessage" }.compactMap(\.message?.id)
        XCTAssertEqual(sent.count, 3)
        let outcomes = deltas.map { IGAdapter.apply($0, account: tamo, to: room) }
        XCTAssertFalse(outcomes.contains(.refresh))  // both reaction deletes name the ❤️ added in this run

        let messages = Timeline.reduce(room, me: me)
        XCTAssertEqual(messages.first { $0.eventID == sent[0] }?.kind, .unsent)
        let reply = try XCTUnwrap(messages.first { $0.eventID == sent[1] })
        XCTAssertEqual(reply.body, "P0 capture: a reply, edited")
        XCTAssertTrue(reply.isEdited)
        XCTAssertEqual(reply.reactions.map(\.key), ["😂"])
        XCTAssertEqual(reply.reactions.first?.senders, [me])
        XCTAssertEqual(reply.reply?.eventID, sent[0])
        XCTAssertNotNil(room.related[sent[0]])  // the quoted message came with the reply
        let back = try XCTUnwrap(messages.last)
        XCTAssertEqual(back.eventID, sent[2])
        XCTAssertTrue(back.isSeen)
        XCTAssertFalse(room.isUnread)
    }

    /// Their newest message makes the chat unread; when they unsend it and ours is newest again, it's read.
    func testUnsendingTheUnreadMessageReadsTheChat() throws {
        let room = room(try thread(), account: tamo)
        let incoming = try XCTUnwrap(try deltas().first { $0.typename == "SlideUQPPNewMessage" })
        XCTAssertEqual(IGAdapter.apply(incoming, account: tamo, to: room), .applied)
        XCTAssertTrue(room.isUnread)
        var unsend = try XCTUnwrap(try deltas().first { $0.typename == "SlideUQPPDeleteMessage" })
        unsend.messageId = incoming.message?.id
        XCTAssertEqual(IGAdapter.apply(unsend, account: tamo, to: room), .applied)
        XCTAssertFalse(room.isUnread)
        XCTAssertEqual(room.lastMessage?.sender, me)
    }

    /// Primary ↔ General on Instagram, live: the raw move deltas Ferry captured (spike S5) move the chat here.
    func testMovesBetweenPrimaryAndGeneral() throws {
        let room = room(try dm(try login("ig_login_kivo")), account: kivo)
        let moves = try Fixture.ig([IG.Delta].self, "deltas_s5_ig_move_thread")
        XCTAssertEqual(moves.map(\.igInboxFolder), ["GENERAL", "PRIMARY"])
        XCTAssertEqual(IGAdapter.apply(moves[0], account: kivo, to: room), .applied)
        XCTAssertEqual(Inbox.folder(of: room), .general)
        XCTAssertEqual(IGAdapter.apply(moves[1], account: kivo, to: room), .applied)
        XCTAssertEqual(Inbox.folder(of: room), .chats)
    }

    /// A request accepted, or a thread deleted, on another device.
    func testFolderChangesAndDeletesFromElsewhere() throws {
        let room = room(try thread(), account: tamo)
        var delta = try XCTUnwrap(try deltas().first { $0.typename == "SlideUQPPMarkRead" })
        delta.typename = "SlideUQPPUpdateThreadFolder"
        XCTAssertEqual(IGAdapter.apply(delta, account: tamo, to: room), .refresh)
        delta.typename = "SlideUQPPDeleteThread"
        XCTAssertEqual(IGAdapter.apply(delta, account: tamo, to: room), .removed)
    }

    /// N1: a search result is a contact by FBID; someone we've never messaged gets a draft chat until the first message.
    func testSearchResultsAndDrafts() throws {
        let json = #"{"xfb_combinedIGSearchQuery":{"search_messenger_contact_v2":[{"interop_messaging_user_fbid":"17841400000000999","username":"sample.person","full_name":"Sample Person","pk":"4200000999","profile_pic_url":"https://scontent.example.invalid/v/f099.jpg","is_verified":false}]}}"#
        let result = try XCTUnwrap(IG.decode(IG.SearchResponse.self, Data(json.utf8)).xfbCombinedigsearchquery?.searchMessengerContactV2?.first)
        let contact = try XCTUnwrap(IGAdapter.contact(result))
        XCTAssertEqual(contact.id, "17841400000000999")
        XCTAssertEqual(contact.handle, "sample.person")
        XCTAssertEqual(contact.name, "Sample Person")

        let draft = IGAdapter.draft(account: tamo, contact: contact, viewer: nil)
        XCTAssertEqual(draft.id, IGAdapter.draftID(account: tamo, user: contact.id))
        let room = Room(id: draft.id)
        IGAdapter.apply(draft, to: room)
        XCTAssertEqual(room.bridge?.receiver, tamo)
        XCTAssertEqual(room.bridge?.channelID, contact.id)  // whom the first message goes to
        XCTAssertEqual(room.bridge?.isDM, true)
        XCTAssertEqual(room.name, "Sample Person")
        XCTAssertEqual(room.prevBatch, IGAdapter.startToken)
        XCTAssertEqual(draft.profiles[IGAdapter.user(contact.id)]?.handle, "sample.person")

        // Our existing DM is found by the other person's FBID, without asking Instagram.
        let dm = self.room(try dm(try login("ig_login_tamo")), account: tamo)
        XCTAssertEqual(Inbox.existingDM(with: kivo, account: tamo, in: [dm])?.id, dm.id)
        XCTAssertNil(Inbox.existingDM(with: contact.id, account: tamo, in: [dm]))
    }

    /// Shares (Instagram's XMA, shaped like P0's raw captures, with fictional authors): the bridge's content shapes,
    /// so the cards read them as before.
    func testSharesBecomeTheBridgesShapes() throws {
        func message(_ xma: JSON, snippet: String = "") throws -> IG.Message {
            let json = try JSONEncoder().encode(JSON.object(["id": "mid.share", "content_type": "MESSAGE_INLINE_SHARE", "igd_snippet": .string(snippet),
                                                             "sender_fbid": .string(kivo), "timestamp_ms": "1792172900000",
                                                             "content": ["xma": xma]]))
            return try IG.decode(IG.Message.self, json)
        }
        let preview: JSON = ["url": "https://scontent.example.invalid/v/f101.jpg", "width": 1080, "height": 1920]
        let reel = IGAdapter.content(try message(["header_title_text": "sample.travels", "preview_image": preview,
                                                  "target_url": "https://www.instagram.com/reel/DSampleRl01/", "target_id": "3400000000000000001"]))
        XCTAssertEqual(MessageKind(type: "m.room.message", content: reel), .share(.reel, .unresolved))  // "Load video"
        XCTAssertEqual(ShareCaption(content: reel).author, "sample.travels")
        XCTAssertEqual(MediaInfo(content: reel).previewURL, "https://scontent.example.invalid/v/f101.jpg")

        let post = IGAdapter.content(try message(["header_title_text": "sample.photos", "preview_image": preview, "title_text": "Golden hour",
                                                  "target_url": "https://www.instagram.com/p/DSamplePo01/", "target_id": "3400000000000000002"]))
        XCTAssertEqual(MessageKind(type: "m.room.message", content: post), .share(.post, .ready))
        XCTAssertEqual(ShareCaption(content: post).caption, "Golden hour")

        let link = IGAdapter.content(try message(["target_url": "https://example.com/article", "title_text": "An article", "preview_image": preview]))
        XCTAssertEqual(MessageKind(type: "m.room.message", content: link), .link)
        XCTAssertEqual(LinkPreview(content: link)?.title, "An article")

        let expired = IGAdapter.content(try message(["caption_body_text": "Story unavailable", "eyebrow_text": "Shared a story"]))
        XCTAssertEqual(expired["body"]?.string, "Story unavailable")

        // "Load video": the hidden edit swaps the card to the reel itself.
        let room = room(try thread(), account: tamo)
        let share = try message(["header_title_text": "sample.travels", "preview_image": preview,
                                 "target_url": "https://www.instagram.com/reel/DSampleRl01/", "target_id": "3400000000000000001"])
        room.apply(JoinedRoom(timeline: .init(events: IGAdapter.events(share, account: tamo), limited: false)))
        let before = try XCTUnwrap(Timeline.reduce(room, me: me).last)
        room.apply(JoinedRoom(timeline: .init(events: [IGAdapter.resolved(IG.Resolved(url: "https://scontent.example.invalid/v/f102.mp4", video: true,
                                                                                         width: 720, height: 1280, duration: 12.5), for: before)], limited: false)))
        let after = try XCTUnwrap(Timeline.reduce(room, me: me).last)
        XCTAssertEqual(after.kind, .share(.reel, .ready))
        XCTAssertFalse(after.isEdited)
        XCTAssertEqual(MediaInfo(content: after.content).url, "https://scontent.example.invalid/v/f102.mp4")
        XCTAssertEqual(MediaInfo(content: after.content).duration, 12_500)
        XCTAssertEqual(ShareCaption(content: after.content).author, "sample.travels")
    }

    /// A delete for a reaction this window never saw added (one from before this launch) re-reads the thread.
    func testUnknownReactionDeleteRereadsTheThread() throws {
        let room = room(try thread(), account: tamo)
        var delete = try XCTUnwrap(try deltas().first { $0.typename == "SlideUQPPDeleteReaction" })
        delete.reaction?.logMessageId = "mid.unknown"
        XCTAssertEqual(IGAdapter.apply(delete, account: tamo, to: room), .refresh)
        var join = delete
        join.typename = "SlideUQPPParticipantJoin"
        XCTAssertEqual(IGAdapter.apply(join, account: tamo, to: room), .refresh)
    }

    /// Our local echo's ID is what Instagram's web client sends (`GenerateEpochID`): the time, a counter, 42. The P0
    /// capture app's own sends came back with theirs.
    func testOfflineThreadingIDs() throws {
        let ms: Int64 = 1_792_172_845_304
        let id = try XCTUnwrap(Int64(IGAdapter.offlineThreadingID(ms: ms, counter: 3)))
        XCTAssertEqual(id >> 22, ms)
        XCTAssertEqual((id >> 12) & 0x3FF, 3)
        XCTAssertEqual(id & 0xFFF, 42)
        XCTAssertNotEqual(IGAdapter.offlineThreadingID(ms: ms, counter: 1), IGAdapter.offlineThreadingID(ms: ms, counter: 2))
        let echoed = try XCTUnwrap(try deltas().last { $0.typename == "SlideUQPPNewMessage" }?.message)
        XCTAssertEqual(Int64(try XCTUnwrap(echoed.offlineThreadingId)).map { $0 & 0xFFF }, 42)
    }

    func testTypingFillsAndClears() throws {
        let room = room(try thread(), account: tamo)
        room.apply(IGAdapter.typing([IGAdapter.user(kivo)]))
        XCTAssertEqual(room.typing, [IGAdapter.user(kivo)])
        room.apply(IGAdapter.typing([]))
        XCTAssertEqual(room.typing, [])
        // The notice names the thread by its long ID and the person by their Instagram user ID (P0).
        let typing = try Fixture.ig([IG.Event].self, "ig_events_tamo").first { $0.kind == "TypingNotification" }
        XCTAssertEqual(typing?.thread, try thread().threadId)
        XCTAssertEqual(typing?.typing?.senderId.map(String.init), try thread().users?.first?.id)
        XCTAssertEqual(typing?.typing?.activityStatus, 1)
    }
}
