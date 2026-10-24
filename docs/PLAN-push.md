# Ferry Messenger: catch-up notifications on the iPhone (plan)

> Draft, 2026-10-24, rewritten the same day: everything runs on the phone, no server (the user's call; the relay
> design is in this file's history). Decisions W1–W4 wait for the user; nothing is built. Account names are the
> fictional stand-ins (`tamoveska` personal, `kivostudio` professional). Builds on the on-device spike's web push runs
> ([spikes/2026-10-16-on-device.md](spikes/2026-10-16-on-device.md) "Web push").

**Goal:** a notification for new Instagram messages that arrived while the app was closed, with the sender and the
text, and a tap opens the chat. Not in real time: they come when iOS next wakes the app. No server, no paid Apple
account, and no Instagram request when the app wakes.

**Why catch-up and not real time.** iOS suspends an app seconds after it leaves the screen, and nothing keeps it
running. Only two things wake it: APNs (needs a server holding the app's push key: set aside) and iOS's own Background
App Refresh, at times iOS picks. Android can stay connected instead (PLAN-android E8); the iPhone can't.

**How it works.** Instagram sends web push (what instagram.com asks a browser for) and, in the spike, delivered it to
Mozilla's push service within a second. A push service holds pushes for a client that isn't connected, until their
time to live (Instagram's pushes say 6 h; step 1 checks both). So the phone is the client, it just isn't connected
most of the time:

```
Instagram ─web push─▶ Mozilla holds it ─▶ iOS wakes the app ─▶ the app connects for ~2 s, takes what's waiting,
                                                                 decrypts it, posts local notifications, disconnects
```

- **Once per account,** while the app is open: a Mozilla channel (registered with Instagram's VAPID key) and a web
  push key pair made on the phone, then one Instagram request registering the channel's endpoint and the public keys
  (`RegisterPushNotifications`, `device_type: web_vapid`).
- **Each wake** (Background App Refresh, and each time the app opens): connect to Mozilla with the phone's ID, take
  the waiting pushes, `ack` them, decrypt them with the account's keys (`messagix/pushcrypto`), post a notification per
  new message. Instagram isn't asked anything: the 2026-10-19 version of this idea loaded every inbox on each wake,
  which added to the ban risk; this one costs Mozilla a connection and Instagram nothing.
- **What Mozilla and Apple learn:** Mozilla, that the account gets a push and when (it can't read it: web push is
  encrypted to the phone's key). Apple, nothing it doesn't already: local notifications never leave the phone.

## 1. Decisions first (the user's)

Each has a recommendation. W1 is needed before step 1; the rest can wait until step 3.

| # | Question | Recommendation |
|---|---|---|
| W1 | **Mozilla's push service from an app that isn't Firefox.** It publishes no terms for other clients (searched 2026-10-24; its docs describe it as Firefox's service). The README's "The app talks only to Instagram" becomes "Instagram, and Mozilla's push service for notifications". | **Go ahead with step 1**, using it lightly (a connection of a few seconds per wake, one channel per account). Asking Mozilla first (the autopush team's #push channel) is yours to do if you want certainty. |
| W2 | **Which pushes become notifications** | **Messages only**, of whatever web push carries (step 1 shows): texts, media, shares, voice notes, and reactions to your messages as their own line ("@sam reacted ❤️"). Never likes, follows or comments. Requests: notify too until step 1 shows whether a push says it's a request; then your call. |
| W3 | **What a notification shows** | The sender (`@handle`, or the group's name) as the title, the text as the body, the account's name as the subtitle when there are two or more accounts; iOS's "Show Previews" hides the text as usual. Grouped per chat. No icon badge and no sender photo at first. |
| W4 | **When the app asks for permission** | Once, right after the first account connects (the end of onboarding), plus a row in Accounts to turn it on later, which also says when Background App Refresh is off for the app. Never at first launch. A "no" costs nothing: the app works as today. |

## 2. What gets built

**The engine** (`core/`), because a push is Instagram's data (CLAUDE.md "Code") and Android can reuse it:

- `core/push`: a small Mozilla client grown from `core/cmd/autopush` (`hello` with the phone's UAID and channels,
  `register`, `unregister`, `ack`; `github.com/coder/websocket`, already pinned in `core/go.mod`) and the push's
  meaning: decrypt (`pushcrypto`, already in the pinned mautrix), then kind (a message, a reaction, something else),
  sender, text, message ID, time and the chat's IDs (`params.u` in a DM, `params.f` in a group). Pure apart from the
  socket, tested on step 1's captured pushes and against a fake Mozilla server (`httptest`).
- Three exports, each with its JNI function in `jni_android.c` in the same commit (Android pins a commit of `core/`):
  - `IGPushSetup(state, accounts)`: one connection to Mozilla; a channel and keys for each listed account that has
    none, channels of unlisted accounts dropped (`unregister`). Answers the new state.
  - `IGPushDrain(state, since)`: connects, takes what's waiting for a few seconds (until 1.5 s pass with nothing new,
    10 s at most), acks, answers the decrypted pushes, each marked whether to notify (W2's kinds, and newer than
    `since`, the last time the app was open, so nothing already seen comes back).
  - `IGRegisterPush(account, state)`: registers the account's channel with Instagram when `rules.go` says to: a new
    session (every login, A3's re-login included), a new endpoint, or 7 days since the last (one request per account
    a week, tuned by step 4). C6 counts it like any request.
- **The push state** (the phone's UAID, and per account the channel, endpoint, key pair and when it was last
  registered) leaves `core/` only for Swift to write straight to the Keychain, like the cookies (decision C3), never
  logged. A UAID Mozilla no longer knows (one idle for long) comes back as a new one: every channel is made again and
  re-registered at the next open.
- `PushRoom(account, user, group)` in `core/chat`, with a test: the room a tap opens (a DM through `fbidByUserID` and
  `ExistingDM`, a group by its thread ID), once the account's chats have loaded; else the inbox.

**The app:**

- The push state as one Keychain item (service `ferry`, account `push`, `AfterFirstUnlockThisDeviceOnly`, so a locked
  phone still reads it). `Keychain.accounts()` already skips it (it lists `instagram:` items only).
- After each account connects: `IGPushSetup` if the account has no channel, then `IGRegisterPush`.
- Background App Refresh: `UIBackgroundModes` `fetch` and the task's ID in `Config/Info.plist`, SwiftUI's
  `.backgroundTask(.appRefresh(…))`, the next refresh booked each time the app goes to the background and at the end
  of each run (no earlier than 15 minutes; iOS decides the rest). A run only drains: it never connects an account
  (`startSync` already runs only when the app is active).
- Each run posts a local notification per push marked to notify, identified by the message ID, so the same push
  taken twice replaces its notification instead of adding one. When the app opens, it drains without notifying (the
  inbox shows those messages) and clears its delivered notifications.
- The tap (`UNUserNotificationCenterDelegate`): opens the app, waits for that account's first page, then the chat
  (`PushRoom`). Remove Account drops the account's channel (`IGPushSetup` without it); Instagram still isn't told
  (CLAUDE.md "Safety"), and its next push to the dropped channel gets Mozilla's "gone".
- `FERRY_DEBUG_DEMO` and the UI tests never ask for permission, set up, drain or register. The simulator can't be
  relied on to run Background App Refresh, so a DEBUG switch runs the same drain a few seconds after HOME, while iOS
  still lets the app finish.
- No extension, no App Group, no APNs, no new entitlement: a free Apple account builds it, and AltStore and SideStore
  installs get it too.

## 3. Steps

Each ends with tests green. Live steps use the dummies only: the user hears the expected actions first, and the C6
counts are reported (CLAUDE.md "Safety").

| Step | What | Who | Estimate |
|---|---|---|---|
| 1 | **Gate: does Mozilla keep Instagram's pushes for a phone that isn't connected, and which ones?** On the Mac, `core/cmd/pushtool` makes the keys and `core/cmd/autopush`, taught to keep its UAID and drain later, makes the channel. The app only registers them with Instagram: `IGRegisterPush` and a DEBUG switch that reads the endpoint and public keys from a host file (push keys, never cookies). One launch on the simulator as `tamoveska`, inbox only (no chat opened, so no "Seen"), then HOME. From `kivostudio` (the capture app, or Instagram on your phone): three texts a minute apart, a photo, a reaction to a message, and one thing that isn't a message (a like on a post, if there's one). Drains from the Mac after 10 minutes (are all six there, or only the newest? Instagram's `collapse_key` may become a web push `Topic`, which keeps one per key) and after 2 hours. Then one text with `tamoveska` back in the app (does Instagram push while the session is connected?). Captured pushes, scrubbed, become fixtures with their throwaway keys (the channel is dropped afterwards). About 1 launch, 1 registration, 7 actions from `kivostudio`, and Mozilla connections that cost Instagram nothing. **If Mozilla doesn't keep them, stop**: back to the user. | Me, you watching | ½–1 d |
| 2 | `core/push` (the client and the kinds), the other two exports, the three JNI functions, `PushRoom` and the register rule, with Go tests. | Me | 1–1½ d |
| 3 | The app: Keychain state, permission, the refresh task, notifications, the tap, Remove Account, the Accounts row, the DEBUG drain; unit tests for what's pure. | Me | 1–1½ d |
| 4 | **On your phone for a week**, both dummies on it, a few messages a day, with a temporary log of each wake: how often iOS wakes the app, how late notifications are, whether a registration lasts. Then the README ("No notifications" → catch-up notifications; who the app talks to), CHANGELOG, specs.md, DEVELOPMENT.md (the switch, Background App Refresh's settings) and CLAUDE.md (the push state's invariants). | You use it, I check | a week, elapsed |

About 3–4 days of work plus the week; a guess, and step 1 decides whether it's worth it.

## 4. Risks

- **Late by design.** iOS wakes an app more often the more it's used, perhaps between one wake an hour and a few a
  day (Apple publishes no numbers; step 4 measures); never after it's swiped away in the app switcher (until it's opened again), and not in Low Power Mode or with
  Background App Refresh off. A push older than 6 h is gone from Mozilla: no notification, though the message is in
  the chat as usual.
- **Mozilla doesn't hold pushes, or holds only the newest per topic** (step 1). If only the newest, a wake shows the
  newest message and "and N more" can't be counted: still useful, less so.
- **Mozilla limits or blocks a client that isn't Firefox** (W1), or **Instagram stops web push to Mozilla**: the app
  works as today, without notifications.
- **A notification for a message already read elsewhere** (on instagram.com or Instagram's app): a wake doesn't ask
  Instagram, so it can't know. Accepted.
- **Two notifications per message** when Instagram's app is also installed with its notifications on: the user's
  setting.
- **Account risk:** a web push registration is what instagram.com sends when a browser allows notifications; about
  one request a week per account. Low.

## 5. Not in this plan

Real-time notifications (they need a server, or the Home Screen web-app route, both set aside 2026-10-24); icon
badges; sender photos; replying from a notification. **Android** could hold the same Mozilla connection in E8's
foreground service instead of Instagram's own socket, sharing `core/push`, for real-time alerts that don't show the
account as active: worth weighing at A8.
