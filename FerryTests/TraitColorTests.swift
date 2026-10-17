import SwiftUI
import XCTest
@testable import Ferry

/// Regression (device crash 2026-10-15, switching account scope): SwiftUI resolves colours on its async render thread,
/// and a trait closure that inherited MainActor isolation trapped there. Every trait colour must resolve off-main.
final class TraitColorTests: XCTestCase {
    @MainActor
    func testTraitColorsResolveOffTheMainThread() async {
        let colors: [Color] = [.inkSecondary, .inkSecondaryOnBubble, .statusOK, .statusWarn, .statusError,
                               .bubbleIncoming, .reactionBackground, .swipeArchive]
            + AccountColor.allCases.flatMap { [$0.ink, $0.wash] }
            + [Scenery.seaHorizon, Scenery.seaFloor, Scenery.seaHaze]
        let uiColors = colors.map { UIColor($0) }
        let resolved = await Task.detached {
            let dark = UITraitCollection(userInterfaceStyle: .dark)
            return uiColors.map { $0.resolvedColor(with: dark) }
        }.value
        XCTAssertEqual(resolved.count, colors.count)
        // The dark variant really applied (Ocean's ink is #7FAAF7 in dark mode).
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved[8].getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(Int((blue * 255).rounded()), 0xF7)
        // And the scenery's: seaHorizon is #0F4561 at night.
        resolved[resolved.count - 3].getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(Int((green * 255).rounded()), 0x45)
    }
}
