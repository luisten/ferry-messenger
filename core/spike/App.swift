// The capture app (docs/PLAN-core.md P0): libigcore with several accounts, each thread action one button, Instagram's
// answers and live events written to $FERRY_DEBUG_CAPTURE for fixtures. Started as the on-device spike.
// ponytail: one file, untyped JSON, no persistence (every launch needs the logins again). A tool, not the app.
import SwiftUI
import WebKit

private func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { IGFree(p) }
    return String(cString: p)
}

/// Calls core with C strings and returns its JSON (or nil).
private func core(_ args: [String], _ f: ([UnsafeMutablePointer<CChar>]) -> UnsafeMutablePointer<CChar>?) -> String? {
    let ptrs = args.map { strdup($0)! }
    defer { ptrs.forEach { free($0) } }
    return take(f(ptrs))
}

typealias JSON = [String: Any]
private func parse(_ s: String?) -> JSON { (s.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? JSON) ?? [:] }
private func dig(_ j: Any?, _ path: String...) -> Any? { path.reduce(j) { ($0 as? JSON)?[$1] } }

private func otid() -> String { take(IGNewOTID()) ?? "" }

struct Account: Identifiable { let id: String; let username: String; let professional: Bool; let tabbed: Bool }

/// A chat as the engine's updates built it: enough to list it and act on its messages (oldest first).
struct Chat {
    let id: String, account: String
    var name = "", channel: JSON = [:], events: [JSON] = []

    /// Messages that aren't edits, newest first.
    var messages: [JSON] {
        events.filter { $0["type"] as? String == "m.room.message" && dig($0, "content", "m.relates_to", "rel_type") as? String != "m.replace" }.reversed()
    }
}

@MainActor @Observable final class Capture {
    var accounts: [Account] = []
    var chats: [String: Chat] = [:]
    var events: [String] = []
    var status = ""
    var counts = ""
    private var polling = false

    init() {
        if let dir = ProcessInfo.processInfo.environment["FERRY_DEBUG_CAPTURE"] {
            _ = core([dir]) { IGSetCapture($0[0]); return nil }
            status = "Capturing to \(dir)"
        }
    }

    func login(cookies: [String: String]) {
        status = "Loading index + mailbox…"
        if !polling { polling = true; poll() }
        let json = String(data: try! JSONSerialization.data(withJSONObject: cookies), encoding: .utf8)!
        Task.detached {
            let r = parse(core([json]) { IGLogin($0[0]) })
            await MainActor.run {
                guard let id = r["account"] as? String else { self.status = "Error: \(r["error"] ?? "?")"; return }
                let v = r["viewer"] as? JSON ?? [:]
                self.accounts.removeAll { $0.id == id }
                self.accounts.append(Account(id: id, username: v["username"] as? String ?? "?",
                                             professional: v["is_professional_account"] as? Bool ?? false,
                                             tabbed: v["has_tabbed_inbox"] as? Bool ?? false))
                self.status = "@\(v["username"] ?? "?") logged in"
                self.refreshCounts()
            }
        }
    }

    private func poll() {
        Task.detached {
            while true {
                guard let batch = take(IGNextEvent(1000)),
                      let all = (try? JSONSerialization.jsonObject(with: Data(batch.utf8))) as? [JSON] else { continue }
                await MainActor.run {
                    for e in all {
                        self.apply(e)
                        self.events.insert(String(data: (try? JSONSerialization.data(withJSONObject: e)) ?? Data(), encoding: .utf8) ?? "", at: 0)
                    }
                    if self.events.count > 100 { self.events.removeLast(self.events.count - 100) }
                }
            }
        }
    }

