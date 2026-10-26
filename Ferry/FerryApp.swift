import SwiftUI
import UserNotifications
#if DEBUG
import os
#endif

@main
struct FerryApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
    /// Hosted unit tests launch the app; keep it inert so tests never hit the network or a web view.
    private let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup {
            if isUnitTestHost {
                Text("Running unit tests")
            } else {
                RootView().environment(delegate.model)
            }
        }
        // Connected to Instagram only while open; iOS suspends the sockets in the background anyway. Closed, catch-up
        // notifications come from Mozilla when iOS wakes the app (docs/PLAN-push.md).
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard !isUnitTestHost else { return }
            switch phase {
            case .active: delegate.model.startSync()
            case .background: delegate.model.stopSync()
            default: break
            }
        }
        .backgroundTask(.appRefresh(PushNotifications.refreshID)) { await PushNotifications.shared.refresh() }
    }
}

/// Owns the model, so a notification tapped on a cold launch reaches it: the delegate is the notification center's.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Not the `async` form: Swift calls its completion handler on a background thread, and UIKit's asserts the main
    /// one, so 1.6.0 crashed on every tap (the phone's crash reports, 2026-10-25). The simulator can't tap one.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let push = (response.notification.request.content.userInfo["push"] as? String)
            .flatMap { try? JSONDecoder().decode(IG.Push.self, from: Data($0.utf8)) }
        nonisolated(unsafe) let done = completionHandler  // only ever called on the main thread, below
        Task { @MainActor in
            if let push { model.openPush(push) }
            done()
        }
    }

    /// Notifications are posted only from a wake; the app opening takes the rest without showing them.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}

#if DEBUG
/// Logs process start → first inbox rows once per launch (PLAN M3 exit: cold-launch time).
/// Read it with `xcrun simctl spawn booted log show --last 2m --predicate 'subsystem == "<bundle ID>" AND category == "launch"'`.
enum LaunchTimer {
    private static var logged = false

    static func inboxVisible() {
        guard !logged else { return }
        logged = true
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return }
        let start = info.kp_proc.p_starttime
        let ms = Int((Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1e6)) * 1000)
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "ferry", category: "launch").notice("cold launch to inbox rows: \(ms, privacy: .public) ms")
    }
}
#endif
