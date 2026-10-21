import XCTest

/// Smoke flows (PLAN §4, M7b; PLAN-core C8). Most run on `FERRY_DEBUG_DEMO`'s made-up accounts and chats, which never
/// connect, so nothing reaches Instagram. The live ones use the accounts logged in to the simulator's app and are
/// opt-in (`TEST_RUNNER_FERRY_UITEST_LIVE=1`): each launch loads every account's inbox. Nothing is typed anywhere:
/// never into instagram.com, never a message, never a search.
final class SmokeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Inbox rows → an account chip filters them → a chat with nothing unread → bubble, composer with its photo/video
    /// button and the mic (the field is empty) → Chat Info → back.
    @MainActor
    func testInboxScopeThreadAndChatInfo() throws {
        let app = launch()
        let rows = app.descendants(matching: .any).matching(identifier: "inbox.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["inbox.folders"].exists)

        // Each row's VoiceOver label names its account ("…, via Tamo account, …") when there are several.
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'scope.' AND identifier != 'scope.all'"))
        if chips.count > 0 {
            let chip = chips.element(boundBy: 0)
            let name = try XCTUnwrap(chip.label.components(separatedBy: ",").first)
            chip.tap()
            XCTAssertTrue(chip.waitForSelected())
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
            for row in rows.allElementsBoundByIndex {
                XCTAssertTrue(row.label.contains("via \(name) account"), "\(row.label) isn't in \(name)")
            }
            app.buttons["scope.all"].tap()
        }

        let read = rows.matching(NSPredicate(format: "NOT (label CONTAINS ' unread')")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        read.tap()
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN {'thread.bubble', 'thread.media'}"))
        XCTAssertTrue(message.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].exists)
        XCTAssertTrue(app.buttons["composer.photo"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["composer.mic"].exists)

        app.descendants(matching: .any)["thread.header"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Chat Info"].waitForExistence(timeout: 5))
        app.navigationBars["Chat Info"].buttons.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
    }

    /// #17/#34: right after a cold launch (and again on reopening), the first two chats with nothing unread open with
    /// their newest message fully above the composer; on the dummies those are the two accounts' DMs with each other,
    /// full of tall reel and post cards, so it's a live test. Nothing here scrolls the thread up: a query after that can hang the app
    /// (CLAUDE.md, FOLLOWUPS #39).
    @MainActor
    func testThreadOpensAtTheBottomAfterColdLaunch() throws {
        continueAfterFailure = true  // check both chats
        for index in 0..<2 {
            let app = try launchLive()
            let rows = app.descendants(matching: .any).matching(identifier: "inbox.row")
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
            let read = rows.matching(NSPredicate(format: "NOT (label CONTAINS ' unread')"))
            guard read.count > index else { throw XCTSkip("Fewer than \(index + 1) chats with nothing unread.") }
            let row = read.element(boundBy: index)
            let name = row.label
            for open in ["cold", "reopened"] {  // the first push after launch, then the same chat again
                row.tap()
                let field = app.descendants(matching: .any)["composer.field"]
                XCTAssertTrue(field.waitForExistence(timeout: 10))
                Thread.sleep(forTimeInterval: 1.5)  // what the user sees once the push has settled
                attachScreenshot(app, "thread-\(index)-\(open)")
                XCTAssertLessThanOrEqual(threadBottom(app), field.frame.minY, "\(name) (\(open)): the newest message is under the composer")
                app.navigationBars.buttons.firstMatch.tap()
                XCTAssertTrue(row.waitForExistence(timeout: 5))
            }
        }
    }

    /// The mic (DESIGN §6.9), with every send and upload blocked in the app (`FERRY_DEBUG_BLOCK_SENDS`) and a voice file
    /// that doesn't exist standing in for the microphone (`FERRY_DEBUG_VOICE_FILE`), so even a misfire sends nothing: a
    /// tap only says "Hold to record" (the field's placeholder for 2 s); holding records, and sliding left cancels.
    @MainActor
    func testMicTapHintsAndSlideCancels() throws {
        let app = launch(["FERRY_DEBUG_BLOCK_SENDS": "1", "FERRY_DEBUG_VOICE_FILE": "/nonexistent/voice.m4a"])
        try openReadChat(app)
        let mic = app.descendants(matching: .any)["composer.mic"]
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        let placeholder = field.placeholderValue
        mic.tap()
        XCTAssertTrue(field.waitForPlaceholder("Hold to record", timeout: 2))
        attachScreenshot(app, "mic-hint")
        XCTAssertTrue(field.waitForPlaceholder(try XCTUnwrap(placeholder), timeout: 4), "the hint goes after 2 s")

        let start = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1.2, thenDragTo: start.withOffset(CGVector(dx: -220, dy: 0)))
        XCTAssertTrue(app.descendants(matching: .any)["composer.recordingCancelled"].waitForExistence(timeout: 2))
        attachScreenshot(app, "mic-cancelled")
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["thread.retry"].exists, "nothing was sent")
    }

    /// Sends one video (the newest in the simulator's Photos) and one held voice note in the chat whose row label
    /// starts with `TEST_RUNNER_FERRY_UITEST_SEND_CHAT` (e.g. "<other dummy's name>,"): two Instagram messages, so it only
    /// runs with `TEST_RUNNER_FERRY_UITEST_SEND=1` and that chat set. `TEST_RUNNER_FERRY_UITEST_BLOCK_SENDS=1` rehearses it
    /// with every upload blocked in the app (both end "Not sent"); `TEST_RUNNER_FERRY_UITEST_VOICE_FILE=<m4a>` replaces the
    /// microphone (`FERRY_DEBUG_VOICE_FILE`).
    @MainActor
    func testSendVideoAndVoiceNote() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FERRY_UITEST_SEND"] == "1", let chat = env["FERRY_UITEST_SEND_CHAT"], !chat.isEmpty else {
            throw XCTSkip("Sends a video and a voice note to Instagram; set TEST_RUNNER_FERRY_UITEST_SEND=1 and TEST_RUNNER_FERRY_UITEST_SEND_CHAT to run it.")
        }
        let rehearsal = env["FERRY_UITEST_BLOCK_SENDS"] == "1"
        var extra: [String: String] = rehearsal ? ["FERRY_DEBUG_BLOCK_SENDS": "1"] : [:]
        if let file = env["FERRY_UITEST_VOICE_FILE"], !file.isEmpty { extra["FERRY_DEBUG_VOICE_FILE"] = file }
        let app = try launchLive(extra)
        try openReadChat(app, named: chat)
        let videos = NSPredicate(format: "label BEGINSWITH 'Video.' OR label BEGINSWITH 'Video,'")
        let voices = NSPredicate(format: "label BEGINSWITH 'Your voice message'")
        let failures = NSPredicate(format: "identifier == 'thread.retry'")

        var (before, failed) = (count(app, videos), count(app, failures))
        app.buttons["composer.photo"].tap()
        // The picker runs in another process: its cells ("Video, six seconds, 14 October, 22:50") are found but not
        // hittable, so the newest video (first in the grid) is tapped by coordinate.
        let picked = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Video,'")).firstMatch
        XCTAssertTrue(picked.waitForExistence(timeout: 10), "no video in the picker")
        attachScreenshot(app, "picker")
        picked.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Video · '")).firstMatch.waitForExistence(timeout: 90),
                      "the video never got ready")  // the attachment bar's "Video · 0:06"; "Preparing video…" until then
        attachScreenshot(app, "video-ready")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(poll(90) { self.count(app, videos) > before }, "no video echo")
        XCTAssertTrue(rehearsal ? poll(90, until: { self.count(app, failures) > failed }) : waitForSent(app), "the video didn't end Sent/Not sent")
        attachScreenshot(app, "video-sent")

        (before, failed) = (count(app, voices), count(app, failures))
        let mic = app.descendants(matching: .any)["composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        mic.press(forDuration: 3.5)
        XCTAssertTrue(poll(30) { self.count(app, voices) > before }, "no voice echo")
        XCTAssertTrue(rehearsal ? poll(30, until: { self.count(app, failures) > failed }) : waitForSent(app), "the voice note didn't end Sent/Not sent")
        attachScreenshot(app, "voice-sent")
    }

    @MainActor
    private func count(_ app: XCUIApplication, _ predicate: NSPredicate) -> Int {
        app.descendants(matching: .any).matching(predicate).count
    }

    /// Polls `condition` every half second for up to `timeout` seconds.
    @MainActor
    private func poll(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let end = Date.now.addingTimeInterval(timeout)
        while Date.now < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    /// Our last message's status line (only the newest own message has one) says Sent: Instagram has it (it sends no
    /// "delivered", P0).
    @MainActor
    private func waitForSent(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'thread.status' AND label IN {'Sent', 'Seen'}"))
            .firstMatch.waitForExistence(timeout: 90)
    }

    /// Opens the first chat with nothing unread (opening an unread one sends "Seen" to Instagram), optionally the one
    /// whose row label starts with `prefix`.
    @MainActor
    private func openReadChat(_ app: XCUIApplication, named prefix: String? = nil) throws {
        let rows = app.descendants(matching: .any).matching(identifier: "inbox.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        let read = rows.matching(NSPredicate(format: "NOT (label CONTAINS ' unread')"))
        let row = (prefix.map { read.matching(NSPredicate(format: "label BEGINSWITH %@", $0)) } ?? read).firstMatch
        guard row.waitForExistence(timeout: 5) else { throw XCTSkip("No chat with nothing unread\(prefix.map { " starting \"\($0)\"" } ?? "").") }
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 10))
    }

    /// The lowest edge of anything in the thread (bubbles, cards, reactions, status line, typing).
    @MainActor
    private func threadBottom(_ app: XCUIApplication) -> CGFloat {
        let parts = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'thread.' AND NOT (identifier IN {'thread.header', 'thread.more'}) OR identifier BEGINSWITH 'media.'"))
        return parts.allElementsBoundByIndex.map(\.frame.maxY).max() ?? 0
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Requests from the Folders menu. A request (DEBUG fixture room; the app refuses anything sent to it) shows the
    /// request bar instead of the composer, and no photo button. Opening it sends nothing. Back in the inbox, the
    /// Requests card is gone: those requests have been looked at.
    @MainActor
    func testRequestThreadHasRequestBarAndNoComposer() throws {
        let app = launch()
        let folders = app.buttons["inbox.folders"]
        XCTAssertTrue(folders.waitForExistence(timeout: 15))
        folders.tap()
        let requests = app.buttons["folder.requests"]
        XCTAssertTrue(requests.waitForExistence(timeout: 5))
        requests.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'inbox.row' AND label CONTAINS 'Kestrel Bikes'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["thread.requestBar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["request.accept"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["composer.field"].exists)
        XCTAssertFalse(app.buttons["composer.photo"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["composer.mic"].exists)

        app.navigationBars.buttons.firstMatch.tap()  // back to Requests
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()  // back to the inbox
        XCTAssertTrue(folders.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["inbox.requestsCard"].exists)
    }

    /// Groups (FOLLOWUPS #24) on the hand-made DEBUG group (no request about it leaves the app):
    /// every incoming bubble tells VoiceOver who sent it, ours don't, someone who left is named from their profile,
    /// and the header opens Chat Info with the members, "You" last.
    @MainActor
    func testGroupThreadNamesSendersAndChatInfoListsMembers() throws {
        let app = launch()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'inbox.row' AND label BEGINSWITH 'Saturday Climbs'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.label.contains("Theo: 9:30 then"), row.label)
        row.tap()
        let bubbles = app.descendants(matching: .any).matching(identifier: "thread.bubble")
        XCTAssertTrue(bubbles.firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)  // the thread appears once it rests at its end
        let labels = bubbles.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains("From Theo Park, Thinking the north wall at 9"), "\(labels)")
        XCTAssertTrue(labels.contains("From Priya Nair, Can't this week, have fun"), "\(labels)")
        XCTAssertTrue(labels.contains("You: Count me in"), "\(labels)")
        let lines = app.descendants(matching: .any).matching(identifier: "thread.event").allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(lines, ["Priya left the group", "Sam sent a poll. Open Instagram to see it."])
        attachScreenshot(app, "group-thread")

        app.descendants(matching: .any)["thread.header"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Chat Info"].waitForExistence(timeout: 5))
        let members = app.descendants(matching: .any).matching(identifier: "info.member")
        XCTAssertTrue(members.firstMatch.waitForExistence(timeout: 5))
        let names = members.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(Array(names.dropLast()), ["Maya Chen, @maya.chen", "Sam Lee", "Theo Park, @theo.climbs"])  // Priya left
        XCTAssertTrue(names.last?.hasPrefix("You, ") == true, "\(names)")
        XCTAssertEqual(app.staticTexts["info.membersHeader"].label.lowercased(), "4 members")
        attachScreenshot(app, "group-info")
        app.navigationBars["Chat Info"].buttons.firstMatch.tap()
        XCTAssertTrue(bubbles.firstMatch.waitForExistence(timeout: 5))
    }

    /// Where an unread chat opens (2026-10-20) on the made-up group with more unread (`FERRY_DEBUG_GROUP_EXTRA`): much
    /// more that's new than fits holds the "New messages" line with the jump-to-newest button, which counts what arrives
    /// meanwhile (`FERRY_DEBUG_GROUP_INCOMING`), goes to the end and hides; a little more opens at the end, no button.
    /// The held thread is queried but never scrolled by a gesture.
    @MainActor
    func testUnreadOverflowOpensOnTheLineOrAtTheEnd() throws {
        func openGroup(_ app: XCUIApplication) {
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'inbox.row' AND label BEGINSWITH 'Saturday Climbs'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 1.5)  // the thread appears once it rests
        }
        var app = launch(["FERRY_DEBUG_GROUP_EXTRA": "14", "FERRY_DEBUG_GROUP_INCOMING": "2"])
        openGroup(app)
        let jump = app.buttons["thread.jump"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        XCTAssertEqual(jump.label, "Jump to newest message")
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS ' new message'"), object: jump)
        XCTAssertEqual(XCTWaiter().wait(for: [counted], timeout: 8), .completed, "no count: \(jump.value ?? "nil")")
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5))

        app = launch(["FERRY_DEBUG_GROUP_EXTRA": "7"])
        openGroup(app)
        XCTAssertFalse(app.buttons["thread.jump"].exists)
    }

    /// Design-pass screenshots (`TEST_RUNNER_FERRY_UITEST_TOUR=<folder>`, e.g. the gitignored `docs/verification`;
    /// `TEST_RUNNER_FERRY_UITEST_TOUR_SUFFIX=light|dark` to match `simctl ui appearance`), all on the made-up data, so
    /// they're safe to share. Never taps Add, Log in, Connect or anything that sends. The group scrolled to its start
    /// is the last thing in its launch: no query after scrolling up. Media cards and the player need real chats: the
    /// live tests and `FERRY_DEBUG_PLAYER_FAILS` cover them.
    @MainActor
    func testDesignTour() throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["FERRY_UITEST_TOUR"], !folder.isEmpty else {
            throw XCTSkip("Writes screenshots; set TEST_RUNNER_FERRY_UITEST_TOUR to a folder to run it.")
        }
        let suffix = env["FERRY_UITEST_TOUR_SUFFIX"].map { "-\($0)" } ?? ""
        func shot(_ name: String) throws {
            Thread.sleep(forTimeInterval: 1.5)  // sheets and pushes animate
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(folder)/v3-\(name)\(suffix).png"))
        }
        let any = { (app: XCUIApplication, id: String) in app.descendants(matching: .any)[id] }

        // Inbox, then Accounts, then A2's editor; a DM and its Chat Info.
        var app = launch()
        let rows = app.descendants(matching: .any).matching(identifier: "inbox.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'scope.' AND identifier != 'scope.all'"))
        let ids = chips.allElementsBoundByIndex.map { String($0.identifier.dropFirst("scope.".count)) }
        XCTAssertGreaterThanOrEqual(ids.count, 2, "the tour needs two accounts")
        try shot("inbox")
        app.buttons["inbox.accounts"].tap()
        XCTAssertTrue(app.staticTexts["accounts.footer"].waitForExistence(timeout: 5))
        try shot("accounts")
        app.buttons.matching(identifier: "accounts.row").element(boundBy: 1).tap()  // the longer name: its chips scroll
        XCTAssertTrue(app.textFields["identity.name"].waitForExistence(timeout: 5))
        try shot("account-detail")

        app = launch()
        try openReadChat(app, named: "Jonas Berg,")
        try shot("dm")
        any(app, "thread.header").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Chat Info"].waitForExistence(timeout: 5))
        try shot("info-dm")

        // A signed-out account: its badge and the banner (never "Log in"), then the stack with 3 and 4+ accounts.
        app = launch(["FERRY_DEBUG_LOGIN_STATE": "\(ids[1])=BAD_CREDENTIALS"])
        XCTAssertTrue(any(app, "banner").waitForExistence(timeout: 15))
        try shot("attention")
        app = launch(["FERRY_DEBUG_STACK_EXTRA": "CONNECTING"])
        XCTAssertTrue(app.buttons["inbox.accounts"].waitForExistence(timeout: 15))
        try shot("stack3")
        app = launch(["FERRY_DEBUG_STACK_EXTRA": "CONNECTED,BAD_CREDENTIALS,CONNECTED"])
        XCTAssertTrue(app.buttons["inbox.accounts"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["inbox.accounts"].label.hasSuffix("and 3 more. Extra 2 needs attention."), app.buttons["inbox.accounts"].label)
        try shot("stack5")

        // A request; the mic's hint (sends blocked); O6; the group, its Chat Info and its start.
        app = launch()
        XCTAssertTrue(app.buttons["inbox.folders"].waitForExistence(timeout: 15))
        app.buttons["inbox.folders"].tap()
        app.buttons["folder.requests"].tap()
        let request = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'inbox.row' AND label CONTAINS 'Lena Ortiz'")).firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.tap()
        XCTAssertTrue(any(app, "thread.requestBar").waitForExistence(timeout: 5))
        try shot("request")

        app = launch(["FERRY_DEBUG_BLOCK_SENDS": "1", "FERRY_DEBUG_VOICE_FILE": "/nonexistent/voice.m4a"])
        try openReadChat(app)
        any(app, "composer.mic").tap()
        XCTAssertTrue(any(app, "composer.field").waitForPlaceholder("Hold to record", timeout: 2))
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(folder)/v3-mic-hint\(suffix).png"))

        app = launch(["FERRY_DEBUG_ONBOARDING": "another"])
        XCTAssertTrue(app.buttons["another.connect"].waitForExistence(timeout: 10))
        try shot("o6")

        app = launch()
        let group = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'inbox.row' AND label BEGINSWITH 'Saturday Climbs'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 15))
        group.tap()
        XCTAssertTrue(any(app, "thread.start").waitForExistence(timeout: 10))
        try shot("group")
        any(app, "thread.header").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "info.member").firstMatch.waitForExistence(timeout: 5))
        try shot("info-group")
        app.navigationBars["Chat Info"].buttons.firstMatch.tap()
        XCTAssertTrue(any(app, "composer.field").waitForExistence(timeout: 5))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.1, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 400)), withVelocity: .slow, thenHoldForDuration: 0.3)
        try shot("group-start")  // the whole start block; nothing is queried after scrolling up
        app.terminate()
    }

    /// O1 over the made-up accounts. "Connect" opens instagram.com's login, so it's only checked, never tapped.
    /// VoiceOver meets it top-down (DESIGN O1): one header, the picture as one image, the three promises, the button.
    @MainActor
    func testOnboardingWelcomeOffersConnect() throws {
        let app = launch(["FERRY_DEBUG_ONBOARDING": "welcome"])
        let connect = app.buttons["welcome.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        let labelled = { (label: String) in app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch }
        let parts = [labelled("Ferry. All your Instagram DMs. None of the feed."), labelled("A ferry carrying messages across calm water."),
                     labelled("Every account, one inbox"), labelled("Reels play right in the chat"),
                     labelled("No feed, no Explore, no algorithm"), connect]
        for part in parts { XCTAssertTrue(part.exists, part.debugDescription) }
        XCTAssertTrue(labelled("Not affiliated with Instagram or Meta.").exists)
        let tops = parts.map(\.frame.minY)
        XCTAssertEqual(tops, tops.sorted(), "Welcome's parts are out of order: \(tops)")
    }

    /// N1: in All, nothing is preselected and the search stays off until an account is chosen. Nothing is typed (each
    /// search is an Instagram request).
    @MainActor
    func testNewMessageNeedsAnAccountFirst() throws {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "inbox.row").firstMatch.waitForExistence(timeout: 15))
        if app.buttons["scope.all"].exists { app.buttons["scope.all"].tap() }
        app.buttons["inbox.compose"].tap()
        let to = app.textFields["newMessage.to"]
        XCTAssertTrue(to.waitForExistence(timeout: 5))
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'newMessage.from.'"))
        XCTAssertGreaterThan(chips.count, 0)
        if chips.count > 1 {
            XCTAssertFalse(to.isEnabled)
            XCTAssertEqual(to.placeholderValue, "Choose an account first")
            chips.element(boundBy: 0).tap()
        }
        XCTAssertTrue(to.waitForEnabled())
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Searching Instagram from @'")).firstMatch.exists)
        app.buttons["newMessage.cancel"].tap()
        XCTAssertTrue(app.buttons["inbox.compose"].waitForExistence(timeout: 5))
    }

    /// Opens instagram.com's login page in the Connect sheet (then cancels; nothing is typed), so it only runs with
    /// `TEST_RUNNER_FERRY_UITEST_LOGIN=1`.
    @MainActor
    func testConnectSheetOpensAndCancels() throws {
        guard ProcessInfo.processInfo.environment["FERRY_UITEST_LOGIN"] == "1" else {
            throw XCTSkip("Loads instagram.com; set TEST_RUNNER_FERRY_UITEST_LOGIN=1 to run it.")
        }
        let app = launch()
        let accounts = app.buttons["inbox.accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 10))
        accounts.tap()

        let add = app.buttons["accounts.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        app.buttons["connect.cancel"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }

    /// The made-up accounts and chats (`FERRY_DEBUG_DEMO`, requests and group included): nothing connects.
    @MainActor
    private func launch(_ extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["FERRY_DEBUG_DEMO": "1"].merging(extra) { _, new in new }
        app.launch()
        return app
    }

    /// The accounts logged in to the simulator's app (its Keychain survives reinstalls); every launch loads each one's
    /// inbox from Instagram.
    @MainActor
    private func launchLive(_ extra: [String: String] = [:]) throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["FERRY_UITEST_LIVE"] == "1" else {
            throw XCTSkip("Uses the simulator's Instagram accounts; set TEST_RUNNER_FERRY_UITEST_LIVE=1 to run it.")
        }
        let app = XCUIApplication()
        app.launchEnvironment = extra
        app.launch()
        return app
    }
}

private extension XCUIElement {
    func waitForSelected(timeout: TimeInterval = 5) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: self)],
                         timeout: timeout) == .completed
    }

    func waitForPlaceholder(_ text: String, timeout: TimeInterval) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "placeholderValue == %@", text), object: self)],
                         timeout: timeout) == .completed
    }

    func waitForEnabled(timeout: TimeInterval = 5) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: self)],
                         timeout: timeout) == .completed
    }
}