    /// One engine update: a chat's fresh window, live change or removal (the app's `Room.apply`, cut down).
    private func apply(_ e: JSON) {
        guard let id = e["room"] as? String else { return }
        if e["kind"] as? String == "RoomRemoved" { chats[id] = nil; return }
        var chat = chats[id] ?? Chat(id: id, account: e["account"] as? String ?? "")
        for s in dig(e, "update", "state", "events") as? [JSON] ?? [] {
            if s["type"] as? String == "m.room.name" { chat.name = dig(s, "content", "name") as? String ?? chat.name }
            if s["type"] as? String == "m.bridge" { chat.channel = dig(s, "content", "channel") as? JSON ?? [:] }
        }
        if let t = dig(e, "update", "timeline") as? JSON {
            if t["limited"] as? Bool == true { chat.events = [] }
            chat.events += t["events"] as? [JSON] ?? []
        }
        chats[id] = chat
    }

    /// One core call off the main actor; the status line shows its result.
    func run(_ label: String, _ args: [String], _ f: @escaping @Sendable ([UnsafeMutablePointer<CChar>]) -> UnsafeMutablePointer<CChar>?) async -> JSON {
        status = "\(label)…"
        let raw = await Task.detached { core(args, f) }.value
        let r = parse(raw)
        status = "\(label): " + (r["error"].map { "error \($0)" } ?? "ok, \(raw?.count ?? 0) bytes")
        refreshCounts()
        return r
    }

    func refreshCounts() { counts = take(IGCounts()) ?? "" }

    private func log(_ line: String) {
        status = line
        guard let dir = ProcessInfo.processInfo.environment["FERRY_DEBUG_CAPTURE"],
              let h = FileHandle(forWritingAtPath: dir + "/script.log") ?? {
                  FileManager.default.createFile(atPath: dir + "/script.log", contents: nil); return FileHandle(forWritingAtPath: dir + "/script.log")
              }() else { return }
        h.seekToEndOfFile(); h.write(Data("\(Date().ISO8601Format()) \(line)\n".utf8)); try? h.close()
    }

    /// Reads the chat in full (a read); its update comes through the event poll.
    func read(_ room: String) async {
        _ = await run("Read \(chats[room]?.name ?? room)", [room]) { IGReadChat($0[0]) }
        try? await Task.sleep(for: .seconds(1))
    }

    /// x's DM with y: its channel is the other person.
    private func dm(_ x: Account, with y: Account) -> String? {
        chats.values.first { $0.account == x.id && $0.channel["id"] as? String == y.id }?.id
    }

    /// P0's live script (docs/PLAN-core.md): A is the first login, B the second, in their DM with each other.
    /// Every step is one Instagram action or one read; script.log in the capture folder says what ran when.
    func runP0() async {
        guard accounts.count == 2 else { log("P0: log in exactly two accounts first"); return }
        let (a, b) = (accounts[0], accounts[1])
        guard let ta = dm(a, with: b), let tb = dm(b, with: a) else { log("P0: no DM between them in the first mailbox page"); return }
        func pause(_ s: Double = 4) async { try? await Task.sleep(for: .seconds(s)) }
        func newestIncoming(_ room: String) async -> String? {
            await read(room)
            return chats[room]?.messages.first { $0["sender"] as? String != "@me" }?["event_id"] as? String
        }
        log("P0 start: A @\(a.username), B @\(b.username)")

        await read(ta); await read(tb)
        log("P0 B sends a text")
        let first = await run("B send", [tb, "P0 capture: hello", "", otid()]) { IGSend($0[0], $0[1], $0[2], $0[3]) }["id"] as? String ?? ""
        await pause()
        log("P0 B replies to it")
        let reply = await run("B reply", [tb, "P0 capture: a reply", first, otid()]) { IGSend($0[0], $0[1], $0[2], $0[3]) }["id"] as? String ?? ""
        await pause()

        if let id = await newestIncoming(ta) {
            log("P0 A reacts, removes it, reacts again")
            _ = await run("A react", [ta, id, "❤️"]) { IGReact($0[0], $0[1], $0[2], 0) }; await pause()
            _ = await run("A unreact", [ta, id, "❤️"]) { IGReact($0[0], $0[1], $0[2], 1) }; await pause()
            _ = await run("A react 😂", [ta, id, "😂"]) { IGReact($0[0], $0[1], $0[2], 0) }; await pause()
        }
        log("P0 B edits its reply, unsends the first text")
        _ = await run("B edit", [tb, reply, "P0 capture: a reply, edited"]) { IGEdit($0[0], $0[1], $0[2]) }
        await pause()
        _ = await run("B unsend", [tb, first]) { IGUnsend($0[0], $0[1]) }
        await pause()
        log("P0 B types for 3 s")
        _ = await run("B typing", [tb]) { IGTyping($0[0], 1) }; await pause(3)
        _ = await run("B typing off", [tb]) { IGTyping($0[0], 0) }; await pause()

        if await newestIncoming(ta) != nil {
            log("P0 A marks B's newest read (one Seen, when unread)")
            _ = await run("A mark read", [ta]) { IGMarkRead($0[0]) }
            await pause()
        }
        log("P0 A sends one back")
        _ = await run("A send", [ta, "P0 capture: back", "", otid()]) { IGSend($0[0], $0[1], $0[2], $0[3]) }
        await pause()

        log("P0 history")  // the folders' pages load after each login by themselves
        await read(ta)
        _ = await run("A older", [ta]) { IGOlder($0[0]) }
        await read(ta); await read(tb)
        refreshCounts()
        log("P0 done. Counts: \(counts)")
    }
}

