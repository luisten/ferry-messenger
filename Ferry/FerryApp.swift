import SwiftUI
#if DEBUG
import os
#endif

@main
struct FerryApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Hosted unit tests launch the app; keep it inert so tests never hit the network or a web view.
    private let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup {
            if isUnitTestHost {
                Text("Running unit tests")
            } else {
                RootView().environment(model)
            }
        }
        // Connected only while open (D6: no push): the sockets close in the background (`stopSync`, `IGPause`).
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard !isUnitTestHost else { return }
            switch phase {
            case .active: model.startSync()
            case .background: model.stopSync()
            default: break
            }
        }
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
