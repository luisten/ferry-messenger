import XCTest
@testable import Ferry

/// The app's half of core/chat's tests: what the engine makes of P0's captures (`engine_*.json`, written by `go test
/// ./chat -update` from core/testdata/ig_*.json), applied as `AppModel` applies it, then read by `Timeline`, `Inbox`
/// and the cards. The engine's own rules (unread, folders, live changes, typing, IDs) are tested in Go.
final class EngineTests: XCTestCase {
    private let tamo = Fixture.tamoLogin, kivo = Fixture.kivoLogin
    private let me = IGAdapter.me

    private func room(_ updates: [IG.Update]) -> Room {
        let room = Room(id: updates.first?.room ?? "")
        room.ownUserID = me
        for update in updates { IGAdapter.apply(update, to: room) }
        return room
    }

    /// `IGLogin`'s answer and the chats it queued.
    private func login(_ name: String) throws -> (login: IG.Login, rooms: [IG.Update]) {
        struct Login: Decodable { var login: IG.Login }
        struct Rooms: Decodable { var rooms: [IG.Update] }
        return (try IG.decode(Login.self, Fixture.data("engine_login_\(name)")).login, try Fixture.engine(Rooms.self, "login_\(name)").rooms)
    }

    /// The DM after P0's script as `IGReadChat` makes it, as tamoveska's chat or (the same capture) kivostudio's.
    private func thread(_ account: String) throws -> Room {
        room([try XCTUnwrap(Fixture.engine([String: IG.Update].self, "thread_tamo")[account == tamo ? "tamo" : "kivo"])])
    }

    private func events(_ name: String, _ key: String) throws -> [Event] {
        try XCTUnwrap(Fixture.engine([String: [Event]].self, name)[key])
    }

    func testLoginAndAccount() throws {
        let tamoLogin = try login("tamo").login, kivoLogin = try login("kivo").login
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
        let tamoLogin = try login("tamo"), kivoLogin = try login("kivo")
        let a = room(tamoLogin.rooms), b = room(kivoLogin.rooms)
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
        let accounts = [tamoLogin.login, kivoLogin.login].map { IGAdapter.login(account: $0.account, viewer: $0.viewer, state: "CONNECTED", since: .now) }
        XCTAssertEqual(Inbox.contactHandle(a, accounts: accounts), "kivostudio")
    }

    /// Names and @handles come with the thread: no profile lookups, no localparts.
    func testPeopleCarryNamesAndHandles() throws {
        let update = try XCTUnwrap(login("tamo").rooms.first)
        let contact = IGAdapter.user(kivo)
        XCTAssertEqual(update.profiles?[contact]?.handle, "kivostudio")
        XCTAssertEqual(update.profiles?[contact]?.name, "Kivo Studio")
        let room = room([update])
        XCTAssertEqual(Inbox.contactUserID(room, me: me), contact)
        XCTAssertEqual(room.displayName(of: contact), "Kivo Studio")
        XCTAssertNotNil(room.avatarURL)  // the contact's picture, a CDN link
        XCTAssertEqual(Inbox.memberCount(of: room), 2)
    }

    /// Instagram's folders (P0): `system_folder` PENDING/SPAM is a request, `folder` GENERAL is General.
    func testRequestsAndGeneralComeFromTheFolders() throws {
        XCTAssertEqual(room(try login("kivo").rooms).bridge?.folder, .primary)
        let folders = try Fixture.engine([String: IG.Update].self, "folders_kivo")
        XCTAssertEqual(Inbox.folder(of: room([try XCTUnwrap(folders["general"])])), .general)
        let request = room([try XCTUnwrap(folders["pending"])])
        XCTAssertEqual(Inbox.folder(of: request), .requests)
        XCTAssertFalse(Inbox.allowsReceipts(request))  // opening it must send nothing
        XCTAssertTrue(Inbox.isRequest(room([try XCTUnwrap(folders["spam"])])))
    }

