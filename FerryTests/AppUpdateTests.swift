import XCTest
@testable import Ferry

/// Builds from source: which release counts as newer, GitHub's redirect, and the provisioning profile's expiry.
final class AppUpdateTests: XCTestCase {
    func testNewerReleaseByNumbersNotText() {
        XCTAssertTrue(AppUpdate.isNewer("v1.8", than: "1.7.1", prerelease: ""))
        XCTAssertTrue(AppUpdate.isNewer("v1.10", than: "1.9", prerelease: ""))
        XCTAssertTrue(AppUpdate.isNewer("v1.7.1", than: "1.7", prerelease: ""))
        XCTAssertTrue(AppUpdate.isNewer("v2", than: "1.99.9", prerelease: ""))
        XCTAssertFalse(AppUpdate.isNewer("v1.7", than: "1.7.0", prerelease: ""))
        XCTAssertFalse(AppUpdate.isNewer("v1.7.1", than: "1.7.1", prerelease: ""))
        XCTAssertFalse(AppUpdate.isNewer("v1.7", than: "1.8", prerelease: ""))
        XCTAssertFalse(AppUpdate.isNewer("v1.9", than: "1.10", prerelease: ""))
    }

    func testAReleaseCandidateIsOlderThanItsRelease() {
        XCTAssertTrue(AppUpdate.isNewer("v1.8", than: "1.8", prerelease: "RC1"))
        XCTAssertTrue(AppUpdate.isNewer("v1.8.0", than: "1.8", prerelease: "RC2"))
        XCTAssertFalse(AppUpdate.isNewer("v1.7.1", than: "1.8", prerelease: "RC1"))
    }

    func testAnythingButNumbersIsNeverNewer() {
        for latest in ["", "v", "latest", "v1.8-rc1", "v1..8", "v1.8.", "1.x"] {
            XCTAssertFalse(AppUpdate.isNewer(latest, than: "1.7", prerelease: ""), latest)
        }
        XCTAssertFalse(AppUpdate.isNewer("v1.8", than: "", prerelease: ""))
    }

    func testTagFromGitHubsRedirect() {
        XCTAssertEqual(AppUpdate.tag(fromLocation: "https://github.com/luisten/ferry-messenger/releases/tag/v1.7.1"), "v1.7.1")
        XCTAssertNil(AppUpdate.tag(fromLocation: "https://github.com/luisten/ferry-messenger/releases"))  // no release yet
        XCTAssertNil(AppUpdate.tag(fromLocation: "https://github.com/luisten/ferry-messenger/releases/tag/v1.8/extra"))
        XCTAssertNil(AppUpdate.tag(fromLocation: "https://github.com/login"))
    }

    /// A made-up profile: the plist sits inside binary CMS bytes, which hold neither `<?xml` nor `</plist>`.
    func testExpiryFromTheProfilesPlist() throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>CreationDate</key>
            \t<date>2026-11-18T09:00:00Z</date>
            \t<key>ExpirationDate</key>
            \t<date>2026-11-25T09:00:00Z</date>
            \t<key>IsXcodeManaged</key>
            \t<true/>
            </dict>
            </plist>
            """
        let blob = Data([0x30, 0x80, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02, 0xA0, 0x80])
            + Data(plist.utf8) + Data([0x00, 0x00, 0xA0, 0x82, 0x0B, 0x31])
        XCTAssertEqual(AppUpdate.expiry(ofProfile: blob), try Date("2026-11-25T09:00:00Z", strategy: .iso8601))
        XCTAssertNil(AppUpdate.expiry(ofProfile: Data(plist.prefix(200).utf8)))  // cut short
        XCTAssertNil(AppUpdate.expiry(ofProfile: Data([0x30, 0x80, 0x06])))
    }
}
