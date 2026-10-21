import SwiftUI

// MARK: - Media cards (DESIGN §6.3–6.8; PLAN §2.7: only thumbnails load by themselves, full media on tap)

/// Picks the card for a media kind. Every failure keeps an "Open in Instagram" way out when there is a link.
struct MediaCard: View {
    let message: Message
    let own: Bool
    /// First name, or "You" (VoiceOver: "Voice message from Kivo").
    let sender: String
    let fill: Color
    let actions: MessageActions

    var body: some View {
        let info = MediaInfo(content: message.content)
        switch message.kind {
        case _ where info.album.count > 1:
            AlbumStack(message: message, album: info.album, own: own, sender: sender, fill: fill, actions: actions)
        case .share(.story, .unavailable):
            NoticeCard(symbol: "clock", title: "Story no longer available", detail: "Stories disappear after 24 hours.")
        case .share(let type, .unavailable):
            NoticeCard(symbol: type.symbol, title: type == .reel ? "Video unavailable" : "\(type.label) unavailable",
                       detail: "It may be from a private account, or it was removed." + Self.captionLine(message),
                       preview: info.previewURL, link: info.externalURL)
        case .share(let type, .tooLarge):
            NoticeCard(symbol: type.symbol, title: "\(type.label) too large",
                       detail: "This \(type == .other ? "attachment" : type.rawValue) is too big to bring into the chat.", link: info.externalURL)
        case .tooLarge:
            NoticeCard(symbol: "doc", title: "Attachment too large", detail: "It's too big to bring into the chat. Open Instagram to see it.",
                       link: Self.instagramInbox)
        case .viewOnce:
            NoticeCard(symbol: "eye.slash", title: message.body.contains("video") ? "View-once video" : "View-once photo",
                       detail: "Open Instagram to view it.", link: Self.instagramInbox)
        case .share(.post, .ready) where !info.isVideo, .share(.other, _):
            PostCard(message: message, info: info, own: own, fill: fill, actions: actions)
        case .share, .video:
            VideoCard(message: message, info: info, actions: actions)
        case .image, .sticker, .gif:
            PhotoCard(message: message, info: info, actions: actions)
        case .voice, .audio:
            VoiceBubble(message: message, info: info, own: own, sender: sender, fill: fill, actions: actions)
        default:  // files (rare on Instagram): just the name
            Label { Text(message.body).lineLimit(1) } icon: { Image(systemName: "doc.fill") }
                .font(.subheadline).foregroundStyle(own ? Color.white : Color.primary)
                .padding(.horizontal, 14).padding(.vertical, 12).background(fill)
        }
    }

    /// Opens the IG app (universal link) for things only Instagram can show.
    static let instagramInbox = URL(string: "https://www.instagram.com/direct/inbox/")

    /// ` "Sunset at Playa Grande" · @wave.house` (mockups' unavailable card).
    static func captionLine(_ message: Message) -> String {
        let caption = ShareCaption(content: message.content)
        let text = [caption.caption ?? (caption.author == nil ? caption.title : nil)].compactMap(\.self).map { "“\($0)”" }
            + [caption.author.map { "@\($0)" }].compactMap(\.self)
        return text.isEmpty ? "" : " " + text.joined(separator: " · ")
    }
}

