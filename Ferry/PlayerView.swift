import AVFoundation
import SwiftUI

/// What a thread shows full screen: a video (M1) or a photo (M2), always from a downloaded file, because AVPlayer
/// can't send the auth header media needs (PLAN §2.7).
struct MediaViewerItem: Identifiable {
    let message: Message
    let file: URL
    /// Who shared it, for "Shared by Kivo · 9:31 AM" (DESIGN M1).
    let sender: String
    var id: String { message.id }
    var isVideo: Bool { MediaInfo(content: message.content).isVideo }
}

/// "0:42"
nonisolated func clockText(_ seconds: Double) -> String {
    Duration.seconds(max(0, seconds.isFinite ? seconds : 0)).formatted(.time(pattern: .minuteSecond))
}

// MARK: - M1 player

/// DESIGN M1 with D10: one video and nothing after it, looping; swipe down or up goes back to the chat. Built on
/// AVPlayerLayer with a few controls of our own, not `VideoPlayer`: its controls would sit under the caption and
/// take the dismiss drag.
struct PlayerView: View {
    let item: MediaViewerItem
    let identity: AccountIdentity?
    @Environment(\.dismiss) private var dismiss
    @State private var playback = LoopingPlayback()
    @State private var drag: CGFloat = 0
    @State private var captionExpanded = false

    private static let dismissDistance: CGFloat = 120

    var body: some View {
        let info = MediaInfo(content: item.message.content)
        ZStack {
            Color.black.opacity(1 - min(abs(drag) / 500, 0.6)).ignoresSafeArea()
            Group {
                PlayerLayer(player: playback.player)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { playback.toggle() }
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("player.video")
                if playback.failed {
                    failure(info)
                } else if !playback.isPlaying {
                    Image(systemName: "play.fill").font(.system(size: 26)).foregroundStyle(.white)
                        .frame(width: 64, height: 64).glassEffect(.regular, in: .circle).allowsHitTesting(false)
                }
                overlay(info)
            }
            .offset(y: drag)
        }
        // Swipe down or up anywhere outside the controls; the scrubber's own drag wins over it.
        .gesture(DragGesture(minimumDistance: 20)
            .onChanged { drag = $0.translation.height }
            .onEnded { value in
                let distance = abs(value.predictedEndTranslation.height) > 400 ? value.predictedEndTranslation.height : value.translation.height
                if abs(distance) > Self.dismissDistance { close(direction: distance > 0 ? 1 : -1) } else {
                    withAnimation(.snappy) { drag = 0 }
                }
            })
        .sensoryFeedback(.impact(flexibility: .soft), trigger: abs(drag) > Self.dismissDistance) { _, past in past }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .presentationBackground(.clear)  // the chat shows through while dragging
        .onAppear { playback.load(item.file) }
        .onDisappear { playback.stop() }
    }

    /// Slides out the way it was swiped, then dismisses without the cover's own (downward) animation.
    private func close(direction: CGFloat) {
        withAnimation(.easeOut(duration: 0.2)) { drag = direction * 1000 } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }

