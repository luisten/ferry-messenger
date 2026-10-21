import Foundation

/// What a message shows as (PLAN §2.6 media table, DESIGN §6.3–6.8). Shapes are from the bridge source (mautrix/meta
/// v0.2609.0 `igconv/xma.go`, `from-instagram.go`) and live samples (S3, M5).
nonisolated enum MessageKind: Equatable, Sendable {
    case text, notice, emote
    case image, video, audio, voice, file, sticker
    /// An animated image: Instagram's GIFs (`animated_media`) and the ones we send, marked `info.fi.mau.gif`.
    case gif
    /// An Instagram share (the bridge's XMA) and how far the bridge got fetching its media.
    case share(ShareType, ShareState)
    /// A text with the bridge's link preview (`com.beeper.linkpreviews`).
    case link
    /// View-once media: the bridge sends a notice instead ("This image can only be viewed once…").
    case viewOnce
    /// A plain attachment over the size cap: the bridge's "Too large attachment" notice (S3).
    case tooLarge
    /// Unsent (redacted): a tombstone that keeps its sender and time.
    case unsent
    /// Instagram's own line about the chat ("… named the group …", "… left the group"): `body` as it is.
    case event
    /// Something the app can't show (`IGAdapter.unsupported`): what it is, "a poll" or "a message Ferry can't show".
    case unsupported(String)

    static let eventKey = "fi.ferry.event"
    static let unsupportedKey = "fi.ferry.unsupported"
    /// The text sent with a share (`IGAdapter.share`): a story reply, or a story reaction's emoji.
    static let shareTextKey = "fi.ferry.share_text"
    /// A sticker from Instagram's GIPHY picker: an animated image (`MediaInfo.isAnimated`) shown as a sticker.
    static let stickerKey = "fi.ferry.sticker"

    /// `other`: anything shared that isn't a reel, post or story (a profile, music…); the bridge can't fetch it.
    enum ShareType: String, Sendable { case reel, post, story, other }
    enum ShareState: Sendable { case ready, unresolved, unavailable, tooLarge }

    /// For an edited message pass the edit's `m.new_content` (S3: it has no `xma_fetch_status`, so a resolved reel
    /// reads as ready).
    init(type: String, content: JSON) {
        if type == "m.sticker" { self = .sticker; return }
        // Only the bridge's XMA parts carry `external_url`.
        let share = content["external_url"]?.string.map { ShareType(instagramURL: $0) ?? .other }
        // S3: `unresolved_media` = backfilled and not fetched yet. `xma_fetch_status` is absent on success, "skip"
        // when deferred, otherwise a failure; "reupload fail" means too big for the homeserver.
        if content["com.beeper.unresolved_media"] != nil { self = .share(share ?? .reel, .unresolved); return }
        if let status = content["fi.mau.instagram.xma_fetch_status"]?.string, status != "skip", let share {
            // `other` was never fetchable ("unrecognized type"): show its preview and link, not "unavailable".
            self = share == .other ? .share(.other, .ready) : .share(share, status == "reupload fail" ? .tooLarge : .unavailable)
            return
        }
        let body = content["body"]?.string ?? ""
        switch content["msgtype"]?.string {
        case "m.image" where content[Self.stickerKey] != nil: self = .sticker
        case "m.image": self = share.map { .share($0, .ready) } ?? (content["info"]?["fi.mau.gif"]?.bool == true ? .gif : .image)
        case "m.video": self = share.map { .share($0, .ready) } ?? .video
        case "m.audio": self = content["org.matrix.msc3245.voice"] != nil ? .voice : .audio
        case "m.file": self = .file
        // The bridge's own English notices are the only signal for these two (`errorToNotice`, `makeViewOnceError`).
        case "m.notice" where body == "Too large attachment": self = .tooLarge
        case "m.notice" where body.hasPrefix("This ") && body.hasSuffix(" once. Use the Instagram app to view."): self = .viewOnce
        case "m.notice" where content[Self.eventKey] != nil: self = .event
        case "m.notice" where content[Self.unsupportedKey]?.string != nil: self = .unsupported(content[Self.unsupportedKey]?.string ?? "")
        case "m.notice": self = .notice
        case "m.emote": self = .emote
        default:  // the spec says unknown msgtypes fall back to their body
            self = content["com.beeper.linkpreviews"]?.array?.isEmpty == false ? .link : .text
        }
    }

    /// One-line symbol and label for non-text kinds (inbox preview, reply quote).
    var media: (symbol: String, label: String)? {
        switch self {
        case .text, .notice, .emote, .link, .event: nil
        case .image: ("photo", "Photo")
        case .video: ("video", "Video")
        case .audio: ("waveform", "Audio")
        case .voice: ("waveform", "Voice message")
        case .file: ("doc", "File")
        case .sticker: ("face.smiling", "Sticker")
        case .gif: ("photo", "GIF")
        case .share(let type, _): (type.symbol, type.label)
        case .viewOnce: ("eye.slash", "View-once media")
        case .tooLarge: ("doc", "Attachment")
        case .unsent: ("arrow.uturn.backward", "Unsent message")
        case .unsupported: ("questionmark.bubble", "Unsupported message")
        }
    }

    /// A line across the thread, not a bubble: no sender label, menu or status.
    var isChatEvent: Bool {
        switch self {
        case .event, .unsupported: true
        default: false
        }
    }
}

