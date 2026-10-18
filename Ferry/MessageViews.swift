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
        if message.kind.isChatEvent { eventLine } else { bubbleRow }
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
            HStack(alignment: .bottom, spacing: 6) {
                if let sender = row.groupSender {
                    Group {
                        if sender.showsAvatar {
                            let who = member(message.sender)
                            MXCImage(mxc: who.avatarURL, size: Self.avatarSize, initial: who.name)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: Self.avatarSize, height: Self.avatarSize)
                    .padding(.bottom, reactionsInset)  // level with the bubble, not with its reaction pills
                }
                bubble
                    .modifier(SpokenSender(name: row.groupSender != nil && message.kind != .unsent ? member(message.sender).name : nil))
                    .overlay(alignment: own ? .bottomLeading : .bottomTrailing) {
                        if !message.reactions.isEmpty {
                            ReactionPills(reactions: message.reactions).offset(x: own ? -8 : 8, y: 14)
                        }
                    }
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

    @ViewBuilder private var bubble: some View {
        switch message.kind {
        case .unsent:
            Text(own ? "You unsent a message" : "\(name(message.sender)) unsent a message")
                .font(.footnote).foregroundStyle(.inkSecondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .accessibilityIdentifier("thread.unsent")
        case .text, .notice, .emote:
            if Self.isEmojiOnly(message.body) {
                Text(message.body).font(.system(size: 48)).menu(message, actions)  // DESIGN §6.1: no bubble
            } else {
                Text(message.body)
                    .font(.body)
                    .foregroundStyle(own ? Color.white : Color.primary)
                    .tint(own ? .white : nil)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(fill, in: Self.shape(row.position, own: own))
                    .contentShape(.contextMenuPreview, Self.shape(row.position, own: own))
                    .menu(message, actions)
                    .accessibilityLabel(spoken(message.body))
                    .accessibilityIdentifier("thread.bubble")
            }
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
            Text(statusText).font(.caption2).foregroundStyle(.inkSecondary).padding(.horizontal, 6)
                .accessibilityIdentifier("thread.status")
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

// MARK: - Context menu (DESIGN §6.2: reaction palette, Reply, Copy, Edit, Unsend)

private extension View {
    func menu(_ message: Message, _ actions: MessageActions) -> some View {
        modifier(MessageMenu(message: message, actions: actions))
    }
}

private struct MessageMenu: ViewModifier {
    let message: Message
    let actions: MessageActions
    static let palette = ["❤️", "😂", "😮", "😢", "🔥", "👍"]

    func body(content: Content) -> some View {
        content
            // Double-tap hearts it, like Instagram (DESIGN §6.2). Not on media: its taps play, load or cancel.
            .gesture(TapGesture(count: 2).onEnded { if canSend && !isMineAlready("❤️") { actions.react("❤️", message) } },
                     including: message.kind.media == nil ? .all : .subviews)
            .contextMenu {
                if canSend {
                    Picker("React", selection: reaction) {
                        ForEach(Self.palette, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .pickerStyle(.palette)
                    .menuActionDismissBehavior(.enabled)  // a palette keeps the menu open by default (iOS 26.4)
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { actions.reply(message) }
                }
                if !message.body.isEmpty, message.kind.media == nil {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.body }
                }
                if !actions.readOnly, Timeline.canEdit(message) {
                    Button("Edit", systemImage: "pencil") { actions.edit(message) }
                }
                if let url = message.content["external_url"]?.string.flatMap(URL.init(string:)) {
                    Link(destination: url) { Label("Open in Instagram", systemImage: "arrow.up.forward.app") }
                }
                if !actions.readOnly, message.isOwn, message.eventID != nil {
                    Button("Unsend", systemImage: "arrow.uturn.backward", role: .destructive) { actions.unsend(message) }
                } else if message.isOwn, case .failed = message.status {
                    Button("Delete", systemImage: "trash", role: .destructive) { actions.discard(message) }
                }
            }
    }

    private var canSend: Bool { !actions.readOnly && message.eventID != nil }

    private func isMineAlready(_ key: String) -> Bool { message.reactions.contains { $0.key == key && $0.myEventID != nil } }

    /// Highlights our current reaction. Choosing it again removes it; the setter sees either that same key or nil
    /// (palette pickers may deselect), and both mean "remove".
    private var reaction: Binding<String?> {
        let mine = message.reactions.first { $0.myEventID != nil }?.key
        return Binding(get: { mine }, set: { new in
            if let key = new ?? mine { actions.react(key, message) }
        })
    }
}

// MARK: - Pieces

/// DESIGN §6.2: emoji (+ count when more than one) in a capsule overlapping the bubble's bottom edge.
struct ReactionPills: View {
    let reactions: [Message.Reaction]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(reactions, id: \.key) { reaction in
                Text(reaction.key)
                if reaction.count > 1 { Text("\(reaction.count)").font(.caption.weight(.semibold)).foregroundStyle(.inkSecondary) }
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 6)
        .frame(minHeight: 24)
        .background(Color.reactionBackground, in: .capsule)
        .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 2))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reactions: " + reactions.map { $0.count > 1 ? "\($0.key) \($0.count)" : $0.key }.joined(separator: ", "))
        .accessibilityIdentifier("thread.reactions")
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