    func testTheThreadReducesToItsMessages() throws {
        let room = try thread(tamo)
        let messages = Timeline.reduce(room, me: me)
        XCTAssertEqual(messages.count, 17)
        let back = try XCTUnwrap(messages.last)
        XCTAssertEqual(back.body, "P0 capture: back")
        XCTAssertTrue(back.isOwn)
        XCTAssertNil(back.reply)  // Instagram sends `replied_to_message_id: ""` on every message that isn't a reply
        XCTAssertFalse(back.isSeen)  // kivostudio hadn't read it when this was captured
        XCTAssertNotNil(back.txnID)  // our offline threading ID, which clears the local echo
        let edited = try XCTUnwrap(messages.first { $0.body == "P0 capture: a reply, edited" })
        XCTAssertTrue(edited.isEdited)
        XCTAssertFalse(edited.isOwn)
        XCTAssertEqual(edited.reactions, [Message.Reaction(key: "😂", senders: [me], myEventID: edited.reactions.first?.myEventID)])
        XCTAssertEqual(edited.reply?.kind, .unsent)  // its target was unsent: Instagram sends no quote, the quote says so
        XCTAssertTrue(messages.contains { $0.kind == .voice })
        XCTAssertTrue(messages.contains { $0.kind == .video })
        XCTAssertTrue(messages.contains { $0.kind == .viewOnce })
        XCTAssertEqual(Inbox.preview(of: room, me: me)?.text, "You: P0 capture: back")
        XCTAssertFalse(room.isUnread)  // the newest is our own
        XCTAssertTrue(try thread(kivo).isUnread)  // from the other side: kivostudio's watermark is older
    }

    func testOlderPagesPrependUntilTheStart() throws {
        let room = try thread(tamo)
        let token = try XCTUnwrap(room.prevBatch)
        XCTAssertNotEqual(token, IGAdapter.startToken)
        let oldest = try XCTUnwrap(room.events.first { $0.isBaseMessage }?.originServerTS)
        room.prepend(try XCTUnwrap(Fixture.engine([String: MessagesPage].self, "older_tamo")["page"]), from: token)
        XCTAssertGreaterThan(Timeline.reduce(room, me: me).count, 17)
        XCTAssertLessThan(try XCTUnwrap(room.events.first { $0.isBaseMessage }?.originServerTS), oldest)
        XCTAssertTrue(room.reachedStart)  // that page is the rest of the dummies' DM: Instagram reports nothing older
    }

    /// A GIF from the other dummy (live, after P7: Instagram turned an uploaded GIF into one): its WebP, marked so the
    /// card plays it; this one came with no still preview.
    func testAGIFIsAnAnimatedImage() throws {
        let event = try XCTUnwrap(events("event_gif_kivo", "live").first)
        XCTAssertEqual(MessageKind(type: event.type, content: event.content), .gif)
        let info = MediaInfo(content: event.content)
        XCTAssertEqual(info.url, "https://scontent.example.invalid/v/g001.webp")
        XCTAssertEqual(info.mimetype, "image/webp")
        XCTAssertEqual([info.width, info.height], [240, 240])
        XCTAssertNil(info.thumbnailURL)
        XCTAssertEqual(MessageKind.gif.media?.label, "GIF")

        // The mailbox's copy (live): no media, still a GIF, so the inbox says so; opening the chat reads the rest.
        let bare = try XCTUnwrap(events("event_gif_kivo", "mailbox").first)
        XCTAssertEqual(MessageKind(type: bare.type, content: bare.content), .gif)
        XCTAssertNil(MediaInfo(content: bare.content).url)
    }

    /// A sticker, then a GIF, from Instagram's GIPHY picker (live 2026-10-20, `ig_animated_images_tamo`): both play
    /// like a GIF; the sticker is named so and drawn as one. Ferry said it couldn't show either.
    func testGIPHYStickersAndGIFsAreAnimatedImages() throws {
        let thread = Timeline.reduce(try events("animated_images_tamo", "thread"), me: me)
        XCTAssertEqual(thread.map(\.kind), [.sticker, .gif])
        XCTAssertEqual(thread.map { MediaInfo(content: $0.content).isAnimated }, [true, true])
        XCTAssertEqual(MediaInfo(content: thread[0].content).url, "https://scontent.example.invalid/v/a001.webp")
        XCTAssertEqual(MessageKind.sticker.media?.label, "Sticker")

        // The mailbox's copies: no media, named from Instagram's snippet until the thread is read.
        func preview(_ event: Event) -> String? {
            let room = Room(id: "!ig-test")
            room.apply(JoinedRoom(timeline: .init(events: [event], limited: false)))
            return Inbox.preview(of: room, me: me)?.text
        }
        let receiver = try events("animated_images_tamo", "mailbox_receiver")
        XCTAssertEqual(receiver.map { MessageKind(type: $0.type, content: $0.content) }, [.sticker, .gif])
        XCTAssertEqual(receiver.map { MediaInfo(content: $0.content).url }, [nil, nil])
        XCTAssertEqual(receiver.map(preview), ["Sticker", "GIF"])
        XCTAssertEqual(try events("animated_images_tamo", "mailbox_sender").map(preview), ["You: Sticker", "You: GIF"])
    }

