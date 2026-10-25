import SwiftUI

/// What a row can ask the thread to do (DESIGN §6.2 context menu).
struct MessageActions {
    var react: (String, Message) -> Void
    var reply: (Message) -> Void
    var edit: (Message) -> Void
    var unsend: (Message) -> Void
    var retry: (Message) -> Void
    var discard: (Message) -> Void
    var showOriginal: (String) -> Void
    var loadReplyTarget: (String) -> Void
    /// Media: download (or cancel the download in progress), then full screen.
    var openMedia: (Message) -> Void
    /// "Load video" on a backfilled share (`resolve_media`).
    var resolveMedia: (Message) -> Void
    /// Photos sent together: download them all, then the share sheet.
    var shareAll: (Message) -> Void
    /// A tap on the reactions: who reacted with what.
    var showReactions: (Message) -> Void
    /// A long press: `MessageSheet`.
    var showMenu: (Message) -> Void
    /// Our user ID ("@me"), for "is this reaction ours".
    var me: String
    /// A tap on someone's picture in a group: who they are.
    var showPerson: (String) -> Void
    /// Request rooms: nothing that sends. The bridge marks the chat read on Instagram for *every* event we send
    /// (seen in its logs in M4: "Sending implicit read receipt"), so even a reaction would leak "Seen".
    var readOnly = false
}

/// One thread row (DESIGN §6.1–6.2): optional time label, reply quote, the bubble with its reactions, then
/// "Edited" and the status line.
struct MessageRow: View {
    let row: Timeline.Row
    let me: String
    let identity: AccountIdentity?
    /// First name for a user ID ("Kivo"), for "You replied to Kivo" and "Kivo unsent a message".
    let name: (String) -> String
    /// Full name and avatar for a user ID: a group's sender label (`Room.displayName`, `Room.avatarURL`).
    let member: (String) -> (name: String, avatarURL: String?)
    /// Our last message carries the status line (Sending… / Sent / Delivered / Seen).
    let showsStatus: Bool
    /// Groups: "Seen by Maya and Sam" under the newest message (ours: in place of "Seen").
    var seenLine: String?
    /// Reactions show who chose them.
    var isGroup = false
    var highlighted = false
    let actions: MessageActions

    /// DESIGN §6.1 groups: the sender's avatar (28 pt) beside the last bubble of a run, and the indent it leaves on
    /// every incoming row.
    static let avatarSize: CGFloat = 28
    static let groupIndent: CGFloat = avatarSize + 6

    private var message: Message { row.message }
    private var own: Bool { message.isOwn }
    private var alignment: Alignment { own ? .trailing : .leading }
    private var indent: CGFloat { row.groupSender == nil ? 0 : Self.groupIndent }
    private var reactionsInset: CGFloat { message.reactions.isEmpty ? 0 : 14 }

    var body: some View {
        VStack(spacing: 0) {
            if row.startsUnread { unreadLine }
            if message.kind.isChatEvent { eventLine } else { bubbleRow }
        }
    }

