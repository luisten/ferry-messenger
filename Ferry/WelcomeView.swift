import SwiftUI

// MARK: - O1 Welcome: "The crossing"

/// O1 (DESIGN O1, REVIEW-2026-10-15 R2.3, D19): the wordmark and headline, the icon's ferry crossing a calm sea with
/// two accounts aboard, the three promises, and the one button. Everything you read or tap sits on the system
/// background; only the picture uses the brand's sea (principle 10). Nothing waits for the picture's motion.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    let connect: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var wordmark: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var disc: CGFloat = 36
    /// The scroll view's visible height: the content is at least that tall, so spare room splits above and below it.
    @State private var viewport: CGFloat = 0

    var body: some View {
        let large = typeSize.isAccessibilitySize
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                header(large: large)
                AmbientMotion { motion in
                    CrossingScene(passengers: Crossing.passengers(model.orderedAccounts.compactMap { model.identities[$0.id] }),
                                  motion: motion, scale: large ? 0.7 : 1)
                }
                .padding(.top, 16)
                promises(large: large).padding(.top, 28)
                if large { legal.padding(.top, 28).padding(.horizontal, 24) }  // the pinned bar keeps only the button
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, minHeight: viewport)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in viewport = height }
        .safeAreaBar(edge: .bottom) {  // a bar: the scroll edge effect softens what passes under it
            VStack(spacing: 12) {
                Button(action: connect) {
                    Text("Connect Instagram account")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, large ? 8 : 0)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent).labelOnTint()
                .accessibilityIdentifier("welcome.connect")
                if !large { legal }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func header(large: Bool) -> some View {
        VStack(spacing: 8) {
            Text(verbatim: "Ferry")
                .font(.system(size: min(wordmark, 62), weight: .bold, design: .rounded))  // stops growing at AX1
                .tracking(-0.5)
            Text("All your Instagram DMs.\nNone of the feed.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: large ? 345 : 320)
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ferry. All your Instagram DMs. None of the feed.")
        .accessibilityAddTraits(.isHeader)
    }

    /// A centred column, rows leading-aligned. The spec's 300 pt wraps the third promise in SF Pro (it needs 303), so
    /// the column takes its rows' width while they fit on one line, and the screen's width once they don't.
    private func promises(large: Bool) -> some View {
        let rows = VStack(alignment: .leading, spacing: large ? 20 : 16) {
            promise("tray", "Every account, one inbox", large: large)
            promise("play.rectangle.on.rectangle", "Reels play right in the chat", large: large)
            promise("eye.slash", "No feed, no Explore, no algorithm", large: large)
        }
        return ViewThatFits(in: .horizontal) {
            rows.fixedSize()
            rows.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
    }

    private func promise(_ symbol: String, _ text: LocalizedStringKey, large: Bool) -> some View {
        HStack(alignment: large ? .top : .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: min(disc, 50), height: min(disc, 50))
                .background(Color(.tertiarySystemFill), in: .circle)
                .accessibilityHidden(true)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var legal: some View {
        Text("Not affiliated with Instagram or Meta.")
            .font(.caption)
            .foregroundStyle(.inkSecondary)
            .multilineTextAlignment(.center)
    }
}

// MARK: - The scene

/// O1's picture (REVIEW R2.3 "The scene", back to front): the sky is the screen's background; a haze above the
/// horizon; the sea band with a wavy lower edge; two swell lines; a short wake; the icon's hull with two accounts'
/// bubbles aboard. Brand scenery: the one place in the app the sea's colours appear. One image to VoiceOver.
struct CrossingScene: View {
    /// Front, then back (`Crossing.passengers`).
    let passengers: [AccountIdentity]
    let motion: Crossing.Motion
    /// 1, or 0.7 at accessibility text sizes: the picture yields to the text.
    var scale: CGFloat = 1
    @State private var start = Date.now
    @State private var arrived = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: motion != .running)) { timeline in
            let pose = Crossing.pose(at: motion == .still ? nil : timeline.date.timeIntervalSince(start))
            Canvas { context, size in sea(&context, size: size, pose: pose) }
                // An overlay: the artboard (307 pt) is taller than the scene and mustn't size it.
                .overlay(alignment: .top) { ferry(pose: pose, shown: arrived || motion == .still) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Crossing.height * scale)
        .onAppear { arrived = true }  // the entrance, once per appearance; none when still
        .onDisappear { arrived = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A ferry carrying messages across calm water.")
        .accessibilityAddTraits(.isImage)
    }

    private func sea(_ context: inout GraphicsContext, size: CGSize, pose: Crossing.Pose) {
        let k = scale, width = size.width
        let horizon = Crossing.horizon * k, edge = Crossing.edge * k
        // Increase Contrast: no haze, swell lines at full foam (DESIGN O1).
        let increased = contrast == .increased
        if !increased {
            let haze = CGRect(x: 0, y: horizon - 40 * k, width: width, height: 40 * k)
            context.fill(Path(haze), with: .linearGradient(Gradient(colors: [Scenery.seaHaze.opacity(0), Scenery.seaHaze]),
                                                           startPoint: CGPoint(x: 0, y: haze.minY), endPoint: CGPoint(x: 0, y: haze.maxY)))
        }

        // The band runs well past both sides so its drifting edge always covers the width.
        let half = Crossing.edgeWavelength / 2
        let count = Int(((width + 2 * Crossing.edgeWavelength) / half).rounded(.up)) + 1
        let left = -Crossing.edgeWavelength - pose.edge, right = left + CGFloat(count) * half
        var band = Path()
        band.move(to: CGPoint(x: left, y: horizon))
        band.addLine(to: CGPoint(x: right, y: horizon))
        band.addLine(to: CGPoint(x: right, y: edge))
        Crossing.addArches(to: &band, from: right, y: edge, half: -half, amplitude: 5 * k, count: count)
        band.closeSubpath()
        context.fill(band, with: .linearGradient(Gradient(colors: [Scenery.seaHorizon, Scenery.seaFloor]),
                                                 startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: edge)))

        let swellOpacity = increased ? 1 : colorScheme == .dark ? 0.4 : 0.5
        for (i, line) in [(y: horizon + 54 * k, strength: 1.0), (y: horizon + 70 * k, strength: 0.7)].enumerated() {
            let wavelength = Crossing.swellWavelengths[i]
            let count = Int(((width + 2 * wavelength) / (wavelength / 2)).rounded(.up)) + 1
            let start = -wavelength - pose.swell[i]
            var swell = Path()
            swell.move(to: CGPoint(x: start, y: line.y))
            Crossing.addArches(to: &swell, from: start, y: line.y, half: wavelength / 2, amplitude: 2.5 * k, count: count)
            context.stroke(swell, with: .color(Scenery.foam.opacity(increased ? 1 : swellOpacity * line.strength)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }

        // The wake: two short strokes from behind the stern, at the waterline; the hull covers their start.
        let s = Crossing.ferryScale * k
        let stern = width / 2 - 512 * s + 175 * s, water = horizon + 26 * k
        var near = Path(), far = Path()
        near.move(to: CGPoint(x: stern + 6 * k, y: water))
        near.addCurve(to: CGPoint(x: stern - 40 * k, y: water + 2 * k), control1: CGPoint(x: stern - 10 * k, y: water + 4 * k),
                      control2: CGPoint(x: stern - 26 * k, y: water + 4 * k))
        far.move(to: CGPoint(x: stern + 12 * k, y: water + 10 * k))
        far.addCurve(to: CGPoint(x: stern - 26 * k, y: water + 13 * k), control1: CGPoint(x: stern - 2 * k, y: water + 13 * k),
                     control2: CGPoint(x: stern - 14 * k, y: water + 14 * k))
        for (path, opacity) in zip([near, far], pose.wake) {
            context.stroke(path, with: .color(Scenery.foam.opacity(opacity)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    /// The icon's artboard at 0.3 (hull 210 pt wide), centred, its deck 6 pt below the horizon. It glides in from the
    /// left, then the bubbles board; afterwards it bobs and rolls around the keel.
    private func ferry(pose: Crossing.Pose, shown: Bool) -> some View {
        let s = Crossing.ferryScale * scale
        return ZStack(alignment: .topLeading) {
            FerryShape(.hull).fill(.white)
            bubble(.backBubble, passengers[1], mark: CGPoint(x: 686, y: 306), fontSize: 96,
                   base: UnitPoint(x: 692.8 / 1024, y: 436.8 / 1024), delay: 0.40, shown: shown, s: s)
            bubble(.frontBubble, passengers[0], mark: CGPoint(x: 368, y: 368), fontSize: 120,
                   base: UnitPoint(x: 359.5 / 1024, y: 535.0 / 1024), delay: 0.25, shown: shown, s: s)
        }
        .frame(width: 1024 * s, height: 1024 * s)
        .rotationEffect(.degrees(pose.roll), anchor: UnitPoint(x: 0.5, y: 700.0 / 1024))  // the keel's centre
        .offset(y: pose.bob)
        .offset(x: shown ? 0 : -28)
        .opacity(shown ? 1 : 0)
        .animation(.smooth(duration: 0.7), value: shown)
        .offset(y: (Crossing.horizon + 6) * scale - 572 * s)
    }

    /// A bubble in the account's colour with its mark, rising 12 pt from the deck as it scales up from 0.6.
    private func bubble(_ part: FerryShape.Part, _ rider: AccountIdentity, mark: CGPoint, fontSize: CGFloat, base: UnitPoint,
                        delay: Double, shown: Bool, s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            FerryShape(part).fill(rider.color.fill)
            Text(rider.mark)
                .font(.system(size: fontSize * s, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .position(x: mark.x * s, y: mark.y * s)
        }
        .scaleEffect(shown ? 1 : 0.6, anchor: base)
        .offset(y: shown ? 0 : 12 * scale)
        .opacity(shown ? 1 : 0)
        .animation(.spring(duration: 0.55, bounce: 0.3).delay(delay), value: shown)
    }
}

/// The pause rules of O1's motion (DESIGN O1, §9), shared with O4's deck: still under Reduce Motion or in Low Power
/// Mode; paused while the app isn't active or a pushed step covers the view; otherwise running.
struct AmbientMotion<Content: View>: View {
    @ViewBuilder let content: (Crossing.Motion) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var visible = false

    var body: some View {
        content(Crossing.motion(reduceMotion: reduceMotion, lowPower: lowPower, active: scenePhase == .active, visible: visible))
            .onAppear { visible = true }
            .onDisappear { visible = false }  // a pushed step covers it
            .task {
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                    lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                }
            }
    }
}

// MARK: - Logic

/// O1's scene as plain logic (DESIGN O1, REVIEW R2.3): who rides the ferry, whether it moves, and where the moving
/// parts are at a given moment. Lengths are points at scale 1 (393 × 224).
nonisolated enum Crossing {
    static let height: CGFloat = 224
    static let horizon: CGFloat = 132
    /// The sea band's wavy lower edge.
    static let edge: CGFloat = 214
    /// The icon's artboard → the scene (the hull is 700 units, so 210 pt).
    static let ferryScale: CGFloat = 0.3
    static let edgeWavelength: CGFloat = 131
    static let swellWavelengths: [CGFloat] = [120, 160]

    /// Before any account exists the bubbles carry these (the mockups' Ocean "A" and Ember "S"); then they can stand in
    /// for a second account, colours swapped if they must.
    static let samples = [
        AccountIdentity(name: "A", color: .ocean, mark: "A", order: 0),
        AccountIdentity(name: "S", color: .ember, mark: "S", order: 1),
        AccountIdentity(name: "A", color: .ember, mark: "A", order: 1),
        AccountIdentity(name: "S", color: .ocean, mark: "S", order: 1),
    ]

    /// Front and back bubble: your first two accounts in your order. With one, it rides in front and a sample that
    /// shares neither its colour nor its mark rides behind it (two accounts never look alike, DESIGN §3.6). With none,
    /// the samples.
    static func passengers(_ accounts: [AccountIdentity]) -> [AccountIdentity] {
        var riders = Array(accounts.sorted { $0.order < $1.order }.prefix(2))
        for sample in samples where riders.count < 2 {
            if !riders.contains(where: { $0.color == sample.color || $0.mark.uppercased() == sample.mark }) { riders.append(sample) }
        }
        return riders
    }

    enum Motion: Equatable, Sendable {
        /// Drawn once at rest: a level ferry, bubbles aboard, no entrance (Reduce Motion, Low Power Mode).
        case still
        /// Frozen where it is: the app isn't active, or a pushed step covers it.
        case paused
        case running
    }

    static func motion(reduceMotion: Bool, lowPower: Bool, active: Bool, visible: Bool) -> Motion {
        if reduceMotion || lowPower { return .still }
        return active && visible ? .running : .paused
    }

    /// Where the moving parts are; the default is at rest.
    struct Pose: Equatable, Sendable {
        /// Points, the ferry and its bubbles (±1.5 over 4.8 s; O4's deck too).
        var bob: CGFloat = 0
        /// Degrees around the keel (±0.8 over 6.4 s).
        var roll: Double = 0
        /// How far each swell line has drifted left (8 and 5 pt/s), wrapping every wavelength.
        var swell: [CGFloat] = [0, 0]
        /// The same for the band's lower edge (3 pt/s).
        var edge: CGFloat = 0
        /// The wake's two strokes, out of phase (0.35 ↔ 0.7 over 2.4 s).
        var wake: [Double] = [0.5, 0.5]
    }

    /// `t` seconds into the crossing; nil is at rest.
    static func pose(at t: TimeInterval?) -> Pose {
        guard let t else { return Pose() }
        let wake = 0.175 * sin(2 * .pi * t / 2.4)
        return Pose(bob: 1.5 * sin(2 * .pi * t / 4.8),
                    roll: 0.8 * sin(2 * .pi * t / 6.4 + 1.1),
                    swell: [drift(t, speed: 8, wavelength: swellWavelengths[0]), drift(t, speed: 5, wavelength: swellWavelengths[1])],
                    edge: drift(t, speed: 3, wavelength: edgeWavelength),
                    wake: [0.525 + wake, 0.525 - wake])
    }

    private static func drift(_ t: TimeInterval, speed: Double, wavelength: CGFloat) -> CGFloat {
        CGFloat((t * speed).truncatingRemainder(dividingBy: Double(wavelength)))
    }

    /// Half-sine arches along `y`, each `half` long (negative runs right to left), alternately up and down: the cubic
    /// approximation the icon's wave and the mockups use.
    static func addArches(to path: inout Path, from x: CGFloat, y: CGFloat, half: CGFloat, amplitude: CGFloat, count: Int) {
        for i in 0..<count {
            let start = x + CGFloat(i) * half, crest = y + (i.isMultiple(of: 2) ? -1 : 1) * 1.333 * amplitude
            path.addCurve(to: CGPoint(x: start + half, y: y), control1: CGPoint(x: start + 0.364 * half, y: crest),
                          control2: CGPoint(x: start + 0.636 * half, y: crest))
        }
    }
}
