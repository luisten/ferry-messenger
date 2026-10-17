import SwiftUI
import UniformTypeIdentifiers

/// Instagram's media for the UI, from its CDN links (no auth; they expire, which P5's refresh covers). Thumbnails
/// (profile pictures, previews) are kept in memory and load as rows appear; full media downloads only on tap, to
/// `Caches/media/<name>.<ext>` (PLAN §2.7), with progress and in-flight dedupe, and plays from there.
@Observable
final class MediaCache {
    /// Downloads in flight: fraction done (0…1) by URL. The cards' progress rings read it.
    private(set) var progress: [String: Double] = [:]
    /// URLs whose last download failed (the card offers a retry).
    private(set) var failed: Set<String> = []

    /// Bounded: a long scroll through media-heavy threads would otherwise keep every thumbnail for the whole launch.
    /// The cost is the decoded size in bytes.
    @ObservationIgnored private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 64 << 20
        return cache
    }()
    @ObservationIgnored private var loading: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var downloads: [String: Task<URL, any Error>] = [:]
    /// GIFs (by URL) that have had their three plays this launch.
    @ObservationIgnored var playedGIFs: Set<String> = []

    nonisolated static let directory = URL.cachesDirectory.appending(path: "media", directoryHint: .isDirectory)

    init() {
        Task.detached(priority: .utility) { Self.trim() }  // at launch: AppModel makes one per run
    }

    // MARK: Thumbnails (memory)

    /// A seeded image (a photo we're sending) stands in for any size, so its bubble never flashes empty.
    func cached(_ url: String, pixels: Int) -> UIImage? {
        images.object(forKey: "\(url)#\(pixels)" as NSString) ?? images.object(forKey: "\(url)#seed" as NSString)
    }

    /// Shows `image` for `url` (a `local:` stand-in while uploading, then the real link) without a download.
    func seed(_ image: UIImage, for url: String) {
        let bytes = (image.cgImage.map { $0.bytesPerRow * $0.height }) ?? 0
        images.setObject(image, forKey: "\(url)#seed" as NSString, cost: bytes)
    }

    /// Files a photo we just uploaded as if it had been downloaded, so tapping it opens at once.
    func store(_ data: Data, url: String, mimetype: String) {
        guard let name = Self.fileName(url: url, mimetype: mimetype) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.directory.appending(path: name), options: .atomic)
    }

    /// The same for a video or voice note we just uploaded: its file moves into the cache (no second copy).
    func store(file: URL, url: String, mimetype: String) {
        guard let name = Self.fileName(url: url, mimetype: mimetype) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: file, to: Self.directory.appending(path: name))
    }

    func thumbnail(_ url: String, pixels: Int) async -> UIImage? {
        let key = "\(url)#\(pixels)"
        if let image = cached(url, pixels: pixels) { return image }
        if let task = loading[key] { return await task.value }
        let task = Task { await Self.image(url) }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image {  // a failure isn't stored, so the next appearance retries
            let bytes = (image.cgImage.map { $0.bytesPerRow * $0.height }) ?? pixels * pixels * 4
            images.setObject(image, forKey: key as NSString, cost: bytes)
        }
        return image
    }

    /// Forgets every image and file (cancels downloads in flight).
    func clear() {
        for task in downloads.values { task.cancel() }
        images.removeAllObjects()
        failed.removeAll()
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: Files (Caches/media)

    /// The file from an earlier download (this launch or a previous one), if the OS hasn't purged it.
    func localFile(_ url: String, mimetype: String?) -> URL? {
        guard let name = Self.fileName(url: url, mimetype: mimetype) else { return nil }
        let url = Self.directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path()) ? url : nil
    }

    /// The media as a local file: cached, or downloaded now (one download per URI, however many callers). The
    /// download isn't tied to the caller's task, so a lazy row re-creating itself can't cancel it (CLAUDE.md);
    /// `cancel` does.
    func file(_ mxc: String, mimetype: String?) async throws -> URL {
        if let local = localFile(mxc, mimetype: mimetype) {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: local.path())  // recently used, for `trim`
            return local
        }
        if let running = downloads[mxc] { return try await running.value }
        guard let name = Self.fileName(url: mxc, mimetype: mimetype), let remote = URL(string: mxc) else { throw URLError(.badURL) }
        let request = URLRequest(url: remote)
        let destination = Self.directory.appending(path: name)
        let task = Task { [weak self] in
            try await Self.download(request, to: destination) { fraction in
                Task { @MainActor in if self?.downloads[mxc] != nil { self?.progress[mxc] = fraction } }
            }
            return destination
        }
        downloads[mxc] = task
        progress[mxc] = 0
        failed.remove(mxc)
        defer {
            downloads[mxc] = nil
            progress[mxc] = nil
        }
        do {
            let file = try await task.value
            Task.detached(priority: .utility) { Self.trim() }
            return file
        } catch {
            if !task.isCancelled { failed.insert(mxc) }
            throw error
        }
    }

    func cancel(_ mxc: String) { downloads[mxc]?.cancel() }

    /// Keeps the folder bounded instead of leaving it all to the OS: over `ceiling`, deletes the least recently used
    /// files (modification date; `file` touches a file it opens from here) until under `target`.
    /// ponytail: 500 MB ceiling, trimmed to 400 MB; a full scan of the folder, run at launch and after each download.
    nonisolated static func trim(_ folder: URL = directory, ceiling: Int = 500_000_000, target: Int = 400_000_000) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let files = urls.compactMap { url -> (url: URL, used: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let size = values.fileSize else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, size)
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > ceiling else { return }
        for file in files.sorted(by: { $0.used < $1.used }) where total > target {
            if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }

    /// A thumbnail: Instagram's CDN serves each picture at one size, so `pixels` only keys the memory cache.
    @concurrent private static func image(_ string: String) async -> UIImage? {
        guard let url = URL(string: string), url.scheme == "https",
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }

    /// Written to a temporary file and moved into place when complete, so a file in the cache is always whole.
    @concurrent private static func download(_ request: URLRequest, to destination: URL,
                                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let (temporary, response) = try await URLSession.shared.download(for: request, delegate: ProgressDelegate(report: progress))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Instagram returned HTTP \(status)."])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// `<name>.<ext from mimetype>`: an Instagram CDN link's file name (`https`), or an `mxc://server/id`'s ID (fixtures,
    /// the bridge's media). Nil for anything else and for names with more than letters, digits, `_` and `-`, so a
    /// name can never point outside the cache folder.
    nonisolated static func fileName(url string: String, mimetype: String?) -> String? {
        guard let url = URL(string: string), url.host() != nil else { return nil }
        let id = switch url.scheme {
        case "https": url.deletingPathExtension().lastPathComponent
        case "mxc": String(url.path().dropFirst())
        default: ""
        }
        guard id.wholeMatch(of: /[A-Za-z0-9_\-]+/) != nil else { return nil }
        return "\(id).\(fileExtension(mimetype))"
    }

    /// AVFoundation picks the format by extension (PLAN P3).
    nonisolated static func fileExtension(_ mimetype: String?) -> String {
        let type = mimetype?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch type {
        case "audio/ogg": return "ogg"
        case "audio/mp4": return "m4a"
        case "image/jpeg": return "jpg"
        default: return UTType(mimeType: type)?.preferredFilenameExtension ?? "bin"
        }
    }
}

/// Progress for one download. The async download API sends no progress callbacks, but the task's `progress`
/// updates; reported in 1% steps so the main actor isn't flooded.
nonisolated private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?
    private var lastPercent = -1

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            guard let self, Int(progress.fractionCompleted * 100) != lastPercent else { return }
            lastPercent = Int(progress.fractionCompleted * 100)
            report(progress.fractionCompleted)
        }
    }
}

