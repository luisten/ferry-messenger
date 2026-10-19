import SwiftUI

/// DESIGN §8.1 colour tokens: system semantic colours where they pass contrast, custom ones where they don't. Text
/// tokens pass WCAG AA (4.5:1) on the surfaces they're used on; ratios in the comments. Account colours are
/// `AccountColor` (AccountIdentity.swift, DESIGN §3.4).
extension ShapeStyle where Self == Color {
    /// `labelSecondary`: system secondary (#8A8A8E, 3.4:1) fails AA for small text. 5.22 on white, 4.67 on #F2F2F7,
    /// 8.18 on black, 6.63 on #1C1C1E; darker/lighter under Increase Contrast.
    static var inkSecondary: Color { dynamic(light: 0x6C6C72, dark: 0xA1A1A8, lightHigh: 0x48484A, darkHigh: 0xC7C7CC) }

    /// Secondary text on a `bubbleIncoming` card (notice cards, incoming voice duration, typing): `inkSecondary` is
    /// only 4.30 on #E9E9EB. 5.31 on #E9E9EB; dark 5.88 on #262629.
    static var inkSecondaryOnBubble: Color { dynamic(light: 0x5E5E64, dark: 0xA1A1A8, lightHigh: 0x48484A, darkHigh: 0xC7C7CC) }

    /// Status text and glyphs (DESIGN §8.1; always with a glyph, never colour alone). System green/orange/red are
    /// 2.2–3.4:1 on white; these are 5.2–5.4 on white, 4.66+ on #F2F2F7, 5+ on #1C1C1E.
    static var statusOK: Color { dynamic(light: 0x1F7A35, dark: 0x30D158) }
    static var statusWarn: Color { dynamic(light: 0xB25000, dark: 0xFF9F0A) }
    static var statusError: Color { dynamic(light: 0xD70015, dark: 0xFF453A) }

    /// `bubbleIncoming`: text contrast 17.3 / 15.1.
    static var bubbleIncoming: Color { dynamic(light: 0xE9E9EB, dark: 0x262629) }
    /// The mockups' `--rx-bg`: reaction pills.
    static var reactionBackground: Color { dynamic(light: 0xFFFFFF, dark: 0x2C2C2E) }
    /// The mockups' `--sw-a`: the Archive swipe action (neutral, DESIGN I1).
    static var swipeArchive: Color { dynamic(light: 0x1C1C1E, dark: 0x3A3A3C) }
}

/// Brand: scenery only (DESIGN §8.1 "Brand: the sea", principle 10). The sea of O1's picture; the icon and the launch
/// screen carry the same colours in their own files (the SVGs, `LaunchBackground`). Never a tint, a control, text or
/// chrome: colour in the UI means account. A namespace, not `Color` statics, so `.foregroundStyle(.foam)` can't happen.
enum Scenery {
    /// The sea band's top, at the horizon (the icon gradient's top in light mode).
    static var seaHorizon: Color { dynamic(light: 0x1A7893, dark: 0x0F4561) }
    /// The sea band's lower edge.
    static var seaFloor: Color { dynamic(light: 0x0D3F5B, dark: 0x05192A) }
    /// The 40 pt above the horizon, fading in from the sky (the screen's background).
    static var seaHaze: Color { dynamic(light: 0xE4F0F3, dark: 0x0B1C27) }
    /// Swell and wake, at 28–70% opacity.
    static var foam: Color { Color(UIColor(rgb: 0x9ED6E2)) }
}

/// A colour that follows light/dark mode and Increase Contrast.
private func dynamic(light: UInt32, dark: UInt32, lightHigh: UInt32? = nil, darkHigh: UInt32? = nil) -> Color {
    traitColor { traits in
        let high = traits.accessibilityContrast == .high
        let rgb = traits.userInterfaceStyle == .dark ? (high ? darkHigh ?? dark : dark) : (high ? lightHigh ?? light : light)
        return UIColor(rgb: rgb)
    }
}

/// Every trait-dependent colour goes through here. SwiftUI resolves colours on its async render thread, and a closure
/// written in this MainActor-default target inherits MainActor isolation, so Swift's runtime check trapped there
/// (device crash 2026-10-15, switching account scope). A `@Sendable` closure is nonisolated.
nonisolated func traitColor(_ provider: @escaping @Sendable (UITraitCollection) -> UIColor) -> Color {
    Color(UIColor(dynamicProvider: provider))
}

extension UIColor {
    nonisolated convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// For `.glassProminent` / `.borderedProminent`: they draw the label white whatever the tint, and with the app's
    /// monochrome tint (white in dark mode) or an account's ink (light in dark mode) that's white on white. The
    /// screen background's color is the opposite of either tint.
    func labelOnTint() -> some View { foregroundStyle(Color(.systemBackground)) }

    /// Glass for a control on a photo or video: a dim layer under its white glyph. Glass takes the brightness of
    /// what's behind it, so over a bright frame in light mode it was white under white (1.03:1, 2026-10-19).
    func mediaGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        background(.black.opacity(0.65), in: shape).glassEffect(.regular.interactive(interactive), in: shape)
    }
}
