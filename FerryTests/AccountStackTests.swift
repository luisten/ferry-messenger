import XCTest
@testable import Ferry

/// The inbox toolbar's account stack (design review 2026-10-15 §3, DESIGN §3.5, principle 9): your accounts side by
/// side, never over each other; up to three avatars, from four on the first two and "+N"; a problem is a badge on the
/// account it's about, or on "+N" when that account is behind it.
final class AccountStackTests: XCTestCase {
    private func account(_ name: String, _ health: BridgeAPI.Login.Health = .connected) -> Inbox.AccountStack.Account {
        Inbox.AccountStack.Account(id: name.lowercased(), name: name, health: health)
    }

    // MARK: Shown and hidden

    func testUpToThreeAccountsAllShow() {
        for count in 1...3 {
            let names = ["Alex", "Alex Studio", "Band"].prefix(count)
            let stack = Inbox.AccountStack(names.map { account($0) })
            XCTAssertEqual(stack.shown.map(\.name), Array(names))
            XCTAssertTrue(stack.hidden.isEmpty)
        }
    }

    /// Two and a count, never three and a count: the capsule stays 112 pt at most.
    func testFromFourAccountsTheFirstTwoAndACount() {
        let names = ["Alex", "Alex Studio", "Band", "Market", "Shop", "Club"]
        for count in 4...6 {
            let stack = Inbox.AccountStack(names.prefix(count).map { account($0) })
            XCTAssertEqual(stack.shown.map(\.name), ["Alex", "Alex Studio"])  // Accounts order
            XCTAssertEqual(stack.hidden.count, count - 2)
        }
    }

    func testNoAccountsShowNothing() {
        let stack = Inbox.AccountStack([])
        XCTAssertTrue(stack.shown.isEmpty)
        XCTAssertTrue(stack.hidden.isEmpty)
        XCTAssertNil(stack.hiddenStatus)
        XCTAssertEqual(stack.accessibilityLabel, "Accounts")
    }

    // MARK: Status

    /// Whoami health → badge: signed out and errors need you; connecting, syncing and reconnecting spin.
    func testStatusFromHealth() {
        XCTAssertNil(account("A", .connected).status)
        XCTAssertEqual(account("A", .needsLogin).status, .needsYou)
        XCTAssertEqual(account("A", .error("boom")).status, .needsYou)
        XCTAssertEqual(account("A", .error(nil)).status, .needsYou)
        XCTAssertEqual(account("A", .connecting).status, .connecting)
        XCTAssertEqual(account("A", .syncing).status, .connecting)
        XCTAssertEqual(account("A", .reconnecting).status, .connecting)
    }

    /// The badge goes on the avatar of the account it's about, not after the stack.
    func testAShownAccountCarriesItsOwnBadge() {
        let stack = Inbox.AccountStack([account("Alex", .connecting), account("Alex Studio", .needsLogin)])
        XCTAssertEqual(stack.shown.map(\.status), [.connecting, .needsYou])
        XCTAssertNil(stack.hiddenStatus)
    }

    /// A hidden account's problem goes on "+N"; needs-you wins over connecting there.
    func testAHiddenAccountsStatusGoesOnTheCountAndNeedsYouWins() {
        let accounts = [account("Alex"), account("Alex Studio"), account("Band", .connecting), account("Market")]
        XCTAssertEqual(Inbox.AccountStack(accounts).hiddenStatus, .connecting)
        let worse = accounts + [account("Shop", .needsLogin)]
        XCTAssertEqual(Inbox.AccountStack(worse).hiddenStatus, .needsYou)
        XCTAssertEqual(Inbox.AccountStack(worse).shown.map(\.status), [nil, nil], "shown accounts keep only their own")
        XCTAssertNil(Inbox.AccountStack(accounts.map { account($0.name) }).hiddenStatus)
    }

    // MARK: VoiceOver (one element, the button trait)

    func testAccessibilityLabelNamesTheShownAccountsAndCountsTheRest() {
        XCTAssertEqual(Inbox.AccountStack([account("Alex")]).accessibilityLabel, "Accounts: Alex.")
        XCTAssertEqual(Inbox.AccountStack([account("Alex"), account("Alex Studio")]).accessibilityLabel, "Accounts: Alex and Alex Studio.")
        XCTAssertEqual(Inbox.AccountStack([account("Alex"), account("Alex Studio"), account("Band")]).accessibilityLabel,
                       "Accounts: Alex, Alex Studio, and Band.")
        XCTAssertEqual(Inbox.AccountStack(["Alex", "Alex Studio", "Band", "Market"].map { account($0) }).accessibilityLabel,
                       "Accounts: Alex, Alex Studio, and 2 more.")
    }

    /// The review's example, then who's connecting; hidden accounts are named too (the count can't say whose).
    func testAccessibilityLabelSaysWhoNeedsAttention() {
        let accounts = [account("Alex"), account("Alex Studio", .needsLogin), account("Band"), account("Market")]
        XCTAssertEqual(Inbox.AccountStack(accounts).accessibilityLabel,
                       "Accounts: Alex, Alex Studio, and 2 more. Alex Studio needs attention.")
        let more = [account("Alex", .connecting), account("Alex Studio", .needsLogin), account("Band"), account("Market", .error(nil))]
        XCTAssertEqual(Inbox.AccountStack(more).accessibilityLabel,
                       "Accounts: Alex, Alex Studio, and 2 more. Alex Studio and Market need attention. Alex is connecting.")
        XCTAssertEqual(Inbox.AccountStack([account("Alex", .syncing), account("Band", .reconnecting)]).accessibilityLabel,
                       "Accounts: Alex and Band. Alex and Band are connecting.")
    }

    // MARK: Title fit (review §3)

    /// With three or more accounts the stack is 112 pt and a professional account's "@handle · Primary" no longer fits
    /// beside it: the handle goes (it's in Chat Info and Accounts).
    func testScopeSubtitleDropsTheHandleWhenTheStackIsWidest() {
        XCTAssertEqual(Inbox.scopeSubtitle(handle: "alexstudio", isProfessional: true, accounts: 2), "@alexstudio · Primary")
        XCTAssertEqual(Inbox.scopeSubtitle(handle: "alexstudio", isProfessional: true, accounts: 3), "Primary")
        XCTAssertEqual(Inbox.scopeSubtitle(handle: "alexstudio", isProfessional: true, accounts: 5), "Primary")
        XCTAssertEqual(Inbox.scopeSubtitle(handle: "alex.personal", isProfessional: false, accounts: 4), "@alex.personal")
        XCTAssertEqual(Inbox.scopeSubtitle(handle: nil, isProfessional: true, accounts: 2), "")
    }
}
