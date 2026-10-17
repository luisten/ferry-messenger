import XCTest
@testable import Ferry

/// #25: `Caches/media` stays bounded. `trim` runs on a temporary folder here, with small limits.
final class MediaTrimTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "media-trim-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Five 100 kB files, last used 5…1 minutes ago (f0 is the oldest).
    private func fill() throws {
        for i in 0..<5 {
            let url = folder.appending(path: "f\(i).mp4")
            try Data(count: 100_000).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 5) * 60)], ofItemAtPath: url.path())
        }
    }

    private var remaining: [String] {
        get throws { try FileManager.default.contentsOfDirectory(atPath: folder.path()).sorted() }
    }

    func testOverTheCeilingDeletesTheLeastRecentlyUsedUntilUnderTheTarget() throws {
        try fill()
        MediaCache.trim(folder, ceiling: 450_000, target: 250_000)
        XCTAssertEqual(try remaining, ["f3.mp4", "f4.mp4"])
    }

    func testAtOrUnderTheCeilingKeepsEverything() throws {
        try fill()
        MediaCache.trim(folder, ceiling: 500_000, target: 250_000)
        XCTAssertEqual(try remaining.count, 5)
    }

    /// The file's date is what "recently used" means: a touched old file outlives newer ones.
    func testRecentlyTouchedFileIsKept() throws {
        try fill()
        try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: folder.appending(path: "f0.mp4").path())
        MediaCache.trim(folder, ceiling: 450_000, target: 250_000)
        XCTAssertEqual(try remaining, ["f0.mp4", "f4.mp4"])
    }

    func testMissingFolderIsFine() {
        MediaCache.trim(folder.appending(path: "missing"), ceiling: 0, target: 0)
    }

    /// Opening a file from the cache touches it, with no request (the API has no server to reach). The test host is the
    /// app, so this uses the simulator app's own cache folder, like `testClearEmptiesTheMediaFolder`.
    @MainActor
    func testOpeningACachedFileMarksItUsed() async throws {
        try FileManager.default.createDirectory(at: MediaCache.directory, withIntermediateDirectories: true)
        let file = MediaCache.directory.appending(path: "m25test.mp4")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let old = Date(timeIntervalSinceNow: -86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path())
        let opened = try await MediaCache().file("mxc://igm.home.arpa/m25test", mimetype: "video/mp4")
        XCTAssertEqual(opened, file)
        let used = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        XCTAssertGreaterThan(used, old.addingTimeInterval(3600))
    }
}
