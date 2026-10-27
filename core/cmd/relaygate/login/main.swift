// relaygate-login (docs/PLAN-relay.md step 1): instagram.com's login page in a window, on a fresh store that lives in
// memory only. The user logs in by hand. Once Ferry's own CookieGate (Ferry/InstagramLogin.swift, compiled in) says
// the session is ready, its cookies go to standard output as one JSON object, for `relaygate add` to read from the
// pipe, and the window closes. Nothing is written anywhere else: it refuses any output but a pipe.
//
//   relaygate-login | relaygate add

import AppKit
import WebKit

@MainActor
final class Login: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    private var window: NSWindow!
    private var web: WKWebView!
    private var done = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()  // nothing reaches disk; gone when this quits
        // WKWebView leaves out Safari's own suffix; without it instagram.com can treat the page as an unknown browser.
        configuration.applicationNameForUserAgent = "Version/18.6 Safari/605.1.15"
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 760), configuration: configuration)
        web.navigationDelegate = self
        configuration.websiteDataStore.httpCookieStore.add(self)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Log in to Instagram (Ferry relay gate)"
        window.contentView = web
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: CookieStep.instagram.url))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if !done { FileHandle.standardError.write(Data("relaygate-login: closed before logging in; nothing sent\n".utf8)) }
    }

    // Logging out here would end the session the gate is about to get.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url.map(InstagramLogin.isLogoutURL) == true ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { check() }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.check() }
    }

    private func check() {
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            switch CookieGate.evaluate(.instagram, cookies: cookies, url: self.web.url) {
            case .ready(let values): self.send(values)
            case .captured: self.window.title = "Almost there: choose \"Not now\" if Instagram asks to save your login"
            case .waiting: break
            }
        }
    }

    private func send(_ values: [String: String]) {
        guard !done, let json = try? JSONSerialization.data(withJSONObject: values) else { return }
        done = true
        FileHandle.standardOutput.write(json + Data("\n".utf8))
        exit(0)
    }
}

// Only ever into a pipe: never a terminal, where the cookies would show, and never a file, where they'd stay.
var out = stat()
guard fstat(STDOUT_FILENO, &out) == 0, out.st_mode & S_IFMT == S_IFIFO else {
    FileHandle.standardError.write(Data("relaygate-login: pipe it into the gate, nowhere else: relaygate-login | relaygate add\n".utf8))
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let login = Login()
app.delegate = login
app.run()
