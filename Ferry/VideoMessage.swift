import AVFoundation
import CoreTransferable
import ImageIO
import UniformTypeIdentifiers

/// Sending a video (DESIGN §6.9): fit Instagram's limit, then an `m.video` with `info` and a thumbnail (our own card
/// shows it). The bridge takes mp4/mov/webm/ogg up to 25 × 1000 × 1000 bytes and drops captions (igconnector
/// `capabilities.go`; it refuses a bigger `info.size` before uploading). Videos stay files from the picker to the
/// upload: never read into memory.
nonisolated enum VideoMessage {
    static let maxBytes = 25_000_000
    /// Containers Instagram takes that Photos hands over: sent with their own codec, only remuxed to drop metadata.
    static let passThroughTypes: Set<String> = ["video/mp4", "video/quicktime"]
    /// H.264 MP4 re-encodes, largest first, until one fits. Instagram plays DM videos at about 720p anyway.
    static let presets = [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPreset640x480]
    /// The thumbnail's longest side: the card is 220 pt wide at 3×.
    static let thumbnailPixels = 720

    /// A video ready to upload: its file (ours, in the temporary folder) and what the event says about it.
    struct Video: Equatable, Sendable {
        var file: URL
        var mimetype: String
        var size: Int
        var width: Int
        var height: Int
        /// Milliseconds.
        var duration: Int
        var thumbnail: PhotoMessage.Encoded

        /// The event's `body`; the bridge names the Instagram upload after it.
        var filename: String { mimetype == "video/quicktime" ? "video.mov" : "video.mp4" }
    }

    enum Step: Equatable {
        case send
        case export(String)
        case tooLong
    }

    enum Failure: LocalizedError {
        case unreadable, tooLong

        var errorDescription: String? {
            switch self {
            case .unreadable: "That video couldn't be read."
            case .tooLong: "This video is too long to send to Instagram. Trim it first."
            }
        }
    }

    /// What to do with the picked movie (`exports == 0`) or with the result of the `exports`-th re-encode (always MP4).
    static func next(size: Int, mimetype: String?, exports: Int, maxBytes: Int = maxBytes) -> Step {
        if let mimetype, passThroughTypes.contains(mimetype), size <= maxBytes { return .send }
        return exports < presets.count ? .export(presets[exports]) : .tooLong
    }

    static func mimetype(ofExtension ext: String) -> String? {
        UTType(filenameExtension: ext.lowercased())?.preferredMIMEType
    }

    /// The `m.video` content (and, with `local:` URLs, the local echo's). `replyTo` makes it a reply.
    static func content(url: String, video: Video, thumbnailURL: String, replyTo: String? = nil) -> JSON {
        var fields: [String: JSON] = [
            "msgtype": "m.video",
            "body": .string(video.filename),  // and no `filename` key, so it isn't taken for a caption
            "url": .string(url),
            "info": [
                "mimetype": .string(video.mimetype),
                "size": .number(Double(video.size)),
                "w": .number(Double(video.width)),
                "h": .number(Double(video.height)),
                "duration": .number(Double(video.duration)),
                "thumbnail_url": .string(thumbnailURL),
                "thumbnail_info": [
                    "mimetype": .string(PhotoMessage.mimetype),
                    "size": .number(Double(video.thumbnail.data.count)),
                    "w": .number(Double(video.thumbnail.width)),
                    "h": .number(Double(video.thumbnail.height)),
                ],
            ],
        ]
        if let replyTo { fields["m.relates_to"] = ["m.in_reply_to": ["event_id": .string(replyTo)]] }
        return .object(fields)
    }

    /// The picked movie → a new file that fits, with its size, pixels, duration and thumbnail. Every path goes through
    /// an export session so its metadata filter drops the location (as photos do); a pass-through only remuxes.
    /// Throws `tooLong` when even the smallest preset is over `maxBytes`. The caller deletes `picked`.
    @concurrent static func prepare(_ picked: URL, maxBytes: Int = maxBytes) async throws -> Video {
        let asset = AVURLAsset(url: picked)
        guard try await asset.load(.isReadable) else { throw Failure.unreadable }
        let original = mimetype(ofExtension: picked.pathExtension)
        var current: (file: URL?, size: Int, mimetype: String?) = (nil, try fileSize(picked), original)
        var exports = 0
        while true {
            switch next(size: current.size, mimetype: current.mimetype, exports: exports, maxBytes: maxBytes) {
            case .send:
                let mimetype = current.mimetype ?? "video/mp4"
                guard let file = current.file else {
                    // The original fits: remux it (no re-encode) and decide again on what came out.
                    let file = try await export(asset, preset: AVAssetExportPresetPassthrough, as: mimetype == "video/quicktime" ? .mov : .mp4)
                    current = (file, try fileSize(file), mimetype)
                    continue
                }
                do {
                    return try await describe(file, mimetype: mimetype)
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
            case .export(let preset):
                if let file = current.file { try? FileManager.default.removeItem(at: file) }
                let file = try await export(asset, preset: preset, as: .mp4)
                current = (file, try fileSize(file), "video/mp4")
                exports += 1
            case .tooLong:
                if let file = current.file { try? FileManager.default.removeItem(at: file) }
                throw Failure.tooLong
            }
        }
    }

    private static func export(_ asset: AVAsset, preset: String, as type: AVFileType) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw Failure.unreadable }
        session.metadataItemFilter = .forSharing()  // location and other personal tags stay on the phone
        session.shouldOptimizeForNetworkUse = true
        let file = URL.temporaryDirectory.appending(path: "video-\(UUID().uuidString).\(type == .mov ? "mov" : "mp4")")
        do {
            try await session.export(to: file, as: type)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }

    /// Display size (the track's transform applied: iPhones store portrait video as rotated landscape), duration,
    /// and a JPEG of the first frame.
    private static func describe(_ file: URL, mimetype: String) async throws -> Video {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.unreadable }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailPixels, height: thumbnailPixels)
        let (frame, _) = try await generator.image(at: .zero)
        guard let jpeg = PhotoMessage.jpeg(frame, quality: 0.8) else { throw Failure.unreadable }
        return Video(file: file, mimetype: mimetype, size: try fileSize(file), width: Int(abs(shown.width).rounded()),
                     height: Int(abs(shown.height).rounded()), duration: Int((duration.isFinite ? duration : 0) * 1000),
                     thumbnail: PhotoMessage.Encoded(data: jpeg, width: frame.width, height: frame.height))
    }

    private static func fileSize(_ file: URL) throws -> Int {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Failure.unreadable }
        return size
    }
}

/// A picked video as a file: Photos hands over a file that is only valid during the import, so it's cloned into our
/// temporary folder (APFS clone: no copy of the bytes, nothing read into memory).
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copy = URL.temporaryDirectory.appending(path: "picked-\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