    /// Where what you hadn't read starts, when the chat opened unread (the thread opens here when it's long).
    private var unreadLine: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color(.separator)).frame(height: 1)
            Text("New messages").font(.caption.weight(.semibold)).foregroundStyle(.inkSecondary).fixedSize()
            Rectangle().fill(Color(.separator)).frame(height: 1)
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
        .accessibilityAddTraits(.isHeader)  // VoiceOver's headings rotor jumps to it
        .accessibilityIdentifier("thread.unreadLine")
    }

    private var bubbleRow: some View {
        VStack(alignment: own ? .trailing : .leading, spacing: 3) {
            if row.showsTime { time }
            if row.groupSender?.showsName == true, message.reply == nil {  // a reply's caption names the sender instead
                // Neutral, never coloured: colour means account (DESIGN §3.6). The bubble says it to VoiceOver.
                Text(member(message.sender).name).font(.caption).foregroundStyle(.inkSecondary).lineLimit(1)
                    .padding(.leading, indent + 12)
                    .accessibilityHidden(true)
            }
            if let reply = message.reply { quote(reply).padding(.leading, indent) }
            // Instagram's own line about a share: "Replied to @Tamo Veska's story", "Reacted to your story".
            if let eyebrow = ShareCaption(content: message.content).eyebrow, message.kind != .unsent {
                Text(eyebrow).font(.caption).foregroundStyle(.inkSecondary).padding(.horizontal, 4).padding(.leading, indent)
                    .accessibilityIdentifier("thread.shareEyebrow")
            }
            HStack(alignment: .bottom, spacing: 6) {
                if let sender = row.groupSender {
                    Group {
                        if sender.showsAvatar {
                            let who = member(message.sender)
                            Button { actions.showPerson(message.sender) } label: {
                                MXCImage(mxc: who.avatarURL, size: Self.avatarSize, initial: who.name)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(who.name)
                            .accessibilityHint("Shows who they are")
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: Self.avatarSize, height: Self.avatarSize)
                    .padding(.bottom, reactionsInset)  // level with the bubble, not with its reaction pills
                }
                bubble
                    .modifier(SpokenSender(name: row.groupSender != nil && message.kind != .unsent ? member(message.sender).name : nil))
                    .overlay(alignment: own ? .bottomLeading : .bottomTrailing) { if message.shareText == nil { pills } }
                    .padding(.bottom, reactionsInset)
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .containerRelativeFrame(.horizontal, alignment: alignment) { width, _ in width * 0.75 }
                    .frame(maxWidth: .infinity, alignment: alignment)
            }
            Group {
                if message.isEdited && message.kind != .unsent {
                    Text("Edited").font(.caption2).foregroundStyle(.inkSecondary).padding(.horizontal, 6)
                }
                statusLine
            }
            .padding(.leading, indent)
        }
    }

    private var time: some View {
        Text(Self.timeLabel(message.ts)).font(.caption).foregroundStyle(.inkSecondary)
            .frame(maxWidth: .infinity).padding(.bottom, 6)
    }

    /// Instagram's own lines and what the app can't show: small centred text across the thread, no bubble or menu.
    private var eventLine: some View {
        VStack(spacing: 3) {
            if row.showsTime { time }
            Text(eventText).font(.footnote).foregroundStyle(.inkSecondary).multilineTextAlignment(.center)
                .padding(.horizontal, 24).frame(maxWidth: .infinity)
                .accessibilityIdentifier("thread.event")
        }
    }

    private var eventText: String {
        guard case .unsupported(let what) = message.kind else { return message.body }
        return "\(own ? "You" : name(message.sender)) sent \(what). Open Instagram to see it."
    }

    // MARK: Bubble

    /// A story reply or reaction is the story with what was sent under it, as Instagram shows them. Its reactions sit
    /// on what was sent, not by the card's far edge (Android's live check, 2026-10-21).
    @ViewBuilder private var bubble: some View {
        if let text = message.shareText {
            VStack(alignment: own ? .trailing : .leading, spacing: 4) {
                content
                textBubble(text).overlay(alignment: own ? .bottomLeading : .bottomTrailing) { pills }
            }
        } else {
            content
        }
    }

    /// DESIGN §6.2: the reactions on the bubble's bottom edge.
    @ViewBuilder private var pills: some View {
        if !message.reactions.isEmpty {
            ReactionPills(reactions: message.reactions, me: me, face: isGroup ? member : nil, show: { actions.showReactions(message) })
                .offset(x: own ? -8 : 8, y: 14)
        }
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .unsent:
            Text(own ? "You unsent a message" : "\(name(message.sender)) unsent a message")
                .font(.footnote).foregroundStyle(.inkSecondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .accessibilityIdentifier("thread.unsent")
        case .text, .notice, .emote:
            textBubble(message.body)
        case .link:
            LinkBubble(message: message, own: own)
                .background(fill)
                .clipShape(Self.shape(row.position, own: own))
                .contentShape(.contextMenuPreview, Self.shape(row.position, own: own))
                .menu(message, actions)
                .accessibilityIdentifier("thread.bubble")
        default:
            MediaCard(message: message, own: own, sender: name(message.sender), fill: fill, actions: actions)
                .clipShape(Self.shape(row.position, own: own))
                .contentShape(.contextMenuPreview, Self.shape(row.position, own: own))
                .menu(message, actions)
                .accessibilityIdentifier("thread.media")
        }
    }

    @ViewBuilder private func textBubble(_ text: String) -> some View {
        if Self.isEmojiOnly(text) {
            Text(text).font(.system(size: 48)).menu(message, actions)  // DESIGN §6.1: no bubble
        } else {
            Text(text)
                .font(.body)
                .foregroundStyle(own ? Color.white : Color.primary)
                .tint(own ? .white : nil)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(fill, in: Self.shape(row.position, own: own))
                .contentShape(.contextMenuPreview, Self.shape(row.position, own: own))
                .menu(message, actions)
                .accessibilityLabel(spoken(text))
                .accessibilityIdentifier("thread.bubble")
        }
    }

    private var fill: Color { own ? (identity?.color.fill ?? .accentColor) : .bubbleIncoming }

    /// VoiceOver names the sender where a run of bubbles starts, and the account at the top of a time block
    /// ("From you, as Tamo"); inside a run it's just the text (DESIGN §11: less noise). In a group every incoming
    /// bubble names its sender instead (`SpokenSender`).
    private func spoken(_ text: String) -> String {
        guard row.position == .single || row.position == .first, row.groupSender == nil else { return text }
        let who = own ? (row.showsTime ? "From you, as \(identity?.name ?? "you")" : "You")
            : (row.showsTime ? "From \(name(message.sender))" : name(message.sender))
        return "\(who): \(text)"
    }

    /// DESIGN §6.1: radius 20; corners on the sender's side shrink to 6 where the bubble joins its neighbour.
    static func shape(_ position: Timeline.GroupPosition, own: Bool) -> UnevenRoundedRectangle {
        let top: CGFloat = position == .middle || position == .last ? 6 : 20
        let bottom: CGFloat = position == .first || position == .middle ? 6 : 20
        return own
            ? UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: bottom, topTrailingRadius: top)
            : UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: 20, topTrailingRadius: 20)
    }

    /// 1–3 emoji and nothing else.
    static func isEmojiOnly(_ text: String) -> Bool {
        (1...3).contains(text.count) && text.allSatisfy { $0.unicodeScalars.first?.properties.isEmojiPresentation == true
            || $0.unicodeScalars.count > 1 && $0.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0xFF } }
    }

    // MARK: Reply quote (DESIGN §6.2)

    private func quote(_ reply: Message.Reply) -> some View {
        let replied: String = switch reply.sender {
        case nil: "replied"
        case message.sender: own ? "replied to yourself" : "replied to themselves"
        case me: "replied to you"
        case let other?: "replied to \(name(other))"
        }
        // Where a group's run starts this is its sender label too, so the full name: "Sam Lee replied to Theo".
        let replier = own ? "You" : row.groupSender?.showsName == true ? member(message.sender).name : name(message.sender)
        let caption = "\(replier) \(replied)"
        let snippet = !reply.isLoaded ? "Loading…" : reply.kind == .unsent ? "Unsent message"
            : reply.kind?.media?.label ?? reply.body
        return VStack(alignment: own ? .trailing : .leading, spacing: 3) {
            Text(caption).font(.caption).foregroundStyle(.inkSecondary).padding(.horizontal, 4)
            Button { actions.showOriginal(reply.eventID) } label: {
                Text(snippet)
                    .font(.subheadline).lineLimit(2)
                    .foregroundStyle(.inkSecondary)  // a Button: .secondary would take the tint
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(.separator)))
            }
            .buttonStyle(.plain)
            .containerRelativeFrame(.horizontal, alignment: alignment) { width, _ in width * 0.7 }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
        .task(id: reply.eventID) { if !reply.isLoaded { actions.loadReplyTarget(reply.eventID) } }
        .accessibilityElement(children: .combine)
    }

    // MARK: Status (DESIGN §6.2)

    @ViewBuilder private var statusLine: some View {
        if case .failed = message.status {
            Button { actions.retry(message) } label: {
                Label("Not sent. Tap to retry.", systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(.statusError)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("thread.retry")
        } else if showsStatus, message.kind != .unsent {
            Text(seenLine ?? statusText).font(.caption2).foregroundStyle(.inkSecondary).padding(.horizontal, 6)
                .accessibilityIdentifier("thread.status")
        } else if let seenLine {
            Text(seenLine).font(.caption2).foregroundStyle(.inkSecondary).padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .trailing)  // where Instagram's web app puts it
                .accessibilityIdentifier("thread.seenBy")
        }
    }

    private var statusText: String {
        switch message.status {
        case .sending: "Sending…"
        case .sent: message.isSeen ? "Seen" : "Sent"
        case .delivered: message.isSeen ? "Seen" : "Delivered"
        case .failed: ""
        }
    }

    static func timeLabel(_ ts: Int64, now: Date = .now) -> String {
        let date = Date(timeIntervalSince1970: Double(ts) / 1000)
        if Calendar.current.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Groups: every incoming bubble, whatever its kind, tells VoiceOver who sent it ("From Theo Park, …": the label's
/// parts are read with a pause between them); the visible name and avatar are hidden from it.
private struct SpokenSender: ViewModifier {
    let name: String?

    func body(content: Content) -> some View {
        if let name {
            content.accessibilityLabel { label in
                Text("From \(name)")
                label
            }
        } else {
            content
        }
    }
}

// MARK: - Long-press sheet (DESIGN §6.2: reactions, Reply, Copy, Edit, Unsend)

private extension View {
    func menu(_ message: Message, _ actions: MessageActions) -> some View {
        modifier(MessageMenu(message: message, actions: actions))
    }
}

/// Double-tap hearts; a long press opens `MessageSheet` (VoiceOver: "React or reply").
private struct MessageMenu: ViewModifier {
    let message: Message
    let actions: MessageActions

    func body(content: Content) -> some View {
        content
            .environment(\.messageHold, MessageHold(messageID: message.id) { actions.showMenu(message) })  // `.tapOrHold`
            // Double-tap hearts it, like Instagram (DESIGN §6.2). Not on media: its taps play, load or cancel.
            .gesture(TapGesture(count: 2).onEnded { if canSend && !message.reacted("❤️", by: actions.me) { actions.react("❤️", message) } },
                     including: message.kind.media == nil ? .all : .subviews)
            .onLongPressGesture(minimumDuration: TapOrHoldButtonStyle.hold) { actions.showMenu(message) }
            .accessibilityAction(named: "React or reply") { actions.showMenu(message) }
    }

    private var canSend: Bool { !actions.readOnly && message.eventID != nil }
}

extension EnvironmentValues {
    /// The bubble's long press, for a card's Buttons.
    @Entry var messageHold: MessageHold?
}

/// The bubble's long press: `MessageSheet`. Equal by message, so the new closure each update doesn't redraw every card
/// (ThreadView's `showMenu` takes only the message's ID).
nonisolated struct MessageHold: Equatable {
    let messageID: String
    let open: @MainActor () -> Void

    static func == (a: Self, b: Self) -> Bool { a.messageID == b.messageID }
}

/// A media card's Button: a tap is its own, a hold the bubble's (`MessageMenu`). A Button's own press took the touch
/// from the bubble, so holding a photo, a video or a post's image did nothing (2026-10-22). A plain tap gesture made the
/// bubble's hold wait ~0.8 s for it to give up, and a hold with priority over it stopped the tap: both live here. Not
/// for small controls (voice notes, "Open in Instagram").
struct TapOrHoldButtonStyle: PrimitiveButtonStyle {
    /// 0.3 s, as the mic's hold (0.4 felt slow, 2026-10-22): a slow tap on a photo still opens it.
    static let hold = 0.3
    @Environment(\.messageHold) private var messageHold

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.gesture(LongPressGesture(minimumDuration: Self.hold).exclusively(before: TapGesture()).onEnded { gesture in
            if case .first = gesture { messageHold?.open() } else { configuration.trigger() }
        })
    }
}

extension PrimitiveButtonStyle where Self == TapOrHoldButtonStyle {
    static var tapOrHold: Self { Self() }
}

/// The long press (2026-10-21, the user's call over the stock context menu, whose palette iOS draws small): one line
/// naming the message, a big row of recent reactions and "+" for any emoji (Instagram takes any, one per person: the
/// same again removes it), then what the menu held. No reactions where nothing can be sent (requests, ours on its way).
struct MessageSheet: View {
    let message: Message
    /// "You", or their first name.
    let sender: String
    let actions: MessageActions
    /// Closes the sheet, then runs what's given (Reply focuses the composer, Unsend confirms) once it's gone.
    let close: (@escaping () -> Void) -> Void
    @State private var picking = false
    /// The content's height: the sheet fits it until "+" opens the emoji keyboard (`.large`).
    @State private var height: CGFloat = 320
    @State private var detent = PresentationDetent.height(320)
    @State private var row = RecentReactions.row()

    var body: some View {
        let mine = message.reactions.first { $0.myEventID != nil }?.key
        VStack(alignment: .leading, spacing: 18) {
            Text("\(sender): \(message.kind.media?.label ?? message.body)")
                .font(.footnote).foregroundStyle(.inkSecondary).lineLimit(1)
            if canSend {
                HStack(spacing: 4) {
                    ForEach(RecentReactions.shown(row, current: mine), id: \.self) { key in
                        let isMine = mine.map { Message.Reaction.same($0, key) } ?? false
                        Button { react(key) } label: {
                            Text(key).font(.largeTitle).dynamicTypeSize(...DynamicTypeSize.accessibility1)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background { if isMine { Circle().fill(Color.primary.opacity(0.12)) } }
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isMine ? .isSelected : [])
                        .accessibilityHint(isMine ? "Removes your reaction" : "")
                    }
                    if EmojiField.isAvailable {
                        Button { picking = true } label: {
                            Image(systemName: "plus").font(.title2.weight(.semibold)).foregroundStyle(Color.primary)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color.primary.opacity(0.06), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("All emoji")
                        .accessibilityIdentifier("sheet.allEmoji")
                    }
                }
                .background { EmojiField(active: $picking, picked: react).frame(width: 1, height: 1).opacity(0) }
                .accessibilityIdentifier("sheet.reactions")
            }
            VStack(spacing: 0) { actionRows }
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 16))
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
            height = new
            if !picking { detent = .height(new) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(height), .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var actionRows: some View {
        if canSend { row("Reply", "arrowshape.turn.up.left") { close { actions.reply(message) } } }
        if let text = message.shareText ?? (message.kind.media == nil && !message.body.isEmpty ? message.body : nil) {
            row("Copy", "doc.on.doc") { UIPasteboard.general.string = text; close {} }
        }
        if !actions.readOnly, Timeline.canEdit(message) { row("Edit", "pencil") { close { actions.edit(message) } } }
        if case let info = MediaInfo(content: message.content), info.album.count > 1 {
            row("Share All", "square.and.arrow.up.on.square", detail: info.albumLabel) { close { actions.shareAll(message) } }
        }
        if let url = message.content["external_url"]?.string.flatMap(URL.init(string:)) {
            row("Open in Instagram", "arrow.up.forward.app") { close { UIApplication.shared.open(url) } }
        }
        if !actions.readOnly, message.isOwn, message.eventID != nil {
            row("Unsend", "arrow.uturn.backward", destructive: true) { close { actions.unsend(message) } }
        } else if message.isOwn, case .failed = message.status {
            row("Delete", "trash", destructive: true) { close { actions.discard(message) } }
        }
    }

    private func row(_ title: String, _ symbol: String, detail: String? = nil, destructive: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.inkSecondary) }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? Color.statusError : Color.primary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sheet.\(title)")
    }

    private var canSend: Bool { !actions.readOnly && message.eventID != nil }

    private func react(_ key: String) {
        actions.react(key, message)
        close {}
    }
}

/// The reactions a long press offers first: the last six used on this device, any account, kept in place so the row
/// never shuffles under a thumb (a new one goes first, the oldest drops off); the defaults until then.
nonisolated enum RecentReactions {
    static let defaults = ["❤️", "😂", "😮", "😢", "🔥", "👍"]
    private static let storeKey = "reactions.recent"

    /// `stored`, or the defaults for what's missing.
    static func row(_ stored: [String]? = UserDefaults.standard.stringArray(forKey: storeKey)) -> [String] {
        var row = Array((stored ?? []).prefix(defaults.count))
        for key in defaults where row.count < defaults.count && !row.contains(where: { Message.Reaction.same($0, key) }) {
            row.append(key)
        }
        return row
    }

    static func adding(_ key: String, to row: [String]) -> [String] {
        row.contains { Message.Reaction.same($0, key) } ? row : Array(([key] + row).prefix(defaults.count))
    }

    /// Our current reaction, in the last place when it isn't one of the six: it's how to remove it.
    static func shown(_ row: [String], current: String?) -> [String] {
        guard let current, !row.contains(where: { Message.Reaction.same($0, current) }) else { return row }
        return row.dropLast() + [current]
    }

    static func use(_ key: String) {
        UserDefaults.standard.set(adding(key, to: row()), forKey: storeKey)
    }
}

/// A hidden field on the system emoji keyboard (search, skin tones): iOS has no emoji picker, but a field can ask for
/// that keyboard (`textInputMode`). The first emoji typed is the pick; anything else is ignored.
struct EmojiField: UIViewRepresentable {
    @Binding var active: Bool
    let picked: (String) -> Void

    /// Not without the emoji keyboard among the user's keyboards.
    static var isAvailable: Bool { UITextInputMode.activeInputModes.contains { $0.primaryLanguage == "emoji" } }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.tintColor = .clear
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.picked = picked
        if active, !field.isFirstResponder { field.becomeFirstResponder() }
        if !active, field.isFirstResponder { field.resignFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }

    final class Field: UITextField {
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var picked: (String) -> Void
        init(picked: @escaping (String) -> Void) { self.picked = picked }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if let emoji = string.first(where: EmojiField.isEmoji) { picked(String(emoji)) }
            return false
        }
    }

    /// An emoji, not a digit or a letter that has an emoji form ("1", "#").
    nonisolated static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first, first.properties.isEmoji else { return false }
        return first.properties.isEmojiPresentation || character.unicodeScalars.count > 1
    }
}

