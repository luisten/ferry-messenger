import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Ferry

/// Sending photos (M7b, DESIGN §6.9): JPEG within Instagram's 8 MB, orientation applied, no metadata, no black
/// background from transparency, and the `m.image` content the bridge reads.
final class PhotoMessageTests: XCTestCase {
    func testLargeImageIsDownscaledToJPEGKeepingAspect() throws {
        let png = try Self.image(width: 4000, height: 3000, type: .png)
        let photo = try PhotoMessage.encode(png)
        XCTAssertEqual(photo.width, 2048)
        XCTAssertEqual(photo.height, 1536)
        XCTAssertEqual(Array(photo.data.prefix(2)), [0xFF, 0xD8])  // JPEG
        XCTAssertLessThanOrEqual(photo.data.count, PhotoMessage.maxBytes)
    }

    func testSmallImageIsNotUpscaled() throws {
        let photo = try PhotoMessage.encode(Self.image(width: 120, height: 80, type: .png))
        XCTAssertEqual([photo.width, photo.height], [120, 80])
    }

    /// A portrait photo stored landscape with EXIF orientation 6 (rotate 90°) comes out portrait.
    func testOrientationIsAppliedToThePixels() throws {
        let jpeg = try Self.image(width: 200, height: 100, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let photo = try PhotoMessage.encode(jpeg)
        XCTAssertEqual([photo.width, photo.height], [100, 200])
    }

    /// Location (and every other tag) stays on the phone.
    func testMetadataIsDropped() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 51.48, kCGImagePropertyGPSLongitude: 0.01]
        let jpeg = try Self.image(width: 64, height: 64, type: .jpeg, properties: [kCGImagePropertyGPSDictionary: gps])
        XCTAssertNotNil(Self.properties(jpeg)[kCGImagePropertyGPSDictionary as String], "the input should carry GPS")
        let photo = try PhotoMessage.encode(jpeg)
        XCTAssertNil(Self.properties(photo.data)[kCGImagePropertyGPSDictionary as String])
    }

    /// JPEG has no alpha; transparent pixels must become white, not black.
    func testTransparencyBecomesWhite() throws {
        let photo = try PhotoMessage.encode(Self.image(width: 32, height: 32, type: .png, alpha: 0))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(photo.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[0], 240)
        XCTAssertGreaterThan(pixel[1], 240)
        XCTAssertGreaterThan(pixel[2], 240)
    }

    func testTooLargeAndUnreadableFail() throws {
        XCTAssertThrowsError(try PhotoMessage.encode(Self.image(width: 400, height: 400, type: .png), maxBytes: 100))
        XCTAssertThrowsError(try PhotoMessage.encode(Data("not an image".utf8)))
    }

    /// The event the bridge turns into an Instagram photo: `m.image`, `url`, and `info` with size and pixels.
    func testContentIsAnImageWithInfo() throws {
        let photo = PhotoMessage.Encoded(data: Data(count: 1234), width: 2048, height: 1536)
        let content = PhotoMessage.content(url: "mxc://igm.home.arpa/abc", photo: photo)
        XCTAssertEqual(content["msgtype"], "m.image")
        XCTAssertNil(content["m.relates_to"])
        let info = MediaInfo(content: content)
        XCTAssertEqual(info.url, "mxc://igm.home.arpa/abc")
        XCTAssertEqual(info.mimetype, "image/jpeg")
        XCTAssertEqual(info.size, 1234)
        XCTAssertEqual(info.width, 2048)
        XCTAssertEqual(info.height, 1536)
        XCTAssertEqual(MessageKind(type: "m.room.message", content: content), .image)

        let reply = PhotoMessage.content(url: "mxc://igm.home.arpa/abc", photo: photo, replyTo: "$target")
        XCTAssertEqual(Timeline.replyTarget(reply), "$target")
    }

    /// The local echo shows as our photo, still sending, until sync brings the event with the same transaction ID.
    func testLocalEchoIsAnImageUntilEchoed() throws {
        let photo = PhotoMessage.Encoded(data: Data(count: 10), width: 3, height: 4)
        let url = PhotoMessage.localURL("t1")
        XCTAssertTrue(PhotoMessage.isLocal(url))
        XCTAssertFalse(PhotoMessage.isLocal("mxc://igm.home.arpa/abc"))
        let pending = PendingMessage(txnID: "t1", content: PhotoMessage.content(url: url, photo: photo), ts: 5, state: .sending)
        let echoing = Timeline.reduce([], me: Fixture.me, pending: [pending])
        XCTAssertEqual(echoing.map(\.kind), [.image])
        XCTAssertEqual(echoing.first?.status, .sending)
        XCTAssertEqual(echoing.first?.txnID, "t1")

        var echo = Event.message("$e", ts: 6, sender: Fixture.me, msgtype: "m.image")
        echo.unsigned = .init(transactionID: "t1")
        XCTAssertEqual(Timeline.reduce([echo], me: Fixture.me, pending: [pending]).map(\.id), ["$e"])
    }

    // MARK: GIFs

    /// An animated GIF stays an animated GIF, frames and delays kept (a delay under 20 ms plays as 100 ms), and is
    /// marked so the card plays it; a still GIF or any other image is left to `encode`.
    func testAnimatedGIFStaysAGIF() throws {
        let gif = try Self.gif(delays: [0.1, 0.2, 0.01])
        let photo = try XCTUnwrap(PhotoMessage.gif(gif))
        XCTAssertEqual(photo.mimetype, "image/gif")
        XCTAssertEqual([photo.width, photo.height], [40, 30])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(photo.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        XCTAssertEqual((0..<3).map { AnimatedFrames.delay(source, $0) }, [0.1, 0.2, 0.1])
        XCTAssertNil(try PhotoMessage.gif(Self.gif(delays: [0.1])))
        XCTAssertNil(try PhotoMessage.gif(Self.image(width: 10, height: 10, type: .png)))
        XCTAssertThrowsError(try PhotoMessage.gif(gif, maxBytes: 100))

        let content = PhotoMessage.content(url: "local:t1", photo: photo)
        XCTAssertEqual(MessageKind(type: "m.room.message", content: content), .gif)
        XCTAssertEqual(MediaInfo(content: content).mimetype, "image/gif")
        XCTAssertEqual(PhotoMessage.file("t1", photo).lastPathComponent, "photo-t1.gif")
        XCTAssertEqual(MessageKind(type: "m.room.message", content: PhotoMessage.content(url: "local:t2", photo: try PhotoMessage.encode(gif))), .image)
    }

    /// Only a message that is nothing but an https link to a .gif or .webp is sent as a GIF.
    func testGIFLinks() {
        XCTAssertEqual(PhotoMessage.gifLink("https://media.example.com/media/abc/giphy.gif")?.host(), "media.example.com")
        XCTAssertNotNil(PhotoMessage.gifLink("https://i.example.com/x.WEBP?cid=1"))
        XCTAssertNil(PhotoMessage.gifLink("http://media.example.com/a.gif"))
        XCTAssertNil(PhotoMessage.gifLink("look https://media.example.com/a.gif"))
        XCTAssertNil(PhotoMessage.gifLink("https://example.com/gifs/funny-cat-abc"))
        XCTAssertNil(PhotoMessage.gifLink("https://example.com/a.jpg"))
        XCTAssertNil(PhotoMessage.gifLink("a.gif"))
    }

    /// The card's frames with their delays, and which one shows when: three plays, then nothing (the card rests on its
    /// first frame); a replay is one play.
    func testAnimatedFramesPlayASetNumberOfTimes() async throws {
        let file = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString).gif")
        try Self.gif(delays: [0.1, 0.2, 0.3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let loaded = await AnimatedFrames.clip(file)
        let clip = try XCTUnwrap(loaded)
        XCTAssertEqual(clip.frames.count, 3)
        XCTAssertEqual(clip.frames.first?.size, CGSize(width: 40, height: 30))
        XCTAssertEqual(clip.duration, 0.6, accuracy: 0.001)
        XCTAssertEqual([0, 0.05, 0.15, 0.35, 0.65, 1.75].map { clip.frame(at: $0, loops: 3) }, [0, 0, 1, 2, 0, 2])
        XCTAssertNil(clip.frame(at: 1.801, loops: 3))
        XCTAssertNil(clip.frame(at: 0.601, loops: 1))
        XCTAssertNil(clip.frame(at: -1, loops: 1))
    }

    // MARK: Helpers

    /// A 40×30 GIF with one frame per delay, each a different shade, looping forever.
    private static func gif(delays: [Double]) throws -> Data {
        let out = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, delays.count, nil))
        CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, delay) in delays.enumerated() {
            let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: Double(index) / Double(delays.count), green: 0.5, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return out as Data
    }

    /// A solid image (red, or transparent with `alpha: 0`) written as PNG or JPEG with extra properties.
    private static func image(width: Int, height: Int, type: UTType, alpha: CGFloat = 1, properties: [CFString: Any] = [:]) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return out as Data
    }

    private static func properties(_ data: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }
}
