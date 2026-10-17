import XCTest
@testable import Ferry

/// Cases from PLAN M1, against the app's copy of the bridge's cookie step (`CookieStep.instagram`), which the first
/// test checks against the real `login/start` fixture.
final class CookieGateTests: XCTestCase {
    private let required = ["sessionid": "S", "csrftoken": "C", "ds_user_id": "42"]

    private func step() throws -> CookieStep { .instagram }

    /// The constant is the bridge's own step (mautrix-meta v0.2609.0), field for field.
    func testInstagramStepMatchesTheBridgesLoginStep() throws {
        let bridge = try XCTUnwrap(Fixture.jsonObject("login_start_cookies")["cookies"])
        XCTAssertEqual(CookieStep.instagram.url.absoluteString, bridge["url"]?.string)
        XCTAssertEqual(CookieStep.instagram.waitForURLPattern, bridge["wait_for_url_pattern"]?.string)
        let fields = try XCTUnwrap(bridge["fields"]?.array).map { field in
            CookieStep.Field(id: field["id"]?.string ?? "", required: field["required"]?.bool ?? false,
                             cookieName: field["sources"]?.array?.first?["name"]?.string ?? "",
                             cookieDomain: field["sources"]?.array?.first?["cookie_domain"]?.string)
        }
        XCTAssertEqual(CookieStep.instagram.fields, fields)
    }

    private func cookies(_ values: [String: String], domain: String = ".instagram.com") -> [HTTPCookie] {
        values.map { HTTPCookie(properties: [.name: $0.key, .value: $0.value, .domain: domain, .path: "/"])! }
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    func testMissingRequiredCookieWaits() throws {
        let jar = cookies(["sessionid": "S", "csrftoken": "C"])
        let result = CookieGate.evaluate(try step(), cookies: jar, url: url("https://www.instagram.com/"))
        XCTAssertEqual(result, .waiting(missing: ["ds_user_id"]))
    }

    func testNoCookiesListsAllRequiredInFieldOrder() throws {
        let result = CookieGate.evaluate(try step(), cookies: [], url: url("https://www.instagram.com/accounts/login/"))
        XCTAssertEqual(result, .waiting(missing: ["sessionid", "csrftoken", "ds_user_id"]))
    }

    func testAllRequiredOnOneTapIsCapturedButNotReady() throws {
        // IG's "Save your login info?" page doesn't match the pattern: "Continue" is offered, no auto-submit.
        let result = CookieGate.evaluate(try step(), cookies: cookies(required),
                                         url: url("https://www.instagram.com/accounts/onetap/?next=%2F"))
        XCTAssertEqual(result, .captured(required))
        XCTAssertFalse(result.isReady)
        XCTAssertEqual(result.values, required)
    }

    func testAllRequiredOnDirectInboxIsReadyWithPresentOptionals() throws {
        let jar = cookies(required.merging(["mid": "M", "ig_did": "D"]) { a, _ in a })
            + cookies(["unrelated": "x"])
        let result = CookieGate.evaluate(try step(), cookies: jar, url: url("https://www.instagram.com/direct/inbox/"))
        XCTAssertEqual(result, .ready(required.merging(["mid": "M", "ig_did": "D"]) { a, _ in a }))
        XCTAssertTrue(result.isReady)
    }

    func testCookieOnForeignDomainIsIgnored() throws {
        let jar = cookies(["csrftoken": "C", "ds_user_id": "42"])
            + cookies(["sessionid": "evil"], domain: "evilinstagram.com")
            + cookies(["sessionid": "evil2"], domain: "instagram.com.example.net")
        let result = CookieGate.evaluate(try step(), cookies: jar, url: url("https://www.instagram.com/"))
        XCTAssertEqual(result, .waiting(missing: ["sessionid"]))
    }

    func testEmptyCookieValueCountsAsMissing() throws {
        // IG clears cookies by setting them empty; an empty sessionid is not a session.
        let jar = cookies(["sessionid": "", "csrftoken": "C", "ds_user_id": "42"])
        let result = CookieGate.evaluate(try step(), cookies: jar, url: url("https://www.instagram.com/"))
        XCTAssertEqual(result, .waiting(missing: ["sessionid"]))
    }

    func testCookieOnSubdomainOrBareDomainCounts() throws {
        let jar = cookies(["sessionid": "S"], domain: "www.instagram.com")
            + cookies(["csrftoken": "C", "ds_user_id": "42"], domain: "instagram.com")
        let result = CookieGate.evaluate(try step(), cookies: jar, url: url("https://www.instagram.com/"))
        XCTAssertEqual(result, .ready(required))
    }

    func testPatternURLWithQueryStringIsReady() throws {
        let gate = try step()
        let jar = cookies(required)
        XCTAssertEqual(CookieGate.evaluate(gate, cookies: jar, url: url("https://www.instagram.com/?hl=en")), .ready(required))
        XCTAssertEqual(CookieGate.evaluate(gate, cookies: jar, url: url("https://www.instagram.com/direct/inbox/?hl=en")),
                       .ready(required))
        XCTAssertEqual(CookieGate.evaluate(gate, cookies: jar, url: url("https://www.instagram.com/direct/t/1234567/")),
                       .ready(required))
        // Counter-cases: the login page itself, and a lookalike host.
        XCTAssertEqual(CookieGate.evaluate(gate, cookies: jar, url: url("https://www.instagram.com/accounts/login/?next=%2F")),
                       .captured(required))
        XCTAssertEqual(CookieGate.evaluate(gate, cookies: jar, url: url("https://www.instagram.com.evil.net/")),
                       .captured(required))
    }

    func testNoURLYetIsCapturedNotReady() throws {
        XCTAssertEqual(CookieGate.evaluate(try step(), cookies: cookies(required), url: nil), .captured(required))
    }

    func testLogoutURLsAreBlocked() {
        XCTAssertTrue(InstagramLogin.isLogoutURL(url("https://www.instagram.com/accounts/logout/")))
        XCTAssertTrue(InstagramLogin.isLogoutURL(url("https://www.instagram.com/accounts/logout/ajax/?one_tap_app_login=1")))
        XCTAssertFalse(InstagramLogin.isLogoutURL(url("https://www.instagram.com/accounts/login/")))
        XCTAssertFalse(InstagramLogin.isLogoutURL(url("https://example.com/accounts/logout/")))
    }

    /// `IGCore.Failure.reason` (core's `classify`, the bridge's login errors) to copy; anything else keeps core's message.
    func testRefusalCopy() {
        XCTAssertEqual(InstagramLogin.message(reason: "checkpoint"), InstagramLogin.message(reason: "challenge"))
        XCTAssertTrue(InstagramLogin.message(reason: "consent")?.contains("accept the update") == true)
        XCTAssertTrue(InstagramLogin.message(reason: "logged_out")?.contains("Log in again") == true)
        XCTAssertNil(InstagramLogin.message(reason: "network"))
        XCTAssertNil(InstagramLogin.message(reason: nil))
    }
}
