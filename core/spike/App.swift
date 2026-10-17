// The capture app (docs/PLAN-core.md P0): libigcore with several accounts, each thread action one button, everything
// that crosses from Go written to $FERRY_DEBUG_CAPTURE for fixtures. Started as the on-device spike.
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
private func edges(_ j: Any?) -> [JSON] { ((j as? JSON)?["edges"] as? [JSON] ?? []).compactMap { $0["node"] as? JSON } }

/// Offline threading ID, as `methods.GenerateEpochID`: milliseconds << 22, a counter << 12, then 42.
private func otid() -> String { String((Int64(Date().timeIntervalSince1970 * 1000) << 22) | (Int64.random(in: 0..<1024) << 12) | 42) }

struct Account: Identifiable { let id: String; let username: String; let professional: Bool; let tabbed: Bool; var threads: [JSON] }

@MainActor @Observable final class Capture {
    var accounts: [Account] = []
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
        let json = String(data: try! JSONSerialization.data(withJSONObject: cookies), encoding: .utf8)!
        Task.detached {
            let r = parse(core([json]) { IGLogin($0[0]) })
            await MainActor.run {
                guard let id = r["account"] as? String else { self.status = "Error: \(r["error"] ?? "?")"; return }
                let v = r["viewer"] as? JSON ?? [:]
                let threads = edges(dig(r, "mailbox", "threads_by_folder")).compactMap { $0["as_ig_direct_thread"] as? JSON }
                self.accounts.removeAll { $0.id == id }
                self.accounts.append(Account(id: id, username: v["username"] as? String ?? "?",
                                             professional: v["is_professional_account"] as? Bool ?? false,
                                             tabbed: v["has_tabbed_inbox"] as? Bool ?? false, threads: threads))
                self.status = "@\(v["username"] ?? "?") logged in, \(threads.count) threads"
                self.refreshCounts()
                if !self.polling { self.polling = true; self.poll() }
            }
        }
    }

    private func poll() {
        Task.detached {
            while true {
                guard let e = take(IGNextEvent(1000)) else { continue }
                await MainActor.run {
                    self.events.insert(e, at: 0)
                    if self.events.count > 100 { self.events.removeLast() }
                }
            }
        }
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

    private func messages(_ t: ThreadRef) async -> [JSON] {
        let r = await run("Thread @\(t.account)", [t.account, t.id]) { IGThread($0[0], $0[1]) }
        return edges(dig(r, "get_slide_thread_nullable", "as_ig_direct_thread", "slide_messages"))
    }

    private func dm(_ x: Account, with y: Account) -> ThreadRef? {
        x.threads.first { t in
            !(t["is_group"] as? Bool ?? false) && (t["users"] as? [JSON] ?? []).contains { $0["username"] as? String == y.username }
        }.map { ThreadRef(account: x.id, me: x.id, thread: $0) }
    }

    /// P0's live script (docs/PLAN-core.md): A is the first login, B the second, in their DM with each other.
    /// Every step is one Instagram action or one read; script.log in the capture folder says what ran when.
    func runP0() async {
        guard accounts.count == 2 else { log("P0: log in exactly two accounts first"); return }
        let (a, b) = (accounts[0], accounts[1])
        guard let ta = dm(a, with: b), let tb = dm(b, with: a) else { log("P0: no DM between them in the first mailbox page"); return }
        func pause(_ s: Double = 4) async { try? await Task.sleep(for: .seconds(s)) }
        func sentID(_ r: JSON) -> String { dig(r, "xig_direct_text_send_with_slide_messaging_response", "id") as? String ?? "" }
        func newestIncoming(_ t: ThreadRef) async -> JSON? {
            await messages(t).first { "\($0["sender_fbid"] ?? "")" != t.me }
        }
        log("P0 start: A @\(a.username), B @\(b.username)")

        _ = await messages(ta); _ = await messages(tb)
        log("P0 B sends a text")
        let first = sentID(await run("B send", [b.id, tb.id, "P0 capture: hello", "", otid()]) { IGSend($0[0], $0[1], $0[2], $0[3], $0[4]) })
        await pause()
        log("P0 B replies to it")
        let reply = sentID(await run("B reply", [b.id, tb.id, "P0 capture: a reply", first, otid()]) { IGSend($0[0], $0[1], $0[2], $0[3], $0[4]) })
        await pause()

        if let m = await newestIncoming(ta), let id = m["id"] as? String {
            log("P0 A reacts, removes it, reacts again")
            _ = await run("A react", [a.id, ta.id, id, "❤️"]) { IGReact($0[0], $0[1], $0[2], $0[3], 0) }; await pause()
            _ = await run("A unreact", [a.id, ta.id, id, "❤️"]) { IGReact($0[0], $0[1], $0[2], $0[3], 1) }; await pause()
            _ = await run("A react 😂", [a.id, ta.id, id, "😂"]) { IGReact($0[0], $0[1], $0[2], $0[3], 0) }; await pause()
        }
        log("P0 B edits its reply, unsends the first text")
        _ = await run("B edit", [b.id, tb.id, reply, "P0 capture: a reply, edited", otid()]) { IGEdit($0[0], $0[1], $0[2], $0[3], $0[4]) }
        await pause()
        _ = await run("B unsend", [b.id, tb.long, first]) { IGUnsend($0[0], $0[1], $0[2]) }
        await pause()
        log("P0 B types for 3 s")
        _ = await run("B typing", [b.id, tb.id]) { IGTyping($0[0], $0[1], 1) }; await pause(3)
        _ = await run("B typing off", [b.id, tb.id]) { IGTyping($0[0], $0[1], 0) }; await pause()

        if let m = await newestIncoming(ta), let id = m["id"] as? String {
            log("P0 A marks B's newest read (one Seen)")
            let ts = Int64(m["timestamp_ms"] as? String ?? "") ?? 0
            _ = await run("A mark read", [a.id, ta.long, id]) { IGMarkRead($0[0], $0[1], $0[2], ts) }
            await pause()
        }
        log("P0 A sends one back")
        _ = await run("A send", [a.id, ta.id, "P0 capture: back", "", otid()]) { IGSend($0[0], $0[1], $0[2], $0[3], $0[4]) }
        await pause()

        log("P0 history and folders")
        let page = await messages(ta)
        _ = await run("A older", [a.id, ta.id, "", page.last?["id"] as? String ?? ""]) { IGOlder($0[0], $0[1], $0[2], $0[3]) }
        for (x, folders) in [(a, ["INBOX", "PENDING"]), (b, ["INBOX", "PENDING", "GENERAL", "PRIMARY"])] {
            for f in folders { _ = await run("Inbox \(f) @\(x.username)", [x.id, f, ""]) { IGInboxPage($0[0], $0[1], $0[2]) } }
        }
        _ = await messages(ta); _ = await messages(tb)
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

private func title(_ t: JSON) -> String {
    let name = t["thread_title"] as? String ?? ""
    let users = (t["users"] as? [JSON] ?? []).compactMap { $0["username"] as? String }
    return name.isEmpty ? users.joined(separator: ", ") : name
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
                        ForEach(a.threads.indices, id: \.self) { i in
                            let t = a.threads[i]
                            NavigationLink(value: ThreadRef(account: a.id, me: a.id, thread: t)) {
                                VStack(alignment: .leading) {
                                    Text(title(t)).font(.headline)
                                    Text(verbatim: "folder \(t["folder"] ?? "-") · system \(t["system_folder"] ?? "-")").font(.caption)
                                }
                            }
                        }
                        HStack {
                            ForEach(["INBOX", "PENDING", "GENERAL", "PRIMARY"], id: \.self) { f in
                                Button(f) { Task { _ = await capture.run("Inbox \(f)", [a.id, f, ""]) { IGInboxPage($0[0], $0[1], $0[2]) } } }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                }
                Section("Events (newest first)") {
                    ForEach(Array(capture.events.enumerated()), id: \.offset) { Text($0.element.prefix(400)).font(.caption2.monospaced()) }
                }
            }
            .navigationTitle("Capture")
            .navigationDestination(for: ThreadRef.self) { ThreadScreen(ref: $0) }
        }
        .sheet(isPresented: $loggingIn) {
            LoginSheet { cookies in loggingIn = false; capture.login(cookies: cookies) }
        }
    }
}

