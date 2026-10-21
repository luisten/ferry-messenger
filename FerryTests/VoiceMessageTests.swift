import XCTest
@testable import Ferry

/// Sending voice notes (DESIGN §6.9): the mic's touch-and-hold rules and the `m.audio` the bridge uploads to Instagram
/// as a voice clip (`IsVoiceClip` when `org.matrix.msc3245.voice` is present; `audio/mp4` fully supported, spike S4).
final class VoiceMessageTests: XCTestCase {
    typealias Hold = VoiceMessage.Hold

    // MARK: Touch and hold

    /// A quick tap records hands-free (the user's call, 2026-10-21; it used to be a "Hold to record" hint): from when the
    /// finger lifts, until Send.
    func testQuickTapRecordsHandsFreeUntilSend() {
        var hold = Hold()
        XCTAssertNil(hold.tick(held: 0.1, recorded: 0))
        XCTAssertNil(hold.tick(held: Hold.tapLimit - 0.01, recorded: 0))
        XCTAssertEqual(hold.release(recorded: 0), .start)
        XCTAssertTrue(hold.isHandsFree)
        XCTAssertNil(hold.tick(held: 4, recorded: 3.7), "it keeps recording")
        XCTAssertNil(hold.drag(-200), "no finger, no slide")
        XCTAssertEqual(hold.finish(recorded: 3.7), .send)
        XCTAssertNil(hold.finish(recorded: 4), "one send")
        XCTAssertFalse(hold.isHandsFree)
    }

    func testHandsFreeUnderASecondIsDroppedAndTheTrashCancels() {
        var short = Hold()
        _ = short.release(recorded: 0)
        XCTAssertEqual(short.finish(recorded: 0.99), .discard)
        var trashed = Hold()
        _ = trashed.release(recorded: 0)
        XCTAssertEqual(trashed.cancel(), .cancel)
        XCTAssertNil(trashed.finish(recorded: 5))
        var pressing = Hold()
        XCTAssertNil(pressing.cancel(), "nothing to cancel before it records")
    }

    /// Stop, hands-free: listen back, then Send (or the trash); nothing else records or sends meanwhile.
    func testStopToListenBackThenSendOrBin() {
        var hold = Hold()
        _ = hold.release(recorded: 0)
        XCTAssertEqual(hold.stop(), .stop)
        XCTAssertTrue(hold.isHandsFree, "Send and the trash stay")
        XCTAssertNil(hold.stop())
        XCTAssertNil(hold.tick(held: 400, recorded: Hold.maxDuration), "stopped: nothing sends by itself")
        XCTAssertEqual(hold.finish(recorded: 4), .send)
        var binned = Hold()
        _ = binned.release(recorded: 0)
        _ = binned.stop()
        XCTAssertEqual(binned.cancel(), .cancel)
        var short = Hold()
        _ = short.release(recorded: 0)
        _ = short.stop()
        XCTAssertEqual(short.finish(recorded: 0.5), .discard)
        var held = Hold(recording: true)
        XCTAssertNil(held.stop(), "a hold has no Stop")
    }

    func testHandsFreeSendsByItselfAtTheMaximum() {
        var hold = Hold()
        _ = hold.release(recorded: 0)
        XCTAssertEqual(hold.tick(held: 301, recorded: Hold.maxDuration), .send)
        XCTAssertNil(hold.finish(recorded: Hold.maxDuration))
    }

    func testHoldingPastTheTapLimitStartsOnce() {
        var hold = Hold()
        XCTAssertEqual(hold.tick(held: Hold.tapLimit, recorded: 0), .start)
        XCTAssertNil(hold.tick(held: 0.5, recorded: 0.2))
    }

    /// Let go too soon to send: it carries on hands-free instead of throwing the start away.
    func testReleaseUnderASecondCarriesOnHandsFree() {
        var hold = Hold(recording: true)
        XCTAssertNil(hold.release(recorded: 0.99))
        XCTAssertTrue(hold.isHandsFree)
        XCTAssertEqual(hold.finish(recorded: 2), .send)
    }

    func testReleaseFromASecondSends() {
        var hold = Hold(recording: true)
        XCTAssertEqual(hold.release(recorded: 1), .send)
        XCTAssertNil(hold.release(recorded: 1), "one send per hold")
    }

