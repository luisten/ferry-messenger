import Foundation
import IGCore

/// `core/`'s C API (docs/PLAN-core.md §3): one Instagram client per account, Instagram's own JSON in and out (decoded
/// with `IG`). Every call can wait on the network, so they all run off the main actor. Nothing here logs what
/// crosses it: cookies, message text.
nonisolated enum IGCore {
    /// A failure from `core/`. `code` uses the bridge's state names, so `BridgeAPI.Login.Health` reads it as before:
    /// `BAD_CREDENTIALS` (Instagram wants a new login; `reason` says why: `logged_out`, `challenge`, `checkpoint`,
    /// `consent`, `suspended`), `TRANSIENT_DISCONNECT` (the network), or `UNKNOWN_ERROR`.
    struct Failure: LocalizedError, Equatable, Sendable {
        var message: String
        var code: String?
        var reason: String?

        var errorDescription: String? { message }
    }

    /// Logs in with the cookies from the web view (or, at launch, the Keychain's): Instagram's index and mailbox,
    /// then the live socket. Returns `IG.Login`; the same account again replaces its client.
    @concurrent static func login(cookies: [String: String]) async throws -> Data {
        let json = String(decoding: try JSONEncoder().encode(cookies), as: UTF8.self)
        return try result(call([json]) { IGLogin($0[0]) })
    }

    /// The session's cookies as they are now (Instagram rotates some), for the Keychain only (decision C3).
    @concurrent static func session(_ account: String) async -> [String: String]? {
        guard let text = call([account], { IGSession($0[0]) }), let data = try? result(text) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// One page of a mailbox folder (`INBOX`, `PENDING`, `GENERAL`) after `cursor`: `IG.MailboxPage`.
    @concurrent static func inboxPage(_ account: String, folder: String, cursor: String) async throws -> Data {
        try result(call([account, folder, cursor]) { IGInboxPage($0[0], $0[1], $0[2]) })
    }

    /// A thread with its newest messages: `IG.ThreadResponse`. A read; it sends nothing.
    @concurrent static func thread(_ account: String, _ thread: String) async throws -> Data {
        try result(call([account, thread]) { IGThread($0[0], $0[1]) })
    }

    /// The page after `cursor`, else the messages older than `message`: `IG.OlderResponse`. A read.
    @concurrent static func older(_ account: String, _ thread: String, cursor: String, message: String = "") async throws -> Data {
        try result(call([account, thread, cursor, message]) { IGOlder($0[0], $0[1], $0[2], $0[3]) })
    }

    /// Sends a text (a reply when `replyTo`), returning Instagram's message: `IG.SendResponse`. `otid` is the local
    /// echo's offline threading ID; the socket's echo of the message carries it back.
    @concurrent static func send(_ account: String, thread: String, text: String, replyTo: String?, otid: String) async throws -> Data {
        try result(call([account, thread, text, replyTo ?? "", otid]) { IGSend($0[0], $0[1], $0[2], $0[3], $0[4]) })
    }

    /// The first message to someone we have no thread with (`recipient`, their FBID): Instagram makes the thread, and
    /// it arrives through the socket like any new one.
    @concurrent static func sendNew(_ account: String, recipient: String, text: String, otid: String) async throws {
        _ = try result(call([account, recipient, text, otid]) { IGSendNew($0[0], $0[1], $0[2], $0[3]) })
    }

    @concurrent static func accept(_ account: String, thread: String, otid: String) async throws {
        _ = try result(call([account, thread, otid]) { IGAccept($0[0], $0[1], $0[2]) })
    }

    /// A request's Delete: the thread goes for this account on Instagram too.
    @concurrent static func deleteThread(_ account: String, thread: String) async throws {
        _ = try result(call([account, thread]) { IGDeleteThread($0[0], $0[1]) })
    }

    /// N1's search, as `account` (an Instagram request: the sheet debounces): `IG.SearchResponse`.
    @concurrent static func search(_ account: String, query: String) async throws -> Data {
        try result(call([account, query]) { IGSearch($0[0], $0[1]) })
    }

    /// Our DM with `user` (their FBID), if Instagram has one: `IG.FoundDM`.
    @concurrent static func findDM(_ account: String, user: String) async throws -> Data {
        try result(call([account, user]) { IGFindDM($0[0], $0[1]) })
    }

    /// A photo, video or voice note from `file`: uploaded for the thread (`threadKey`), then sent to it (`thread`).
    @concurrent static func sendMedia(_ account: String, threadKey: String, thread: String, file: URL, mimetype: String, voice: Bool,
                                      replyTo: String?, otid: String) async throws {
        _ = try result(call([account, threadKey, thread, file.path, mimetype, replyTo ?? "", otid]) {
            IGSendMedia($0[0], $0[1], $0[2], $0[3], $0[4], voice ? 1 : 0, $0[5], $0[6])
        })
    }

    /// A share's own media (a reel's video, a post's image): `IG.Resolved`. A read.
    @concurrent static func resolveMedia(_ account: String, target: String, id: String) async throws -> Data {
        try result(call([account, target, id]) { IGResolveMedia($0[0], $0[1], $0[2]) })
    }

    /// Adds our reaction, or removes it (`remove`; Instagram keeps one per person, so another emoji replaces it).
    @concurrent static func react(_ account: String, thread: String, message: String, emoji: String, remove: Bool) async throws {
        _ = try result(call([account, thread, message, emoji]) { IGReact($0[0], $0[1], $0[2], $0[3], remove ? 1 : 0) })
    }

    @concurrent static func edit(_ account: String, thread: String, message: String, text: String, otid: String) async throws {
        _ = try result(call([account, thread, message, text, otid]) { IGEdit($0[0], $0[1], $0[2], $0[3], $0[4]) })
    }

    /// Unsend, for everyone. Instagram names the thread by its long ID here (P0).
    @concurrent static func unsend(_ account: String, threadLong: String, message: String) async throws {
        _ = try result(call([account, threadLong, message]) { IGUnsend($0[0], $0[1], $0[2]) })
    }

    @concurrent static func typing(_ account: String, thread: String, on: Bool) async throws {
        _ = try result(call([account, thread]) { IGTyping($0[0], $0[1], on ? 1 : 0) })
    }

    /// "Seen" up to `message` (sent at `ms`): the two requests the bridge made. Never in a request (C7).
    @concurrent static func markRead(_ account: String, threadLong: String, message: String, ms: Int64) async throws {
        _ = try result(call([account, threadLong, message]) { IGMarkRead($0[0], $0[1], $0[2], ms) })
    }

    /// Disconnects the account and forgets its client (Remove Account). Instagram isn't told.
    @concurrent static func stop(_ account: String) async {
        _ = call([account]) { IGStop($0[0]); return nil }
    }

    /// The next event from any account (`IG.Event`), or nil after `timeout` without one.
    @concurrent static func nextEvent(timeout: Duration) async -> Data? {
        let ms = Int32(timeout / .milliseconds(1))
        return call([]) { _ in IGNextEvent(ms) }.map { Data($0.utf8) }
    }

    /// Requests made per account since login, by operation (C6).
    static func counts() -> String { call([]) { _ in IGCounts() } ?? "{}" }

    #if DEBUG
    /// `FERRY_DEBUG_CAPTURE=<host dir>`: everything `core/` hands over is also written there, for fixtures.
    static func capture(to dir: String) { _ = call([dir]) { IGSetCapture($0[0]); return nil } }
    #endif

    /// Calls `core/` with C strings and returns its JSON text.
    private static func call(_ args: [String], _ f: ([UnsafeMutablePointer<CChar>]) -> UnsafeMutablePointer<CChar>?) -> String? {
        let pointers = args.map { strdup($0)! }
        defer { pointers.forEach { free($0) } }
        guard let out = f(pointers) else { return nil }
        defer { IGFree(out) }
        return String(cString: out)
    }

    private struct ErrorBody: Decodable {
        var error: String?
        var code: String?
        var reason: String?
    }

    private static func result(_ text: String?) throws -> Data {
        guard let text else { throw Failure(message: "core/ returned nothing.", code: "UNKNOWN_ERROR") }
        let data = Data(text.utf8)
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: data), let message = body.error {
            throw Failure(message: message, code: body.code, reason: body.reason)
        }
        return data
    }
}