extension MessageKind.ShareType {
    nonisolated init?(instagramURL: String) {
        guard let url = URL(string: instagramURL), let host = url.host(),
              host == "instagram.com" || host.hasSuffix(".instagram.com") else { return nil }
        let path = url.path()
        if path.contains("/reel/") || path.contains("/reels/") { self = .reel }
        else if path.contains("/p/") { self = .post }
        else if path.contains("/stories/") { self = .story }
        else { return nil }
    }

    nonisolated var label: String { self == .other ? "Attachment" : rawValue.capitalized }
    /// "Sent a reel", "Sent an attachment".
    nonisolated var phrase: String { self == .other ? "an attachment" : "a \(rawValue)" }
    nonisolated var symbol: String {
        switch self {
        case .reel: "play.rectangle.on.rectangle"
        case .post: "photo.on.rectangle"
        case .story: "circle.dashed"
        case .other: "link"
        }
    }
}

/// The fields media cards need from a message's current content (the latest edit's `m.new_content`).
nonisolated struct MediaInfo: Equatable, Sendable {
    var msgtype: String?
    /// The media itself (`mxc://`).
    var url: String?
    var mimetype: String?
    /// Bytes as the bridge reports them. Not always the download's size: for voice notes it's the size before the
    /// bridge converted them to Ogg (M5), so progress uses the HTTP length instead.
    var size: Int?
    var width: Double?
    var height: Double?
    /// Milliseconds. Voice notes carry it; reels don't (S3).
    var duration: Int?
    var thumbnailURL: String?
    var externalURL: URL?
    /// Photos and videos sent together, each its own content (`IGAdapter.album`); empty for one.
    var album: [JSON]
    /// A GIF, or a sticker from Instagram's GIPHY picker: plays like one (`info.fi.mau.gif`).
    var isAnimated: Bool

    static let albumKey = "fi.ferry.album"

    init(content: JSON) {
        let info = content["info"]
        msgtype = content["msgtype"]?.string
        url = content["url"]?.string
        mimetype = info?["mimetype"]?.string
        size = info?["size"]?.int64.map(Int.init)
        width = info?["w"]?.number
        height = info?["h"]?.number
        duration = (info?["duration"] ?? content["org.matrix.msc1767.audio"]?["duration"])?.int64.map(Int.init)
        thumbnailURL = info?["thumbnail_url"]?.string
        externalURL = content["external_url"]?.string.flatMap(URL.init(string:))
        album = content[Self.albumKey]?.array ?? []
        isAnimated = info?["fi.mau.gif"]?.bool == true
    }

    var isVideo: Bool { msgtype == "m.video" }

    /// "3 photos", "2 videos", "3 photos and videos": the pile's badge and "Share All".
    var albumLabel: String {
        let videos = album.filter { $0["msgtype"]?.string == "m.video" }.count
        return "\(album.count) \(videos == 0 ? "photos" : videos == album.count ? "videos" : "photos and videos")"
    }

    /// What a card shows before anything is downloaded: a video's thumbnail (for reels, the old preview image), an
    /// image itself.
    var previewURL: String? { isVideo ? thumbnailURL : url }

    /// Height over width, when the bridge said.
    var aspect: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return height / width
    }
}