    /// Photos and videos from Instagram's in-chat camera (live 2026-10-24, `ig_camera_media_tamo`): kept in chat, the
    /// same cards as camera-roll media; view once and allow replay stay a view-once line. Ferry showed the kept photo as
    /// view-once and the video as a message it couldn't show.
    func testCameraPhotosAndVideos() throws {
        let thread = Timeline.reduce(try events("camera_media_tamo", "thread"), me: me)
        XCTAssertEqual(thread.map(\.kind), [.viewOnce, .viewOnce, .image, .video])
        XCTAssertEqual(MediaInfo(content: thread[2].content).url, "https://scontent.example.invalid/v/c004.jpg")
        XCTAssertEqual(MediaInfo(content: thread[3].content).url, "https://scontent.example.invalid/v/c010.mp4")
    }

    /// Three photos sent at once from the Instagram app (live 2026-10-18): one message with every photo, in order,
    /// so it keeps one menu, one row of reactions and one unsend. Ferry showed only the first.
    func testPhotosSentTogetherAreOneMessageWithAll() throws {
        let messages = Timeline.reduce(try events("message_photos_tamo", "thread"), me: me)
        XCTAssertEqual(messages.count, 1)
        let info = MediaInfo(content: try XCTUnwrap(messages.first).content)
        XCTAssertEqual(messages.first?.kind, .image)
        XCTAssertEqual(info.url, "https://scontent.example.invalid/v/f040.jpg")  // the first: inbox, quotes
        XCTAssertEqual(info.album.map { MediaInfo(content: $0).url }, (0..<3).map { "https://scontent.example.invalid/v/f0\(40 + 2 * $0).jpg" })
        XCTAssertEqual(info.album.map { MessageKind(type: "m.room.message", content: $0) }, [.image, .image, .image])
        XCTAssertEqual(MediaInfo(content: info.album[2]).aspect, 468.0 / 750)
        XCTAssertEqual(info.albumLabel, "3 photos")  // the pile's badge, "Share All"

        // The mailbox's copy (live): no attachments, still a photo, and no album to stack.
        let bare = try XCTUnwrap(events("message_photos_tamo", "mailbox").first).content
        XCTAssertEqual(MessageKind(type: "m.room.message", content: bare), .image)
        XCTAssertTrue(MediaInfo(content: bare).album.isEmpty)

        // Photos and videos together (upstream's `ordered_photo_video_attachments`, not seen live): each item says which.
        let mixed = MediaInfo(content: try XCTUnwrap(events("message_photos_tamo", "mixed").first).content)
        XCTAssertEqual(mixed.album.map { MessageKind(type: "m.room.message", content: $0) }, [.image, .video])
        XCTAssertEqual(MediaInfo(content: mixed.album[1]).thumbnailURL, "https://scontent.example.invalid/v/f047.jpg")
        XCTAssertEqual(mixed.albumLabel, "2 photos and videos")
    }

