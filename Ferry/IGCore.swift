import Foundation
import IGCore

/// `core/`'s C API (docs/PLAN-core.md §3, docs/PLAN-android.md stage 1): one Instagram client per account, chats named
/// by their room ID, and every change to a chat as an update from `nextUpdates`. Every call can wait on the network,
/// so they all run off the main actor. Nothing here logs what crosses it: cookies, message text.
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
    /// then the live socket. The same account again replaces its client; its chats stay.
    @concurrent static func login(cookies: [String: String]) async throws -> IG.Login {
        let json = String(decoding: try JSONEncoder().encode(cookies), as: UTF8.self)
        return try IG.decode(IG.Login.self, result(call([json]) { IGLogin($0[0]) }))
    }

    /// The session's cookies as they are now (Instagram rotates some), for the Keychain only (decision C3).
    @concurrent static func session(_ account: String) async -> [String: String]? {
        guard let text = call([account], { IGSession($0[0]) }), let data = try? result(text) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// One page of a mailbox folder (`INBOX`, `PENDING`, `GENERAL`) after `cursor`; its chats arrive as updates.
    /// Returns the next page's cursor, nil at the end.
    @concurrent static func inboxPage(_ account: String, folder: String, cursor: String) async throws -> String? {
        try answer(call([account, folder, cursor]) { IGInboxPage($0[0], $0[1], $0[2]) }).next
    }

    /// The chat read in full (it arrives as an update, up to the returned `seq`). A read; it sends nothing.
    @concurrent static func readChat(_ room: String) async throws -> Int {
        try answer(call([room]) { IGReadChat($0[0]) }).seq ?? 0
    }

    /// The page before the room's window (also kept by the engine). A read.
    @concurrent static func older(_ room: String) async throws -> MessagesPage {
        try JSONDecoder().decode(MessagesPage.self, from: result(call([room]) { IGOlder($0[0]) }))
    }

    /// Sends a text (a reply when `replyTo`), returning Instagram's ID for it. `otid` is the local echo's offline
    /// threading ID; the socket's echo of the message carries it back.
    @concurrent static func send(_ room: String, text: String, replyTo: String?, otid: String) async throws -> String? {
        try answer(call([room, text, replyTo ?? "", otid]) { IGSend($0[0], $0[1], $0[2], $0[3]) }).id.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The first message to someone we have no thread with (`recipient`, their FBID): Instagram makes the thread, and
    /// it arrives through the socket like any new one.
    @concurrent static func sendNew(_ account: String, recipient: String, text: String, otid: String) async throws {
        _ = try result(call([account, recipient, text, otid]) { IGSendNew($0[0], $0[1], $0[2], $0[3]) })
    }

    /// A new offline threading ID for a local echo (no network).
    static func newOTID() -> String { call([]) { _ in IGNewOTID() } ?? "" }

    @concurrent static func accept(_ room: String, otid: String) async throws {
        _ = try result(call([room, otid]) { IGAccept($0[0], $0[1]) })
    }

    /// A request's Delete: the thread goes for this account on Instagram too, and its room here.
    @concurrent static func deleteThread(_ room: String) async throws {
        _ = try result(call([room]) { IGDeleteThread($0[0]) })
    }

    /// N1's search, as `account` (an Instagram request: the sheet debounces).
    @concurrent static func search(_ account: String, query: String) async throws -> [BridgeAPI.Contact] {
        try JSONDecoder().decode([BridgeAPI.Contact].self, from: result(call([account, query]) { IGSearch($0[0], $0[1]) }))
    }

    /// Our DM with `user` (their FBID), if Instagram has one: its room, read in full (an update, up to `seq`).
    @concurrent static func findDM(_ account: String, user: String) async throws -> (room: String, seq: Int)? {
        let found = try answer(call([account, user]) { IGFindDM($0[0], $0[1]) })
        guard found.found == true, let room = found.room else { return nil }
        return (room, found.seq ?? 0)
    }

    /// A photo, video or voice note from `file`: uploaded for the chat's thread, then sent to it.
    @concurrent static func sendMedia(_ room: String, file: URL, mimetype: String, voice: Bool, replyTo: String?, otid: String) async throws {
        _ = try result(call([room, file.path, mimetype, replyTo ?? "", otid]) {
            IGSendMedia($0[0], $0[1], $0[2], voice ? 1 : 0, $0[3], $0[4])
        })
    }

    /// "Load video": a share's own media (a reel's video, a post's image) in place of its card, as an update up to the
    /// returned `seq`. A read.
    @concurrent static func resolveMedia(_ room: String, message: String) async throws -> Int {
        try answer(call([room, message]) { IGResolveMedia($0[0], $0[1]) }).seq ?? 0
    }

    /// Adds our reaction, or removes it (`remove`; Instagram keeps one per person, so another emoji replaces it).
    @concurrent static func react(_ room: String, message: String, emoji: String, remove: Bool) async throws {
        _ = try result(call([room, message, emoji]) { IGReact($0[0], $0[1], $0[2], remove ? 1 : 0) })
    }

    @concurrent static func edit(_ room: String, message: String, text: String, otid: String) async throws {
        _ = try result(call([room, message, text, otid]) { IGEdit($0[0], $0[1], $0[2], $0[3]) })
    }

    /// Unsend, for everyone.
    @concurrent static func unsend(_ room: String, message: String) async throws {
        _ = try result(call([room, message]) { IGUnsend($0[0], $0[1]) })
    }

    @concurrent static func typing(_ room: String, on: Bool) async throws {
        _ = try result(call([room]) { IGTyping($0[0], on ? 1 : 0) })
    }

    /// "Seen" up to `message`: the two requests the bridge made. The chat reads at once (an update); if Instagram
    /// refuses, it's unread again. Never in a request (C7).
    @concurrent static func markRead(_ room: String, message: String) async throws {
        _ = try result(call([room, message]) { IGMarkRead($0[0], $0[1]) })
    }

    /// Disconnects the account and forgets its client and chats (Remove Account). Instagram isn't told.
    @concurrent static func stop(_ account: String) async {
        _ = call([account]) { IGStop($0[0]); return nil }
    }

    /// Everything that happened since the last call, in order (empty after `timeout` without anything).
    @concurrent static func nextUpdates(timeout: Duration) async -> [IG.Update] {
        let ms = Int32(timeout / .milliseconds(1))
        guard let text = call([], { _ in IGNextEvent(ms) }) else { return [] }
        return (try? JSONDecoder().decode([IG.Update].self, from: Data(text.utf8))) ?? []
    }

    /// Requests made per account since login, by operation (C6).
    static func counts() -> String { call([]) { _ in IGCounts() } ?? "{}" }

    #if DEBUG
    /// `FERRY_DEBUG_CAPTURE=<host dir>`: Instagram's answers are also written there, for fixtures.
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

    private static func answer(_ text: String?) throws -> IG.Result {
        try JSONDecoder().decode(IG.Result.self, from: result(text))
    }
}