/// A share's caption, from `formatted_body` as the bridge's `wrapXMACaption` builds it (S3), every part optional:
/// `<blockquote>eyebrow</blockquote><strong>title</strong><br>subtitle<p>caption</p><p><a href="url">url</a></p>`.
///
/// Live samples (M2 part 2, DESIGN §16 Q1): the bridge fills these only from IG's `title_text`/`subtitle_text`/
/// `caption_body_text` and ignores `header_title_text`, which is where IG puts the author.
/// - **Reels and stories** come with no text at all: just the link.
/// - **Posts** come as `<strong>{handle} {caption, cut to 100 chars + "…"}</strong>`.
/// So the author is the post title's first word, or the story URL's `/stories/<handle>/`. A reel's author is unknown.
nonisolated struct ShareCaption: Equatable, Sendable {
    var eyebrow: String?
    var title: String?
    var subtitle: String?
    var caption: String?
    /// The author's handle when the share's shape gives it away (see above); otherwise `author` falls back to a
    /// handle-shaped title.
    var handle: String?

    init() {}

    /// The caption of a message's current content: its `formatted_body`, plus what its `external_url` says.
    init(content: JSON) {
        self.init(html: content["formatted_body"]?.string)
        guard let link = content["external_url"]?.string, let url = URL(string: link) else { return }
        switch MessageKind.ShareType(instagramURL: link) {
        case .post:
            // `title_text` is "<handle> <caption>"; split it only when the first word is handle-shaped.
            if caption == nil, let title, let space = title.firstIndex(of: " "),
               let first = Self.handleShaped(title[..<space]) {
                handle = first
                let rest = title[space...].trimmingCharacters(in: .whitespaces)
                caption = rest.isEmpty ? nil : rest
                self.title = nil
            }
        case .story:
            // `/stories/<handle>/<media id>`
            let parts = url.pathComponents
            if let at = parts.firstIndex(of: "stories"), at + 1 < parts.count { handle = Self.handleShaped(parts[at + 1]) }
        default: break
        }
    }

    init(html: String?) {
        guard let html, !html.isEmpty else { return }
        func text(_ match: Substring?) -> String? {
            guard let match else { return nil }
            let text = Self.unescape(match.replacing("<br/>", with: "\n").replacing("<br>", with: "\n"))
            return text.isEmpty ? nil : text
        }
        eyebrow = text(html.firstMatch(of: /<blockquote>(.*?)<\/blockquote>/)?.1)
        title = text(html.firstMatch(of: /<strong>(.*?)<\/strong>/)?.1)
        subtitle = text(html.firstMatch(of: /<br>([^<]*)/)?.1)  // the caption's own line breaks are `<br/>`
        // Every paragraph but the trailing link is caption text (TextToHTML: escaped, newlines as `<br/>`).
        let paragraphs = html.matches(of: /<p>(.*?)<\/p>/).map(\.1).filter { !$0.hasPrefix("<a href=") }
        caption = text(paragraphs.isEmpty ? nil : Substring(paragraphs.joined(separator: "<br/>")))
    }

    /// The handle from the share's shape, else a title that is only a handle (other XMA kinds; otherwise the card
    /// shows the title as text).
    var author: String? {
        handle ?? title.flatMap { Self.handleShaped($0) }
    }

    /// Instagram usernames: letters, digits, `.` and `_`, at most 30.
    private static func handleShaped(_ text: some StringProtocol) -> String? {
        let text = String(text)
        return text.wholeMatch(of: /[A-Za-z0-9._]{1,30}/) != nil ? text : nil
    }

    /// Go's `html.EscapeString` escapes exactly these five.
    private static func unescape(_ text: some StringProtocol) -> String {
        String(text).replacing("&lt;", with: "<").replacing("&gt;", with: ">").replacing("&#34;", with: "\"")
            .replacing("&quot;", with: "\"").replacing("&#39;", with: "'").replacing("&amp;", with: "&")
    }
}

