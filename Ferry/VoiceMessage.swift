import AVFoundation
import SwiftUI

/// Sending a voice note (DESIGN §6.9): AAC in an .m4a, sent as `m.audio` with the voice flag, which the bridge uploads
/// to Instagram as a voice clip (`IsVoiceClip`; `audio/mp4` is fully supported, igconnector `capabilities.go`; spike
/// S4 sent one this way). Instagram gets no caption, and the bridge sets no length limit.
nonisolated enum VoiceMessage {
    static let mimetype = "audio/mp4"
    static let filename = "voice.m4a"

    /// A finished recording: our file in the temporary folder, its length (ms) and size.
    struct Recorded: Equatable, Sendable {
        var file: URL
        var duration: Int
        var size: Int
    }

    /// The `m.audio` content (and, with a `local:` URL, the local echo's). No waveform: the bridge reads one 0…256
    /// while MSC1767 says 0…1024, and our bubble draws its own bars anyway.
    static func content(url: String, voice: Recorded, replyTo: String? = nil) -> JSON {
        var fields: [String: JSON] = [
            "msgtype": "m.audio",
            "body": .string(filename),
            "url": .string(url),
            "info": ["mimetype": .string(mimetype), "size": .number(Double(voice.size)), "duration": .number(Double(voice.duration))],
            "org.matrix.msc1767.audio": ["duration": .number(Double(voice.duration))],
            "org.matrix.msc3245.voice": [:],
        ]
        if let replyTo { fields["m.relates_to"] = ["m.in_reply_to": ["event_id": .string(replyTo)]] }
        return .object(fields)
    }

    /// The recorder's average power (dB) as 0…1 for the meter: -50 dB and below is silence.
    static func level(decibels: Float) -> Double {
        min(max((Double(decibels) + 50) / 50, 0), 1)
    }

    /// The mic's touch-and-hold rules (DESIGN §6.9), fed by `VoiceRecorder`: a tap is only a hint; holding records;
    /// sliding left past `cancelDistance` cancels at once; lifting sends from a second on; at the maximum it sends
    /// by itself. Each hold produces at most one of cancel, hint, discard or send.
    struct Hold: Equatable {
        /// Shorter presses are taps, so the recorder (and the microphone prompt) never starts for them.
        static let tapLimit: TimeInterval = 0.3
        static let minDuration: TimeInterval = 1
        /// The user's choice (2026-10-15); the bridge sets no `MaxDuration` for voice, and Instagram's app caps its own
        /// recordings at 60 s, so a long note is checked live (manual-verification row 13).
        static let maxDuration: TimeInterval = 300
        /// Points left of where the finger went down.
        static let cancelDistance = 120.0

        enum Action: Equatable { case start, cancel, hint, discard, send }

        private enum Phase { case pressing, recording, done }
        private var phase: Phase

        /// `recording`: VoiceOver's activation starts the recorder at once (it can't hold).
        init(recording: Bool = false) {
            phase = recording ? .recording : .pressing
        }

        /// On a timer while the finger is down: `held` since it went down, `recorded` the recorder's time.
        mutating func tick(held: TimeInterval, recorded: TimeInterval) -> Action? {
            switch phase {
            case .pressing where held >= Self.tapLimit:
                phase = .recording
                return .start
            case .recording where recorded >= Self.maxDuration:
                phase = .done
                return .send
            default:
                return nil
            }
        }

        /// The finger moved; `translation` is horizontal, negative to the left.
        mutating func drag(_ translation: Double) -> Action? {
            guard phase == .recording, translation <= -Self.cancelDistance else { return nil }
            phase = .done
            return .cancel
        }

        mutating func release(recorded: TimeInterval) -> Action? {
            defer { phase = .done }
            switch phase {
            case .pressing: return .hint
            case .recording: return recorded < Self.minDuration ? .discard : .send
            case .done: return nil
            }
        }

        /// 0 at rest, 1 at the threshold: the "Slide to cancel" label fades out on the way.
        static func cancelProgress(_ translation: Double) -> Double {
            min(max(-translation / cancelDistance, 0), 1)
        }
    }
}