/// A round thumbnail for a picture's link, with an initial on gray until (or unless) it loads.
struct MXCImage: View {
    @Environment(AppModel.self) private var model
    let mxc: String?
    let size: CGFloat
    var initial = ""
    /// Drawn instead of the initial when there's no picture (a group's people glyph).
    var symbol: String?
    @State private var loaded: UIImage?

    private var pixels: Int { Int(size * 3) }

    var body: some View {
        ZStack {
            if let image = loaded ?? mxc.flatMap({ model.media.cached($0, pixels: pixels) }) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let symbol {
                Color(.tertiarySystemFill)
                Image(systemName: symbol).font(.system(size: size * 0.5)).foregroundStyle(Color(.secondaryLabel))
                    .frame(width: size * 0.7, height: size * 0.7)  // a wide glyph at half the size stays inside the circle
            } else {
                Color(.systemGray5)
                Text(initial.prefix(1).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(.secondaryLabel))  // not .secondary: inside a button that would take the tint
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
        .task(id: mxc) {
            guard let mxc else { loaded = nil; return }
            loaded = await model.media.thumbnail(mxc, pixels: pixels)
        }
    }
}

/// A chat's picture. A group without one gets the people glyph: its name's initial looked like a contact called "S"
/// (review 2026-10-15 #9).
struct RoomAvatar: View {
    let room: Room
    let size: CGFloat

    var body: some View {
        MXCImage(mxc: room.avatarURL, size: size, initial: room.name, symbol: room.bridge?.roomType == .group ? "person.2.fill" : nil)
    }
}

/// A rectangular thumbnail filling its frame (media cards); `placeholder` until it loads.
struct MXCThumbnail: View {
    @Environment(AppModel.self) private var model
    let mxc: String?
    /// The size it's shown at, in pixels (keys the memory cache).
    let pixels: Int
    var placeholder = Color(.systemGray5)
    @State private var loaded: UIImage?

    var body: some View {
        placeholder
            .overlay {
                if let image = loaded ?? mxc.flatMap({ model.media.cached($0, pixels: pixels) }) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: mxc) {
                guard let mxc else { return }
                loaded = await model.media.thumbnail(mxc, pixels: pixels)
            }
    }
}