    /// Sliding left past the threshold cancels at once, finger still down; lifting it afterwards does nothing.
    func testSlidingLeftPastTheThresholdCancels() {
        var hold = Hold(recording: true)
        XCTAssertNil(hold.drag(-(Hold.cancelDistance - 1)))
        XCTAssertEqual(hold.drag(-Hold.cancelDistance), .cancel)
        XCTAssertNil(hold.drag(-200))
        XCTAssertNil(hold.tick(held: 70, recorded: 70))
        XCTAssertNil(hold.release(recorded: 5))
    }

    /// Sliding right, or left and back, still sends.
    func testSlidingBackStillSends() {
        var hold = Hold(recording: true)
        XCTAssertNil(hold.drag(200))
        XCTAssertNil(hold.drag(-60))
        XCTAssertNil(hold.drag(0))
        XCTAssertEqual(hold.release(recorded: 3), .send)
    }

    /// Before the recorder starts, a slide is just a moving tap.
    func testSlideBeforeRecordingIsStillATap() {
        var hold = Hold()
        XCTAssertNil(hold.drag(-200))
        XCTAssertEqual(hold.release(recorded: 0), .start)
        XCTAssertTrue(hold.isHandsFree)
    }

    /// At the maximum it sends by itself, once; the finger lifting later does nothing.
    func testTheMaximumSendsByItself() {
        var hold = Hold(recording: true)
        XCTAssertNil(hold.tick(held: 299.95, recorded: Hold.maxDuration - 0.05))
        XCTAssertEqual(hold.tick(held: 300.3, recorded: Hold.maxDuration), .send)
        XCTAssertNil(hold.tick(held: 300.4, recorded: Hold.maxDuration))
        XCTAssertNil(hold.release(recorded: Hold.maxDuration))
    }

    func testLimits() {
        XCTAssertEqual(Hold.minDuration, 1)
        XCTAssertEqual(Hold.maxDuration, 300)
    }

    /// The "Slide to cancel" label fades as the finger nears the threshold.
    func testCancelProgress() {
        XCTAssertEqual(Hold.cancelProgress(40), 0)
        XCTAssertEqual(Hold.cancelProgress(-Hold.cancelDistance / 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(Hold.cancelProgress(-500), 1)
    }

    /// The meter: silence (-160 dB and anything under -50) is empty, full scale is 1.
    func testLevelFromDecibels() {
        XCTAssertEqual(VoiceMessage.level(decibels: -160), 0)
        XCTAssertEqual(VoiceMessage.level(decibels: -50), 0)
        XCTAssertEqual(VoiceMessage.level(decibels: -25), 0.5, accuracy: 0.001)
        XCTAssertEqual(VoiceMessage.level(decibels: 0), 1)
        XCTAssertEqual(VoiceMessage.level(decibels: 3), 1)
    }

    // MARK: Content

    /// Exact keys, as in spike S4's send that Instagram took as a voice clip (minus the made-up waveform).
    func testContentIsAVoiceAudio() {
        let voice = VoiceMessage.Recorded(file: URL(fileURLWithPath: "/tmp/v.m4a"), duration: 4200, size: 33_000)
        let content = VoiceMessage.content(url: "mxc://igm.home.arpa/a", voice: voice)
        XCTAssertEqual(content, [
            "msgtype": "m.audio",
            "body": "voice.m4a",
            "url": "mxc://igm.home.arpa/a",
            "info": ["mimetype": "audio/mp4", "size": 33_000, "duration": 4200],
            "org.matrix.msc1767.audio": ["duration": 4200],
            "org.matrix.msc3245.voice": [:],
        ])
        XCTAssertEqual(MessageKind(type: "m.room.message", content: content), .voice)
        XCTAssertEqual(MediaInfo(content: content).duration, 4200)

        let reply = VoiceMessage.content(url: "mxc://igm.home.arpa/a", voice: voice, replyTo: "$target")
        XCTAssertEqual(Timeline.replyTarget(reply), "$target")
    }

    func testLocalEchoIsAVoiceNoteUntilEchoed() {
        let voice = VoiceMessage.Recorded(file: URL(fileURLWithPath: "/tmp/v.m4a"), duration: 4200, size: 33_000)
        let pending = PendingMessage(txnID: "t1", content: VoiceMessage.content(url: PhotoMessage.localURL("t1"), voice: voice),
                                     ts: 5, state: .sending)
        let echoing = Timeline.reduce([], me: Fixture.me, pending: [pending])
        XCTAssertEqual(echoing.map(\.kind), [.voice])
        XCTAssertEqual(echoing.first?.status, .sending)
    }
}
