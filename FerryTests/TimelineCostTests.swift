import XCTest
@testable import Ferry

/// #16: what `ThreadView` pays per body evaluation, `Timeline.reduce` plus `layout`, over a long window: the real
/// backfill page (state, an unresolved reel and its resolve edit), then the real M4/M5 events (messages, media, edits,
/// reactions, redactions, send statuses) copied with fresh event IDs, about 500 events in all. Debug build, so an upper
/// bound for the app.
final class TimelineCostTests: XCTestCase {
    static let fixtures = ["events_m4_tamo", "events_m4_kivo", "events_m5_kivo_own_resolve", "events_m5_tamo_own_media",
                           "event_reel_live", "event_post_live", "event_story_live", "event_photo_incoming",
                           "event_voice_incoming", "event_text_incoming", "event_text_own"]

    /// The backfill page, then `copies` copies of the fixtures, each event ID (and every reference to it) suffixed `_k`.
    static func window(copies: Int) throws -> [Event] {
        let backfill = try JSONDecoder().decode(MessagesPage.self, from: Fixture.data("messages_dm_backfill")).chunk.reversed()
        let texts = try fixtures.map { try String(decoding: Fixture.data($0), as: UTF8.self) }
        return try backfill + (0..<copies).flatMap { k in
            try texts.flatMap { text -> [Event] in
                let data = Data(text.replacing(/"\$([A-Za-z0-9_\-]+)"/) { "\"$\($0.1)_\(k)\"" }.utf8)
                return text.hasPrefix("[") ? try JSONDecoder().decode([Event].self, from: data) : [try JSONDecoder().decode(Event.self, from: data)]
            }
        }
    }

    /// Well under a frame (16 ms at 60 Hz), so memoizing isn't needed (#16, 2026-10-14: about 2 ms).
    func testReduceAndLayoutOf500EventsFitsInAFrame() throws {
        let events = try Self.window(copies: 13)
        XCTAssertEqual(events.count, 495)
        let rows = Timeline.layout(Timeline.reduce(events, me: Fixture.me))
        XCTAssertGreaterThan(rows.count, 150)

        let reduce = (0..<50).map { _ in ContinuousClock().measure { _ = Timeline.reduce(events, me: Fixture.me) } }.sorted()
        let times = (0..<50).map { _ in ContinuousClock().measure { _ = Timeline.layout(Timeline.reduce(events, me: Fixture.me)) } }.sorted()
        print("#16 \(events.count) events, \(rows.count) rows: reduce median \(reduce[25]); reduce+layout median \(times[25]), max \(times.last!)")
        XCTAssertLessThan(times[25], .milliseconds(16))
    }
}
