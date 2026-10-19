import Foundation

/// Instagram's own JSON as `core/` passes it through (docs/PLAN-core.md C1): only the fields the app reads. Keys are
/// snake_case, decoded with `.convertFromSnakeCase` (which turns `fetch__SlideMailbox` into `fetchSlidemailbox`).
nonisolated enum IG {
    struct Login: Decodable, Sendable {
        var account: String
        var viewer: Viewer
        var mailbox: Mailbox?
    }

    /// The account itself; also kept in the Keychain with its cookies, for the account list at launch.
    struct Viewer: Codable, Equatable, Sendable {
        var id: String?
        var fbid: String?
        var username: String?
        var fullName: String?
        var profilePicUrl: String?
        var isProfessionalAccount: Bool?
    }

    struct Mailbox: Decodable, Sendable {
        var threadsByFolder: Page<Wrapped>?
    }

    /// `IGInboxPage`.
    struct MailboxPage: Decodable, Sendable {
        var fetchSlidemailbox: Mailbox?
    }

    /// `IGThread`.
    struct ThreadResponse: Decodable, Sendable {
        var getSlideThreadNullable: Wrapped?
    }

    /// `IGOlder`.
    struct OlderResponse: Decodable, Sendable {
        var fetchSlidethread: Wrapped?
    }

    /// `IGSearch`.
    struct SearchResponse: Decodable, Sendable {
        var xfbCombinedigsearchquery: Results?

        struct Results: Decodable, Sendable {
            var searchMessengerContactV2: [SearchResult]?
        }
    }

    struct SearchResult: Decodable, Sendable {
        var interopMessagingUserFbid: String?
        var username: String?
        var fullName: String?
        var profilePicUrl: String?
    }

    /// `IGResolveMedia`: a share's media at its best size.
    struct Resolved: Decodable, Sendable {
        var url: String
        var video: Bool?
        var width: Double?
        var height: Double?
        /// Seconds.
        var duration: Double?
    }

    /// `IGFindDM`.
    struct FoundDM: Decodable, Sendable {
        var found: Bool
        var threadFbid: String?
    }

    /// `IGSend`: Instagram's ID for the message we just sent.
    struct SendResponse: Decodable, Sendable {
        var xigDirectTextSendWithSlideMessagingResponse: Sent?

        struct Sent: Decodable, Sendable {
            var id: String?
        }
    }

    struct Page<T: Decodable & Sendable>: Decodable, Sendable {
        var edges: [Node<T>]?
        var pageInfo: PageInfo?

        var nodes: [T] { edges?.map(\.node) ?? [] }
        /// The cursor for the next page, nil at the end.
        var next: String? { pageInfo?.hasNextPage == true ? pageInfo?.endCursor : nil }
    }

    struct Node<T: Decodable & Sendable>: Decodable, Sendable {
        var node: T
    }

    struct PageInfo: Decodable, Sendable {
        var endCursor: String?
        var hasNextPage: Bool?
    }

    struct Wrapped: Decodable, Sendable {
        var asIgDirectThread: Thread?
    }

    /// Three IDs (P0): `id` for most calls and in deltas' `thread_fbid`; `threadId` (the long one) for unsend, mark
    /// read and typing; `threadKey` in a DM is the other person's FBID.
    struct Thread: Decodable, Sendable {
        var id: String
        var threadKey: String?
        var threadId: String?
        var isGroup: Bool?
        var threadTitle: String?
        var threadImageUrl: String?
        /// Everyone but us.
        var users: [User]?
        var slideMessages: Page<Message>?
        var slideReadReceipts: [ReadReceipt]?
        var markedAsUnread: Bool?
        /// `PRIMARY`/`GENERAL` (Instagram's tabs) and `INBOX`/`PENDING`/`SPAM` (requests), P0.
        var folder: String?
        var systemFolder: String?
    }

    struct User: Decodable, Sendable {
        /// The Instagram user ID (typing names people by it).
        var id: String?
        /// What messages, reactions and receipts name people by.
        var interopMessagingUserFbid: String?
        var username: String?
        var fullName: String?
        var profilePicUrl: String?
    }

    struct Message: Decodable, Sendable {
        var id: String
        var senderFbid: String?
        var timestampMs: String?
        var contentType: String?
        var textBody: String?
        var igdSnippet: String?
        var offlineThreadingId: String?
        var repliedToMessageId: String?
        var reactions: [Reaction]?
        /// The message this one replies to, sent along with it.
        var repliedToMessage: Quoted?
        /// Earlier versions, oldest first; `textBody` is the current one.
        var slideEditHistory: [Edit]?
        /// The attachments, by kind (`audio_attachments`, `videos`, `attachments`).
        var content: JSON?

        var ms: Int64 { Int64(timestampMs ?? "") ?? 0 }

        /// Instagram's "Reacted 😂 to your message" log entry repeats a reaction the message itself shows: not a row.
        var isShown: Bool { contentType != "REACTION_LOG_XMAT" }
    }

    struct Reaction: Decodable, Sendable {
        var reaction: String?
        var senderFbid: String?
    }

    /// A reply's target as Instagram sends it with the reply: enough for the quote.
    struct Quoted: Decodable, Sendable {
        var id: String?
        var senderFbid: String?
        var timestampMs: String?
        var contentType: String?
        var textBody: String?
        var igdSnippet: String?
        var content: JSON?

        var message: Message? {
            id.map { Message(id: $0, senderFbid: senderFbid, timestampMs: timestampMs, contentType: contentType, textBody: textBody,
                             igdSnippet: igdSnippet, content: content) }
        }
    }

    struct Edit: Decodable, Sendable {
        var body: String?
    }

    struct ReadReceipt: Decodable, Sendable {
        var participantFbid: String?
        var watermarkTimestampMs: String?

        var ms: Int64 { Int64(watermarkTimestampMs ?? "") ?? 0 }
    }

    /// What `IGNextEvent` returns: `{account, kind}` plus a delta's wire JSON, typing, or an error.
    struct Event: Decodable, Sendable {
        var account: String
        var kind: String
        var delta: Delta?
        var error: String?
        var code: String?
        /// `TypingNotification`: the thread's long ID (`Thread.threadId`) and who.
        var thread: String?
        var typing: Typing?
    }

    struct Typing: Decodable, Sendable {
        /// The Instagram user ID (`User.id`), not the FBID.
        var senderId: Int64?
        /// 1 typing, 0 stopped.
        var activityStatus: Int?
        /// How long it holds without another notice, ms.
        var ttl: Int64?
    }

    /// One live change. Only the kinds the app applies are decoded; the rest are skipped.
    struct Delta: Decodable, Sendable {
        var typename: String
        var threadFbid: String?
        var message: Message?
        var threadReadStateEffect: String?
        var markedAsUnread: Bool?
        var readReceipt: ReadReceipt?
        /// Reactions, edits and unsends: the message they're about.
        var messageId: String?
        var reaction: DeltaReaction?
        var textBody: String?
        var slideEditHistoryEntry: EditEntry?
        /// `SlideUQPPIGMoveThread`: Instagram's tab the thread moved to (`PRIMARY`/`GENERAL`).
        var igInboxFolder: String?
        /// `SlideUQPPMarkRead`: how far we've read (here or on another device), ms.
        var readTimestampMs: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename", threadFbid, message, threadReadStateEffect, markedAsUnread, readReceipt
            case messageId, reaction, textBody, slideEditHistoryEntry, igInboxFolder, readTimestampMs
        }
    }

    /// A reaction's log entry: its ID is how a later delete names it (the delete carries nothing else, P0).
    struct DeltaReaction: Decodable, Sendable {
        var logMessageId: String?
        var reaction: String?
        var senderFbid: String?
        var reactionTimestampMs: String?
    }

    struct EditEntry: Decodable, Sendable {
        var timestampMs: String?
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
}

