import PhotosUI
import SwiftUI

/// T1 Thread (DESIGN §5 T1, §6): one chat, locked to the account it belongs to. The timeline is
/// `Timeline.reduce(room)`; actions go through `AppModel` and come back through /sync.
struct ThreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let roomID: String
    @Binding var path: [InboxRoute]

    @State private var draft = ""
    @State private var replyingTo: Message?
    @State private var editing: Message?
    @State private var unsending: Message?
    @State private var highlighted: String?
    @State private var viewer: MediaViewerItem?
    @State private var sharing: SharedFiles?
    /// T2 "Reply instead": the composer replaces the request bar, with the "replying accepts" note.
    @State private var replyingInstead = false
    @State private var confirmingDelete = false
    @State private var relogin: ReloginTarget?
    @State private var accepted = 0
    /// Haptic triggers (DESIGN §10): a message sent, a reaction sent.
    @State private var sent = 0
    @State private var reacted = 0
    /// The composer's `+`: what the picker returned, then the photo or video being prepared or ready to send.
    @State private var photoItem: PhotosPickerItem?
    @State private var attachment: Attachment?
    @State private var preparing: Task<Void, Never>?
    /// The thread stays on its newest message until the user scrolls away from it (see the re-pin below). A plain
    /// object, not state: nothing on screen depends on it, and the geometry action reads it mid-layout.
    @State private var pin = BottomPin()
    /// The thread is invisible until the bottom pin has landed after the push (`revealWhenSettled`).
    @State private var revealed = false
    /// The jump-to-newest button (`updateJump`).
    @State private var jumpShown = false
    /// How far we'd read when the chat opened unread (our `m.read`, ms), taken once before our "Seen" moves it: the
    /// "New messages" line goes after it (`Timeline.layout`).
    @State private var unreadAfter: Int64?
    @State private var opened = false
    @State private var sheet: ThreadSheet?
    @FocusState private var composerFocused: Bool

    var body: some View {
        if let room = model.room(roomID) {
            thread(room)
        } else {
            ContentUnavailableView("Chat not found", systemImage: "text.bubble")
        }
    }

    private func thread(_ room: Room) -> some View {
        let me = model.me
        let identity = room.bridge?.receiver.flatMap { model.identities[$0] }
        let login = room.bridge?.receiver.flatMap { id in model.accounts.first { $0.id == id } }
        let messages = Timeline.reduce(room, me: me)
        let lastOwn = messages.last { $0.isOwn && !$0.kind.isChatEvent }?.id
        let typing = room.typing.contains { $0 != me }
        let profiles = model.profiles
        let name = { (user: String) in Self.firstName(user, in: room, me: me, profile: profiles[user]) }
        // Groups label who wrote what (DESIGN §6.1); a missing room type means a group (S7.6).
        let isGroup = room.bridge?.roomType == .group
        let member = { (user: String) in
            (name: room.displayName(of: user, profile: profiles[user]), avatarURL: room.avatarURL(of: user, profile: profiles[user]))
        }
        let actions = actions(room)
        let rows = Timeline.layout(messages, isGroup: isGroup, unreadAfter: unreadAfter)
        let unreadLine = rows.first(where: \.startsUnread)?.id
        let seen = isGroup ? messages.first { !$0.seenBy.isEmpty } : nil
        // Everyone but us and its sender: "Seen by everyone".
        let seenLine = seen.flatMap { seen in
            Timeline.seenByLine(seen.seenBy.map(name), everyone: seen.seenBy.count >= Inbox.memberCount(of: room) - (seen.isOwn ? 1 : 2))
        }

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    top(room, identity: identity, isEmpty: messages.isEmpty)
                    ForEach(rows) { row in
                        MessageRow(row: row, me: me, identity: identity, name: name, member: member, showsStatus: row.id == lastOwn,
                                   seenLine: row.id == seen?.id ? seenLine : nil, isGroup: isGroup,
                                   highlighted: highlighted == row.id, actions: actions)
                            .padding(.top, row.spacing)
                            .background(highlighted == row.id ? Color.secondary.opacity(0.15) : .clear)
                            .id(row.id)
                            // New messages rise into place; under Reduce Motion they fade in (DESIGN §9).
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                    if typing { TypingBubble().padding(.top, 10).padding(.leading, isGroup ? MessageRow.groupIndent : 0) }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .environment(\.autoplaysGIFs, !Inbox.isRequest(room))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                // Only the newest message animates. An older page (loaded on every open while the top spinner shows)
                // bounced the whole thread when it arrived just after the push.
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .bouncy(duration: 0.45, extraBounce: 0.05), value: messages.last?.id)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)  // meant for prepends; at the end the re-pin below does it
            // Photos and our coloured bubbles don't show through behind the header's capsule (review 2026-10-15 #1).
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollDismissesKeyboard(.interactively)
            // The anchors above don't follow the keyboard or rows that grow after their first layout (M4), and a
            // push (every first open after launch, some reopens) jumps to the top when the navigation bar and composer
            // insets arrive (#17). So until the user scrolls away from the newest message, every size change pins it
            // again. Whether they have is decided when their scrolling stops: the action's `old` can already be the
            // jumped one.
            .onScrollPhaseChange { old, phase, context in
                guard phase != old else { return }  // the first call, on appearing, is idle → idle
                if phase == .tracking || phase == .interacting {
                    revealed = true
                    pin.holdsLine = false
                }
                pin.followsEnd = phase == .idle && ScrollEdge(context.geometry).distanceFromEnd < 60
                if phase == .idle { updateJump(ScrollEdge(context.geometry), atRest: true) }
            }
            .onScrollGeometryChange(for: ScrollEdge.self) { ScrollEdge($0) } action: { old, new in
                // A chat that opened unread holds its "New messages" line at the top instead, until the user scrolls;
                // when what's new fits, the line can't reach the top and this lands on the end anyway.
                pin.edge = new
                let line = pin.holdsLine ? unreadLine : nil
                if !revealed { revealWhenSettled(new, onLine: line != nil, proxy: proxy) }
                updateJump(new, atRest: false)
                guard line != nil || pin.followsEnd, new.container != old.container || new.content != old.content else { return }
                let (target, anchor) = line.map { ($0, UnitPoint.top) } ?? (Self.bottom, .bottom)
                proxy.scrollTo(target, anchor: anchor)
                // Mid-push the scroll view can drop a scroll made in the same update (#17): repeat it after.
                Task { proxy.scrollTo(target, anchor: anchor) }
            }
            .overlay(alignment: .bottomTrailing) {  // above the composer (its inset) and the keyboard
                VStack {
                    if jumpShown {
                        Button {
                            pin.holdsLine = false
                            jumpShown = false
                            withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                        } label: {
                            Image(systemName: "chevron.down").font(.body.weight(.semibold))
                                .foregroundStyle(Color.primary)  // chrome: never the account's colour
                                .frame(width: 44, height: 44).contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Jump to newest message")
                        .accessibilityIdentifier("thread.jump")
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.trailing, 12)
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.2), value: jumpShown)
            }
            .opacity(revealed ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: revealed)
            .task {  // never left hidden
                try? await Task.sleep(for: .seconds(1))
                revealed = true
                if let edge = pin.edge { updateJump(edge, atRest: false) }
            }
            .onChange(of: messages.last?.id) { _, _ in
                guard messages.last?.isOwn == true else { return }
                pin.holdsLine = false
                withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onChange(of: attachment != nil) { _, shown in
                // The bar grows the bottom inset (M7b). Added when the re-pin above never ran; not re-checked since.
                guard shown else { return }
                pin.holdsLine = false  // as a send does, or the next size change snaps back to the line
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
            }
            .onChange(of: highlighted) { _, id in
                guard let id else { return }
                pin.holdsLine = false
                withAnimation { proxy.scrollTo(id, anchor: .center) }
                Task { try? await Task.sleep(for: .seconds(0.6)); highlighted = nil }
            }
        }
        .background(alignment: .top) { if let identity { AccountWash(identity: identity, height: 170) } }
        .safeAreaInset(edge: .bottom) {
            switch Inbox.threadBar(room, health: login?.health, replyingInstead: replyingInstead) {
            case .request:
                RequestBar(room: room, identity: identity, handle: model.contactHandle(of: room), failure: Inbox.requestActionFailure(room),
                           accept: { accepted += 1; model.accept(room) },
                           delete: { confirmingDelete = true },
                           replyInstead: { replyingInstead = true; composerFocused = true })
            case .signedOut:
                RecoveryBar(name: identity?.name ?? login?.displayName ?? "This account") {
                    if let id = room.bridge?.receiver { relogin = ReloginTarget(id: id) }
                }
            case let bar:
                // No media while editing, or in a request (sending accepts it; "Reply instead" is text only).
                let media = bar == .composer && editing == nil
                Composer(draft: $draft, focused: $composerFocused, identity: identity, login: login,
                         replyingTo: replyingTo.map { (name($0.sender), $0.kind.media?.label ?? $0.body) },
                         isEditing: editing != nil, acceptsRequest: bar == .replyAccepts,
                         photoItem: media ? $photoItem : nil,
                         attachment: attachment, removeAttachment: removeAttachment,
                         send: { send(in: room) }, cancel: cancelMode,
                         typing: { model.setTyping($0 && editing == nil, in: room) },
                         sendVoice: media ? { sendVoice($0, in: room) } : nil,
                         stopPlayback: { model.voice.stop() })
            }
        }
        .sensoryFeedback(.success, trigger: accepted)
        .sensoryFeedback(.impact(weight: .light), trigger: sent)
        .sensoryFeedback(.impact(weight: .light), trigger: reacted)
        .sensoryFeedback(trigger: messages.count { if case .failed = $0.status { true } else { false } }) { old, new in
            new > old ? .error : nil  // a send just failed (DESIGN §10)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { path.append(.chatInfo(room.id)) } label: {
                    ThreadHeader(room: room, identity: identity)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityHint("Shows chat info")
            }
            .sharedBackgroundVisibility(.hidden)  // the header is its own capsule
            ToolbarItem(placement: .topBarTrailing) { menu(room) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .tint(identity?.color.ink ?? .primary)
        // On open and on each new event while open and active (DESIGN T1). markRead refuses request rooms.
        .task(id: room.events.last?.eventID) {
            if !opened {  // before markRead moves our m.read
                opened = true
                unreadAfter = room.isUnread ? room.receipts[me]?.ts : nil
                pin.holdsLine = unreadAfter != nil
            }
            if scenePhase == .active { model.markRead(room) }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.markRead(room) } }
        .onDisappear {
            model.setTyping(false, in: room)
            model.voice.stop()
        }
        // "Load video" finished: play it, as if tapped again (M5 stopped at the swapped card).
        .onChange(of: model.autoOpen) { _, id in
            guard let id, let message = Timeline.reduce(room, me: me).first(where: { $0.id == id }) else { return }
            model.autoOpen = nil
            open(message, in: room)
        }
        .onChange(of: photoItem) { _, item in if let item { prepare(item) } }
        .task(id: room.id) {
            model.openThread(room)  // the whole thread: reactions, edits, reply targets
            if model.focusComposer == roomID {  // opened from New Message: ready to type (DESIGN N1)
                model.focusComposer = nil
                try? await Task.sleep(for: .milliseconds(400))  // after the push, or the focus is dropped
                composerFocused = true
            }
        }
        .fullScreenCover(item: $viewer) { item in
            if item.isVideo { PlayerView(item: item, identity: identity) } else { PhotoViewer(item: item) }
        }
        .confirmationDialog("Delete request from \(room.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.deleteRequest(room)
                dismiss()  // the bridge deletes the room; nothing left to show here
            }
        } message: {
            Text(RequestCopy.deleteMessage(handle: login?.profile?.username))
        }
        .sheet(item: $relogin) { ReloginSheet(loginID: $0.id) }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .reactions(let id):
                if let message = messages.first(where: { $0.id == id }) { ReactionList(message: message, me: me, member: member) }
            case .person(let user):
                PersonCard(name: member(user).name, handle: profiles[user]?.handle, avatarURL: member(user).avatarURL)
            }
        }
        .sheet(item: $sharing) { ShareSheet(files: $0.files).presentationDetents([.medium, .large]) }
        .confirmationDialog("Unsend message?", isPresented: Binding(get: { unsending != nil }, set: { if !$0 { unsending = nil } }),
                            titleVisibility: .visible, presenting: unsending) { message in
            Button("Unsend", role: .destructive) { model.unsend(message, in: room) }
        } message: { _ in
            Text("It will be removed for everyone in this chat.")
        }
    }

    /// DESIGN T1's trailing ⋯ menu, v1 subset: Chat Info, Open in Instagram (when the handle is known) and Archive
    /// (no mute or search in chat).
    private func menu(_ room: Room) -> some View {
        let folder = Inbox.folder(of: room)
        return Menu("More", systemImage: "ellipsis") {
            Button("Chat Info", systemImage: "info.circle") { path.append(.chatInfo(room.id)) }
            if let url = model.contactHandle(of: room).flatMap({ URL(string: "https://www.instagram.com/\($0)/") }) {
                Link(destination: url) { Label("Open in Instagram", systemImage: "arrow.up.forward.app") }
            }
            if folder != .requests {
                Button(folder == .archived ? "Unarchive" : "Archive", systemImage: folder == .archived ? "tray.and.arrow.up" : "archivebox") {
                    model.setArchived(folder != .archived, room)
                }
            }
        }
        .accessibilityIdentifier("thread.more")
    }

    /// The top of the list: a spinner that pages back while visible, or the start block (DESIGN T1): content, not a
    /// second header, so bigger than the toolbar's name and set apart from the first timestamp.
    @ViewBuilder private func top(_ room: Room, identity: AccountIdentity?, isEmpty: Bool) -> some View {
        if room.reachedStart {
            let block = Inbox.startBlock(isGroup: room.bridge?.roomType == .group, members: Inbox.memberCount(of: room),
                                         handle: model.contactHandle(of: room), account: identity?.name, isEmpty: isEmpty)
            VStack(spacing: 4) {
                RoomAvatar(room: room, size: 64).padding(.bottom, 6)
                Text(room.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                if let subtitle = block.subtitle { Text(subtitle).font(.footnote).foregroundStyle(.inkSecondary) }
                if let identity { AccountTag(identity: identity).padding(.top, 6) }
                if let line = block.messagingFrom { Text(line).font(.footnote).foregroundStyle(.inkSecondary).padding(.top, 4) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .padding(.bottom, 20)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("thread.start")
        } else {
            // Re-runs whenever a page lands while it's still on screen, until the screen is full or history ends.
            ProgressView()
                .opacity(model.paginating.contains(room.id) ? 1 : 0.4)
                .frame(maxWidth: .infinity, minHeight: 44)
                .task(id: room.prevBatch) { model.loadOlder(room) }
        }
    }

    private func actions(_ room: Room) -> MessageActions {
        MessageActions(
            react: { reacted += 1; model.react($0, to: $1, in: room) },
            reply: { message in editing = nil; replyingTo = message; composerFocused = true },
            edit: { message in replyingTo = nil; editing = message; draft = message.body; composerFocused = true },
            unsend: { unsending = $0 },
            retry: { model.retry($0, in: room) },
            discard: { model.discard($0, in: room) },
            showOriginal: { highlighted = $0 },
            loadReplyTarget: { _ in },  // Instagram sends the target with the reply (`Room.related`)
            openMedia: { open($0, in: room) },
            resolveMedia: { model.resolveMedia($0, in: room) },
            shareAll: { shareAll($0, in: room) },
            showReactions: { sheet = .reactions($0.id) },
            showPerson: { sheet = .person($0) },
            readOnly: !Inbox.allowsReceipts(room))
    }

    /// Full media only on tap (PLAN §2.7): download with the card's ring, then full screen. A second tap while it
    /// downloads cancels. A cached file opens at once, with no request at all.
    private func open(_ message: Message, in room: Room) {
        let info = MediaInfo(content: message.content)
        if let txnID = message.txnID, model.uploads[txnID] != nil { return model.cancelUpload(txnID, in: room) }
        guard let mxc = info.url, !PhotoMessage.isLocal(mxc) else { return }  // a photo still on its way up
        if model.media.progress[mxc] != nil { return model.media.cancel(mxc) }
        let sender = Self.firstName(message.sender, in: room, me: model.me, profile: model.profiles[message.sender])
        Task {
            guard let file = try? await model.media.file(mxc, mimetype: info.mimetype) else { return model.refreshMedia(in: room) }
            model.voice.stop()
            viewer = MediaViewerItem(message: message, file: file, sender: sender)
        }
    }

    /// "Share All": every photo of a set downloaded at once (the pile's ring; a tap on it cancels), then the share
    /// sheet, whose "Save N Images" puts them in Photos.
    private func shareAll(_ message: Message, in room: Room) {
        let items = MediaInfo(content: message.content).album.map(MediaInfo.init(content:))
        Task {
            let downloads = items.map { item in Task { try await model.media.file(item.url ?? "", mimetype: item.mimetype) } }
            do {
                var files: [URL] = []
                for download in downloads { files.append(try await download.value) }
                sharing = SharedFiles(files: files)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                model.refreshMedia(in: room)  // the links may have expired
            }
        }
    }

    private func send(in room: Room) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachment == nil, editing == nil, let link = PhotoMessage.gifLink(text) { return sendGIFLink(link, text: text, in: room) }
        let media: (OutgoingMedia, UIImage?)? = switch attachment {
        case .photo(let photo, let preview): (.photo(photo), preview)
        case .video(let video, let preview): (.video(video), preview)
        case .preparing, nil: nil
        }
        guard !text.isEmpty || media != nil, text.count <= Timeline.maxTextLength else { return }
        if let editing {
            if text != editing.body { model.edit(editing, to: text, in: room) }
        } else {
            // The photo or video first, then the text as its own message (Instagram drops captions). A reply goes
            // with the text when there is one.
            if let (item, preview) = media {
                model.sendMedia(item, preview: preview, replyTo: text.isEmpty ? replyingTo?.eventID : nil, in: room)
                attachment = nil
            }
            if !text.isEmpty { model.send(text, replyTo: replyingTo?.eventID, in: room) }
            sent += 1
        }
        draft = ""
        replyingTo = nil
        editing = nil
    }

    /// A message that is only a link to a GIF (or an animated WebP) goes as the GIF itself, which Instagram shows as a
    /// GIF, not a link. The link is fetched only now, on Send; anything that doesn't load as an animated image goes as
    /// the link it was. ✕ on the bar while it loads puts the link back in the field.
    private func sendGIFLink(_ link: URL, text: String, in room: Room) {
        let replyTo = replyingTo?.eventID
        draft = ""
        replyingTo = nil
        attachment = .preparing(isVideo: false, gif: true)
        preparing = Task {
            let gif = try? await Self.gif(from: link)
            if Task.isCancelled {
                if draft.isEmpty { draft = text }
                return
            }
            attachment = nil
            preparing = nil
            if let (photo, preview) = gif { model.sendMedia(.photo(photo), preview: preview, replyTo: replyTo, in: room) }
            else { model.send(text, replyTo: replyTo, in: room) }
            sent += 1
        }
    }

    /// The mic's note (DESIGN §6.9), as a reply when replying. Its own haptic already played.
    private func sendVoice(_ voice: VoiceMessage.Recorded, in room: Room) {
        model.sendMedia(.voice(voice), preview: nil, replyTo: replyingTo?.eventID, in: room)
        replyingTo = nil
    }

    /// Reads the picked photo (re-encoded) or video (as a file, made to fit) off the main actor; the composer shows it
    /// once ready.
    private func prepare(_ item: PhotosPickerItem) {
        photoItem = nil  // so the same item can be picked again
        removeAttachment()
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        attachment = .preparing(isVideo: isVideo)
        preparing = Task {
            do {
                let ready: Attachment
                if isVideo {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw VideoMessage.Failure.unreadable }
                    defer { try? FileManager.default.removeItem(at: movie.url) }
                    let video = try await VideoMessage.prepare(movie.url)
                    ready = .video(video, UIImage(data: video.thumbnail.data))
                } else {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoMessage.Failure.unreadable }
                    let (photo, preview) = try await Self.encode(data)
                    ready = .photo(photo, preview)
                }
                guard !Task.isCancelled, case .preparing = attachment else {  // removed meanwhile
                    if case .video(let video, _) = ready { try? FileManager.default.removeItem(at: video.file) }
                    return
                }
                attachment = ready
            } catch {
                guard !Task.isCancelled else { return }
                attachment = nil
                model.actionError = error.localizedDescription
            }
        }
    }

    /// The bar's ✕ (or a new pick): stops a video still being made to fit and drops its file.
    private func removeAttachment() {
        preparing?.cancel()
        preparing = nil
        if case .video(let video, _) = attachment { try? FileManager.default.removeItem(at: video.file) }
        attachment = nil
    }

    /// JPEG (or an animated GIF as a GIF) plus a small decoded preview for the composer and the local echo.
    @concurrent private static func encode(_ data: Data) async throws -> (PhotoMessage.Encoded, UIImage?) {
        let photo = try PhotoMessage.gif(data) ?? PhotoMessage.encode(data)
        return (photo, preview(photo))
    }

    /// A linked GIF, downloaded to a file (never past `PhotoMessage.maxSource`), as `encode` makes it; throws unless it
    /// is an animated image.
    @concurrent private static func gif(from link: URL) async throws -> (PhotoMessage.Encoded, UIImage?) {
        var request = URLRequest(url: link)
        request.timeoutInterval = 20
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        guard (response as? HTTPURLResponse)?.statusCode == 200, size <= PhotoMessage.maxSource else { throw PhotoMessage.Failure.tooLarge }
        guard let photo = try PhotoMessage.gif(Data(contentsOf: file)) else { throw PhotoMessage.Failure.unreadable }
        return (photo, preview(photo))
    }

    /// 720 px (the bubble's size at 3×); a GIF's is its first frame.
    nonisolated private static func preview(_ photo: PhotoMessage.Encoded) -> UIImage? {
        let scale = 720 / Double(max(photo.width, photo.height, 720))
        return UIImage(data: photo.data)?.preparingThumbnail(of: CGSize(width: Double(photo.width) * scale, height: Double(photo.height) * scale))
    }

    private func cancelMode() {
        if editing != nil { draft = "" }
        if replyingTo == nil && editing == nil { replyingInstead = false; draft = "" }  // back to the request bar
        replyingTo = nil
        editing = nil
    }

    private static let bottom = "thread.bottom"

    private final class BottomPin {
        var followsEnd = true
        /// Opened unread: the "New messages" line stays at the top until the user scrolls (or it turns out that what's
        /// new overflows by little, `ScrollEdge.endIsNear`).
        var holdsLine = false
        var reveal: Task<Void, Never>?
        /// The latest geometry, for the 1 s reveal.
        var edge: ScrollEdge?
    }

    private enum ThreadSheet: Identifiable {
        case reactions(String)
        case person(String)

        var id: String {
            switch self {
            case .reactions(let id): "reactions:\(id)"
            case .person(let user): "person:\(user)"
            }
        }
    }

    /// A push lays the thread out without the bars' insets, at its end; when they arrive it jumps to the top and the
    /// re-pin scrolls it back down (#17). The first layout also shows the top spinner, so an older page lands right
    /// after, above the end, and the offset trails it for a few frames. The user saw both as a jump. So the thread
    /// appears only once it has stayed at its end, under the bars, for 100 ms (rows re-measure for a few frames after
    /// a scroll) with no page on its way, and at the latest after 1 s or when the user touches it. Held on the "New
    /// messages" line, anywhere settled will do, unless what's new overflows by little (`endIsNear`): then the end
    /// instead, so the newest message is never cut off by the composer, and the thread follows its end.
    private func revealWhenSettled(_ edge: ScrollEdge, onLine: Bool, proxy: ScrollViewProxy) {
        pin.reveal?.cancel()
        guard onLine ? edge.topInset > 0 : edge.restsAtEnd else { return }
        pin.reveal = Task {
            try? await Task.sleep(for: .milliseconds(100))
            // A page still loading changes the geometry when it lands, which schedules this again.
            guard !Task.isCancelled, !model.paginating.contains(roomID) else { return }
            if onLine, edge.endIsNear {
                pin.holdsLine = false
                proxy.scrollTo(Self.bottom, anchor: .bottom)
                if !edge.restsAtEnd { return }  // the scroll's geometry schedules this again, at the end
            }
            revealed = true
            updateJump(edge, atRest: false)
        }
    }

    /// DESIGN §5 T1's scroll-to-bottom button, without its count for now. It shows once the thread has appeared away
    /// from its end: held on the "New messages" line, or where the user's scroll came to rest. Never mid-scroll or
    /// while the pin catches up (the keyboard, a row growing), and it hides as soon as the end is close.
    private func updateJump(_ edge: ScrollEdge, atRest: Bool) {
        let shown = revealed && edge.distanceFromEnd > 60 && (jumpShown || pin.holdsLine || atRest)
        if shown != jumpShown { jumpShown = shown }
    }

    /// What the bottom pin reads from the scroll geometry. The offset and top inset are part of the value, so the
    /// frame where a push jumps to the top is reported (M4's value read the same just before it, so it went unseen).
    nonisolated struct ScrollEdge: Equatable {
        var offset: CGFloat
        var content: CGFloat
        /// The frame minus the bars' and composer's insets.
        var container: CGFloat
        var topInset: CGFloat

        init(_ geometry: ScrollGeometry) {
            offset = geometry.contentOffset.y
            content = geometry.contentSize.height
            container = geometry.containerSize.height
            topInset = geometry.contentInsets.top
        }

        /// How far the newest message is below what the bars and composer leave visible: 0 at the end (the offset
        /// starts at minus the top inset). M4 took `containerSize` for the whole frame and read 208 pt here on iOS
        /// 26.4, so its re-pin never ran (ThreadScrollTests).
        var distanceFromEnd: CGFloat { content - container - topInset - offset }

        /// At the end (give or take the list's 8 pt bottom padding) with the navigation bar's inset in place: mid-push,
        /// before the insets arrive, the thread is also at its end, and then jumps.
        var restsAtEnd: Bool { topInset > 0 && distanceFromEnd < 20 }

        /// Held on the "New messages" line, how far below the end is, i.e. how much that's new doesn't fit: up to a
        /// quarter of the screen opens at the end instead (the line and a bubble or two go under the header; the user
        /// saw the newest message cut off by the composer, 2026-10-20).
        var endIsNear: Bool { distanceFromEnd <= container / 4 }
    }

    /// "Kivo" for the ghost named "Kivo Studio". Without a member event: their ghost profile, the room name in a DM
    /// (the partner), else the localpart (`Room.displayName`), so a group's reply quote never names the group.
    static func firstName(_ user: String, in room: Room, me: String, profile: UserProfile? = nil) -> String {
        if user == me { return "You" }
        let full = room.displayName(of: user, profile: profile)
        return full.split(separator: " ").first.map(String.init) ?? full
    }
}

