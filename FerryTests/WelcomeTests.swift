import SwiftUI
import XCTest
@testable import Ferry

/// O1 "The crossing" (DESIGN O1, REVIEW-2026-10-15 R2.3): who rides the ferry, when it moves, and the icon's shapes
/// it's drawn with. `scripts/make_icon.swift` checks that `FerryShape`'s path data is the SVG's, verbatim.
final class WelcomeTests: XCTestCase {
    private func identity(_ color: AccountColor, _ mark: String, order: Int) -> AccountIdentity {
        AccountIdentity(name: "Account \(order)", color: color, mark: mark, order: order)
    }

    private func look(_ riders: [AccountIdentity]) -> [String] { riders.map { "\($0.color.rawValue) \($0.mark)" } }

    func testNoAccountYetCarriesTheSamples() {
        XCTAssertEqual(look(Crossing.passengers([])), ["ocean A", "ember S"])
    }

    func testOneAccountRidesInFrontWithASampleThatDoesNotLookLikeIt() {
        // The usual first account: Ocean (first free colour) and its name's first letter.
        XCTAssertEqual(look(Crossing.passengers([identity(.ocean, "T", order: 0)])), ["ocean T", "ember S"])
        XCTAssertEqual(look(Crossing.passengers([identity(.grape, "🌊", order: 0)])), ["grape 🌊", "ocean A"])
        // Sharing a colour with one sample and the mark of the other: the samples swap colours.
        XCTAssertEqual(look(Crossing.passengers([identity(.ocean, "S", order: 0)])), ["ocean S", "ember A"])
        XCTAssertEqual(look(Crossing.passengers([identity(.ember, "A", order: 0)])), ["ember A", "ocean S"])
        XCTAssertEqual(look(Crossing.passengers([identity(.ember, "a", order: 0)])), ["ember a", "ocean S"])
    }

    func testTwoOrMoreAccountsCarryTheFirstTwoInYourOrder() {
        let studio = identity(.teal, "S", order: 1), personal = identity(.berry, "P", order: 0), band = identity(.moss, "B", order: 2)
        XCTAssertEqual(look(Crossing.passengers([studio, personal])), ["berry P", "teal S"])
        XCTAssertEqual(look(Crossing.passengers([band, studio, personal])), ["berry P", "teal S"])
    }

    func testReduceMotionOrLowPowerHoldTheSceneStill() {
        for active in [true, false] {
            for visible in [true, false] {
                XCTAssertEqual(Crossing.motion(reduceMotion: true, lowPower: false, active: active, visible: visible), .still)
                XCTAssertEqual(Crossing.motion(reduceMotion: false, lowPower: true, active: active, visible: visible), .still)
                XCTAssertEqual(Crossing.motion(reduceMotion: true, lowPower: true, active: active, visible: visible), .still)
            }
        }
    }

    func testItRunsOnlyWhileActiveAndUncovered() {
        XCTAssertEqual(Crossing.motion(reduceMotion: false, lowPower: false, active: true, visible: true), .running)
        XCTAssertEqual(Crossing.motion(reduceMotion: false, lowPower: false, active: false, visible: true), .paused)
        XCTAssertEqual(Crossing.motion(reduceMotion: false, lowPower: false, active: true, visible: false), .paused)
    }

    func testAtRestTheFerryIsLevel() {
        let rest = Crossing.pose(at: nil)
        XCTAssertEqual(rest.bob, 0)
        XCTAssertEqual(rest.roll, 0)
        XCTAssertEqual(rest.swell, [0, 0])
        XCTAssertEqual(rest.edge, 0)
        XCTAssertEqual(rest.wake, [0.5, 0.5])
    }

    func testTheMotionStaysGentle() {
        var bob: ClosedRange<CGFloat> = 0...0, roll: ClosedRange<Double> = 0...0
        for step in 0...2000 {
            let pose = Crossing.pose(at: Double(step) * 0.01)
            bob = min(bob.lowerBound, pose.bob)...max(bob.upperBound, pose.bob)
            roll = min(roll.lowerBound, pose.roll)...max(roll.upperBound, pose.roll)
            for (drift, wavelength) in zip(pose.swell + [pose.edge], Crossing.swellWavelengths + [Crossing.edgeWavelength]) {
                XCTAssert((0..<wavelength).contains(drift), "drift \(drift) wraps every \(wavelength)")
            }
            for wake in pose.wake { XCTAssert((0.35...0.7).contains(wake), "wake \(wake)") }
        }
        XCTAssertEqual(bob.lowerBound, -1.5, accuracy: 0.01)
        XCTAssertEqual(bob.upperBound, 1.5, accuracy: 0.01)
        XCTAssertEqual(roll.lowerBound, -0.8, accuracy: 0.01)
        XCTAssertEqual(roll.upperBound, 0.8, accuracy: 0.01)
        XCTAssertEqual(Crossing.pose(at: 1).swell[0], 8, accuracy: 0.001)  // 8 pt/s to the left
        XCTAssertEqual(Crossing.pose(at: 16).swell[0], 8, accuracy: 0.001)  // and round again after 120 pt
    }

    /// The parsed paths sit where the SVG draws them, and the crops the deck and O2's glyph use fit them.
    func testFerryShapesParseToTheIconsGeometry() {
        func box(_ part: FerryShape.Part) -> CGRect { FerryPath.path(part.d).boundingRect }
        func assertBox(_ part: FerryShape.Part, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
            let actual = box(part)
            for (a, e) in [(actual.minX, expected.minX), (actual.minY, expected.minY), (actual.maxX, expected.maxX), (actual.maxY, expected.maxY)] {
                XCTAssertEqual(a, e, accuracy: 0.5, "\(part): \(actual)", file: file, line: line)
            }
        }
        assertBox(.hull, FerryShape.hullBox)
        assertBox(.wave, FerryShape.waveBox)
        assertBox(.backBubble, CGRect(x: 570, y: 216, width: 245.6, height: 220.8))  // tail tip at 815.6, 436.8
        assertBox(.frontBubble, CGRect(x: 189, y: 252, width: 341, height: 283))  // tail tip at 189, 535
        let glyph = FerryShape.Part.allCases.map(box).reduce(CGRect.null) { $0.union($1) }
        XCTAssertTrue(FerryShape.glyphBox.contains(glyph))
        XCTAssertEqual(FerryShape.glyphBox.maxY, FerryShape.waveBox.maxY + 18, "the glyph's box ends at the wave stroke's edge")
    }

    func testAShapeFillsItsRectAsTheArtboardWould() {
        let height: CGFloat = 150 * 128 / 700
        let hull = FerryShape(.hull, box: FerryShape.hullBox).path(in: CGRect(x: 10, y: 20, width: 150, height: height)).boundingRect
        XCTAssertEqual(hull.minX, 10, accuracy: 0.01)
        XCTAssertEqual(hull.minY, 20, accuracy: 0.01)
        XCTAssertEqual(hull.width, 150, accuracy: 0.01)
        XCTAssertEqual(hull.height, height, accuracy: 0.01)
        // The scene's scale: the whole artboard at 0.3 makes the hull 210 pt wide.
        let scene = FerryShape(.hull).path(in: CGRect(x: 0, y: 0, width: 307.2, height: 307.2)).boundingRect
        XCTAssertEqual(scene.width, 210, accuracy: 0.01)
    }
}