struct ThreadRef: Hashable {
    let account: String, me: String
    let id: String, long: String, name: String
    init(account: String, me: String, thread: [String: Any]) {
        self.account = account; self.me = me
        id = thread["id"] as? String ?? ""; long = thread["thread_id"] as? String ?? ""; name = title(thread)
    }
}

/// Loads the thread once (a read; it sends nothing), then each button is one Instagram action.
struct ThreadScreen: View {
    @Environment(Capture.self) private var capture
    let ref: ThreadRef
    @State private var messages: [JSON] = []
    @State private var cursor = ""
    @State private var text = ""
    @State private var replying = false

    private func sender(_ m: JSON) -> String { (m["sender_fbid"] as? String) ?? "\(m["sender_fbid"] ?? "")" }
    private var lastOwn: JSON? { messages.first { sender($0) == ref.me } }
    private var lastIncoming: JSON? { messages.first { sender($0) != ref.me } }
    private func id(_ m: JSON?) -> String { m?["id"] as? String ?? "" }

    var body: some View {
        List {
            Section {
                Text("thread \(ref.id)\nlong \(ref.long)").font(.caption2.monospaced()).textSelection(.enabled)
                Text(capture.status).font(.footnote)
            }
            Section("Act as this account") {
                TextField("Message", text: $text).accessibilityIdentifier("message")
                Toggle("Reply to the newest message", isOn: $replying)
                Button("Send") {
                    let reply = replying ? id(messages.first) : ""
                    Task { _ = await capture.run("Send", [ref.account, ref.id, text, reply, otid()]) { IGSend($0[0], $0[1], $0[2], $0[3], $0[4]) } }
                }.disabled(text.isEmpty)
                Button("❤️ the newest incoming") {
                    Task { _ = await capture.run("React", [ref.account, ref.id, id(lastIncoming), "❤️"]) { IGReact($0[0], $0[1], $0[2], $0[3], 0) } }
                }.disabled(lastIncoming == nil)
                Button("Remove ❤️ from the newest incoming") {
                    Task { _ = await capture.run("Unreact", [ref.account, ref.id, id(lastIncoming), "❤️"]) { IGReact($0[0], $0[1], $0[2], $0[3], 1) } }
                }.disabled(lastIncoming == nil)
                Button("Edit my newest to the text above") {
                    Task { _ = await capture.run("Edit", [ref.account, ref.id, id(lastOwn), text, otid()]) { IGEdit($0[0], $0[1], $0[2], $0[3], $0[4]) } }
                }.disabled(lastOwn == nil || text.isEmpty)
                Button("Unsend my newest") {
                    Task { _ = await capture.run("Unsend", [ref.account, ref.long, id(lastOwn)]) { IGUnsend($0[0], $0[1], $0[2]) } }
                }.disabled(lastOwn == nil)
                Button("Mark read (sends Seen)") {
                    let ts = Int64(lastIncoming?["timestamp_ms"] as? String ?? "") ?? 0
                    Task { _ = await capture.run("Mark read", [ref.account, ref.long, id(lastIncoming)]) { IGMarkRead($0[0], $0[1], $0[2], ts) } }
                }.disabled(lastIncoming == nil)
                Button("Typing on") { Task { _ = await capture.run("Typing", [ref.account, ref.id]) { IGTyping($0[0], $0[1], 1) } } }
                Button("Typing off") { Task { _ = await capture.run("Typing off", [ref.account, ref.id]) { IGTyping($0[0], $0[1], 0) } } }
            }
            Section("Messages (newest first)") {
                Button("Reload thread") { Task { await load() } }
                ForEach(messages.indices, id: \.self) { i in
                    let m = messages[i]
                    Text("\(sender(m) == ref.me ? "me" : "them") · \(m["text_body"] as? String ?? m["content_type"] as? String ?? "?") · \((m["reactions"] as? [Any])?.count ?? 0)♥︎ · \(id(m).suffix(10))")
                        .font(.caption)
                }
                Button("Load older") {
                    Task {
                        let r = await capture.run("Older", [ref.account, ref.id, cursor, id(messages.last)]) { IGOlder($0[0], $0[1], $0[2], $0[3]) }
                        let page = dig(r, "fetch__SlideThread", "as_ig_direct_thread", "slide_messages")
                        messages += edges(page)
                        cursor = dig(page, "page_info", "end_cursor") as? String ?? ""
                    }
                }.disabled(messages.isEmpty)
            }
        }
        .navigationTitle(ref.name)
        .task { await load() }
    }

    private func load() async {
        let r = await capture.run("Thread", [ref.account, ref.id]) { IGThread($0[0], $0[1]) }
        let page = dig(r, "get_slide_thread_nullable", "as_ig_direct_thread", "slide_messages")
        messages = edges(page)
        cursor = dig(page, "page_info", "end_cursor") as? String ?? ""
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