/// The first `com.beeper.linkpreviews` entry of a text (bridge `wrapLinkPreview`; keys from mautrix-go).
nonisolated struct LinkPreview: Equatable, Sendable {
    var url: URL
    var title: String?
    var summary: String?
    var imageURL: String?
    /// Height over width of the image, when known.
    var aspect: Double?

    init?(content: JSON) {
        guard let preview = content["com.beeper.linkpreviews"]?.array?.first,
              let url = (preview["matched_url"] ?? preview["og:url"])?.string.flatMap(URL.init(string:)) else { return nil }
        self.url = url
        title = preview["og:title"]?.string
        summary = preview["og:description"]?.string
        imageURL = preview["og:image"]?.string
        // IntOrString: the bridge may send either.
        func number(_ key: String) -> Double? { preview[key]?.number ?? preview[key]?.string.flatMap(Double.init) }
        if let w = number("og:image:width"), let h = number("og:image:height"), w > 0 { aspect = h / w }
    }
}

/// One row of a thread, after edits, reactions, redactions, replies, local echo and receipts are folded in.
nonisolated struct Message: Identifiable, Equatable, Sendable {
    /// The event ID, or `txn:<id>` for a local echo the server hasn't confirmed.
    var id: String
    var eventID: String?
    var txnID: String?
    var sender: String
    var ts: Int64
    var kind: MessageKind
    /// Text to show: the latest edit's body, reply fallback stripped. Empty for tombstones.
    var body: String
    /// The current content (latest edit's `m.new_content`), for M5's media cards.
    var content: JSON
    var isOwn: Bool
    var isEdited = false
    var editCount = 0
    var reply: Reply?
    var reactions: [Reaction] = []
    /// Only meaningful for our own messages.
    var status: Status = .sent
    /// Set on our last message once someone else's read receipt is at or after it.
    var isSeen = false
    /// On the newest message: everyone else (not us, not its sender) whose receipt is at or after it, first reader
    /// first. Groups show it ("Seen by Maya and Sam").
    var seenBy: [String] = []

    /// What was sent with a shared story (a reply, a reaction's emoji), shown under its card.
    var shareText: String? { content[MessageKind.shareTextKey]?.string }

    /// Ours, sent from this device and not back from Instagram yet. Our own message from Instagram's app or website
    /// arrives as an event, like theirs.
    var isLocalEcho: Bool { id.hasPrefix("txn:") }

    enum Status: Equatable, Sendable {
        /// Local echo, request in flight.
        case sending
        /// On our server.
        case sent
        /// The bridge says Instagram has it (`com.beeper.message_send_status` SUCCESS).
        case delivered
        case failed(String?)
    }

    struct Reaction: Equatable, Sendable {
        var key: String
        var senders: [String]
        /// Our reaction event with this key, so choosing it again can redact it.
        var myEventID: String?
        var count: Int { senders.count }

        /// One reaction with or without its variation selector: we send "❤️", Instagram stores and echoes "❤" (Android's
        /// A4 check, 2026-10-21: choosing ❤️ again reacted again instead of removing it).
        static func same(_ a: String, _ b: String) -> Bool {
            // By scalar: "❤️" is one Character, so a String search never finds the selector inside it.
            a.unicodeScalars.filter { $0 != "\u{FE0F}" }.elementsEqual(b.unicodeScalars.filter { $0 != "\u{FE0F}" })
        }
    }

    /// Whether `user` reacted with `key`.
    func reacted(_ key: String, by user: String) -> Bool {
        reactions.contains { Reaction.same($0.key, key) && $0.senders.contains(user) }
    }

    struct Reply: Equatable, Sendable {
        var eventID: String
        /// nil until the target is loaded (the view fetches it).
        var sender: String?
        var kind: MessageKind?
        var body: String
        var isLoaded: Bool { sender != nil }
    }
}

/// A send we've started but whose event hasn't come back through sync yet (PLAN §2.6 local echo).
nonisolated struct PendingMessage: Equatable, Sendable {
    var txnID: String
    var content: JSON
    var ts: Int64
    var state: State

    enum State: Equatable, Sendable {
        case sending
        case sent(String)
        case failed(String)
    }
}