    private func overlay(_ info: MediaInfo) -> some View {
        let caption = ShareCaption(content: item.message.content)
        let isShare = info.externalURL != nil
        let text = isShare ? [caption.author == nil ? caption.title : nil, caption.subtitle, caption.caption].compactMap(\.self).joined(separator: "\n") : ""
        return VStack(spacing: 0) {
            HStack {
                Button("Close", systemImage: "xmark") { close(direction: 1) }
                    .labelStyle(.iconOnly).font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityIdentifier("player.close")
                Spacer()
                Button(playback.isMuted ? "Unmute" : "Mute", systemImage: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    playback.isMuted.toggle()
                }
                .labelStyle(.iconOnly).font(.body.weight(.semibold))
                .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
            }
            .overlay(alignment: .top) {
                Capsule().fill(.white.opacity(0.55)).frame(width: 36, height: 5).offset(y: -12).accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                if isShare && !playback.failed {  // a failure offers its own way out, in the middle
                    HStack(spacing: 10) {
                        if let author = caption.author { Text("@\(author)").font(.subheadline.weight(.bold)) }
                        Spacer(minLength: 0)
                        if let url = info.externalURL {
                            Link(destination: url) {
                                Label("Open in Instagram", systemImage: "arrow.up.forward").labelStyle(TrailingIcon())
                                    .font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(height: 30)
                                    .glassEffect(.regular.interactive(), in: .capsule)
                            }
                            .accessibilityIdentifier("player.openInInstagram")
                        }
                    }
                }
                if !text.isEmpty && !playback.failed {
                    ScrollView { Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: captionExpanded ? 160 : 40)
                        .scrollDisabled(!captionExpanded)
                        .onTapGesture { withAnimation(.snappy) { captionExpanded.toggle() } }
                }
                HStack(spacing: 8) {
                    Text("Shared by \(item.sender) · \(item.message.ts.timeText)").font(.footnote).foregroundStyle(.white.opacity(0.75))
                    if let identity { AccountTag(identity: identity) }
                }
                // Nothing to scrub until the video says how long it is ("0:00 / −0:00" on a failure, review 2026-10-15 #7).
                if playback.duration > 0 {
                    Scrubber(progress: playback.progress, elapsed: playback.elapsed, duration: playback.duration) { playback.seek($0) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 60)
            .padding(.bottom, 12)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    /// DESIGN M1 failed state: what happened, then Try Again and, for a share, the way out to Instagram. The file is
    /// already here, so the cause is playback on this device (the simulator's audio output, CLAUDE.md), not the share.
    private func failure(_ info: MediaInfo) -> some View {
        VStack(spacing: 10) {
            Text("Couldn't play this video").font(.headline)
            Text("It downloaded, but this device couldn't play it.").font(.footnote).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button { playback.retry() } label: { Label("Try Again", systemImage: "arrow.clockwise").capsule() }
                    .accessibilityIdentifier("player.retry")
                if let url = info.externalURL {
                    Link(destination: url) { Label("Open in Instagram", systemImage: "arrow.up.right").capsule() }
                        .accessibilityIdentifier("player.openInInstagram")
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .foregroundStyle(.white)
    }
}

/// Elapsed / remaining under a thin track that thickens while dragged (DESIGN M1).
private struct Scrubber: View {
    let progress: Double
    let elapsed: Double
    let duration: Double
    let seek: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let value = dragging ?? progress
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: geometry.size.width * value)
                }
                .frame(height: dragging == nil ? 3 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = min(max(drag.location.x / max(geometry.size.width, 1), 0), 1)
                        seek(dragging ?? 0)
                    }
                    .onEnded { _ in dragging = nil })
            }
            .frame(height: 24)
            .animation(.snappy(duration: 0.15), value: dragging == nil)
            HStack {
                Text(clockText(dragging.map { $0 * duration } ?? elapsed))
                Spacer()
                Text("−" + clockText(duration - (dragging.map { $0 * duration } ?? elapsed)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(clockText(elapsed)) of \(clockText(duration))")
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            let step = 5 / duration
            seek(min(max(progress + (direction == .increment ? step : -step), 0), 1))
        }
    }
}

/// AVQueuePlayer + AVPlayerLooper on the cached file (D10: reels loop), plus what the overlay shows.
@Observable
final class LoopingPlayback {
    let player = AVQueuePlayer()
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var failed = false
    var isMuted = false { didSet { player.isMuted = isMuted } }
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var failObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var file: URL?

    var progress: Double { duration > 0 ? min(elapsed / duration, 1) : 0 }

    func load(_ file: URL) {
        guard looper == nil else { return }
        self.file = file
        failed = false
        #if DEBUG
        if DebugFixtures.playerFails {
            failed = true
            return
        }
        #endif
        VoicePlayback.activateAudioSession()
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: file))
        self.looper = looper
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        // AVFoundation drops an item it can't render (M5: no audio output in the simulator) with no error on the
        // player, which left a black screen; this is the only signal.
        failObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil,
                                                              queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, self.looper?.loopingPlayerItems.contains(item) == true else { return }
                self.stop()
                self.failed = true
            }
        }
        player.play()
        isPlaying = true
        Task {
            if (try? await AVURLAsset(url: file).load(.isPlayable)) != true { failed = true }
        }
    }

    private func tick(_ time: CMTime) {
        if let length = player.currentItem?.duration, length.isNumeric { duration = length.seconds }
        elapsed = time.seconds  // the looper's current copy of the item, so it restarts at 0 each loop
    }

    func toggle() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(_ fraction: Double) {
        guard duration > 0 else { return }
        elapsed = fraction * duration
        player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func retry() {
        stop()
        if let file { load(file) }
    }

    func stop() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        (timeObserver, failObserver) = (nil, nil)
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        isPlaying = false
    }
}

private struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect  // DESIGN M1: aspect-fit; 9:16 fills the screen
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {}

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }  // layerClass guarantees it
    }
}

private extension View {
    /// The failure's buttons: glass capsules, 44 pt tall.
    func capsule() -> some View {
        font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 44).glassEffect(.regular.interactive(), in: .capsule)
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon }
    }
}

// MARK: - M2 photo viewer