/// Photos and videos sent together, under the one message's menu and reactions: a pile (the first on top, up to four
/// more peeking out behind it, how many there are) that a tap unfolds into a card each, stacked like a run of
/// bubbles, each opening on its own; "Show less" folds it back. Only the pile's previews load until then.
private struct AlbumStack: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let album: [JSON]
    let own: Bool
    let sender: String
    let fill: Color
    let actions: MessageActions
    @State private var expanded = false

    /// The pile's cards, top first.
    private static let tilt: [Double] = [0, -3, 3, -6, 6]

    var body: some View {
        if expanded { column } else { pile }
    }

    private var pile: some View {
        let info = MediaInfo(content: message.content)
        let cards = album.prefix(Self.tilt.count).map(MediaInfo.init(content:))
        let size = PhotoCard.fit(cards[0], max: CGSize(width: 240, height: 320))
        let progress = shareProgress
        return Button {
            if progress != nil { album.compactMap { MediaInfo(content: $0).url }.forEach(model.media.cancel) }
            else { withAnimation(.snappy) { expanded = true } }
        } label: {
            ZStack {
                ForEach(cards.indices.reversed(), id: \.self) { i in
                    MXCThumbnail(mxc: cards[i].previewURL, pixels: Int(max(size.width, size.height) * 3))
                        .frame(width: size.width, height: size.height)
                        .clipShape(.rect(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.18), radius: 2)
                        .rotationEffect(.degrees(Self.tilt[i]))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(info.albumLabel).font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(height: 20).background(.black.opacity(0.42), in: .capsule).padding(8)
            }
            .overlay { if let progress { DownloadRing(progress: progress) } }
            .padding(.horizontal, 16).padding(.vertical, 14)  // room for the tilted cards inside the bubble's clip
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(progress.map { "\(info.albumLabel), downloading, \(Int($0 * 100)) percent. Double-tap to cancel." }
            ?? "\(info.albumLabel). Double-tap to show all.")
        .accessibilityIdentifier("media.pile")
    }

    private var column: some View {
        VStack(alignment: own ? .trailing : .leading, spacing: 2) {
            ForEach(album.indices, id: \.self) { i in
                MediaCard(message: item(album[i]), own: own, sender: sender, fill: fill, actions: actions)
                    .clipShape(MessageRow.shape(i == 0 ? .first : i == album.count - 1 ? .last : .middle, own: own))
            }
            // Under the photos, not on them: a light photo hides a glass button's white label.
            Button { withAnimation(.snappy) { expanded = false } } label: {
                Label("Show less", systemImage: "chevron.up").font(.footnote.weight(.semibold)).foregroundStyle(.inkSecondary)
                    .padding(.horizontal, 12).frame(minHeight: 44).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("media.showLess")
        }
    }

    /// "Share All" under way: the set's share downloaded so far, nil when nothing of it is downloading.
    private var shareProgress: Double? {
        let items = album.map(MediaInfo.init(content:))
        guard items.contains(where: { $0.url.flatMap { model.media.progress[$0] } != nil }) else { return nil }
        let done = items.map { item in
            item.url.flatMap { model.media.progress[$0] } ?? (item.url.flatMap { model.media.localFile($0, mimetype: item.mimetype) } != nil ? 1 : 0)
        }
        return done.reduce(0, +) / Double(done.count)
    }

    private func item(_ content: JSON) -> Message {
        var item = message
        item.content = content
        item.kind = MessageKind(type: "m.room.message", content: content)
        return item
    }
}

/// Reels, stories and videos (DESIGN §6.3, §6.4, §6.7): thumbnail with author and caption, and one control in the
/// middle for the state: Load video → Getting video… (resolve_media) → play → download ring (tap cancels) → retry.
private struct VideoCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let message: Message
    let info: MediaInfo
    let actions: MessageActions

    var body: some View {
        let share: MessageKind.ShareType? = if case .share(let type, _) = message.kind { type } else { nil }
        let unresolved = if case .share(_, .unresolved) = message.kind { true } else { false }
        let caption = ShareCaption(content: message.content)
        let resolve = message.eventID.flatMap { model.resolving[$0] }
        // A video we're sending: its upload ring (✕ cancels), else the download ring.
        let progress = message.txnID.flatMap { model.uploads[$0] } ?? info.url.flatMap { model.media.progress[$0] }
        let failed = unresolved ? resolve == .failed : info.url.map { model.media.failed.contains($0) } ?? false
        let size = Self.size(share, info)
        let noun = share == .story ? "story" : share == .post && !info.isVideo ? "post" : "video"
        Button {
            if unresolved { if resolve != .running { actions.resolveMedia(message) } } else { actions.openMedia(message) }
        } label: {
            ZStack {
                MXCThumbnail(mxc: info.previewURL, pixels: Int(max(size.width, size.height) * 3), placeholder: Color(white: 0.16))
                    .saturation(resolve == .running ? 0.6 : 1)
                    .brightness(resolve == .running ? -0.12 : 0)
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        if let author = caption.author { Text(share == .story ? "Story · @\(author)" : "@\(author)").lineLimit(1) }
                        else if share == .story { Text("Story") }
                        Spacer(minLength: 0)
                        if share == .reel {
                            Image(systemName: "play.rectangle.on.rectangle").font(.caption).frame(width: 26, height: 26)
                                .mediaGlass(in: .circle)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .padding([.horizontal, .top], 9).padding(.bottom, 24)
                    .background(LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom, spacing: 8) {
                        Text(status(resolve: resolve, failed: failed, unresolved: unresolved) ?? caption.caption ?? "")
                            .font(.footnote).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if let pill = progress != nil ? info.size.map({ Int64($0).formatted(.byteCount(style: .file)) })
                            : info.duration.map({ clockText(Double($0) / 1000) }) {
                            Text(pill).font(.caption.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 7).frame(height: 20).background(.black.opacity(0.42), in: .capsule)
                        }
                    }
                    .padding([.horizontal, .bottom], 10).padding(.top, 28)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                }
                control(unresolved: unresolved, resolve: resolve, progress: progress, failed: failed, noun: noun)
            }
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: message.kind)  // the resolve edit swaps it in place (DESIGN §6.3)
        .accessibilityLabel(accessibilityText(share: share, caption: caption, unresolved: unresolved, resolve: resolve, progress: progress,
                                              uploading: message.txnID.flatMap { model.uploads[$0] } != nil))
        .accessibilityActions {
            if let url = info.externalURL { Button("Open in Instagram") { openURL(url) } }
        }
        .accessibilityIdentifier(unresolved ? "media.load" : share == .reel ? "media.reel" : "media.video")
    }

    @ViewBuilder
    private func control(unresolved: Bool, resolve: AppModel.ResolveState?, progress: Double?, failed: Bool, noun: String) -> some View {
        if let progress {
            DownloadRing(progress: progress)
        } else if resolve == .running {
            ProgressView().controlSize(.large).tint(.white).frame(width: 56, height: 56).mediaGlass(in: .circle)
        } else if failed {
            Label("Try again", systemImage: "arrow.clockwise").font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(height: 36).mediaGlass(in: .capsule)
        } else if unresolved {
            Label("Load \(noun)", systemImage: "arrow.down.circle").font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(height: 36).mediaGlass(in: .capsule)
        } else if info.isVideo {
            Image(systemName: "play.fill").font(.system(size: 24)).frame(width: 56, height: 56).mediaGlass(in: .circle)
        }
    }

    /// DESIGN §12 reel copy, in place of the caption while it applies.
    private func status(resolve: AppModel.ResolveState?, failed: Bool, unresolved: Bool) -> String? {
        if resolve == .running { return "Getting video…" }
        if failed { return unresolved ? "Couldn't get it from Instagram. Tap to try again." : "Couldn't load video. Tap to try again." }
        return nil
    }

    private func accessibilityText(share: MessageKind.ShareType?, caption: ShareCaption, unresolved: Bool,
                                   resolve: AppModel.ResolveState?, progress: Double?, uploading: Bool) -> String {
        // DESIGN §11: "Reel by at tidepool dot films. Caption: … Double-tap to play."
        let what = [share?.label ?? "Video", caption.author.map { "by @\($0)" }].compactMap(\.self).joined(separator: " ")
            + (caption.caption.map { ". Caption: \($0)" } ?? "")
        if let progress {
            return "\(what), \(uploading ? "sending" : "downloading") \(Int(progress * 100)) percent. Double-tap to cancel."
        }
        if resolve == .running { return "\(what), getting it from Instagram" }
        return unresolved ? "\(what), preview only. Double-tap to load it." : "\(what). Double-tap to play."
    }

    /// Reels 220×330 (a 2:3 crop of 9:16), stories 160×284, other videos 220 wide at their own aspect (clamped).
    static func size(_ share: MessageKind.ShareType?, _ info: MediaInfo) -> CGSize {
        switch share {
        case .reel: CGSize(width: 220, height: 330)
        case .story: CGSize(width: 160, height: 284)
        default: CGSize(width: 220, height: 220 * min(max(info.aspect ?? 16.0 / 9, 9.0 / 16), 16.0 / 9))
        }
    }
}

/// DESIGN §6.6: an image post (or anything else shared) as a card: author, image, two lines of caption.
private struct PostCard: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let info: MediaInfo
    let own: Bool
    let fill: Color
    let actions: MessageActions

    var body: some View {
        let caption = ShareCaption(content: message.content)
        let text = [caption.author == nil ? caption.title : nil, caption.caption].compactMap(\.self).joined(separator: "\n")
        let isPost = message.kind == .share(.post, .ready)
        VStack(alignment: .leading, spacing: 0) {
            if let author = caption.author {
                HStack {
                    Text("@\(author)").font(.footnote.weight(.semibold))
                    Spacer()
                    Image(systemName: (isPost ? MessageKind.ShareType.post : .other).symbol).font(.footnote).opacity(0.7)
                }
                .padding(.horizontal, 12).frame(height: 36)
            }
            if let preview = info.previewURL {
                Button { actions.openMedia(message) } label: {
                    MXCThumbnail(mxc: preview, pixels: 720)
                        .frame(width: 240, height: 240 * min(max(info.aspect ?? 1, 0.5625), 1.25))
                        .overlay { if let progress = info.url.flatMap({ model.media.progress[$0] }) { DownloadRing(progress: progress) } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPost ? "Post image. Double-tap to open." : "Shared image. Double-tap to open.")
            }
            if !text.isEmpty { Text(text).font(.footnote).lineLimit(2).padding(.horizontal, 12).padding(.top, 8) }
            if !isPost, let url = info.externalURL {
                Link(destination: url) { Label("Open in Instagram", systemImage: "arrow.up.forward") }
                    .font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.top, 6)
            }
            Spacer().frame(height: text.isEmpty && isPost ? 0 : 10)
        }
        .frame(width: 240, alignment: .leading)
        .foregroundStyle(own ? Color.white : Color.primary)
        .tint(own ? .white : .primary)
        .background(fill)
        .accessibilityIdentifier("media.post")
    }
}