    /// Instagram's own lines (upstream's `SlideMessageAdminText`, `text_fragments`; none captured: a group needs three
    /// people) and content the app doesn't know are lines across the thread, never a bubble saying "not supported".
    func testChatEventsAndUnknownContentAreLines() throws {
        let events = try events("chat_events", "events")
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

    /// Their message, our "Seen" on it, our reply, and their "Seen" on ours, live on tamoveska's chat.
    func testLiveMessagesReadsAndReceipts() throws {
        let room = room(try XCTUnwrap(Fixture.engine([String: [IG.Update]].self, "live_tamo")["live"]))
        XCTAssertFalse(room.isUnread)
        let own = try XCTUnwrap(room.lastMessage)
        XCTAssertEqual(own.sender, me)
        XCTAssertNotNil(own.unsigned?.transactionID)  // clears our local echo
        // kivostudio read it on another device three minutes later: "Seen" on our message.
        XCTAssertEqual(room.receipts[IGAdapter.user(kivo)]?.eventID, own.eventID)
        XCTAssertTrue(Timeline.reduce(room, me: me).last?.isSeen == true)
    }

    /// P0's run replayed live on tamoveska's chat as the mailbox had it before: kivostudio's text and its reply
    /// (with the quoted message), our ❤️ then 😂, the edit, the unsend, our "Seen", our reply and their "Seen".
    func testP0RunReplaysLive() throws {
        let room = room(try XCTUnwrap(Fixture.engine([String: [IG.Update]].self, "events_tamo")["replay"]))
        let messages = Timeline.reduce(room, me: me)
        let unsent = try XCTUnwrap(messages.first { $0.kind == .unsent })
        let reply = try XCTUnwrap(messages.first { $0.body == "P0 capture: a reply, edited" })
        XCTAssertTrue(reply.isEdited)
        XCTAssertEqual(reply.reactions.map(\.key), ["😂"])
        XCTAssertEqual(reply.reactions.first?.senders, [me])
        XCTAssertEqual(reply.reply?.eventID, unsent.eventID)
        XCTAssertNotNil(room.related[try XCTUnwrap(unsent.eventID)])  // the quoted message came with the reply
        let back = try XCTUnwrap(messages.last)
        XCTAssertEqual(back.body, "P0 capture: back")
        XCTAssertTrue(back.isSeen)
        XCTAssertFalse(room.isUnread)
        // Our "Seen" (`SlideUQPPMarkRead`) moved our own m.read to their reply: where a "New messages" line would start.
        XCTAssertEqual(room.receipts[me], Room.Receipt(eventID: try XCTUnwrap(reply.eventID), ts: 1_792_172_798_127))
    }

    /// Our own watermark is our m.read, on the newest message at or before it (kivostudio's "On-device spike test"),
    /// and never makes anything "Seen"; the "New messages" line starts after it.
    func testOurWatermarkStartsTheNewMessagesLine() throws {
        let room = try thread(kivo)
        XCTAssertEqual(room.receipts[me]?.ts, 1_792_115_019_051)
        XCTAssertEqual(room.receipts[me]?.eventID, room.events.last { $0.isBaseMessage && ($0.originServerTS ?? 0) <= 1_792_115_019_051 }?.eventID)
        let messages = Timeline.reduce(room, me: me)
        XCTAssertNil(messages.first { $0.isSeen && !$0.isOwn })
        // After our watermark and after our own last message (kivostudio's edited reply), so on "back".
        let rows = Timeline.layout(messages, unreadAfter: room.receipts[me]?.ts)
        XCTAssertEqual(rows.filter(\.startsUnread).map(\.id), [try XCTUnwrap(messages.last).id])
    }

    /// The same chat as its mailbox copy has it, only the newest message, which is past our watermark: our m.read
    /// still comes (on the only message, with our watermark's time), so the line has its place. Without it an unread
    /// live chat opened with no "New messages" line (QA 2026-10-20).
    func testOurWatermarkComesWithAnUnreadMailboxCopy() throws {
        let room = room([try Fixture.engine(IG.Update.self, "unread_window_kivo")])
        XCTAssertTrue(room.isUnread)
        XCTAssertEqual(room.receipts[me]?.ts, 1_792_115_019_051)
        let messages = Timeline.reduce(room, me: me)
        XCTAssertEqual(messages.count, 1)
        let rows = Timeline.layout(messages, unreadAfter: room.receipts[me]?.ts)
        XCTAssertEqual(rows.filter(\.startsUnread).map(\.id), [try XCTUnwrap(messages.first).id])
    }

    /// A reply and an emoji reaction to tamoveska's story, sent by kivostudio from the Instagram app (live 2026-10-19,
    /// `ig_story_replies_kivo`: the thread's copies and both sides' mailbox copies). The thread's copy is the story plus
    /// what was sent and Instagram's line about it; Ferry showed only the story. The mailbox's copy is the text, and its
    /// snippet already says "You: ", which the inbox said again.
    func testStoryRepliesAndReactionsKeepWhatWasSent() throws {
        let threadEvents = try events("story_replies_kivo", "thread")
        let story = Timeline.reduce(threadEvents, me: me)
        XCTAssertEqual(story.map(\.kind), [.share(.story, .unresolved), .share(.story, .unresolved)])  // "Load story"
        XCTAssertEqual(story.map(\.shareText), ["😢", "Droopy"])  // the row shows the emoji big, like any emoji-only message
        XCTAssertEqual(story.map { ShareCaption(content: $0.content).eyebrow }, ["Reacted to @Tamo Veska's story", "Replied to @Tamo Veska's story"])
        XCTAssertEqual(ShareCaption(content: story[1].content).author, "tamoveska")  // "Story · @tamoveska"
        XCTAssertNil(Timeline.reduce(try thread(tamo), me: me).last?.shareText)  // "P0 capture: back"

        // The inbox, from the mailbox's copies (one event each): what was sent, "You: " once on our side.
        func preview(_ event: Event) -> String? {
            let room = Room(id: "!ig-test")
            room.apply(JoinedRoom(timeline: .init(events: [event], limited: false)))
            return Inbox.preview(of: room, me: me)?.text
        }
        XCTAssertEqual(try events("story_replies_kivo", "mailbox_sender").map(preview), ["You: 😢", "You: Droopy"])
        XCTAssertEqual(try events("story_replies_kivo", "mailbox_receiver").map(preview), ["😢", "Droopy"])
        XCTAssertEqual(preview(threadEvents[1]), "You: Droopy")  // the same once the thread is read

        // Any other share's mailbox copy (no `xma`, no text) is Instagram's snippet, which names the sender itself.
        XCTAssertEqual(preview(try XCTUnwrap(events("story_replies_kivo", "bare").first)), "You sent an attachment.")

        // An expired story (not captured): its notice, then what was sent.
        let expired = try XCTUnwrap(events("story_replies_kivo", "expired").first).content
        XCTAssertEqual(MessageKind(type: "m.room.message", content: expired), .notice)
        XCTAssertEqual([expired["body"]?.string, expired[MessageKind.shareTextKey]?.string], ["Story unavailable", "Droopy"])
    }

    /// N1: someone we've never messaged gets a draft chat (the engine's `Draft`) until the first message makes the
    /// thread, which the draft then leads to (`RoomMoved`); our existing DM is found by the other person's FBID.
    func testDraftsAndExistingDMs() throws {
        let drafts = try Fixture.engine([String: [IG.Update]].self, "drafts")
        let draft = try XCTUnwrap(drafts["draft"]?.first)
        XCTAssertEqual(draft.kind, "Draft")
        let room = room([draft])
        XCTAssertEqual(room.bridge?.receiver, tamo)
        XCTAssertEqual(room.bridge?.channelID, "17841400000000999")  // whom the first message goes to
        XCTAssertEqual(room.bridge?.isDM, true)
        XCTAssertEqual(room.name, "Sample Person")
        XCTAssertEqual(room.prevBatch, IGAdapter.startToken)
        XCTAssertEqual(room.memberName(me), "Tamo Veska")
        XCTAssertEqual(draft.profiles?[IGAdapter.user("17841400000000999")]?.handle, "sample.person")
        XCTAssertEqual(Timeline.reduce(room, me: me).count, 0)

        let moved = try XCTUnwrap(drafts["moved"]?.last)
        XCTAssertEqual(moved.kind, "RoomMoved")
        XCTAssertEqual(moved.room, drafts["kivo_draft"]?.first?.room)
        let dm = self.room(try login("tamo").rooms)
        XCTAssertEqual(moved.to, dm.id)
        XCTAssertEqual(Inbox.existingDM(with: kivo, account: tamo, in: [dm])?.id, dm.id)
    }

    /// Shares (Instagram's XMA, shaped like P0's raw captures, with fictional authors): the bridge's content shapes,
    /// so the cards read them as before.
    func testSharesBecomeTheBridgesShapes() throws {
        let reel = try XCTUnwrap(events("shares", "reel").first).content
        XCTAssertEqual(MessageKind(type: "m.room.message", content: reel), .share(.reel, .unresolved))  // "Load video"
        XCTAssertEqual(ShareCaption(content: reel).author, "sample.travels")
        XCTAssertEqual(MediaInfo(content: reel).previewURL, "https://scontent.example.invalid/v/f101.jpg")

        let post = try XCTUnwrap(events("shares", "post").first).content
        XCTAssertEqual(MessageKind(type: "m.room.message", content: post), .share(.post, .ready))
        XCTAssertEqual(ShareCaption(content: post).caption, "Golden hour")

        let link = try XCTUnwrap(events("shares", "link").first).content
        XCTAssertEqual(MessageKind(type: "m.room.message", content: link), .link)
        XCTAssertEqual(LinkPreview(content: link)?.title, "An article")

        XCTAssertEqual(try XCTUnwrap(events("shares", "expired").first).content["body"]?.string, "Story unavailable")

        // "Load video": the hidden edit swaps the card to the reel itself.
        let room = try thread(tamo)
        room.apply(JoinedRoom(timeline: .init(events: try events("shares", "reel"), limited: false)))
        XCTAssertEqual(Timeline.reduce(room, me: me).last?.kind, .share(.reel, .unresolved))
        room.apply(JoinedRoom(timeline: .init(events: try events("shares", "resolved"), limited: false)))
        let after = try XCTUnwrap(Timeline.reduce(room, me: me).last)
        XCTAssertEqual(after.kind, .share(.reel, .ready))
        XCTAssertFalse(after.isEdited)
        XCTAssertEqual(MediaInfo(content: after.content).url, "https://scontent.example.invalid/v/f102.mp4")
        XCTAssertEqual(MediaInfo(content: after.content).duration, 12_500)
        XCTAssertEqual(ShareCaption(content: after.content).author, "sample.travels")
    }
}