/// PLAN §2.6: the pure fold from raw room events to thread rows.
nonisolated enum Timeline {
    /// Instagram's limits, as the bridge's `com.beeper.room_features` reports them.
    static let editMaxAge: Int64 = 900_000
    static let editMaxCount = 5
    static let maxTextLength = 1000

    static func reduce(_ room: Room, me: String) -> [Message] {
        reduce(room.events, me: me, pending: room.pending, receipts: room.receipts, related: room.related)
    }

    /// - Parameters:
    ///   - events: the room's window in timeline order (not timestamp order: backfill keeps Instagram's times).
    ///   - related: reply targets fetched from outside the window.
    static func reduce(_ events: [Event], me: String, pending: [PendingMessage] = [], receipts: [String: Room.Receipt] = [:],
                       related: [String: Event] = [:]) -> [Message] {
        var position: [String: Int] = [:]
        var redacted = Set<String>()
        var echoed = Set<String>()
        for (i, event) in events.enumerated() {
            if let id = event.eventID { position[id] = i }
            if let target = event.redactionTarget { redacted.insert(target) }
            if let txn = event.unsigned?.transactionID { echoed.insert(txn) }
        }
        func isRedacted(_ event: Event) -> Bool {
            event.unsigned?.redactedBecause != nil || redacted.contains(event.eventID ?? "")
        }

        var bases: [Event] = []
        var edits: [String: [Event]] = [:]
        // Each sender's latest surviving reaction per target (Instagram allows one per person). Redacted ones go
        // first: the bridge redacts a replaced reaction itself, and when Instagram's echo races our own send it
        // redacts our copy, which can land after its replacement in the timeline (both seen live in M4).
        var reactions: [String: [String: Event]] = [:]
        var statuses: [String: JSON] = [:]
        for event in events {
            switch event.type {
            case "m.room.message", "m.sticker":
                if let target = event.replacesEventID {
                    if !isRedacted(event) { edits[target, default: []].append(event) }
                } else if event.eventID != nil {
                    bases.append(event)
                }
            case "m.reaction":
                let relation = event.content["m.relates_to"]
                guard !isRedacted(event), relation?["rel_type"]?.string == "m.annotation", relation?["key"]?.string != nil,
                      let target = relation?["event_id"]?.string, let sender = event.sender else { continue }
                reactions[target, default: [:]][sender] = event
            case "com.beeper.message_send_status":
                if let target = event.content["m.relates_to"]?["event_id"]?.string { statuses[target] = event.content }
            default:
                break  // state and unknown events: no membership notices in v1
            }
        }

        var messages = bases.map { base -> Message in
            let id = base.eventID ?? ""
            let sender = base.sender ?? ""
            if isRedacted(base) {
                // Edits to it and reactions on it go with it. (A pre-redacted event has empty content, so a
                // redacted *edit* from backfill would show as a tombstone too; Instagram can't redact edits alone.)
                return Message(id: id, eventID: id, sender: sender, ts: base.originServerTS ?? 0, kind: .unsent, body: "",
                               content: .object([:]), isOwn: sender == me)
            }
            // Only the original sender can edit; the latest by timeline order wins, edits held until the target loads.
            let applied = (edits[id] ?? []).filter { $0.sender == base.sender && $0.content["m.new_content"]?.object != nil }
            let content = applied.last?.content["m.new_content"] ?? base.content
            var message = Message(id: id, eventID: id, txnID: base.unsigned?.transactionID, sender: sender, ts: base.originServerTS ?? 0,
                                  kind: MessageKind(type: base.type, content: content), body: body(of: content), content: content,
                                  isOwn: sender == me)
            // S3: the flag is on the edit's top-level content; resolve_media edits set it.
            message.isEdited = applied.contains { $0.content["com.beeper.dont_render_edited"]?.bool != true }
            // Distinct texts: Instagram's echo of our edit comes back through the double puppet as a second edit
            // with the same text (plus an empty `m.mentions`, M4), and only one counts toward the 5-edit limit.
            message.editCount = Set(applied.map { [$0.content["m.new_content"]?["msgtype"], $0.content["m.new_content"]?["body"]] }).count
            message.reactions = group(Array((reactions[id] ?? [:]).values), position: position, me: me)
            if message.isOwn {
                // Sent from the Instagram app and bridged back by the double puppet: Instagram has it already.
                message.status = base.content["fi.mau.double_puppet_source"] != nil ? .delivered : status(statuses[id])
            }
            return message
        }

        for pending in pending where !echoed.contains(pending.txnID) {
            if case .sent(let id) = pending.state, position[id] != nil { continue }  // echo arrived without our txn ID
            var message = Message(id: "txn:\(pending.txnID)", txnID: pending.txnID, sender: me, ts: pending.ts,
                                  kind: MessageKind(type: "m.room.message", content: pending.content),
                                  body: body(of: pending.content), content: pending.content, isOwn: true)
            switch pending.state {
            case .sending: message.status = .sending
            case .sent(let id): message.eventID = id; message.status = .sent
            case .failed(let reason): message.status = .failed(reason)
            }
            messages.append(message)
        }

        // Replies last, so a quote shows its target as it is now (edited, or unsent).
        let byID = Dictionary(messages.compactMap { m in m.eventID.map { ($0, m) } }, uniquingKeysWith: { first, _ in first })
        let originals = Dictionary(bases.map { ($0.eventID ?? "", $0.content) }, uniquingKeysWith: { first, _ in first })
        for i in messages.indices where messages[i].kind != .unsent {
            let content = messages[i].eventID.flatMap { originals[$0] } ?? messages[i].content
            guard let target = replyTarget(content) else { continue }
            messages[i].reply = quote(target, loaded: byID, related: related)
        }

        // Seen: someone else's m.read at or after our last message. A receipt outside the window is older.
        if let last = messages.lastIndex(where: { $0.isOwn && $0.kind != .unsent && !$0.kind.isChatEvent && $0.eventID.flatMap { position[$0] } != nil }),
           let at = messages[last].eventID.flatMap({ position[$0] }) {
            messages[last].isSeen = receipts.contains { user, receipt in user != me && (position[receipt.eventID] ?? -1) >= at }
        }
        if let newest = messages.lastIndex(where: { !$0.kind.isChatEvent && $0.eventID.flatMap { position[$0] } != nil }),
           let at = messages[newest].eventID.flatMap({ position[$0] }) {
            let sender = messages[newest].sender
            messages[newest].seenBy = receipts.filter { $0.key != me && $0.key != sender && (position[$0.value.eventID] ?? -1) >= at }
                .sorted { ($0.value.ts, $0.key) < ($1.value.ts, $1.key) }.map(\.key)
        }
        return messages
    }

    /// The jump-to-newest button's count: messages from others (no chat events or tombstones) newer than `ms`, the
    /// newest message's time when the button appeared.
    static func newCount(_ messages: [Message], after ms: Int64) -> Int {
        messages.count { !$0.isOwn && !$0.kind.isChatEvent && $0.kind != .unsent && $0.ts > ms }
    }

    /// "Seen by Maya", "Seen by Maya and Sam", "Seen by Maya, Sam + 2", or "Seen by everyone" once all of three or
    /// more have (Instagram's web app; first names, as the rest of the thread uses).
    static func seenByLine(_ names: [String], everyone: Bool) -> String? {
        switch names.count {
        case 0: nil
        case 3... where everyone: "Seen by everyone"
        case 1: "Seen by \(names[0])"
        case 2: "Seen by \(names[0]) and \(names[1])"
        default: "Seen by \(names[0]), \(names[1]) + \(names.count - 2)"
        }
    }

    /// The event to send our "Seen" for: the newest message from someone else. Callers send it only while the chat
    /// is unread (`AppModel.markRead`) and must check `Inbox.allowsReceipts` first.
    static func receiptTarget(_ room: Room, me: String) -> String? {
        room.lastMessage(where: { $0.sender != me })?.eventID
    }

    static func canEdit(_ message: Message, now: Date = .now) -> Bool {
        message.isOwn && message.eventID != nil && message.kind == .text && message.editCount < editMaxCount
            && Int64(now.timeIntervalSince1970 * 1000) - message.ts < editMaxAge
    }

    /// The text to show for a message's content. Replies may carry a fallback quote of their target (`> ` lines,
    /// then a blank line) that clients must strip. `formatted_body` (and its `<mx-reply>`) isn't rendered in v1.
    static func body(of content: JSON) -> String {
        let body = content["body"]?.string ?? ""
        guard replyTarget(content) != nil, body.hasPrefix(">") else { return body }
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        while lines.first?.hasPrefix(">") == true { lines.removeFirst() }
        if lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    static func replyTarget(_ content: JSON) -> String? {
        content["m.relates_to"]?["m.in_reply_to"]?["event_id"]?.string
    }

    // MARK: Layout (DESIGN §6.1)

    enum GroupPosition: Sendable { case single, first, middle, last }

    struct Row: Identifiable, Equatable, Sendable {
        var message: Message
        var position: GroupPosition
        /// Points above the row: 2 inside a group, 10 between groups, 16 when a time label shows.
        var spacing: Double
        /// A time label above the row: the first row, and after a gap of more than an hour.
        var showsTime: Bool
        /// Groups only, on someone else's message; nil in DMs and on ours.
        var groupSender: GroupSender?
        /// The "New messages" line goes above this row.
        var startsUnread = false
        var id: String { message.id }
    }

    /// DESIGN §6.1 groups: the sender's name above the first bubble of a run, their avatar beside the last. Every
    /// incoming row of a group is indented for the avatar; a tombstone shows neither (its text names the sender).
    struct GroupSender: Equatable, Sendable {
        var showsName: Bool
        var showsAvatar: Bool
    }

    /// `unreadAfter`: how far we'd read when the chat opened (`Room.receipts[me]`, ms), nil when it opened read. The
    /// "New messages" line goes above the first message from someone else after it and after our own last message
    /// (we'd read what came before that), so it goes once we reply.
    static func layout(_ messages: [Message], isGroup: Bool = false, unreadAfter: Int64? = nil) -> [Row] {
        let firstUnread = unreadAfter.flatMap { after in
            let from = max(after, messages.last(where: \.isOwn)?.ts ?? .min)
            return messages.firstIndex { !$0.isOwn && $0.ts > from }
        }
        func joins(_ i: Int) -> Bool {
            guard i > 0, i < messages.count, i != firstUnread else { return false }  // the line starts a new run
            let (a, b) = (messages[i - 1], messages[i])
            return a.sender == b.sender && b.ts - a.ts < 180_000 && [a, b].allSatisfy { $0.kind != .unsent && !$0.kind.isChatEvent }
        }
        return messages.indices.map { i in
            let position: GroupPosition = switch (joins(i), joins(i + 1)) {
            case (false, false): .single
            case (false, true): .first
            case (true, true): .middle
            case (true, false): .last
            }
            let showsTime = i == 0 || messages[i].ts - messages[i - 1].ts > 3_600_000
            let spacing: Double = i == 0 ? 0 : joins(i) ? 2 : showsTime || i == firstUnread ? 16 : 10
            let labelled = messages[i].kind != .unsent
            let sender = isGroup && !messages[i].isOwn && !messages[i].kind.isChatEvent  // a chat event spans the thread
                ? GroupSender(showsName: labelled && (position == .single || position == .first),
                              showsAvatar: labelled && (position == .single || position == .last))
                : nil
            return Row(message: messages[i], position: position, spacing: spacing, showsTime: showsTime, groupSender: sender,
                       startsUnread: i == firstUnread)
        }
    }

    // MARK: Helpers

    private static func group(_ reactions: [Event], position: [String: Int], me: String) -> [Message.Reaction] {
        var groups: [Message.Reaction] = []
        for event in reactions.sorted(by: { position[$0.eventID ?? ""] ?? 0 < position[$1.eventID ?? ""] ?? 0 }) {
            guard let key = event.content["m.relates_to"]?["key"]?.string, let sender = event.sender else { continue }
            let mine = sender == me ? event.eventID : nil
            if let i = groups.firstIndex(where: { Message.Reaction.same($0.key, key) }) {
                groups[i].senders.append(sender)
                groups[i].myEventID = groups[i].myEventID ?? mine
            } else {
                groups.append(Message.Reaction(key: key, senders: [sender], myEventID: mine))
            }
        }
        return groups
    }

    /// mautrix statuses: SUCCESS, PENDING, FAIL_RETRIABLE, FAIL_PERMANENT (the failures carry a human `message`).
    private static func status(_ content: JSON?) -> Message.Status {
        guard let status = content?["status"]?.string else { return .sent }
        if status == "SUCCESS" { return .delivered }
        if status.hasPrefix("FAIL") { return .failed(content?["message"]?.string ?? content?["reason"]?.string) }
        return .sent
    }

    private static func quote(_ target: String, loaded: [String: Message], related: [String: Event]) -> Message.Reply {
        if let message = loaded[target] {
            return Message.Reply(eventID: target, sender: message.sender, kind: message.kind, body: message.body)
        }
        if let event = related[target], let sender = event.sender {
            let gone = event.unsigned?.redactedBecause != nil
            return Message.Reply(eventID: target, sender: sender, kind: gone ? .unsent : MessageKind(type: event.type, content: event.content),
                                 body: gone ? "" : body(of: event.content))
        }
        return Message.Reply(eventID: target, sender: nil, kind: nil, body: "")
    }
}
