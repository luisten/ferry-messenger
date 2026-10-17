import Foundation

/// What the instagram.com web view must produce: the cookies to collect and the page that means "logged in". The
/// bridge's own login step (`login/start`, `FerryTests/Fixtures/login_start_cookies.json`) as a constant, now that
/// there's no bridge to ask.
nonisolated struct CookieStep: Equatable, Sendable {
    var url: URL
    var fields: [Field]
    var waitForURLPattern: String?

    struct Field: Equatable, Sendable {
        var id: String
        var required: Bool
        /// The cookie's name and domain (the field ID is the name too).
        var cookieName: String
        var cookieDomain: String?
    }

    static let instagram = CookieStep(
        url: URL(string: "https://www.instagram.com/accounts/login/")!,
        fields: [("sessionid", true), ("csrftoken", true), ("ds_user_id", true), ("rur", false), ("shbid", false),
                 ("shbts", false), ("mid", false), ("ig_did", false)]
            .map { Field(id: $0.0, required: $0.1, cookieName: $0.0, cookieDomain: "instagram.com") },
        waitForURLPattern: #"^https://www\.instagram\.com/(?:direct/(?:inbox/|t/[0-9]+/)?)?(?:\?.*)?$"#)
}

/// Decides when the instagram.com web view has produced a usable session (PLAN §2.9).
nonisolated enum CookieGate {
    enum Result: Equatable, Sendable {
        /// Required cookies still missing (field ids, in the step's order).
        case waiting(missing: [String])
        /// All required cookies exist but the URL doesn't match yet (e.g. IG's one-tap page): offer "Continue".
        case captured([String: String])
        /// Cookies and URL both match: submit automatically.
        case ready([String: String])

        var values: [String: String]? {
            switch self {
            case .waiting: nil
            case .captured(let v), .ready(let v): v
            }
        }

        var isReady: Bool { if case .ready = self { true } else { false } }
    }

    static func evaluate(_ step: CookieStep, cookies: [HTTPCookie], url: URL?) -> Result {
        var values: [String: String] = [:]
        var missing: [String] = []
        for field in step.fields {
            let value = cookies.first { $0.name == field.cookieName && !$0.value.isEmpty && matches($0.domain, field.cookieDomain) }?.value
            if let value { values[field.id] = value } else if field.required { missing.append(field.id) }
        }
        guard missing.isEmpty else { return .waiting(missing: missing) }
        return urlMatches(url, step.waitForURLPattern) ? .ready(values) : .captured(values)
    }

    /// `.instagram.com`, `instagram.com` and `www.instagram.com` match `instagram.com`; `evilinstagram.com` doesn't.
    private static func matches(_ cookieDomain: String, _ wanted: String?) -> Bool {
        guard let wanted, !wanted.isEmpty else { return true }
        let domain = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return domain == wanted || domain.hasSuffix("." + wanted)
    }

    /// The pattern is a Go RE2 regex (the bridge's); this one uses only syntax ICU shares. No pattern means cookies
    /// alone suffice.
    private static func urlMatches(_ url: URL?, _ pattern: String?) -> Bool {
        guard let pattern, !pattern.isEmpty else { return true }
        guard let url else { return false }
        return url.absoluteString.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Small pure helpers for the connect flow.
nonisolated enum InstagramLogin {
    /// Logging out in the login web view would kill the session the app just received.
    static func isLogoutURL(_ url: URL) -> Bool {
        guard let host = url.host(), host == "instagram.com" || host.hasSuffix(".instagram.com") else { return false }
        return url.path().hasPrefix("/accounts/logout")
    }

    /// Copy for why Instagram refused a session (`IGCore.Failure.reason`, the bridge's login errors), DESIGN §7.3
    /// voice; nil for anything else.
    static func message(reason: String?) -> String? {
        switch reason {
        case "challenge", "checkpoint":
            "Instagram wants to confirm it's you. Open the Instagram app or check your email for a login alert, tap \"This was me\", then log in again."
        case "consent":
            "Instagram needs your OK. Open Instagram, accept the update it shows, then log in again."
        case "suspended":
            "Instagram suspended this account. Check the Instagram app for details."
        case "logged_out":
            "Instagram ended the session. Log in again."
        default:
            nil
        }
    }
}