/// The composer's recorder: runs AVAudioRecorder (AAC, mono, `.m4a`) under `.playAndRecord` only while the mic is
/// held, then puts the audio session back as it was. `VoiceMessage.Hold` decides what each touch means.
@Observable
final class VoiceRecorder {
    enum State: Equatable { case idle, recording, cancelled }

    private(set) var state = State.idle
    /// Seconds recorded so far.
    private(set) var elapsed: TimeInterval = 0
    /// Recent levels (0…1), oldest first, for the meter.
    private(set) var levels: [Double] = []
    /// How far the finger is left of where it went down (≤ 0): the mic follows it and "Slide to cancel" fades.
    private(set) var slide: Double = 0
    /// "Hold to record" for 2 s after a tap or a note under a second: the composer field's placeholder meanwhile.
    private(set) var hint: String?
    /// The microphone is off for this app: the composer says why it's needed and links to Settings.
    var permissionDenied = false
    /// Haptic triggers (DESIGN §10).
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var cancelled = 0

    @ObservationIgnored private var hold: VoiceMessage.Hold?
    @ObservationIgnored private var pressedAt = Date.now
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var send: ((VoiceMessage.Recorded) -> Void)?
    @ObservationIgnored private var savedSession: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    @ObservationIgnored private var hintID = 0
    /// "Cancelled" stays while the finger is down, then a moment after it lifts.
    @ObservationIgnored private var fingerDown = false
    @ObservationIgnored private var cancelID = 0
    #if DEBUG
    /// `FERRY_DEBUG_VOICE_FILE`: when the recording started, standing in for the microphone.
    @ObservationIgnored private var fakeSince: Date?
    #endif

    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ]

    /// The finger went down on the mic. `send` gets the note when it's done (the thread it was pressed in).
    func press(send: @escaping (VoiceMessage.Recorded) -> Void) {
        guard hold == nil, state != .recording else { return }
        if state == .cancelled { state = .idle }
        hold = VoiceMessage.Hold()
        self.send = send
        fingerDown = true
        pressedAt = .now
        slide = 0
        startTicker()
        prepare(warmUp: true)
    }

    func drag(_ translation: Double) {
        guard hold != nil else { return }
        slide = max(min(translation, 0), -VoiceMessage.Hold.cancelDistance)
        perform(hold?.drag(translation))
    }

    func release() {
        fingerDown = false
        guard hold != nil else {  // the slide already cancelled this hold
            if state == .cancelled { clearCancelled() }
            return
        }
        perform(hold?.release(recorded: elapsed))
    }

    /// VoiceOver can't hold: activating the mic starts recording, activating it again sends (or discards under 1 s).
    func toggle(send: @escaping (VoiceMessage.Recorded) -> Void) {
        if hold != nil { return release() }
        if state == .cancelled { state = .idle }
        hold = VoiceMessage.Hold(recording: true)
        self.send = send
        pressedAt = .now
        startTicker()
        begin()
    }

    /// The slide's cancel, for VoiceOver.
    func cancel() {
        guard hold != nil else { return }
        perform(.cancel)
    }

    /// The touch was taken away (a call, an alert) or the thread went away: whatever was recorded is dropped.
    func abandon() {
        fingerDown = false
        if state == .cancelled { clearCancelled() }
        guard hold != nil else { return }
        discardRecording()
        endHold()
    }

    private func perform(_ action: VoiceMessage.Hold.Action?) {
        switch action {
        case .start:
            begin()
        case .cancel:
            discardRecording()
            endHold()
            state = .cancelled
            cancelled += 1
            if !fingerDown { clearCancelled() }  // VoiceOver's Cancel
        case .hint, .discard:
            discardRecording()
            endHold()
            showHint("Hold to record")
        case .send:
            let note = finishRecording()
            let send = send
            endHold()
            stopped += 1
            if let note { send?(note) }
        case nil:
            break
        }
    }

    /// Asks for the microphone the first time (that hold ends; the next one records), explains when it's off.
    private func begin() {
        #if DEBUG
        if DebugFixtures.voiceFile != nil {
            fakeSince = .now
            return recording()
        }
        #endif
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            endHold()
            Task { _ = await AVAudioApplication.requestRecordPermission() }
            return
        default:
            endHold()
            permissionDenied = true
            return
        }
        prepare(warmUp: false)
        guard let recorder, recorder.record() else {
            discardRecording()
            endHold()
            return showHint("Couldn't start recording")
        }
        recording()
    }

    /// The audio session and a recorder ready to go: on touch-down (`warmUp`), so they're set up while `Hold` waits to
    /// tell a hold from a tap, and the hold only has to start it (a hold took 690 ms to record here, 366 ms of it this
    /// setup, the user found it slow on the phone, 2026-10-21). Not for a tap's sake: never without the microphone
    /// granted (no prompt on a tap), and not while another app plays audio, which activating the session would pause.
    /// A tap's recorder never records; `discardRecording` drops it.
    private func prepare(warmUp: Bool) {
        guard recorder == nil, AVAudioApplication.shared.recordPermission == .granted else { return }
        #if DEBUG
        if DebugFixtures.voiceFile != nil { return }
        #endif
        let session = AVAudioSession.sharedInstance()
        if warmUp && session.isOtherAudioPlaying { return }
        savedSession = (session.category, session.mode, session.categoryOptions)
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let file = URL.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: file, settings: Self.settings)
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
        } catch {
            restoreSession()
        }
    }

    private func recording() {
        state = .recording
        elapsed = 0
        levels = []
        started += 1
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                tick()
            }
        }
    }

    private func tick() {
        if let recorder {
            recorder.updateMeters()
            elapsed = recorder.currentTime
            levels = Array((levels + [VoiceMessage.level(decibels: recorder.averagePower(forChannel: 0))]).suffix(16))
        }
        #if DEBUG
        if let fakeSince {
            elapsed = Date.now.timeIntervalSince(fakeSince)
            levels = Array((levels + [0.35 + 0.3 * sin(elapsed * 7)]).suffix(16))
        }
        #endif
        perform(hold?.tick(held: Date.now.timeIntervalSince(pressedAt), recorded: elapsed))
    }

    private func finishRecording() -> VoiceMessage.Recorded? {
        #if DEBUG
        if fakeSince != nil, let source = DebugFixtures.voiceFile {
            fakeSince = nil
            return Self.copyOfDebugFile(source)
        }
        #endif
        guard let recorder else { return nil }
        let duration = recorder.currentTime  // 0 once stopped
        recorder.stop()
        self.recorder = nil
        restoreSession()
        let size = (try? recorder.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return VoiceMessage.Recorded(file: recorder.url, duration: Int(duration * 1000), size: size)
    }

    private func discardRecording() {
        #if DEBUG
        fakeSince = nil
        #endif
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        self.recorder = nil
        restoreSession()
    }

    private func endHold() {
        hold = nil
        ticker?.cancel()
        ticker = nil
        slide = 0
        if state == .recording { state = .idle }
    }

    /// Back to the category the app had (playback sets `.playback` for voice notes and videos).
    private func restoreSession() {
        guard let saved = savedSession else { return }
        savedSession = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(saved.0, mode: saved.1, options: saved.2)
    }

    private func clearCancelled() {
        cancelID += 1
        let id = cancelID
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if cancelID == id, state == .cancelled { state = .idle }
        }
    }

    private func showHint(_ text: String) {
        hint = text
        hintID += 1
        let id = hintID
        AccessibilityNotification.Announcement(text).post()
        Task {
            try? await Task.sleep(for: .seconds(2))
            if hintID == id { hint = nil }
        }
    }

    #if DEBUG
    /// A copy of the DEBUG voice file (the upload moves its file into the media cache), with its real length.
    private static func copyOfDebugFile(_ source: URL) -> VoiceMessage.Recorded? {
        let copy = URL.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).m4a")
        // AVAudioFile only reads the file (an AVAudioPlayer would need the audio device the simulator may lack).
        guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil, let audio = try? AVAudioFile(forReading: copy),
              let size = try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return VoiceMessage.Recorded(file: copy, duration: Int(Double(audio.length) / audio.fileFormat.sampleRate * 1000), size: size)
    }
    #endif
}

