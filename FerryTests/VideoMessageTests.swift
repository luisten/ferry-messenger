import AVFoundation
import XCTest
@testable import Ferry

/// Sending videos (DESIGN §6.9): what goes up as it is and what is re-encoded to fit Instagram's 25 MB (igconnector
/// `capabilities.go`: mp4/mov/webm/ogg, `MaxFileSize` 25 × 1000 × 1000), the `m.video` content our own card reads, and
/// the AVFoundation part on small movies written here (orientation, thumbnail, location dropped).
final class VideoMessageTests: XCTestCase {

    // MARK: Send decision

    func testMP4AndMOVWithinTheLimitGoAsTheyAre() {
        XCTAssertEqual(VideoMessage.next(size: 10_000_000, mimetype: "video/mp4", exports: 0), .send)
        XCTAssertEqual(VideoMessage.next(size: 10_000_000, mimetype: "video/quicktime", exports: 0), .send)
        XCTAssertEqual(VideoMessage.next(size: 25_000_000, mimetype: "video/mp4", exports: 0), .send)  // the bridge's limit is inclusive
    }

    func testTooBigIsReencodedAtTheLargestPresetFirst() {
        XCTAssertEqual(VideoMessage.next(size: 25_000_001, mimetype: "video/quicktime", exports: 0), .export(AVAssetExportPreset1280x720))
    }

    /// Anything else Photos may hand over (m4v, a missing type) becomes an H.264 MP4 whatever its size.
    func testOtherTypesAreReencoded() {
        XCTAssertEqual(VideoMessage.next(size: 1_000, mimetype: "video/x-m4v", exports: 0), .export(AVAssetExportPreset1280x720))
        XCTAssertEqual(VideoMessage.next(size: 1_000, mimetype: nil, exports: 0), .export(AVAssetExportPreset1280x720))
    }

    /// Each export that is still too big steps down a preset; past the last one it's too long to send.
    func testExportsStepDownUntilOneFitsOrNoneDoes() {
        XCTAssertEqual(VideoMessage.next(size: 30_000_000, mimetype: "video/mp4", exports: 1), .export(AVAssetExportPreset960x540))
        XCTAssertEqual(VideoMessage.next(size: 30_000_000, mimetype: "video/mp4", exports: 2), .export(AVAssetExportPreset640x480))
        XCTAssertEqual(VideoMessage.next(size: 30_000_000, mimetype: "video/mp4", exports: 3), .tooLong)
        XCTAssertEqual(VideoMessage.next(size: 20_000_000, mimetype: "video/mp4", exports: 2), .send)
    }

    func testMimetypeFromTheFileExtension() {
        XCTAssertEqual(VideoMessage.mimetype(ofExtension: "MOV"), "video/quicktime")
        XCTAssertEqual(VideoMessage.mimetype(ofExtension: "mp4"), "video/mp4")
        XCTAssertNil(VideoMessage.mimetype(ofExtension: ""))
    }

    func testTooLongSaysWhatToDo() {
        XCTAssertEqual(VideoMessage.Failure.tooLong.localizedDescription, "This video is too long to send to Instagram. Trim it first.")
    }

    // MARK: Content

    /// Exact keys: the bridge reads `url`, `info.mimetype` and `info.size` (it refuses over 25 MB); our own card reads
    /// the size, duration and thumbnail.
    func testContentIsAVideoWithInfoAndThumbnail() {
        let video = Self.video(mimetype: "video/quicktime")
        let content = VideoMessage.content(url: "mxc://igm.home.arpa/v", video: video, thumbnailURL: "mxc://igm.home.arpa/t")
        XCTAssertEqual(content, [
            "msgtype": "m.video",
            "body": "video.mov",
            "url": "mxc://igm.home.arpa/v",
            "info": [
                "mimetype": "video/quicktime",
                "size": 1_234_567,
                "w": 1080,
                "h": 1920,
                "duration": 12_345,
                "thumbnail_url": "mxc://igm.home.arpa/t",
                "thumbnail_info": ["mimetype": "image/jpeg", "size": 4321, "w": 450, "h": 800],
            ],
        ])
        XCTAssertEqual(MessageKind(type: "m.room.message", content: content), .video)
        let info = MediaInfo(content: content)
        XCTAssertTrue(info.isVideo)
        XCTAssertEqual(info.previewURL, "mxc://igm.home.arpa/t")
        XCTAssertEqual(info.duration, 12_345)
        XCTAssertEqual(info.aspect ?? 0, 1920.0 / 1080, accuracy: 0.001)

        let mp4 = VideoMessage.content(url: "mxc://igm.home.arpa/v", video: Self.video(mimetype: "video/mp4"), thumbnailURL: "mxc://igm.home.arpa/t")
        XCTAssertEqual(mp4["body"], "video.mp4")
        let reply = VideoMessage.content(url: "mxc://igm.home.arpa/v", video: video, thumbnailURL: "mxc://igm.home.arpa/t", replyTo: "$target")
        XCTAssertEqual(Timeline.replyTarget(reply), "$target")
    }