// MARK: - Header (DESIGN T1: contact, then the AccountTag that says which account this chat belongs to)

/// One 44 pt glass capsule (the button around it adds the glass): on the soft scroll edge alone, the tag became
/// unreadable over photos and our own coloured bubbles (review 2026-10-15 #1).
private struct ThreadHeader: View {
    let room: Room
    let identity: AccountIdentity?

    var body: some View {
        HStack(spacing: 8) {
            RoomAvatar(room: room, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(room.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let identity {
                    // The account name is what this tag is for, so it never truncates: the handle stays in Chat Info
                    // and the composer popover, and large text falls back to the mark and first word, then the mark.
                    ViewThatFits(in: .horizontal) {
                        AccountTag(identity: identity, compact: true)
                        AccountTag(identity: identity, length: .firstWord, compact: true)
                        AccountTag(identity: identity, length: .markOnly, compact: true)
                    }
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(minHeight: 44)
        .contentShape(.capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("thread.header")
    }
}

// MARK: - Composer (DESIGN §6.9)

private struct Composer: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let identity: AccountIdentity?
    let login: BridgeAPI.Login?
    /// (name, snippet) while replying.
    let replyingTo: (String, String)?
    let isEditing: Bool
    /// "Reply instead" in a request: sending accepts it (DESIGN T2).
    var acceptsRequest = false
    /// The `+` button's picker; nil hides it (editing, requests).
    let photoItem: Binding<PhotosPickerItem?>?
    let attachment: Attachment?
    let removeAttachment: () -> Void
    let send: () -> Void
    let cancel: () -> Void
    let typing: (Bool) -> Void
    /// The mic's note; nil hides the mic (editing, requests).
    let sendVoice: ((VoiceMessage.Recorded) -> Void)?
    let stopPlayback: () -> Void
    @State private var showingLock = false
    @State private var recorder = VoiceRecorder()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private var count: Int { draft.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var accountName: String { identity?.name ?? login?.displayName ?? "this account" }
    private var attachmentReady: Bool {
        switch attachment {
        case .photo, .video: true
        case .preparing, nil: false
        }
    }
    private var recording: Bool { recorder.state != .idle }

    var body: some View {
        VStack(spacing: 8) {
            if let (name, snippet) = replyingTo {
                modeBar(symbol: "arrowshape.turn.up.left", title: "Replying to \(name)", detail: snippet)
            } else if isEditing {
                modeBar(symbol: "pencil", title: "Editing message", detail: nil)
            } else if acceptsRequest {
                modeBar(symbol: "person.crop.circle.badge.checkmark", title: "Replying accepts the request.", detail: nil)
            }
            if let attachment { attachmentBar(attachment) }
            HStack(alignment: .bottom, spacing: 8) {
                if let photoItem {
                    // DESIGN §6.9 attachment button: photos and videos (no camera or GIF).
                    PhotosPicker(selection: photoItem, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                        Image(systemName: "plus").font(.title3.weight(.medium)).foregroundStyle(Color.primary)
                            .frame(width: 44, height: 44).contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .opacity(recording ? 0 : 1)
                    .disabled(recording)
                    .accessibilityLabel("Add photo or video")
                    .accessibilityIdentifier("composer.photo")
                }
                field
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onChange(of: draft) { _, text in typing(!text.isEmpty) }
        .onChange(of: recorder.started) { stopPlayback() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { recorder.abandon() } }
        .onDisappear { recorder.abandon() }
        // DESIGN §10: rigid on start and stop, medium when the slide cancels.
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: recorder.started)
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: recorder.stopped)
        .sensoryFeedback(.impact(weight: .medium), trigger: recorder.cancelled)
        .alert("Microphone access is off", isPresented: $recorder.permissionDenied) {
            Button("Open Settings") { URL(string: UIApplication.openSettingsURLString).map { openURL($0) } }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Ferry records voice messages only while you hold the mic button. To send one, turn on Microphone for Ferry in Settings.")
        }
    }

    /// The glass capsule: account avatar (the lock), the text field, then Send once there's something to send, else
    /// the mic (DESIGN §6.9). While recording, the strip covers the field.
    private var field: some View {
        HStack(alignment: .bottom, spacing: 9) {
            Button { showingLock = true } label: {
                AccountAvatar(identity: identity, avatarURL: login?.profile?.avatar, initial: login?.displayName ?? "", size: 28)
                    .padding(8).contentShape(.rect)  // 44 pt hit area (DESIGN §11)
            }
            .buttonStyle(.plain)
            .padding(-8)
            .padding(.bottom, 2)
            .accessibilityLabel("Sending as \(accountName). Double-tap for details.")
            .popover(isPresented: $showingLock) {
                Text(lockText).font(.subheadline).padding().frame(idealWidth: 280).presentationCompactAdaptation(.popover)
            }
            VStack(alignment: .leading, spacing: 2) {
                // The system placeholder grey is ~2:1; the mockups' placeholder is label-2 (DESIGN §11). After a tap on
                // the mic it says "Hold to record" for a moment instead of a hint floating over the thread (#14).
                TextField("Message as \(accountName)", text: $draft,
                          prompt: Text(recorder.hint ?? "Message as \(accountName)").foregroundStyle(.inkSecondary), axis: .vertical)
                    .lineLimit(1...6)
                    .focused(focused)
                    .accessibilityLabel("Message, sending as \(accountName)")
                    .accessibilityIdentifier("composer.field")
                // DESIGN §6.9: a counter from 900; Send disables past 1000 (Instagram's limit, from the bridge).
                if count >= 900 {
                    Text(count > Timeline.maxTextLength ? "\(count - Timeline.maxTextLength) over the limit" : "\(Timeline.maxTextLength - count) left")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(count > Timeline.maxTextLength ? .statusError : .inkSecondary)
                }
            }
            .padding(.vertical, 5)
            // While recording the field stays (hidden, so the keyboard doesn't drop) under the recording strip.
            .opacity(recording ? 0 : 1)
            .overlay { if recording { RecordingStrip(recorder: recorder) } }
            if let sendVoice, attachment == nil, count == 0 || recording {
                MicButton(recorder: recorder, tint: identity?.color.fill ?? .accentColor, send: sendVoice)
            } else if count > 0 || attachmentReady {
                Button(action: send) {
                    Image(systemName: isEditing ? "checkmark" : "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(identity?.color.fill ?? .accentColor, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(count > Timeline.maxTextLength)
                .opacity(count > Timeline.maxTextLength ? 0.4 : 1)
                .accessibilityLabel(isEditing ? "Save edit" : "Send")
                .accessibilityIdentifier("composer.send")
            }
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 4)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    /// The picked photo or video above the field: no caption (Instagram drops them), so typed text goes on its own.
    private func attachmentBar(_ attachment: Attachment) -> some View {
        let (preview, title, isVideo): (UIImage?, String, Bool) = switch attachment {
        case .preparing(let isVideo, let gif): (nil, gif ? "Getting GIF…" : isVideo ? "Preparing video…" : "Preparing photo…", isVideo)
        case .photo(let photo, let preview): (preview, photo.isGIF ? "GIF" : "Photo", false)
        case .video(let video, let preview): (preview, "Video · \(clockText(Double(video.duration) / 1000))", true)
        }
        return HStack(spacing: 10) {
            Group {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                        .overlay { if isVideo { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white) } }
                } else {
                    ProgressView()
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote.weight(.semibold))
                if attachmentReady && count > 0 {
                    Text("Your text is sent as a separate message.").font(.footnote).foregroundStyle(.inkSecondary)
                }
            }
            Spacer(minLength: 0)
            Button(isVideo ? "Remove video" : "Remove photo", systemImage: "xmark", action: removeAttachment)
                .labelStyle(.iconOnly).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).contentShape(.rect)
                .accessibilityIdentifier("composer.removePhoto")
        }
        .padding(.leading, 6).padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.attachment")
    }

    private var lockText: String {
        let handle = login?.profile?.username.map { " (@\($0))" } ?? ""
        return "This chat belongs to \(accountName)\(handle). Replies always come from this account."
    }

    private func modeBar(symbol: String, title: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(identity?.color.ink ?? .primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote.weight(.semibold))
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.inkSecondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Button("Cancel", systemImage: "xmark", action: cancel)
                .labelStyle(.iconOnly).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).contentShape(.rect)
                .accessibilityIdentifier("composer.cancelMode")
        }
        .padding(.leading, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

// MARK: - Request bar (DESIGN T2)

/// Replaces the composer in request rooms. Opening the room sends nothing (no receipts or typing reach a requester,
/// PLAN §2.8); only these buttons, or a reply, send an event.
private struct RequestBar: View {
    let room: Room
    let identity: AccountIdentity?
    /// The requester's @handle once their ghost profile has it (DESIGN T2 names them by handle).
    let handle: String?
    let failure: String?
    let accept: () -> Void
    let delete: () -> Void
    let replyInstead: () -> Void

    var body: some View {
        let title = Inbox.requestTitle(requester: handle.map { "@\($0)" } ?? room.name, account: identity?.name)
        VStack(alignment: .leading, spacing: 6) {
            // The tag ends the title's line (review 2026-10-15 #5: on its own line it made the bar ~195 pt), and wraps
            // under it when both don't fit.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { titleText(title.shown); tag }
                VStack(alignment: .leading, spacing: 4) { titleText(title.shown); tag }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title.spoken)
            .accessibilityAddTraits(.isHeader)
            Text("They won't see that you've read this until you accept.").font(.footnote).foregroundStyle(.inkSecondary)
            if let failure {
                Label("Couldn't do that: \(failure)", systemImage: "exclamationmark.circle.fill")
                    .font(.footnote).foregroundStyle(.statusError)
            }
            HStack(spacing: 10) {
                Button(role: .destructive, action: delete) { Text("Delete").frame(maxWidth: .infinity, minHeight: Self.buttonLabel) }
                    .buttonStyle(.glass).foregroundStyle(.statusError)
                    .accessibilityIdentifier("request.delete")
                Button(action: accept) { Text("Accept").frame(maxWidth: .infinity, minHeight: Self.buttonLabel) }
                    .buttonStyle(.glassProminent).labelOnTint()
                    .accessibilityIdentifier("request.accept")
            }
            .font(.body.weight(.semibold))
            .padding(.top, 6)
            Button(action: replyInstead) {
                Text("Reply instead \(Text("· replying accepts").foregroundStyle(.inkSecondary))")
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
            .accessibilityIdentifier("request.replyInstead")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread.requestBar")
    }

    /// The label's height inside a regular-size glass button: 44 pt buttons (were 54 at `.large`).
    private static let buttonLabel: CGFloat = 30

    private func titleText(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var tag: some View {
        if let identity { AccountTag(identity: identity) }
    }
}

/// DESIGN §7.2 thread recovery bar: the account is signed out, so nothing would send.
private struct RecoveryBar: View {
    let name: String
    let logIn: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.orange)
            Text("\(name) is signed out. Log in again to send and receive messages.").font(.subheadline)
            Spacer(minLength: 0)
            Button("Log in again", action: logIn).buttonStyle(.glassProminent).labelOnTint().accessibilityIdentifier("thread.relogin")
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// Copy shared by I2 rows and T2 (DESIGN §12).
enum RequestCopy {
    /// `IGDeleteThread` deletes it on Instagram for this account. Ferry's bridge marked it read first; `core/` doesn't,
    /// but whether Instagram shows the requester a "Seen" is untested (no real request on the dummies), so the copy
    /// keeps the warning.
    static func deleteMessage(handle: String?) -> String {
        "It's deleted from \(handle.map { "@\($0)'s" } ?? "your") Instagram inbox too. They may see it as read."
    }
}

struct ReloginTarget: Identifiable { let id: String }

/// A photo or video picked in the composer: being read and prepared, or ready with a small preview (a video's is its
/// thumbnail).
enum Attachment {
    case preparing(isVideo: Bool, gif: Bool = false)
    case photo(PhotoMessage.Encoded, UIImage?)
    case video(VideoMessage.Video, UIImage?)
}

/// Files for the share sheet ("Share All").
private struct SharedFiles: Identifiable {
    let id = UUID()
    let files: [URL]
}

private struct ShareSheet: UIViewControllerRepresentable {
    let files: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: files, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
