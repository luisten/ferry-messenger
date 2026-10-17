import SwiftUI

/// One of the app icon's four shapes (DESIGN §18.1, `docs/design/ferry-icon-color.svg`) for O1's scene and the
/// onboarding echoes: O2's glyph, O4's and O6's deck. The path data is the SVG's, verbatim (`scripts/make_icon.swift`
/// checks it), in the icon's 1024-unit artboard. `box` is the part of the artboard the shape's rect shows, so a shape
/// can be cut to just the hull or the wave.
struct FerryShape: Shape {
    let part: Part
    let box: CGRect

    nonisolated init(_ part: Part, box: CGRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)) {
        self.part = part
        self.box = box
    }

    nonisolated func path(in rect: CGRect) -> Path {
        let sx = rect.width / box.width, sy = rect.height / box.height
        return FerryPath.path(part.d)
            .applying(CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: rect.minX - box.minX * sx, ty: rect.minY - box.minY * sy))
    }

    nonisolated enum Part: CaseIterable, Sendable {
        /// In the SVG's drawing order.
        case backBubble, frontBubble, hull, wave

        /// Absolute M, H, V, C and Z only. The wave is a stroke's centre line (36 units wide in the icon).
        var d: String {
            switch self {
            case .backBubble: "M650 216 H722 C766.2 216 802 251.8 802 296 V316 C802 368 795.2 402.1 815.6 436.8 C785.7 418.4 727.2 396 666 396 H650 C605.8 396 570 360.2 570 316 V296 C570 251.8 605.8 216 650 216Z"
            case .frontBubble: "M306 252 H430 C485.2 252 530 296.8 530 352 V384 C530 439.2 485.2 484 430 484 H376 C299.5 484 226.4 512 189 535 C214.5 491.6 206 449 206 384 V352 C206 296.8 250.8 252 306 252Z"
            case .hull: "M162 572 H862 C836 614 808 654 784 684 C776 694 766 700 752 700 H250 C208 700 178 648 162 572Z"
            case .wave: "M242 794 C291.5 772.7 328.5 772.7 378 794 C427.5 815.3 464.5 815.3 514 794 C563.5 772.7 600.5 772.7 650 794 C699.5 815.3 736.5 815.3 786 794"
            }
        }
    }

    /// The hull alone: deck to keel, stern to bow.
    nonisolated static let hullBox = CGRect(x: 162, y: 572, width: 700, height: 128)
    /// The wave's centre line (its crests and troughs at ±16 around y 794).
    nonisolated static let waveBox = CGRect(x: 242, y: 778, width: 544, height: 32)
    /// The whole glyph without the tile: the hull's width, the back bubble's top to the bottom of the wave's stroke.
    nonisolated static let glyphBox = CGRect(x: 162, y: 216, width: 700, height: 612)
}

/// The icon's path data → `Path` (the same subset `scripts/make_icon.swift` draws).
nonisolated enum FerryPath {
    static func path(_ d: String) -> Path {
        var tokens: [Substring] = []
        var start: String.Index?
        for i in d.indices {
            let ch = d[i]
            if ch.isLetter || ch == " " || ch == "," {
                if let s = start { tokens.append(d[s..<i]); start = nil }
                if ch.isLetter { tokens.append(d[i...i]) }
            } else if start == nil {
                start = i
            }
        }
        if let s = start { tokens.append(d[s...]) }

        var path = Path()
        var i = 0
        var point = CGPoint.zero
        func next() -> CGFloat {
            defer { i += 1 }
            return i < tokens.count ? CGFloat(Double(tokens[i]) ?? 0) : 0
        }
        while i < tokens.count {
            let command = tokens[i]
            i += 1
            switch command {
            case "M": point = CGPoint(x: next(), y: next()); path.move(to: point)
            case "H": point.x = next(); path.addLine(to: point)
            case "V": point.y = next(); path.addLine(to: point)
            case "C":
                let c1 = CGPoint(x: next(), y: next()), c2 = CGPoint(x: next(), y: next())
                point = CGPoint(x: next(), y: next())
                path.addCurve(to: point, control1: c1, control2: c2)
            case "Z": path.closeSubpath()
            default: assertionFailure("unsupported path command \(command)")
            }
        }
        return path
    }
}

/// The icon's glyph without its tile, monochrome (DESIGN O2, round 2's echo of O1): ferry and front bubble in ink, back
/// bubble and wave in `inkSecondary`, as the icon pairs white with foam. No sea: that stays on Welcome.
struct FerryGlyph: View {
    var height: CGFloat = 44

    var body: some View {
        let box = FerryShape.glyphBox
        let scale = height / box.height
        ZStack {
            FerryShape(.backBubble, box: box).fill(.inkSecondary)
            FerryShape(.frontBubble, box: box).fill(Color.primary)
            FerryShape(.hull, box: box).fill(Color.primary)
            FerryShape(.wave, box: box)
                .stroke(.inkSecondary, style: StrokeStyle(lineWidth: 36 * scale, lineCap: .round, lineJoin: .round))
        }
        .frame(width: box.width * scale, height: height)
        .accessibilityHidden(true)
    }
}

/// The deck that carries the account through onboarding (DESIGN O4, O6): the icon's hull in `systemFill`, 4 pt under
/// what's aboard, over a 2 pt wave in `tertiaryLabel`. `bob` moves what's aboard and the hull; the wave stays.
struct FerryDeck<Aboard: View>: View {
    let width: CGFloat
    var bob: CGFloat = 0
    @ViewBuilder let aboard: Aboard

    var body: some View {
        let hull = FerryShape.hullBox, wave = FerryShape.waveBox
        VStack(spacing: 6) {
            VStack(spacing: 4) {
                aboard
                FerryShape(.hull, box: hull).fill(Color(.systemFill))
                    .frame(width: width, height: width * hull.height / hull.width)
            }
            .offset(y: bob)
            FerryShape(.wave, box: wave)
                .stroke(Color(.tertiaryLabel), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: width * 0.78, height: width * 0.78 * wave.height / wave.width)
        }
        .accessibilityHidden(true)
    }
}
