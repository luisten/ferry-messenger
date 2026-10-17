import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Sending a photo (DESIGN §6.9): re-encode to JPEG within Instagram's limit, then an `m.image` with `info`. The
/// bridge takes jpeg/png/gif/webp up to 8 MB and drops captions (research/matrix-bridge.md §4), so there's no
/// caption field. Pure, so it's unit-tested.
nonisolated enum PhotoMessage {
    static let maxBytes = 8_000_000  // the bridge's MaxImageSize is decimal, not MiB
    /// The most a linked GIF may weigh before it's written again (`gif`), which must still fit `maxBytes`.
    static let maxSource = 20_000_000
    /// Longest side. Instagram shows DM photos at about 1080 px; 2048 keeps a sharp, zoomable copy far under 8 MB.
    static let maxPixels = 2048
    static let mimetype = "image/jpeg"
    static let filename = "photo.jpg"

    struct Encoded: Equatable, Sendable {
        var data: Data
        var width: Int
        var height: Int
        var mimetype = PhotoMessage.mimetype

        var isGIF: Bool { mimetype == "image/gif" }
    }

    enum Failure: LocalizedError {
        case unreadable, tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: "That photo couldn't be read."
            case .tooLarge: "That photo is too large to send, even compressed."
            }
        }
    }

    /// Any image ImageIO reads (HEIC, PNG, JPEG, a GIF's first frame) → JPEG, longest side ≤ `maxPixels`, ≤ `maxBytes`.
    /// The EXIF orientation is applied to the pixels, and no metadata is copied, so location never leaves the phone.
    static func encode(_ source: Data, maxPixels: Int = maxPixels, maxBytes: Int = maxBytes) throws -> Encoded {
        guard let reader = CGImageSourceCreateWithData(source as CFData, nil) else { throw Failure.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(reader, 0, options as CFDictionary) else { throw Failure.unreadable }
        if hasAlpha(image) { image = try flattened(image) }  // JPEG has no alpha: transparent areas would turn black
        for quality in [0.85, 0.7, 0.5] {
            guard let data = jpeg(image, quality: quality) else { throw Failure.unreadable }
            if data.count <= maxBytes { return Encoded(data: data, width: image.width, height: image.height) }
        }
        throw Failure.tooLarge
    }

    /// An animated GIF (or animated WebP, from a link) goes as a GIF (Instagram makes it one of its own GIFs, seen live),
    /// written again frame by frame with only each frame's delay, so no metadata leaves the phone. Nil when `source`
    /// isn't animated: a still image goes through `encode`.
    /// ponytail: every frame is written as it is; scale frames down if real GIFs come out over `maxBytes`.
    static func gif(_ source: Data, maxBytes: Int = maxBytes) throws -> Encoded? {
        guard let reader = CGImageSourceCreateWithData(source as CFData, nil),
              [UTType.gif.identifier, UTType.webP.identifier].contains(CGImageSourceGetType(reader) as String? ?? ""),
              case let count = CGImageSourceGetCount(reader), count > 1 else { return nil }
        let out = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, count, nil),
              let first = CGImageSourceCreateImageAtIndex(reader, 0, nil) else { throw Failure.unreadable }
        CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(reader, index, nil) else { throw Failure.unreadable }
            let delay = AnimatedFrames.delay(reader, index)
            CGImageDestinationAddImage(writer, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(writer) else { throw Failure.unreadable }
        guard out.length <= maxBytes else { throw Failure.tooLarge }
        return Encoded(data: out as Data, width: first.width, height: first.height, mimetype: "image/gif")
    }

    /// A message that is nothing but an `https` link to a `.gif` or `.webp` (what "Copy image address" gives for a GIF).
    static func gifLink(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), url.scheme == "https", url.host() != nil,
              ["gif", "webp"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    /// The image as JPEG, no metadata (also a video's thumbnail).
    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(writer) ? out as Data : nil
    }

    /// The `m.image` content (and, with a `local:` URL, the local echo's). `replyTo` makes it a reply.
    static func content(url: String, photo: Encoded, replyTo: String? = nil) -> JSON {
        var fields: [String: JSON] = [
            "msgtype": "m.image",
            "body": .string(photo.isGIF ? "photo.gif" : filename),
            "url": .string(url),
            "info": [
                "mimetype": .string(photo.mimetype),
                "size": .number(Double(photo.data.count)),
                "w": .number(Double(photo.width)),
                "h": .number(Double(photo.height)),
                "fi.mau.gif": .bool(photo.isGIF),
            ],
        ]
        if let replyTo { fields["m.relates_to"] = ["m.in_reply_to": ["event_id": .string(replyTo)]] }
        return .object(fields)
    }

    /// Stands in for the `mxc://` URL in a local echo until the upload is done; `MediaCache` holds its preview.
    static func localURL(_ txnID: String) -> String { "local:\(txnID)" }

    static func isLocal(_ url: String?) -> Bool { url?.hasPrefix("local:") == true }

    static func file(_ txnID: String, _ photo: Encoded) -> URL {
        URL.temporaryDirectory.appending(path: "photo-\(txnID).\(MediaCache.fileExtension(photo.mimetype))")
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private static func flattened(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.unreadable }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { throw Failure.unreadable }
        return flat
    }
}

/// GIFs and animated WebP (Instagram's GIFs) as frames and their delays, for the card to play a set number of times:
/// decoded once, at most 360 px (cards are 240 pt and GIFs are small), and only the first `maxFrames`.
/// ponytail: every frame stays decoded while the card is on screen; decode as it plays (`CGAnimateImageAtURLWithBlock`)
/// if long GIFs use too much memory.
nonisolated enum AnimatedFrames {
    static let maxFrames = 150

    struct Clip: Sendable {
        var frames: [UIImage]
        var delays: [Double]

        var duration: Double { delays.reduce(0, +) }

        /// The frame to show `elapsed` seconds into `loops` plays in a row; nil once they're over.
        func frame(at elapsed: Double, loops: Int) -> Int? {
            guard duration > 0, elapsed >= 0, elapsed < duration * Double(loops) else { return nil }
            var time = elapsed.truncatingRemainder(dividingBy: duration)
            for (index, delay) in delays.enumerated() {
                if time < delay { return index }
                time -= delay
            }
            return delays.count - 1
        }
    }

    @concurrent static func clip(_ file: URL) async -> Clip? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 360] as CFDictionary
        var clip = Clip(frames: [], delays: [])
        for index in 0..<min(CGImageSourceGetCount(source), maxFrames) {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            clip.frames.append(UIImage(cgImage: frame))
            clip.delays.append(delay(source, index))
        }
        return clip.frames.isEmpty ? nil : clip
    }

    /// A frame's delay in seconds; under 20 ms counts as 100 ms, as browsers play them.
    static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let webp = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]
            ?? webp?[kCGImagePropertyWebPUnclampedDelayTime] ?? webp?[kCGImagePropertyWebPDelayTime]) as? Double ?? 0.1
        return delay < 0.02 ? 0.1 : delay
    }
}