/// DESIGN §6.5: a photo, aspect-fit up to 240×320; tap → M2. A GIF plays three times, then rests on its first frame
/// with a play button that plays it once more; a sticker plays on a loop (no autoplay in requests or under Reduce
/// Motion: the button only).
private struct PhotoCard: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let info: MediaInfo
    let actions: MessageActions
    @State private var gif: AnimatedFrames.Clip?
    @State private var gifPlay: GIFPlay?

    var body: some View {
        let sticker = message.kind == .sticker
        let size = Self.fit(info, max: sticker ? CGSize(width: 140, height: 140) : CGSize(width: 240, height: 320))
        // A photo we're sending: its upload ring (✕ cancels), else the download ring.
        let uploading = message.txnID.flatMap { model.uploads[$0] }
        Button { actions.openMedia(message) } label: {
            Group {
                if info.isAnimated {
                    // A sticker's mailbox copy has no media yet: grey, not an empty gap, until the thread is read.
                    AnimatedThumbnail(info: info, pixels: Int(max(size.width, size.height) * 3),
                                      placeholder: sticker && info.url != nil ? .clear : Color(.systemGray5), loops: sticker,
                                      clip: $gif, play: $gifPlay)
                }
                else { MXCThumbnail(mxc: info.url, pixels: Int(max(size.width, size.height) * 3), placeholder: sticker ? .clear : Color(.systemGray5)) }
            }
                .frame(width: size.width, height: size.height)
                .overlay {
                    if let progress = uploading ?? info.url.flatMap({ model.media.progress[$0] }) { DownloadRing(progress: progress) }
                    else if info.url.map(model.media.failed.contains) == true {
                        Image(systemName: "arrow.clockwise").font(.title3.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).mediaGlass(in: .circle)
                    }
                }
        }
        .buttonStyle(.plain)
        .overlay {  // over the card, not in it: its own tap target
            if let gif, gif.frames.count > 1, gifPlay == nil, uploading == nil {
                Button { gifPlay = GIFPlay(start: .now, loops: 1) } label: {
                    Image(systemName: "play.fill").font(.system(size: 24)).frame(width: 56, height: 56)  // the video card's
                        .mediaGlass(in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(sticker ? "Play sticker" : "Play GIF")
                .accessibilityIdentifier("media.gifPlay")
            }
        }
        .accessibilityLabel(sticker ? "Sticker" : uploading.map { "Photo, sending, \(Int($0 * 100)) percent. Double-tap to cancel." }
            ?? (message.kind == .gif ? "GIF. Double-tap to open." : "Photo. Double-tap to open."))
        .accessibilityIdentifier("media.photo")
    }

    static func fit(_ info: MediaInfo, max box: CGSize) -> CGSize {
        guard let width = info.width, let height = info.height, width > 0, height > 0 else {
            return CGSize(width: min(200, box.width), height: min(200, box.height))
        }
        let scale = min(box.width / width, box.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}

/// A GIF: its still preview when Instagram sent one, then the GIF itself, downloaded as it appears (like a photo) and
/// played from `play`, in the preview's place (a sticker's clear parts would show it). Our own GIF on its way up shows
/// its seeded preview.
private struct AnimatedThumbnail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.autoplaysGIFs) private var autoplays
    let info: MediaInfo
    let pixels: Int
    var placeholder = Color(.systemGray5)
    /// Plays on and on instead of three times, each time it's on screen: stickers, as in Instagram (the user's call,
    /// 2026-10-21).
    var loops = false
    @Binding var clip: AnimatedFrames.Clip?
    @Binding var play: GIFPlay?

    var body: some View {
        Color.clear  // the card's size; what fills it overflows (scaledToFill)
            .overlay {
                if let clip {
                    TimelineView(.animation(paused: play == nil)) { context in
                        let index = play.flatMap { clip.frame(at: context.date.timeIntervalSince($0.start), loops: $0.loops) } ?? 0
                        Image(uiImage: clip.frames[index]).resizable().scaledToFill()
                    }
                } else {
                    MXCThumbnail(mxc: info.thumbnailURL ?? (PhotoMessage.isLocal(info.url) ? info.url : nil), pixels: pixels,
                                 placeholder: placeholder)
                }
            }
            .clipped()
            .task(id: info.url) {
                guard let url = info.url, !PhotoMessage.isLocal(url),
                      let file = try? await model.media.file(url, mimetype: info.mimetype),
                      let loaded = await AnimatedFrames.clip(file) else { return }
                clip = loaded
                // Three plays the first time it's on screen this launch, so scrolling back doesn't start it again.
                if autoplays, !reduceMotion, loaded.frames.count > 1, loops || model.media.playedGIFs.insert(url).inserted {
                    play = GIFPlay(start: .now, loops: loops ? GIFPlay.forever : GIFPlay.autoplayLoops)
                }
            }
            .task(id: play) {  // then it rests on its first frame
                guard let play, let clip, play.loops != GIFPlay.forever else { return }
                try? await Task.sleep(for: .seconds(clip.duration * Double(play.loops)))
                if !Task.isCancelled { self.play = nil }
            }
    }
}

/// A GIF playing: since when, and how many times in a row.
struct GIFPlay: Equatable {
    static let autoplayLoops = 3
    /// A sticker's: it never rests (`Clip.frame(at:loops:)` reads it as a duration only in `Double`).
    static let forever = Int.max
    var start: Date
    var loops: Int
}

extension EnvironmentValues {
    /// GIFs play by themselves (three times) except in a request: a stranger's moving pictures wait for a tap.
    @Entry var autoplaysGIFs = true
}

/// Unavailable, too large, expired, view-once: a neutral card saying so, with the preview (dimmed) when there is one.
private struct NoticeCard: View {
    let symbol: String
    let title: String
    let detail: String
    var preview: String?
    var link: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview {
                MXCThumbnail(mxc: preview, pixels: 600).frame(height: 96).grayscale(0.85).opacity(0.8).clipShape(.rect(cornerRadius: 12))
            } else {
                Image(systemName: symbol).font(.title3).foregroundStyle(.inkSecondaryOnBubble)
            }
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.inkSecondaryOnBubble).fixedSize(horizontal: false, vertical: true)
            if let link {
                Link(destination: link) {
                    Label("Open in Instagram", systemImage: "arrow.up.forward").font(.footnote.weight(.semibold))
                }
                .padding(.top, 2)
                .accessibilityIdentifier("media.openInInstagram")
            }
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .foregroundStyle(.primary)
        .tint(.primary)
        .background(Color.bubbleIncoming)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("media.notice")
    }
}

