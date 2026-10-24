import BackgroundTasks
import Foundation
import UserNotifications

/// Catch-up notifications (docs/PLAN-push.md): each account's web push channel at Mozilla, and what Mozilla held for
/// them, shown as local notifications when iOS wakes the app (Background App Refresh). Instagram is asked only to
/// register a channel, when the engine's rule says to (a new endpoint, a new login, or weekly); a wake talks to Mozilla
/// only. Nothing happens unless the user allowed notifications.
final class PushNotifications {
    static let shared = PushNotifications()

    /// The refresh task's ID, as `Config/Info.plist` permits it (`$(PRODUCT_BUNDLE_IDENTIFIER).refresh`).
    nonisolated static let refreshID = (Bundle.main.bundleIdentifier ?? "ferry") + ".refresh"

    /// When the app was last open (ms): anything older was there to see, so it doesn't notify.
    private static let lastOpenKey = "push.lastOpen"

    /// Every step reads and writes the state (Keychain only), so they run one at a time, in the order asked.
    private var tail: Task<Void, Never>?

    @discardableResult private func enqueue(_ work: @escaping () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            await work()
        }
        tail = task
        return task
    }

    nonisolated static func allowed() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    /// The app opened: what Mozilla held was there to see in the app, so it's taken without notifying, the
    /// notifications already shown go, and every signed-in account gets a channel. Mozilla only.
    func opened(accounts: [String]) {
        enqueue {
            // In the queue: a wake still posting when the app opens would otherwise leave its notifications behind.
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            guard await Self.allowed() else { return }
            var state = Keychain.pushState() ?? ""
            if !state.isEmpty, let drained = try? await IGCore.pushDrain(state: state, since: .max) {
                state = drained.state
            }
            if let made = try? await IGCore.pushSetup(state: state, accounts: accounts) {
                state = made
            }
            if !state.isEmpty { Keychain.savePushState(state) }
        }
    }

    /// An account connected: its channel is registered with Instagram if the engine's rule says so (one request).
    func connected(_ account: String) {
        enqueue {
            guard await Self.allowed(), let state = Keychain.pushState(),
                  let registered = try? await IGCore.registerPush(account, state: state) else { return }
            Keychain.savePushState(registered)
        }
    }

    /// Remove Account: the removed account's notifications and channel go (Mozilla; Instagram isn't told).
    func removed(_ account: String, remaining accounts: [String]) {
        enqueue {
            let center = UNUserNotificationCenter.current()
            let gone = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier.hasPrefix(account + "/") }
            center.removeDeliveredNotifications(withIdentifiers: gone.map(\.request.identifier))
            guard let state = Keychain.pushState(), let kept = try? await IGCore.pushSetup(state: state, accounts: accounts) else { return }
            Keychain.savePushState(kept)
        }
    }

    /// To the background: from now on, new messages notify, at the next wake, booked only when there's something to
    /// collect (wakes are for nothing otherwise).
    func closed() {
        UserDefaults.standard.set(Int64(Date.now.timeIntervalSince1970 * 1000), forKey: Self.lastOpenKey)
        Task { if await Self.allowed(), Keychain.pushState() != nil { Self.schedule() } }
    }

    /// A Background App Refresh wake: what Mozilla held since the app was last open, as notifications. Mozilla only.
    /// DEBUG's `FERRY_DEBUG_REFRESH_AFTER_HOME` passes 0: everything held shows, what came while the app was open too.
    func refresh(since override: Int64? = nil) async {
        #if DEBUG
        if DebugFixtures.demo { return }  // made-up data: no channels to collect
        #endif
        guard await Self.allowed(), Keychain.pushState() != nil else { return }  // and no next wake
        await enqueue {
            guard let state = Keychain.pushState() else { return }
            let since = override ?? Int64(UserDefaults.standard.integer(forKey: Self.lastOpenKey))
            guard let drained = try? await IGCore.pushDrain(state: state, since: since) else { return }
            Keychain.savePushState(drained.state)
            let names = AccountIdentity.load()
            let now = Int64(Date.now.timeIntervalSince1970 * 1000)
            for (i, push) in drained.pushes.filter(\.notify).enumerated() {
                let notice = PushNotice(push, accountName: names.count > 1 ? names[push.account]?.name : nil, now: now)
                // One sound for a wake's batch, not one per message.
                try? await UNUserNotificationCenter.current().add(notice.request(for: push, sound: i == 0))
            }
        }.value
        Self.schedule()
    }

    /// The next wake: no sooner than 15 minutes; iOS decides when (or whether), by how much the app is used.
    nonisolated static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = .now + 15 * 60
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// What a push shows (docs/PLAN-push.md W3): the sender (or a group's name, the sender then leading the text), the
/// text, and a subtitle: "To" the account it came to when there are two or more (colour can't mark it here, DESIGN
/// §3.3), and when it was sent if that's over 10 minutes before the wake (iOS stamps the notification with the wake).
nonisolated struct PushNotice: Equatable {
    var title: String
    var subtitle: String
    var body: String
    /// One stack per chat.
    var thread: String
}

nonisolated extension PushNotice {
    init(_ push: IG.Push, accountName: String?, now: Int64) {
        // A handle gets its "@"; Instagram's fallback for it is a name (`push.Read`), which doesn't.
        let sender = push.sender.isEmpty ? nil : push.sender.contains(" ") ? push.sender : "@\(push.sender)"
        if let group = push.group, !group.isEmpty {
            (title, body) = (group, sender.map { "\($0): \(push.text)" } ?? push.text)
        } else {
            (title, body) = (sender ?? "New message", push.text)
        }
        var sent: String?
        if now - push.time > 600_000 {
            let date = Date(timeIntervalSince1970: Double(push.time) / 1000)
            let today = Calendar.current.isDate(date, inSameDayAs: Date(timeIntervalSince1970: Double(now) / 1000))
            sent = "Sent " + date.formatted(date: today ? .omitted : .abbreviated, time: .shortened)
        }
        subtitle = [accountName.map { "To \($0)" }, sent].compactMap(\.self).joined(separator: " · ")
        thread = "\(push.account)/\(push.thread.isEmpty ? push.user : push.thread)"
    }

    /// The local notification, carrying the push for the tap (`AppDelegate`), one per message.
    func request(for push: IG.Push, sound: Bool = true) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        (content.title, content.subtitle, content.body, content.threadIdentifier) = (title, subtitle, body, thread)
        content.sound = sound ? .default : nil
        content.userInfo = ["push": String(decoding: (try? JSONEncoder().encode(push)) ?? Data(), as: UTF8.self)]
        return UNNotificationRequest(identifier: push.message.isEmpty ? UUID().uuidString : push.message, content: content, trigger: nil)
    }
}