/// DESIGN M2: one photo; pinch or double-tap to zoom, drag to pan while zoomed; at normal size, swipe down or up to
/// go back (like the player).
struct PhotoViewer: View {
    let item: MediaViewerItem
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.opacity(scale > 1 ? 1 : 1 - min(abs(offset.height) / 500, 0.6)).ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(zoom.simultaneously(with: pan))
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            if scale > 1 { reset() } else { scale = 2.5; baseScale = 2.5 }
                        }
                    }
                    .accessibilityLabel("Photo")
                    .accessibilityIdentifier("photo.image")
            }
            VStack {
                HStack {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityIdentifier("photo.close")
                    Spacer()
                    ShareLink(item: item.file) { Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)) }
                        .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: .circle)
                }
                .padding(.horizontal, 16)
                Spacer()
            }
            .foregroundStyle(.white)
            .opacity(offset.height == 0 || scale > 1 ? 1 : 0)
        }
        .statusBarHidden()
        .presentationBackground(.clear)
        .task { image = UIImage(contentsOfFile: item.file.path()) }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { scale = min(max(baseScale * $0.magnification, 1), 5) }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1 { withAnimation(.snappy) { reset() } }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { drag in
                if scale > 1 {
                    offset = CGSize(width: baseOffset.width + drag.translation.width, height: baseOffset.height + drag.translation.height)
                } else {
                    offset = CGSize(width: 0, height: drag.translation.height)
                }
            }
            .onEnded { drag in
                if scale > 1 { baseOffset = offset; return }
                if abs(drag.predictedEndTranslation.height) > 400 || abs(drag.translation.height) > 120 {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { dismiss() }
                } else {
                    withAnimation(.snappy) { offset = .zero }
                }
            }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}

// MARK: - Voice

/// One voice note at a time (DESIGN §6.8): AVPlayer on the cached file. It plays the bridge's Ogg/Opus natively
/// (PLAN P3; confirmed on a real bridged note in M5, so no AVAudioFile fallback was needed).
@Observable
final class VoicePlayback {
    /// The note playing, or paused part-way; nil when none is.
    private(set) var current: String?
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    /// 1×, 1.5×, 2×; kept across notes.
    private(set) var rate: Float = 1
    /// The note that last failed to play (its bubble says so until it's tried again).
    private(set) var failed: String?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var failObserver: (any NSObjectProtocol)?

    var progress: Double { duration > 0 ? min(elapsed / duration, 1) : 0 }

    func toggle(_ id: String, file: URL, duration known: Double?) {
        guard current == id, let player else { return start(id, file: file, at: 0, duration: known) }
        if isPlaying { player.pause() } else { player.play() }  // play() resumes at defaultRate
        isPlaying.toggle()
    }

    /// Jumps to `fraction` of the note; another note starts from there.
    func seek(_ id: String, file: URL, to fraction: Double, duration known: Double?) {
        guard current == id, let player else { return start(id, file: file, at: fraction * (known ?? 0), duration: known) }
        elapsed = fraction * duration
        player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func cycleRate() {
        rate = rate == 1 ? 1.5 : rate == 1.5 ? 2 : 1
        player?.defaultRate = rate
        if isPlaying { player?.rate = rate }
    }

    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        for observer in [endObserver, failObserver].compactMap(\.self) { NotificationCenter.default.removeObserver(observer) }
        (player, timeObserver, endObserver, failObserver) = (nil, nil, nil, nil)
        (current, isPlaying, elapsed, duration) = (nil, false, 0, 0)
    }

    private func start(_ id: String, file: URL, at seconds: Double, duration known: Double?) {
        stop()
        #if DEBUG
        if DebugFixtures.playerFails {
            failed = id
            return
        }
        #endif
        Self.activateAudioSession()
        let item = AVPlayerItem(url: file)
        let player = AVPlayer(playerItem: item)
        player.defaultRate = rate
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        failObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
                self?.failed = id
            }
        }
        failed = nil
        self.player = player
        (current, duration, elapsed) = (id, known ?? 0, seconds)
        if seconds > 0 { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        player.play()
        isPlaying = true
    }

    private func tick(_ time: CMTime) {
        if let length = player?.currentItem?.duration, length.isNumeric { duration = length.seconds }
        if isPlaying { elapsed = time.seconds }
    }

    /// Back to the start, paused; the note stays current so its speed pill stays (DESIGN §6.8).
    private func finished() {
        isPlaying = false
        elapsed = 0
        player?.seek(to: .zero)
    }

    /// Sound on even with the silent switch, like most video apps (DESIGN M1).
    nonisolated static func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

extension Int64 {
    /// A message time as "9:31 AM" today, else "Oct 12, 9:31 AM".
    var timeText: String { MessageRow.timeLabel(self) }
}