// MARK: - Composer pieces (DESIGN §6.9)

/// The composer's mic, where Send is when the field is empty: touch and hold to record, slide left to cancel, lift
/// to send. VoiceOver: activate to start, activate again to send, or the Cancel action.
struct MicButton: View {
    let recorder: VoiceRecorder
    let tint: Color
    let send: (VoiceMessage.Recorded) -> Void
    @GestureState private var touching = false
    /// This touch called `press`; cleared by `onEnded`, so a touch reset without it was taken away by the system.
    @State private var pressed = false

    var body: some View {
        let recording = recorder.state == .recording
        Image(systemName: recording ? "mic.fill" : "mic")
            .font(.body.weight(.semibold))
            .foregroundStyle(recording ? Color.white : Color.primary)
            .frame(width: 32, height: 32)
            .background {
                if recording { Circle().fill(tint).scaleEffect(1.35) }
            }
            .offset(x: recorder.slide)
            .padding(6).contentShape(.rect).padding(-6)  // 44 pt target (DESIGN §11)
            .animation(.snappy(duration: 0.2), value: recording)
            .gesture(
                // Global: the mic moves with the finger, so local coordinates would chase themselves.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($touching) { _, touching, _ in touching = true }
                    .onChanged { drag in
                        if !pressed {
                            pressed = true
                            recorder.press(send: send)
                        }
                        recorder.drag(drag.translation.width)
                    }
                    .onEnded { _ in
                        pressed = false
                        recorder.release()
                    }
            )
            .onChange(of: touching) { _, touching in
                if !touching && pressed {
                    pressed = false
                    recorder.abandon()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(recording ? "Stop and send voice message" : "Record voice message")
            .accessibilityHint(recording ? "" : "Touch and hold to record, lift to send, slide left to cancel.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { recorder.toggle(send: send) }
            .accessibilityActions {
                if recording { Button("Cancel recording") { recorder.cancel() } }
            }
            .accessibilityIdentifier("composer.mic")
    }
}

/// What the field shows while recording: a red dot, the time, the level, and "Slide to cancel" fading as the finger
/// nears the threshold; then "Cancelled" for a moment.
struct RecordingStrip: View {
    let recorder: VoiceRecorder

    var body: some View {
        HStack(spacing: 8) {
            if recorder.state == .cancelled {
                Image(systemName: "trash")
                Text("Cancelled")
            } else {
                Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(.statusError)
                    .symbolEffect(.pulse, options: .repeating)
                Text(clockText(recorder.elapsed)).monospacedDigit()
                LevelMeter(levels: recorder.levels).frame(width: 64, height: 20)
                Spacer(minLength: 4)
                ViewThatFits(in: .horizontal) {
                    Label("Slide to cancel", systemImage: "chevron.left")
                    Image(systemName: "chevron.left")
                }
                .foregroundStyle(.inkSecondary)
                .opacity(1 - VoiceMessage.Hold.cancelProgress(recorder.slide))
                .padding(.trailing, 4)
            }
        }
        .font(.subheadline)
        .foregroundStyle(recorder.state == .cancelled ? Color.statusError : Color.primary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recorder.state == .cancelled ? "Recording cancelled" : "Recording, \(clockText(recorder.elapsed))")
        .accessibilityIdentifier(recorder.state == .cancelled ? "composer.recordingCancelled" : "composer.recording")
    }
}

/// The last levels as bars, newest on the right.
private struct LevelMeter: View {
    let levels: [Double]

    var body: some View {
        Canvas { context, size in
            let count = max(Int((size.width + 2) / 4), 1)
            let shown = Array(repeating: 0, count: max(count - levels.count, 0)) + levels.suffix(count)
            for (i, level) in shown.enumerated() {
                let h = max(3, size.height * level)
                context.fill(Path(roundedRect: CGRect(x: CGFloat(i) * 4, y: (size.height - h) / 2, width: 2, height: h), cornerRadius: 1),
                             with: .foreground)
            }
        }
        .foregroundStyle(Color.primary)
    }
}