/// A text with the bridge's link preview under it (DESIGN §13: from `com.beeper.linkpreviews`).
struct LinkBubble: View {
    let message: Message
    let own: Bool

    var body: some View {
        let preview = LinkPreview(content: message.content)
        VStack(alignment: .leading, spacing: 0) {
            Text(message.body).padding(.horizontal, 12).padding(.vertical, 8)
            if let preview {
                Link(destination: preview.url) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let image = preview.imageURL {
                            MXCThumbnail(mxc: image, pixels: 720).frame(width: 240, height: 240 * min(max(preview.aspect ?? 0.525, 0.4), 1))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if let title = preview.title { Text(title).font(.subheadline.weight(.semibold)).lineLimit(2) }
                            Text(preview.url.host() ?? preview.url.absoluteString).font(.caption)
                                .foregroundStyle(own ? Color.white : .inkSecondaryOnBubble)
                        }
                        .multilineTextAlignment(.leading)  // a Link centres its label's lines otherwise
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(.black.opacity(0.06))
                }
                .accessibilityIdentifier("media.link")
            }
        }
        .frame(width: preview == nil ? nil : 240, alignment: .leading)
        .foregroundStyle(own ? Color.white : Color.primary)
        .tint(own ? .white : .primary)
    }
}

/// DESIGN §6.8 with the §14 fallback (static bars from the event ID; the bridge sends no waveform, M5): play/pause,
/// drag across the bars to seek, 1×/1.5×/2× once started, duration then elapsed.
private struct VoiceBubble: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let info: MediaInfo
    let own: Bool
    let sender: String
    let fill: Color
    let actions: MessageActions

    var body: some View {
        let voice = model.voice
        let current = voice.current == message.id
        let downloading = info.url.flatMap { model.media.progress[$0] } != nil
        // A note we're sending: its upload ring in the play circle (✕ cancels).
        let uploading = message.txnID.flatMap { model.uploads[$0] }
        let total = current && voice.duration > 0 ? voice.duration : Double(info.duration ?? 0) / 1000
        let shown = current && (voice.isPlaying || voice.elapsed > 0) ? voice.elapsed : total
        // "Can't play": the circle offers the retry a tap already does (review 2026-10-15 #11).
        let failed = voice.failed == message.id
        HStack(spacing: 10) {
            Button {
                if uploading != nil { return actions.openMedia(message) }  // cancels the upload
                withFile { model.voice.toggle(message.id, file: $0, duration: knownDuration) }
            } label: {
                ZStack {
                    Circle().fill(own ? Color.white : Color.primary)
                    if let uploading {
                        Circle().trim(from: 0, to: max(uploading, 0.02))
                            .stroke(fill, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(3)
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(fill)
                    } else if downloading {
                        ProgressView().tint(own ? fill : Color(.systemBackground))
                    } else {
                        Image(systemName: failed ? "arrow.clockwise" : current && voice.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(own ? fill : Color(.systemBackground))
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(uploading.map { "Sending, \(Int($0 * 100)) percent. Cancel" }
                ?? (failed ? "Couldn't play. Try again" : current && voice.isPlaying ? "Pause" : "Play"))
            .accessibilityIdentifier("voice.play")
            VoiceBars(seed: message.id, progress: current ? voice.progress : 0) { fraction in
                withFile { model.voice.seek(message.id, file: $0, to: fraction, duration: knownDuration) }
            }
            .frame(height: 28)
            // DESIGN §6.8: VoiceOver adjusts by 5 s.
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue("\(clockText(current ? voice.elapsed : 0)) of \(clockText(total))")
            .accessibilityAdjustableAction { direction in
                guard total > 0 else { return }
                let now = current ? voice.elapsed : 0
                let fraction = min(max((now + (direction == .increment ? 5 : -5)) / total, 0), 1)
                withFile { model.voice.seek(message.id, file: $0, to: fraction, duration: knownDuration) }
            }
            .accessibilityIdentifier("voice.bars")
            if current {
                Button { voice.cycleRate() } label: {
                    Text(voice.rate == 1 ? "1×" : voice.rate == 1.5 ? "1.5×" : "2×")
                        .font(.caption.weight(.semibold)).padding(.horizontal, 6).frame(height: 20)
                        .background(.primary.opacity(0.12), in: .capsule)
                        .frame(minHeight: 44).contentShape(.rect)  // 44 pt target (DESIGN §11)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Playback speed")
                .accessibilityIdentifier("voice.rate")
            }
            Text(failed ? "Can't play" : clockText(shown)).font(.footnote).monospacedDigit()
                .foregroundStyle(own ? Color.white : .inkSecondaryOnBubble)
        }
        .padding(.leading, 8).padding(.trailing, 12)
        .frame(width: 240, height: 48)
        .foregroundStyle(own ? Color.white : Color.primary)
        .background(fill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(own ? "Your voice message, \(clockText(total))" : "Voice message from \(sender), \(clockText(total))")
        .accessibilityValue(current ? "\(clockText(voice.elapsed)) played" : "")
        .accessibilityIdentifier("media.voice")
    }

    private var knownDuration: Double? { info.duration.map { Double($0) / 1000 } }

    /// Downloads the note on first use (small), then acts. Not tied to the row's lifetime.
    private func withFile(_ then: @escaping (URL) -> Void) {
        guard let mxc = info.url else { return }
        Task {
            if let file = try? await model.media.file(mxc, mimetype: info.mimetype) { then(file) }
        }
    }
}

/// Static bars (3 pt wide, 2 pt gaps) seeded by the event ID, played part opaque, the rest at 35%.
struct VoiceBars: View {
    let seed: String
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let count = max(Int((size.width + 2) / 5), 1)
                for (i, height) in Self.heights(seed: seed, count: count).enumerated() {
                    let h = max(3, size.height * height)
                    var bar = context
                    bar.opacity = (Double(i) + 0.5) / Double(count) <= progress ? 1 : 0.35
                    bar.fill(Path(roundedRect: CGRect(x: CGFloat(i) * 5, y: (size.height - h) / 2, width: 3, height: h), cornerRadius: 1.5),
                             with: .foreground)
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                seek(min(max(drag.location.x / max(geometry.size.width, 1), 0), 1))
            })
        }
    }

    /// FNV-1a of the seed, then an LCG: the same note always gets the same bars.
    nonisolated static func heights(seed: String, count: Int) -> [Double] {
        var state = seed.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 0.25 + Double(state >> 33) / Double(UInt64(1) << 31) * 0.75
        }
    }
}

/// Determinate download ring around a cancel glyph (DESIGN §6.3 "Downloading").
private struct DownloadRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.28), lineWidth: 3)
            Circle().trim(from: 0, to: max(progress, 0.02))
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: 46, height: 46)
        .padding(5)
        .mediaGlass(in: .circle)
        .animation(.linear(duration: 0.15), value: progress)
        .accessibilityIdentifier("media.downloading")
    }
}
