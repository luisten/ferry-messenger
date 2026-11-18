import Foundation

/// For builds from source only (`FerryDistribution` empty): the release workflow stamps its .ipa `ipa`, and AltStore or
/// SideStore learn of new versions from the release's `source.json` instead. Accounts' footer says when a newer
/// release is out and until when this build opens (docs/DEVELOPMENT.md "Update to a new version").
nonisolated enum AppUpdate {
    static let latestURL = URL(string: "https://github.com/luisten/ferry-messenger/releases/latest")!
    static let howToUpdate = URL(string: "https://github.com/luisten/ferry-messenger/blob/main/docs/DEVELOPMENT.md#update-to-a-new-version")!
    /// The Accounts toggle, on unless turned off (D20).
    static let enabledKey = "updates.check"
    /// The newest release's tag GitHub named ("v1.8"), kept between launches.
    static let latestKey = "updates.latest"
    private static let checkedKey = "updates.checked"

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let prerelease = Bundle.main.object(forInfoDictionaryKey: "FerryPrerelease") as? String ?? ""
    static let fromSource = (Bundle.main.object(forInfoDictionaryKey: "FerryDistribution") as? String ?? "").isEmpty

    /// At most once a day, as the app becomes active: one HEAD request to `releases/latest`, whose redirect names the
    /// newest release (D22: no API, no JSON, nothing about the user but the app's version). Any failure: nothing.
    @MainActor static func checkIfDue(defaults: UserDefaults = .standard, now: Date = .now) async {
        guard fromSource, defaults.object(forKey: enabledKey) as? Bool ?? true else { return }
        #if DEBUG
        guard !DebugFixtures.demo, DebugFixtures.latestRelease == nil else { return }  // C8: the UI tests never ask GitHub
        #endif
        if let last = defaults.object(forKey: checkedKey) as? Date, abs(now.timeIntervalSince(last)) < 24 * 3600 { return }
        defaults.set(now, forKey: checkedKey)  // before asking, so a second activation meanwhile doesn't ask too
        var request = URLRequest(url: latestURL, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        request.setValue("FerryMessenger/\(version)", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: request, delegate: NoRedirects()),
              let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let tag = tag(fromLocation: location) else { return }
        defaults.set(tag, forKey: latestKey)
    }

    /// Ephemeral: no cookies or cache, so GitHub gets nothing from earlier checks.
    private static let session = URLSession(configuration: .ephemeral)

    /// The 302 itself is the answer: its `Location` names the release.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        // The completion handler, not the async form: Swift 6.4.2 crashes emitting that one's Objective-C thunk.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// "v1.8" from `https://github.com/…/releases/tag/v1.8`; nil for anything else (with no release, GitHub sends
    /// `…/releases`).
    static func tag(fromLocation location: String) -> String? {
        guard let range = location.range(of: "/releases/tag/") else { return nil }
        let tag = location[range.upperBound...]
        return numbers(tag) == nil ? nil : String(tag)
    }

    /// Whether the release `latest` ("v1.8") is newer than `version` ("1.7.1"): numbers compared in turn, a missing one
    /// is 0. A release candidate (`prerelease` set) is older than the release of its version.
    static func isNewer(_ latest: String, than version: String, prerelease: String) -> Bool {
        guard let new = numbers(latest), let old = numbers(version) else { return false }
        for i in 0..<max(new.count, old.count) {
            let a = i < new.count ? new[i] : 0, b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return !prerelease.isEmpty
    }

    private static func numbers(_ version: some StringProtocol) -> [Int]? {
        let parts = version.drop { $0 == "v" }.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap(\.self)
    }

    /// When this build stops opening: the `ExpirationDate` of the profile Xcode embedded (a plist inside a CMS-signed
    /// blob). The simulator's builds have none.
    static let expiry: Date? = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        .flatMap { try? Data(contentsOf: $0) }.flatMap(expiry(ofProfile:))

    static func expiry(ofProfile blob: Data) -> Date? {
        guard let start = blob.range(of: Data("<?xml".utf8)),
              let end = blob.range(of: Data("</plist>".utf8), in: start.lowerBound..<blob.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: blob[start.lowerBound..<end.upperBound], format: nil)
        else { return nil }
        return (plist as? [String: Any])?["ExpirationDate"] as? Date
    }
}