// MARK: - Pieces

/// DESIGN §6.2: emoji (+ count when more than one) in a capsule overlapping the bubble's bottom edge. In a group each
/// emoji has the faces of who chose it, stacked (Instagram's), up to three and then a count. A tap lists who reacted.
struct ReactionPills: View {
    let reactions: [Message.Reaction]
    let me: String
    /// Groups: a user's name and picture (`MessageRow.member`); nil in a DM, where the count says enough.
    let face: ((String) -> (name: String, avatarURL: String?))?
    let show: () -> Void

    static let faceSize: CGFloat = 16

    var body: some View {
        Button(action: show) {
            HStack(spacing: face == nil ? 2 : 6) {
                ForEach(reactions, id: \.key) { reaction in
                    HStack(spacing: 2) {
                        Text(reaction.key)
                        if let face {
                            HStack(spacing: -5) {
                                ForEach(reaction.senders.prefix(3), id: \.self) { user in
                                    let who = face(user)
                                    MXCImage(mxc: who.avatarURL, size: Self.faceSize, initial: who.name)
                                        .overlay(Circle().stroke(Color.reactionBackground, lineWidth: 1.5))
                                }
                            }
                            if reaction.count > 3 { count(reaction.count - 3, plus: true) }
                        } else if reaction.count > 1 {
                            count(reaction.count, plus: false)
                        }
                    }
                }
            }
            .font(.system(size: 14))
            .fixedSize()  // squeezed, the first emoji's Text shrank under its three faces (2026-10-25)
            .padding(.horizontal, 6)
            .frame(minHeight: 24)
            .background(Color.reactionBackground, in: .capsule)
            .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 2))
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reactions: " + reactions.map(spoken).joined(separator: ", "))
        .accessibilityHint("Shows who reacted")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("thread.reactions")
    }

    private func count(_ n: Int, plus: Bool) -> some View {
        Text(plus ? "+\(n)" : "\(n)").font(.caption.weight(.semibold)).foregroundStyle(.inkSecondary)
    }

    /// "❤️ 2" in a DM; "❤️ from Maya and you" in a group.
    private func spoken(_ reaction: Message.Reaction) -> String {
        guard let face else { return reaction.count > 1 ? "\(reaction.key) \(reaction.count)" : reaction.key }
        let names = reaction.senders.map { $0 == me ? "you" : face($0).name }
        return "\(reaction.key) from \(names.formatted(.list(type: .and)))"
    }
}

/// Who reacted with what (a tap on a message's reactions), as Instagram lists them: everyone's face, name and emoji.
struct ReactionList: View {
    let message: Message
    let me: String
    let member: (String) -> (name: String, avatarURL: String?)

    var body: some View {
        NavigationStack {
            List {
                ForEach(message.reactions.flatMap { reaction in reaction.senders.map { (user: $0, key: reaction.key) } }, id: \.user) { item in
                    let who = member(item.user)
                    HStack(spacing: 12) {
                        MXCImage(mxc: who.avatarURL, size: 36, initial: who.name)
                        Text(item.user == me ? "You" : who.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.key).font(.title2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("reactions.row")
                }
            }
            .listStyle(.plain)
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// DESIGN T1: an incoming bubble with three dots; a static "typing…" under Reduce Motion.
struct TypingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Text("typing…").font(.subheadline).italic()
            } else {
                Image(systemName: "ellipsis").font(.title3.weight(.bold)).symbolEffect(.variableColor.iterative.dimInactiveLayers)
            }
        }
        .foregroundStyle(.inkSecondaryOnBubble)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.bubbleIncoming, in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Typing")
        .accessibilityIdentifier("thread.typing")
    }
}