    /// The local echo is our video, still sending, with the seeded thumbnail standing in until the upload is done.
    func testLocalEchoIsAVideoUntilEchoed() {
        let local = PhotoMessage.localURL("t1")
        let content = VideoMessage.content(url: local, video: Self.video(mimetype: "video/mp4"), thumbnailURL: local)
        let pending = PendingMessage(txnID: "t1", content: content, ts: 5, state: .sending)
        let echoing = Timeline.reduce([], me: Fixture.me, pending: [pending])
        XCTAssertEqual(echoing.map(\.kind), [.video])
        XCTAssertEqual(echoing.first?.status, .sending)
        XCTAssertEqual(MediaInfo(content: echoing[0].content).previewURL, local)
    }

    // MARK: Preparing a picked movie (AVFoundation)

    /// An iPhone-style portrait movie (landscape pixels plus a 90° transform) within the limit keeps its container and
    /// codec, comes out portrait with a JPEG thumbnail, and loses its location (like photos, DESIGN §6.9).
    func testSmallMovieKeepsItsFormatAndLosesItsLocation() async throws {
        let movie = try await Self.movie(width: 320, height: 240, type: .mov, rotated: true, location: true)
        defer { try? FileManager.default.removeItem(at: movie) }
        let before = try await AVURLAsset(url: movie).load(.metadata)
        XCTAssertTrue(before.contains { $0.identifier == .quickTimeMetadataLocationISO6709 }, "the input should carry a location")

        let video = try await VideoMessage.prepare(movie)
        defer { try? FileManager.default.removeItem(at: video.file) }
        XCTAssertNotEqual(video.file, movie)
        XCTAssertEqual(video.mimetype, "video/quicktime")
        XCTAssertEqual([video.width, video.height], [240, 320])
        XCTAssertEqual(Double(video.duration), 1000, accuracy: 150)
        XCTAssertEqual(video.size, try Self.size(video.file))
        XCTAssertEqual(Array(video.thumbnail.data.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual([video.thumbnail.width, video.thumbnail.height], [240, 320])
        let after = try await AVURLAsset(url: video.file).load(.metadata)
        XCTAssertFalse(after.contains { $0.identifier == .quickTimeMetadataLocationISO6709 })
    }

    /// An m4v (not a type we pass through) is re-encoded to MP4, also without its location.
    func testOtherContainersBecomeMP4() async throws {
        let movie = try await Self.movie(width: 160, height: 120, type: .m4v, location: true)
        defer { try? FileManager.default.removeItem(at: movie) }
        let video = try await VideoMessage.prepare(movie)
        defer { try? FileManager.default.removeItem(at: video.file) }
        XCTAssertEqual(video.mimetype, "video/mp4")
        XCTAssertEqual(video.file.pathExtension, "mp4")
        XCTAssertEqual([video.width, video.height], [160, 120])
        let after = try await AVURLAsset(url: video.file).load(.metadata)
        XCTAssertFalse(after.contains { $0.identifier == .quickTimeMetadataLocationISO6709 })
    }

    func testTooBigAtEveryPresetIsTooLong() async throws {
        let movie = try await Self.movie(width: 160, height: 120, type: .mov)
        defer { try? FileManager.default.removeItem(at: movie) }
        do {
            _ = try await VideoMessage.prepare(movie, maxBytes: 100)
            XCTFail("expected tooLong")
        } catch VideoMessage.Failure.tooLong {}
    }

    // MARK: Helpers

    private static func video(mimetype: String) -> VideoMessage.Video {
        VideoMessage.Video(file: URL(fileURLWithPath: "/tmp/v"), mimetype: mimetype, size: 1_234_567, width: 1080, height: 1920,
                           duration: 12_345, thumbnail: PhotoMessage.Encoded(data: Data(count: 4321), width: 450, height: 800))
    }

    private static func size(_ file: URL) throws -> Int {
        try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    /// One second of H.264 at 10 fps, grey frames getting lighter. `rotated` adds a 90° transform the way an iPhone
    /// stores portrait video; `location` a QuickTime ISO 6709 location (Greenwich).
    private static func movie(width: Int, height: Int, type: AVFileType, rotated: Bool = false, location: Bool = false) async throws -> URL {
        let ext = type == .mov ? "mov" : type == .m4v ? "m4v" : "mp4"
        let url = URL.temporaryDirectory.appending(path: "test-\(UUID().uuidString).\(ext)")
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        if location {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.value = "+51.4769+000.0005/" as NSString
            item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
            writer.metadata = [item]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(60 + frame * 15), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 10, timescale: 10))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }
}