@main struct CaptureApp: App {
    @State private var capture = Capture()
    var body: some Scene {
        // `xcrun simctl openurl <sim> igcapture://p0` runs the P0 script once both accounts are in.
        WindowGroup { ContentView().environment(capture).onOpenURL { if $0.host == "p0" { Task { await capture.runP0() } } } }
    }
}

struct ContentView: View {
    @Environment(Capture.self) private var capture
    @State private var loggingIn = false

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(capture.status).font(.footnote).accessibilityIdentifier("status")
                    Button("Log in to Instagram") { loggingIn = true }
                    Text(capture.counts).font(.caption2.monospaced()).accessibilityIdentifier("counts")
                }
                ForEach(capture.accounts) { a in
                    Section("@\(a.username) · \(a.id)\(a.professional ? " · professional" : "")\(a.tabbed ? " · tabbed" : "")") {
                        ForEach(capture.chats.values.filter { $0.account == a.id }.sorted { $0.id < $1.id }, id: \.id) { chat in
                            NavigationLink(value: chat.id) {
                                VStack(alignment: .leading) {
                                    Text(chat.name).font(.headline)
                                    Text(verbatim: "general \(chat.channel["fi.mau.instagram.inbox_folder"] != nil) · request \(chat.channel["com.beeper.message_request"] != nil)")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
                Section("Events (newest first)") {
                    ForEach(Array(capture.events.enumerated()), id: \.offset) { Text($0.element.prefix(400)).font(.caption2.monospaced()) }
                }
            }
            .navigationTitle("Capture")
            .navigationDestination(for: String.self) { ThreadScreen(room: $0) }
        }
        .sheet(isPresented: $loggingIn) {
            LoginSheet { cookies in loggingIn = false; capture.login(cookies: cookies) }
        }
    }
}

/// Reads the chat once (a read; it sends nothing), then each button is one Instagram action.
struct ThreadScreen: View {
    @Environment(Capture.self) private var capture
    let room: String
    @State private var text = ""
    @State private var replying = false

    private var messages: [JSON] { capture.chats[room]?.messages ?? [] }
    private var lastOwn: JSON? { messages.first { $0["sender"] as? String == "@me" } }
    private var lastIncoming: JSON? { messages.first { $0["sender"] as? String != "@me" } }
    private func id(_ m: JSON?) -> String { m?["event_id"] as? String ?? "" }

    var body: some View {
        List {
            Section {
                Text(room).font(.caption2.monospaced()).textSelection(.enabled)
                Text(capture.status).font(.footnote)
            }
            Section("Act as this account") {
                TextField("Message", text: $text).accessibilityIdentifier("message")
                Toggle("Reply to the newest message", isOn: $replying)
                Button("Send") {
                    let reply = replying ? id(messages.first) : ""
                    Task { _ = await capture.run("Send", [room, text, reply, otid()]) { IGSend($0[0], $0[1], $0[2], $0[3]) } }
                }.disabled(text.isEmpty)
                Button("❤️ the newest incoming") {
                    Task { _ = await capture.run("React", [room, id(lastIncoming), "❤️"]) { IGReact($0[0], $0[1], $0[2], 0) } }
                }.disabled(lastIncoming == nil)
                Button("Remove ❤️ from the newest incoming") {
                    Task { _ = await capture.run("Unreact", [room, id(lastIncoming), "❤️"]) { IGReact($0[0], $0[1], $0[2], 1) } }
                }.disabled(lastIncoming == nil)
                Button("Edit my newest to the text above") {
                    Task { _ = await capture.run("Edit", [room, id(lastOwn), text]) { IGEdit($0[0], $0[1], $0[2]) } }
                }.disabled(lastOwn == nil || text.isEmpty)
                Button("Unsend my newest") {
                    Task { _ = await capture.run("Unsend", [room, id(lastOwn)]) { IGUnsend($0[0], $0[1]) } }
                }.disabled(lastOwn == nil)
                Button("Mark read (sends Seen when unread)") {
                    Task { _ = await capture.run("Mark read", [room]) { IGMarkRead($0[0]) } }
                }.disabled(lastIncoming == nil)
                Button("Typing on") { Task { _ = await capture.run("Typing", [room]) { IGTyping($0[0], 1) } } }
                Button("Typing off") { Task { _ = await capture.run("Typing off", [room]) { IGTyping($0[0], 0) } } }
            }
            Section("Messages (newest first)") {
                Button("Reload thread") { Task { await capture.read(room) } }
                ForEach(messages.indices, id: \.self) { i in
                    let m = messages[i]
                    Text("\(m["sender"] as? String == "@me" ? "me" : "them") · \(dig(m, "content", "body") as? String ?? "?") · \(id(m).suffix(10))")
                        .font(.caption)
                }
                Button("Load older") {
                    Task {
                        let page = await capture.run("Older", [room]) { IGOlder($0[0]) }
                        capture.chats[room]?.events.insert(contentsOf: (page["chunk"] as? [JSON] ?? []).reversed(), at: 0)
                    }
                }.disabled(messages.isEmpty)
            }
        }
        .navigationTitle(capture.chats[room]?.name ?? room)
        .task { await capture.read(room) }
    }
}

// The user logs in by hand. Fresh non-persistent store; cookies go straight to IGLogin, never to disk or logs.
struct LoginSheet: View {
    let done: ([String: String]) -> Void
    @State private var captured: [String: String]?

    var body: some View {
        NavigationStack {
            LoginWebView(captured: $captured, done: done)
                .navigationTitle("Instagram login").navigationBarTitleDisplayMode(.inline)
                .toolbar { if let c = captured { Button("Continue") { done(c) } } }
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    @Binding var captured: [String: String]?
    let done: ([String: String]) -> Void
    static let names = ["sessionid", "csrftoken", "ds_user_id", "rur", "shbid", "shbts", "mid", "ig_did"]
    static let pattern = #"^https://www\.instagram\.com/(?:direct/(?:inbox/|t/[0-9]+/)?)?(?:\?.*)?$"#

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: URL(string: "https://www.instagram.com/accounts/login/")!))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LoginWebView
        var finished = false
        init(_ parent: LoginWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? ""
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { all in
                var values: [String: String] = [:]
                for c in all where c.domain.hasSuffix("instagram.com") && LoginWebView.names.contains(c.name) && !c.value.isEmpty { values[c.name] = c.value }
                guard ["sessionid", "csrftoken", "ds_user_id"].allSatisfy({ values[$0] != nil }) else { return }
                self.parent.captured = values
                if !self.finished, url.range(of: LoginWebView.pattern, options: .regularExpression) != nil {
                    self.finished = true
                    self.parent.done(values)
                }
            }
        }
    }
}