/// Instagram threads as the Matrix-shaped rooms the app already shows (docs/PLAN-core.md §2, decision C2): the same
/// `m.bridge`, `m.room.*`, message, reaction and receipt events the bridge used to send, built here. Pure.
nonisolated enum IGAdapter {
    /// The one user the views treat as "us" in every account's chats, as Ferry's double puppet was.
    static let me = "@me"
    /// A room's first page when Instagram has no older one: the thread view shows the start of the chat.
    static let startToken = "ig-start"

    static func user(_ fbid: String) -> String { "@ig_\(fbid)" }

    /// An offline threading ID as Instagram's web client makes them (`methods.GenerateEpochID`): ms << 22, a counter
    /// << 12 for IDs made in the same millisecond, then 42. Our local echo's transaction ID.
    static func offlineThreadingID(ms: Int64, counter: Int64) -> String {
        String((ms << 22) | ((counter & 0x3FF) << 12) | 42)
    }

    /// One room per account and thread: a thread both of our accounts are in is two chats (as with `split_portals`).
    static func roomID(account: String, thread: String) -> String { "!ig-\(account)-\(thread)" }

    /// The account in the bridge's whoami shape, so `Health`, the stack, banners and A1–A3 read it as before.
    static func login(account: String, viewer: IG.Viewer?, state: String, message: String? = nil, since: Date,
                      transientSince: Date? = nil) -> BridgeAPI.Login {
        var login = BridgeAPI.Login(id: account)
        login.name = viewer?.username
        login.profile = .init(name: viewer?.fullName, username: viewer?.username, avatar: viewer?.profilePicUrl)
        login.state = .init(stateEvent: state, message: message, timestamp: since.timeIntervalSince1970,
                            info: .init(isProfessionalAccount: viewer?.isProfessionalAccount))
        login.transientSince = transientSince
        return login
    }

    struct Snapshot: Sendable {
        var id: String
        var joined: JoinedRoom
        /// Names, pictures and @handles of the thread's people (`AppModel.profiles`; no `/profile` to ask any more).
        var profiles: [String: UserProfile]
        /// Reply targets that came with their replies (`Room.related`).
        var related: [Event]
    }

    /// A thread with its newest messages, as a fresh window (`limited`): applying it again replaces the last one.
    /// `readUpTo` is how far we've read as this app knows it (our `m.read`, ms): a read that left before our "Seen"
    /// reached Instagram still says unread, and opening a chat sends both at once.
    static func room(_ thread: IG.Thread, account: String, viewer: IG.Viewer?, readUpTo: Int64 = 0) -> Snapshot {
        let people = (thread.users ?? []).filter { $0.interopMessagingUserFbid != nil && $0.interopMessagingUserFbid != account }
        let isDM = thread.isGroup != true
        let contact = isDM ? people.first : nil
        let name = nonEmpty(thread.threadTitle) ?? contact.flatMap { nonEmpty($0.fullName) ?? $0.username } ?? "Instagram chat"

        var channel: [String: JSON] = [
            "id": .string(isDM ? (thread.threadKey ?? contact?.interopMessagingUserFbid ?? thread.id) : thread.id),
            "displayname": .string(name), "fi.mau.receiver": .string(account),
        ]
        if ["PENDING", "SPAM"].contains(thread.systemFolder) { channel["com.beeper.message_request"] = true }
        if thread.folder == "GENERAL" { channel[BridgeInfo.inboxFolderKey] = "GENERAL" }
        var bridge: [String: JSON] = ["protocol": ["id": .string(BridgeInfo.protocolID), "displayname": "Instagram"], "channel": .object(channel)]
        if isDM { bridge["com.beeper.room_type"] = "dm" }  // a group has none (S7.6)

        var state = [stateEvent("m.bridge", key: "instagram", .object(bridge)), stateEvent("m.room.name", ["name": .string(name)])]
        if let avatar = nonEmpty(isDM ? contact?.profilePicUrl : thread.threadImageUrl) {
            state.append(stateEvent("m.room.avatar", ["url": .string(avatar)]))
        }
        state.append(member(me, name: viewer?.fullName ?? viewer?.username, avatar: viewer?.profilePicUrl))
        var profiles: [String: UserProfile] = [:]
        for person in people {
            guard let fbid = person.interopMessagingUserFbid else { continue }
            state.append(member(user(fbid), name: nonEmpty(person.fullName) ?? person.username, avatar: person.profilePicUrl))
            profiles[user(fbid)] = UserProfile(name: nonEmpty(person.fullName), avatarURL: person.profilePicUrl, handle: person.username)
        }

        let messages = (thread.slideMessages?.nodes.reversed() ?? []).filter(\.isShown)  // oldest first, as rooms keep them
        let receipts = thread.slideReadReceipts ?? []
        let mine = max(receipts.first { $0.participantFbid == account }?.ms ?? 0, readUpTo)
        let unread = thread.markedAsUnread == true || messages.last.map { $0.senderFbid != account && $0.ms > mine } == true
        let joined = JoinedRoom(
            state: EventList(events: state),
            timeline: .init(events: messages.flatMap { events($0, account: account) }, limited: true,
                            prevBatch: thread.slideMessages?.next ?? startToken),
            ephemeral: EventList(events: [readReceipts(receipts, account: account, messages: messages)].compactMap(\.self)),
            unreadNotifications: .init(notificationCount: unread ? 1 : 0, highlightCount: 0))
        return Snapshot(id: roomID(account: account, thread: thread.id), joined: joined, profiles: profiles,
                        related: messages.compactMap { related($0, account: account) })
    }

    /// A search result as New Message's contact (N1): the FBID is who we message and what a DM's channel names.
    static func contact(_ result: IG.SearchResult) -> BridgeAPI.Contact? {
        guard let fbid = result.interopMessagingUserFbid else { return nil }
        return BridgeAPI.Contact(id: fbid, name: nonEmpty(result.fullName) ?? result.username, avatarURL: result.profilePicUrl,
                                 identifiers: result.username.map { ["instagram:\($0)"] })
    }

    /// `IGThread`'s answer leaves `folder` empty (only mailbox pages fill it, P0's capture): a re-read keeps the tab the
    /// room had, or opening a General chat would move it to Chats.
    static func keepingFolder(_ thread: IG.Thread, of room: Room?) -> IG.Thread {
        guard thread.folder?.isEmpty ?? true, room?.bridge?.folder == .general else { return thread }
        var thread = thread
        thread.folder = "GENERAL"
        return thread
    }

    /// The local chat with someone we've never messaged: Instagram has no thread until the first message. Its room ID
    /// says whom it's for; once the real thread arrives, `AppModel.room(_:)` leads there.
    static func draftID(account: String, user: String) -> String { "!ig-\(account)-new-\(user)" }

    static func draft(account: String, contact: BridgeAPI.Contact, viewer: IG.Viewer?) -> Snapshot {
        let name = contact.name ?? contact.handle ?? "New chat"
        let bridge: JSON = ["protocol": ["id": .string(BridgeInfo.protocolID), "displayname": "Instagram"], "com.beeper.room_type": "dm",
                            "channel": ["id": .string(contact.id), "displayname": .string(name), "fi.mau.receiver": .string(account)]]
        var state = [stateEvent("m.bridge", key: "instagram", bridge), stateEvent("m.room.name", ["name": .string(name)]),
                     member(me, name: viewer?.fullName ?? viewer?.username, avatar: viewer?.profilePicUrl),
                     member(user(contact.id), name: name, avatar: contact.avatarURL)]
        if let avatar = nonEmpty(contact.avatarURL) { state.append(stateEvent("m.room.avatar", ["url": .string(avatar)])) }
        return Snapshot(id: draftID(account: account, user: contact.id),
                        joined: JoinedRoom(state: EventList(events: state), timeline: .init(events: [], limited: true, prevBatch: startToken)),
                        profiles: [user(contact.id): UserProfile(name: contact.name, avatarURL: contact.avatarURL, handle: contact.handle)],
                        related: [])
    }

    /// Applies a thread's snapshot to its room: the window, then the reply targets that came with it.
    static func apply(_ snapshot: Snapshot, to room: Room) {
        room.apply(snapshot.joined)
        for event in snapshot.related { room.addRelated(event) }
    }

    /// An older page (`IGOlder`) as `/messages` gave it: newest first, `end` nil at the start of the chat.
    static func page(_ thread: IG.Thread?, account: String) -> MessagesPage {
        let messages = (thread?.slideMessages?.nodes ?? []).filter(\.isShown)
        return MessagesPage(chunk: messages.reversed().flatMap { events($0, account: account) }.reversed(),
                            end: thread?.slideMessages?.next)
    }

    /// A message and what hangs off it: earlier versions as the base plus `m.replace` edits (so it reads "Edited"),
    /// and one `m.reaction` per person. Our own carry their offline threading ID, which clears the local echo.
    static func events(_ message: IG.Message, account: String) -> [Event] {
        let sender = message.senderFbid == account ? me : user(message.senderFbid ?? "")
        let history = (message.slideEditHistory ?? []).compactMap(\.body)
        var base = history.first.map { text($0) } ?? content(message)
        if let reply = nonEmpty(message.repliedToMessageId), case .object(var fields) = base {  // "" on every other message
            fields["m.relates_to"] = ["m.in_reply_to": ["event_id": .string(reply)]]
            base = .object(fields)
        }
        let unsigned = sender == me ? message.offlineThreadingId.map { Event.Unsigned(transactionID: $0) } : nil
        var events = [Event(type: "m.room.message", content: base, eventID: message.id, sender: sender,
                            originServerTS: message.ms, unsigned: unsigned)]
        if !history.isEmpty {
            for (i, body) in (history.dropFirst() + [message.textBody ?? ""]).enumerated() {
                events.append(Event(type: "m.room.message", content: [
                    "msgtype": "m.text", "body": .string("* \(body)"), "m.new_content": text(body),
                    "m.relates_to": ["rel_type": "m.replace", "event_id": .string(message.id)],
                ], eventID: "\(message.id)~edit\(i)", sender: sender, originServerTS: message.ms + Int64(i) + 1))
            }
        }
        for reaction in message.reactions ?? [] {
            guard let key = reaction.reaction, let who = reaction.senderFbid else { continue }
            events.append(Event(type: "m.reaction", content: ["m.relates_to": ["rel_type": "m.annotation", "event_id": .string(message.id), "key": .string(key)]],
                                eventID: "\(message.id)~react\(who)", sender: who == account ? me : user(who), originServerTS: message.ms))
        }
        return events
    }

    /// The message's content in the shapes `MessageKind`, `MediaInfo` and the cards read. Media links are Instagram's
    /// CDN URLs, downloaded on tap (`MediaCache`).
    static func content(_ message: IG.Message) -> JSON {
        let attachments = message.content
        switch message.contentType {
        case "TEXT":
            return text(message.textBody ?? "")
        case "AUDIOS":
            let audio = attachments?["audio_attachments"]?.array?.first
            let ms = audio?["playable_duration_ms"]?.number ?? 0
            return media("m.audio", "Voice message", url: audio?["attachment_cdn_url"]?.string,
                         info: ["mimetype": "audio/mp4", "duration": .number(ms)],
                         extra: ["org.matrix.msc3245.voice": [:], "org.matrix.msc1767.audio": ["duration": .number(ms)]])
        case "VIDEOS":
            return album(attachments?["videos"]?.array, video: true)
        case "IMAGES":
            return album(attachments?["attachments"]?.array, video: false)
        case _ where attachments?["ordered_photo_video_attachments"] != nil:  // photos and videos in one message (upstream's shape)
            return album(attachments?["ordered_photo_video_attachments"]?.array, video: nil)
        case "GIFS":  // a GIF (Instagram's picker, or one we uploaded); the mailbox's copy has no media (`null`), the thread's does
            let gif = attachments?["animated_media"]?.array?.first
            return media("m.image", "GIF", url: gif?["attachment_webp_url"]?.string, info: [
                "mimetype": "image/webp", "w": gif?["preview_width"] ?? .null, "h": gif?["preview_height"] ?? .null,
                "thumbnail_url": gif?["preview_cdn_url"] ?? .null, "fi.mau.gif": true,
            ])
        case _ where attachments?["text_fragments"] != nil:  // Instagram's own line: "… named the group …", "… left the group"
            let line = (attachments?["text_fragments"]?.array ?? []).compactMap { $0["plaintext"]?.string }.joined()
            guard let line = nonEmpty(line) ?? nonEmpty(message.igdSnippet) else { return unsupported(message) }
            return ["msgtype": "m.notice", "body": .string(line), MessageKind.eventKey: true]
        case _ where attachments?["xma"] != nil:
            // A story reply or reaction (`MONTAGE_SHARE_XMA`) is the story plus what was sent, `xma_text_body` (live
            // 2026-10-19, `ig_story_replies_kivo`). The mailbox's copy has `xma: null` and the text only in `text_body`:
            // a text until the thread is read, previewed as Instagram's own snippet does.
            let sent = nonEmpty(attachments?["xma_text_body"]?.string) ?? nonEmpty(message.textBody)
            if attachments?["xma"]?.object == nil, let sent { return text(sent) }
            return share(attachments?["xma"], snippet: message.igdSnippet, text: sent)
        case "RAVEN_IMAGE":
            // The bridge's own wording is how `MessageKind` knows view-once media.
            return ["msgtype": "m.notice", "body": "This photo can only be viewed once. Use the Instagram app to view."]
        default:
            return unsupported(message)
        }
    }

    /// What the app can't show (a poll, a sticker…), as a line that sends you to Instagram. A thread read's copy has no
    /// `igd_snippet` (the mailbox's and live deltas' do), so the content type is all that names it on every path.
    private static func unsupported(_ message: IG.Message) -> JSON {
        // ponytail: "poll" is a guess at Instagram's naming (no poll captured yet); name more kinds once one is.
        let poll = [message.contentType, message.content?["__typename"]?.string].contains { $0?.localizedCaseInsensitiveContains("poll") == true }
        let what = poll ? "a poll" : "a message Ferry can't show"
        return ["msgtype": "m.notice", "body": .string("Sent \(what)"), MessageKind.unsupportedKey: .string(what)]
    }

    /// Photos or videos: one, or several sent together (one message, live 2026-10-18). Several are the first one's
    /// content plus all of them under `MediaInfo.albumKey`, which `MediaCard` stacks. `video` nil: each item says.
    private static func album(_ items: [JSON]?, video: Bool?) -> JSON {
        func card(_ item: JSON?) -> JSON {
            let url = item?["attachment_cdn_url"]?.string, w = item?["preview_width"] ?? .null, h = item?["preview_height"] ?? .null
            return video ?? (item?["__typename"]?.string == "XFBSlideVideoAttachment")
                ? media("m.video", "Video", url: url, info: ["mimetype": "video/mp4", "w": w, "h": h, "thumbnail_url": item?["preview_cdn_url"] ?? .null])
                : media("m.image", "Photo", url: url, info: ["mimetype": "image/jpeg", "w": w, "h": h])
        }
        guard let items, items.count > 1, case .object(var first) = card(items[0]) else { return card(items?.first) }
        first[MediaInfo.albumKey] = .array(items.map(card))
        return .object(first)
    }

    /// A share (Instagram's XMA) in the bridge's shapes, so the cards read it as before: a reel or story waits for
    /// "Load video" (`com.beeper.unresolved_media`, then `resolved`), a post is its image, a link off Instagram is a
    /// text with its preview, an expired story its notice. The author is Instagram's `header_title_text`, its own line
    /// about it ("Replied to @…'s story") `eyebrow_text`, as the bridge's `<blockquote>`. `text` is what was sent with
    /// it (a story reply, or a story reaction's emoji), under `MessageKind.shareTextKey`: one message, so one menu,
    /// reaction row and unsend.
    static func share(_ xma: JSON?, snippet: String?, text: String? = nil) -> JSON {
        let link = xma?["target_url"]?.string
        let preview = xma?["preview_image"]
        let caption = [xma?["title_text"], xma?["caption_body_text"], xma?["subtitle_text"]].compactMap { $0?.string }.first { !$0.isEmpty }
        guard let link, let type = MessageKind.ShareType(instagramURL: link) else {
            guard let link else {
                // The mailbox's copy has no `xma`, and its snippet names the sender ("You sent an attachment."): a line
                // that says who, so the inbox doesn't add "You: " again. The thread's copy replaces it.
                if xma?.object == nil {
                    return ["msgtype": "m.notice", "body": .string(nonEmpty(snippet) ?? "Shared content"), MessageKind.eventKey: true]
                }
                var notice: [String: JSON] = ["msgtype": "m.notice", "body": .string(caption ?? nonEmpty(snippet) ?? "Shared content")]
                notice[MessageKind.shareTextKey] = text.map { .string($0) }
                return .object(notice)
            }
            var preview: [String: JSON] = ["matched_url": .string(link)]
            preview["og:title"] = xma?["title_text"]
            preview["og:description"] = xma?["subtitle_text"]
            preview["og:image"] = xma?["preview_image"]?["url"]
            return ["msgtype": "m.text", "body": .string(text ?? link), "com.beeper.linkpreviews": [.object(preview)]]
        }
        var html = nonEmpty(xma?["eyebrow_text"]?.string).map { "<blockquote>\(escape($0))</blockquote>" } ?? ""
        html += xma?["header_title_text"]?.string.map { "<strong>\(escape($0))</strong>" } ?? ""
        if let caption { html += "<p>\(escape(caption))</p>" }
        var info: [String: JSON] = ["w": preview?["width"] ?? .null, "h": preview?["height"] ?? .null]
        var fields: [String: JSON] = ["body": .string(nonEmpty(snippet) ?? "Sent a \(type.rawValue)"), "external_url": .string(link),
                                      "formatted_body": .string(html), "format": "org.matrix.custom.html"]
        if type == .post {
            fields["msgtype"] = "m.image"
            fields["url"] = preview?["url"]
        } else {
            fields["msgtype"] = "m.video"
            info["thumbnail_url"] = preview?["url"]
            fields["com.beeper.unresolved_media"] = ["target_url": .string(link), "target_id": xma?["target_id"] ?? .null]
        }
        fields[MessageKind.shareTextKey] = text.map { .string($0) }
        fields["info"] = .object(info.filter { $0.value != .null && $0.value != .number(0) })
        return .object(fields)
    }

    /// "Load video" done: the share's media, as the hidden edit that swaps the card (the bridge's resolve_media did the
    /// same; `com.beeper.dont_render_edited` keeps "Edited" off).
    static func resolved(_ media: IG.Resolved, for message: Message) -> Event {
        var content = message.content.object ?? [:]
        content["com.beeper.unresolved_media"] = nil
        var info = content["info"]?.object ?? [:]
        if let w = media.width, w > 0 { info["w"] = .number(w) }
        if let h = media.height, h > 0 { info["h"] = .number(h) }
        if media.video == true {
            content["msgtype"] = "m.video"
            info["mimetype"] = "video/mp4"
            if let seconds = media.duration, seconds > 0 { info["duration"] = .number((seconds * 1000).rounded()) }
        } else {
            content["msgtype"] = "m.image"
            info["mimetype"] = "image/jpeg"
        }
        content["url"] = .string(media.url)
        content["info"] = .object(info)
        let id = message.eventID ?? message.id
        return Event(type: "m.room.message", content: [
            "msgtype": content["msgtype"] ?? "m.video", "body": "* resolved", "m.new_content": .object(content),
            "m.relates_to": ["rel_type": "m.replace", "event_id": .string(id)], "com.beeper.dont_render_edited": true,
        ], eventID: "\(id)~resolved", sender: message.sender, originServerTS: message.ts + 1)
    }

    private static func escape(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;").replacing("\"", with: "&#34;")
    }

    /// What one live delta changes in its room (a delta's `thread_fbid` is `ThreadInfo.id`, P0), or nil for kinds
    /// applied elsewhere (`receipt`) or not yet.
    static func update(_ delta: IG.Delta, account: String) -> JoinedRoom? {
        switch delta.typename {
        case "SlideUQPPNewMessage":
            guard let message = delta.message, message.isShown else { return nil }
            let own = message.senderFbid == account
            let unread = own ? 0 : delta.threadReadStateEffect == "MARK_UNREAD" ? 1 : nil
            return JoinedRoom(timeline: .init(events: events(message, account: account), limited: false),
                              unreadNotifications: unread.map { .init(notificationCount: $0, highlightCount: 0) })
        case "SlideUQPPMarkRead":
            return JoinedRoom(unreadNotifications: .init(notificationCount: 0, highlightCount: 0))
        case "SlideUQPPIGMarkThreadUnread":
            return JoinedRoom(unreadNotifications: .init(notificationCount: delta.markedAsUnread == true ? 1 : 0, highlightCount: 0))
        default:
            return nil
        }
    }

    /// Someone's "Seen" (`SlideUQPPReadReceipt`) as `m.read` on the newest message they'd seen in `events`.
    static func receipt(_ delta: IG.Delta, account: String, events: [Event]) -> JoinedRoom? {
        guard let receipt = delta.readReceipt, let who = receipt.participantFbid, who != account,
              let seen = events.last(where: { $0.isBaseMessage && ($0.originServerTS ?? 0) <= receipt.ms })?.eventID else { return nil }
        return JoinedRoom(ephemeral: EventList(events: [receiptEvent([(user(who), seen, receipt.ms)])]))
    }

    enum Outcome: Equatable, Sendable {
        case applied, ignored
        /// The room needs a full re-read: a reaction from before this launch, a new name, picture, member or folder.
        case refresh
        /// The thread was deleted (here or on another device): the room goes.
        case removed
    }

    /// Applies one live delta to its room (what `AppModel` does with each; tests replay P0's run through it).
    static func apply(_ delta: IG.Delta, account: String, to room: Room) -> Outcome {
        if let message = delta.message, let target = related(message, account: account) { room.addRelated(target) }
        switch delta.typename {
        case "SlideUQPPReadReceipt":
            guard let update = receipt(delta, account: account, events: room.events) else { return .ignored }
            room.apply(update)
        case "SlideUQPPMarkRead":  // read here or on another device, and how far: the "New messages" line starts after it
            let ms = Int64(delta.readTimestampMs ?? "")
            let seen = room.events.last { $0.isBaseMessage && ($0.originServerTS ?? 0) <= ms ?? .max }
            room.apply(read(seen?.eventID, at: ms ?? seen?.originServerTS ?? 0))
        case "SlideUQPPCreateReaction", "SlideUQPPDeleteReaction", "SlideUQPPEditMessage", "SlideUQPPDeleteMessage":
            switch change(delta, account: account, events: room.events) {
            case .apply(let update): room.apply(update)
            case .refresh: return .refresh
            case .ignore: return .ignored
            }
            // An unread message unsent: the chat is read again when what's left ends with ours (seen live in P3).
            if delta.typename == "SlideUQPPDeleteMessage", room.isUnread, room.lastMessage?.sender == me {
                room.apply(JoinedRoom(unreadNotifications: .init(notificationCount: 0, highlightCount: 0)))
            }
        case "SlideUQPPIGMoveThread":  // moved between Primary and General (upstream doesn't map it; the raw delta has it)
            guard let folder = delta.igInboxFolder,
                  let update = bridgeUpdate(room, { $0[BridgeInfo.inboxFolderKey] = folder == "GENERAL" ? "GENERAL" : nil }) else { return .refresh }
            room.apply(update)
        case "SlideUQPPThreadName", "SlideUQPPThreadImage", "SlideUQPPParticipantJoin", "SlideUQPPParticipantLeave",
             "SlideUQPPUpdateThreadFolder":  // a request accepted or moved elsewhere
            return .refresh
        case "SlideUQPPDeleteThread":
            return .removed
        default:
            guard let update = update(delta, account: account) else { return .ignored }
            room.apply(update)
            // Their message ends their typing: Instagram sends no "stopped" with it, so "typing…" held for its 22 s TTL.
            if let fbid = delta.message?.senderFbid, room.typing.contains(user(fbid)) {
                room.apply(typing(user(fbid), on: false, in: room.typing))
            }
        }
        return .applied
    }

    /// A reply's target, filed in `Room.related` so the quote shows without a fetch. Instagram sends none for a target
    /// unsent since: an unsent stand-in then, so the quote says so instead of loading forever.
    static func related(_ message: IG.Message, account: String) -> Event? {
        if let quoted = message.repliedToMessage?.message { return events(quoted, account: account).first }
        guard let target = nonEmpty(message.repliedToMessageId) else { return nil }
        return Event(type: "m.room.message", content: [:], eventID: target, sender: message.senderFbid == account ? me : user(message.senderFbid ?? ""),
                     unsigned: Event.Unsigned(redactedBecause: [:]))
    }

    /// What a reaction, edit or unsend does to its room: needs the message it's about (`events`, the room's window).
    enum Change: Sendable {
        case apply(JoinedRoom)
        /// About a message or reaction this window doesn't have (a reaction from before this launch): re-read the thread.
        case refresh
        case ignore
    }

    static func change(_ delta: IG.Delta, account: String, events: [Event]) -> Change {
        func sender(_ fbid: String?) -> String { fbid == account ? me : user(fbid ?? "") }
        func now(_ ms: String?) -> Int64 { Int64(ms ?? "") ?? events.last?.originServerTS ?? 0 }
        guard let id = delta.messageId else { return .ignore }
        let target = events.first { $0.eventID == id }
        switch delta.typename {
        case "SlideUQPPCreateReaction":
            guard let reaction = delta.reaction, let key = reaction.reaction, let log = reaction.logMessageId else { return .ignore }
            return .apply(timeline(Event(type: "m.reaction", content: ["m.relates_to": ["rel_type": "m.annotation", "event_id": .string(id), "key": .string(key)]],
                                         eventID: log, sender: sender(reaction.senderFbid), originServerTS: now(reaction.reactionTimestampMs))))
        case "SlideUQPPDeleteReaction":
            guard let log = delta.reaction?.logMessageId, let reaction = events.first(where: { $0.eventID == log }) else { return .refresh }
            return .apply(timeline(redaction(of: log, by: reaction.sender ?? me, at: now(nil))))
        case "SlideUQPPEditMessage":
            guard let target, let body = delta.textBody else { return .refresh }
            let ms = now(delta.slideEditHistoryEntry?.timestampMs)
            return .apply(timeline(Event(type: "m.room.message", content: [
                "msgtype": "m.text", "body": .string("* \(body)"), "m.new_content": text(body),
                "m.relates_to": ["rel_type": "m.replace", "event_id": .string(id)],
            ], eventID: "\(id)~edit\(ms)", sender: target.sender, originServerTS: ms)))
        case "SlideUQPPDeleteMessage":
            guard let target else { return .ignore }  // unsent before we saw it: nothing to show
            return .apply(timeline(redaction(of: id, by: target.sender ?? me, at: now(nil))))
        default:
            return .ignore
        }
    }

    /// We've read up to `eventID` (`ms`): the chat is read, and our `m.read` moves there.
    static func read(_ eventID: String?, at ms: Int64) -> JoinedRoom {
        JoinedRoom(ephemeral: eventID.map { EventList(events: [receiptEvent([(me, $0, ms)])]) },
                   unreadNotifications: .init(notificationCount: 0, highlightCount: 0))
    }

    /// Who's typing in a room right now (replaces the list, as `m.typing` did).
    static func typing(_ users: [String]) -> JoinedRoom {
        JoinedRoom(ephemeral: EventList(events: [Event(type: "m.typing", content: ["user_ids": .array(users.map { .string($0) })])]))
    }

    /// One person starting or stopping, the others as they were: in a group, Instagram's notices come one person at a
    /// time, and one person's "stopped" cleared everyone.
    static func typing(_ user: String, on: Bool, in current: [String]) -> JoinedRoom {
        typing(current.filter { $0 != user } + (on ? [user] : []))
    }

    /// The room's `m.bridge` again with its channel changed (the Instagram tab, the request flag).
    private static func bridgeUpdate(_ room: Room, _ change: (inout [String: JSON]) -> Void) -> JoinedRoom? {
        guard var event = room.state["m.bridge"]?.values.first(where: { BridgeInfo(content: $0.content) != nil }),
              case .object(var content) = event.content, case .object(var channel)? = content["channel"] else { return nil }
        change(&channel)
        content["channel"] = .object(channel)
        event.content = .object(content)
        return JoinedRoom(state: EventList(events: [event]))
    }

    private static func timeline(_ event: Event) -> JoinedRoom {
        JoinedRoom(timeline: .init(events: [event], limited: false))
    }

    private static func redaction(of id: String, by sender: String, at ms: Int64) -> Event {
        Event(type: "m.room.redaction", content: ["redacts": .string(id)], eventID: "\(id)~unsent", sender: sender, originServerTS: ms)
    }

    /// Everyone's watermark as `m.read`, ours as `me`'s (where the "New messages" line starts).
    private static func readReceipts(_ receipts: [IG.ReadReceipt], account: String, messages: [IG.Message]) -> Event? {
        let reads: [(String, String, Int64)] = receipts.compactMap { receipt in
            guard let who = receipt.participantFbid, let seen = messages.last(where: { $0.ms <= receipt.ms }) else { return nil }
            return (who == account ? me : user(who), seen.id, receipt.ms)
        }
        return reads.isEmpty ? nil : receiptEvent(reads)
    }

    private static func receiptEvent(_ reads: [(user: String, event: String, ts: Int64)]) -> Event {
        var content: [String: JSON] = [:]
        for read in reads {
            var users = content[read.event]?["m.read"]?.object ?? [:]
            users[read.user] = ["ts": .number(Double(read.ts))]
            content[read.event] = ["m.read": .object(users)]
        }
        return Event(type: "m.receipt", content: .object(content))
    }

    private static func text(_ body: String) -> JSON { ["msgtype": "m.text", "body": .string(body)] }

    private static func media(_ type: String, _ body: String, url: String?, info: [String: JSON], extra: [String: JSON] = [:]) -> JSON {
        var fields: [String: JSON] = ["msgtype": .string(type), "body": .string(body), "info": .object(info.filter { $0.value != .null })]
        if let url { fields["url"] = .string(url) }
        return .object(fields.merging(extra) { a, _ in a })
    }

    private static func stateEvent(_ type: String, key: String = "", _ content: JSON) -> Event {
        Event(type: type, content: content, eventID: "$ig-\(type)-\(key)", sender: me, stateKey: key)
    }

    private static func member(_ id: String, name: String?, avatar: String?) -> Event {
        var content: [String: JSON] = ["membership": "join"]
        if let name = nonEmpty(name) { content["displayname"] = .string(name) }
        if let avatar = nonEmpty(avatar) { content["avatar_url"] = .string(avatar) }
        return Event(type: "m.room.member", content: .object(content), eventID: "$ig-member-\(id)", sender: id, stateKey: id)
    }

    private static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
}
