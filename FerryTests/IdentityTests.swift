import XCTest
@testable import Ferry

/// The O5/A2 editor's rules (DESIGN §3.1, §3.6 rule 1): no two accounts share a name, color or mark.
final class IdentityTests: XCTestCase {
    private let ids: [String: AccountIdentity] = [
        "studio": AccountIdentity(name: "Studio", color: .ocean, mark: "S", order: 0),
        "personal": AccountIdentity(name: "Personal", color: .ember, mark: "P", order: 1),
    ]

    func testUnchangedIdentityHasNoProblems() {
        XCTAssertEqual(AccountIdentity.problems(ids["studio"]!, for: "studio", among: ids), [])
    }

    /// Its own name, color and mark never count as taken; another account's do, ignoring case and stray spaces.
    func testAnotherAccountsNameMarkAndColorAreTaken() {
        var draft = ids["studio"]!
        draft.name = " personal "
        draft.mark = "p"
        draft.color = .ember
        XCTAssertEqual(AccountIdentity.problems(draft, for: "studio", among: ids),
                       [.nameTaken(by: "Personal"), .markTaken(by: "Personal"), .colorTaken(by: "Personal")])
        // The same values for Personal itself are fine.
        XCTAssertEqual(AccountIdentity.problems(draft, for: "personal", among: ids), [])
    }

    func testEmptyNameAndMarkCantBeSaved() {
        let draft = AccountIdentity(name: "   ", color: .grape, mark: "", order: 2)
        XCTAssertEqual(AccountIdentity.problems(draft, for: "new", among: ids), [.nameEmpty, .markEmpty])
        XCTAssertEqual(AccountIdentity.problems(draft, for: "new", among: ids).filter(\.isAboutName), [.nameEmpty])
        XCTAssertEqual(AccountIdentity.problems(draft, for: "new", among: ids).filter(\.isAboutMark), [.markEmpty])
    }

    /// A taken swatch shows its owner's mark; your own color has no "owner".
    func testColorOwner() {
        XCTAssertEqual(AccountIdentity.owner(of: .ember, excluding: "studio", in: ids)?.mark, "P")
        XCTAssertNil(AccountIdentity.owner(of: .ocean, excluding: "studio", in: ids))
        XCTAssertNil(AccountIdentity.owner(of: .grape, excluding: "studio", in: ids))
    }

    func testMarkIsOneGrapheme() {
        XCTAssertEqual(AccountIdentity.normalizedMark("s"), "S")
        XCTAssertEqual(AccountIdentity.normalizedMark("ab"), "B")  // typing a second character replaces the first
        XCTAssertEqual(AccountIdentity.normalizedMark(" x "), "X")
        XCTAssertEqual(AccountIdentity.normalizedMark("🌊"), "🌊")
        XCTAssertEqual(AccountIdentity.normalizedMark("👩🏽‍💻"), "👩🏽‍💻")  // one grapheme, several scalars
        XCTAssertEqual(AccountIdentity.normalizedMark("ß"), "ß")  // uppercases to "SS": keep the letter
        XCTAssertEqual(AccountIdentity.normalizedMark(""), "")
    }

    /// No camera among the emoji: next to "Instagram" it was the one Instagram-like glyph (review 2026-10-15 #12).
    func testMarkSuggestionsSkipTakenMarks() {
        XCTAssertEqual(AccountIdentity.markSuggestions(name: "Studio", taken: []), ["S", "T", "U", "✦", "⛵️", "🌊"])
        XCTAssertEqual(AccountIdentity.markSuggestions(name: "Studio", taken: ["S", "⛵️"]), ["T", "U", "D", "✦", "🌊"])
        XCTAssertEqual(AccountIdentity.markSuggestions(name: "", taken: []), ["✦", "⛵️", "🌊"])
        XCTAssertEqual(AccountIdentity.normalizedMark("⛵️"), "⛵️")  // one grapheme (with its variation selector)
    }

    func testNameSuggestionsStartWithTheInstagramNameAndSkipTakenOnes() {
        XCTAssertEqual(AccountIdentity.nameSuggestions(instagramName: "Kivo Studio", taken: ["personal"]),
                       ["Kivo Studio", "Work", "Studio", "Shop"])
        XCTAssertEqual(AccountIdentity.nameSuggestions(instagramName: nil, taken: []), ["Personal", "Work", "Studio", "Shop"])
    }

    /// A1 drag to reorder: the listed accounts take their new positions; anything else keeps its order.
    func testReorderSetsScopeBarOrder() {
        var all = ids
        all["band"] = AccountIdentity(name: "Band", color: .grape, mark: "B", order: 7)
        let moved = AccountIdentity.reordered(all, ids: ["personal", "studio"])
        XCTAssertEqual(moved["personal"]?.order, 0)
        XCTAssertEqual(moved["studio"]?.order, 1)
        XCTAssertEqual(moved["band"]?.order, 7)
        XCTAssertEqual(moved["studio"]?.name, "Studio")
    }
}
