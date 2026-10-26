# Ferry Messenger: catch-up notifications on the iPhone (plan)

> Draft, 2026-10-24, rewritten the same day: everything runs on the phone, no server (the user's call; the relay
> design is in this file's history). W1–W4 decided 2026-10-24 (the recommendations). Steps 1–3 done the same day
> (§3): the app shows catch-up notifications; the tap and real wakes wait for step 4, on the phone. Account names are the
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
| W1 | **Decided 2026-10-24: go ahead.** **Mozilla's push service from an app that isn't Firefox.** It publishes no terms for other clients (searched 2026-10-24; its docs describe it as Firefox's service). The README's "The app talks only to Instagram" becomes "Instagram, and Mozilla's push service for notifications". | **Go ahead with step 1**, using it lightly (a connection of a few seconds per wake, one channel per account). Asking Mozilla first (the autopush team's #push channel) is yours to do if you want certainty. |
| W2 | **Decided 2026-10-24: the recommendation.** **Which pushes become notifications** | **Every message web push carries**, which step 1 found is texts, photos and videos from the camera roll, and voice notes, one push each. Reactions, likes and anything taken with Instagram's in-chat camera send no push, so they can't notify; shares weren't tried. Requests: notify too until step 1 shows whether a push says it's a request; then your call. |
| W3 | **Decided 2026-10-24: the recommendation.** **What a notification shows** | The sender (`@handle`, or the group's name) as the title, the text as the body, the account's name as the subtitle when there are two or more accounts; iOS's "Show Previews" hides the text as usual. Grouped per chat. No icon badge and no sender photo at first. |
| W4 | **Decided 2026-10-24: the recommendation, then changed the same day (QA round): a one-time inbox card (DESIGN O7) says what notifications are and that they're late, and only its Turn On brings iOS's question.** **When the app asks for permission** | Once, right after the first account connects (the end of onboarding), plus a row in Accounts to turn it on later, which also says when Background App Refresh is off for the app. Never at first launch. A "no" costs nothing: the app works as today. |

## 2. What gets built

**The engine** (`core/`), because a push is Instagram's data (CLAUDE.md "Code") and Android can reuse it:

- `core/push`: a small Mozilla client grown from `core/cmd/autopush` (`hello` with the phone's UAID and channels,
  `register`, `unregister`, `ack`; `github.com/coder/websocket`, already pinned in `core/go.mod`) and the push's
  meaning: decrypt (`pushcrypto`, already in the pinned mautrix), then kind (`direct_v2_text`, `direct_v2_media`,
  `direct_v2_voice_message`, else not a message), sender (`it`), text, message ID (`mid`), time (`ts`) and the chat
  (`t_id`, the thread's long ID; `s`, the sender's Instagram user ID; `u` is the receiving account's, which step 2 first
  took for the sender: the camera capture of 2026-10-24 showed it). Pure apart from the socket, tested on step 1's
  captured pushes and against a fake Mozilla server (`httptest`).
- Four exports, each with its JNI function in `jni_android.c` in the same commit (Android pins a commit of `core/`):
  - `IGPushSetup(state, accounts)`: one connection to Mozilla; a channel and keys for each listed account that has
    none, channels of unlisted accounts dropped (`unregister`). Answers the new state.
  - `IGPushDrain(state, since)`: connects, takes what's waiting for a few seconds (until 1.5 s pass with nothing new,
    10 s at most), acks, answers the decrypted pushes, each marked whether to notify (W2's kinds, and newer than
    `since`, the last time the app was open, so nothing already seen comes back).
  - `IGRegisterPush(account, state)`: registers the account's channel with Instagram when `rules.go` says to: a new
    session (every login, A3's re-login included), a new endpoint, or an hour since the last (was 7 days until step 4
    showed Instagram drops registrations within hours to a day and a half). C6 counts it like any request. `IGLogin`
    marks the new session.
  - `IGPushRoom(account, push)`: the room a tap opens (below).
- **The push state** (the phone's UAID, and per account the channel, endpoint, key pair and when it was last
  registered) leaves `core/` only for Swift to write straight to the Keychain, like the cookies (decision C3), never
  logged. A UAID Mozilla no longer knows (one idle for long) comes back as a new one: every channel is made again and
  re-registered at the next open.
- `PushRoom(long, user)` in `core/chat`, with a test: the room a tap opens (the push's long thread ID through the
  engine's map of them, else its sender's DM through `fbidByUserID` and `ExistingDM`), once the account's chats have
  loaded; else the inbox.

**The app:**

- The push state as one Keychain item (service `ferry`, account `push`, `AfterFirstUnlockThisDeviceOnly`, so a locked
  phone still reads it). `Keychain.accounts()` already skips it (it lists `instagram:` items only).
- Each time the app opens: `IGPushSetup` with every signed-in account (Mozilla only; nothing new when each has its
  channel). After each account connects: `IGRegisterPush`, which the engine's rule usually turns into nothing. One
  at a time, in order (`PushNotifications`), since each reads and writes the state.
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

**Step 1 done 2026-10-24** (the simulator; the user sent as `kivostudio` from Instagram's app on their phone). Tools:
`core/cmd/autopush setup|drain|drop`, `FERRY_DEBUG_WEB_PUSH`. Instagram took the registration
(`POST /api/v1/web/push/register/`, `ok`).

- **Mozilla keeps pushes for a client that isn't connected, one per message, and gives them back until they're
  acked.** Three texts sent a minute apart with the app closed were all there 10 minutes later and still there at
  2 h 2 min (texts say `time_to_live` 21600, media 86400; past 2 h untested). They share
  `collapse_key: direct_v2_message` but weren't merged. A collection that doesn't ack gets the same pushes again on
  the next connection, so a wake cut short loses nothing.
- **Instagram pushes even while the session is connected:** a text sent with the app open on the inbox showed in the
  app live and was held by Mozilla too. So an open takes the queue without notifying (`IGPushDrain`'s `since`).
- **What pushes:** a text (`direct_v2_text`, with the text), a photo or video from the camera roll (`direct_v2_media`,
  "Sent a photo" / "Sent a video", with links to the image or a preview, `a_url` / `p_url`), a voice note
  (`direct_v2_voice_message`, "Sent a voice message"). **What doesn't:** a reaction, a like on a post, and anything
  taken with Instagram's in-chat camera, photo or video, view-once or kept in chat. A push is about 1.5 KB encrypted
  and reached Mozilla within a minute.
- **Counts:** Ferry's one launch, 10 requests: `tamoveska` 5 (inbox page, mailbox query, a folder page, socket, the
  registration), `kivostudio` 5 (inbox page, mailbox query, two folder pages, socket); no "Seen", no typing.
  `kivostudio` from Instagram's app: 4 texts, 3 photos, 2 videos, a voice note, a reaction, a like.
- **Left behind:** one web push registration for `tamoveska` pointing at the dropped Mozilla channel. The captures
  (raw and decrypted, with their throwaway keys) are in the gitignored `docs/local/push-captures-2026-10-24/`. Step 2
  scrubs its fixtures from the decrypted ones; a ciphertext can't be scrubbed, so the decryption test encrypts a
  scrubbed payload itself.
- **Not covered:** requests (no third account, D11), groups, shares, a hold past 2 h, a real phone.

**Step 2 done 2026-10-24** (Go only, no Instagram request). `core/push` (`Setup`, `Drain`, `Read`) and the four
exports above with their JNI functions; `PushRoom` and `PushRegister` in `rules.go`. Step 1's `FERRY_DEBUG_WEB_PUSH`
is gone: step 3 registers for real. Tests: a fake Mozilla holding the four scrubbed captures
(`core/testdata/push_*_kivo.json`), encrypted to test keys. Channels are made, kept on a second setup and dropped for
a removed account; one drain reads, acks and marks what notifies, leaving out what can't be read; a UAID Mozilla
forgot starts over with new endpoints; with no channels nothing connects. Three deliberate bugs (no ack, `since`
ignored, the wrong thread field) each failed them.

**Step 3 done 2026-10-24** (the simulator, both dummies; the user sent as `kivostudio` from Instagram's app on their
phone). `PushNotifications` (setup, register, drain, one at a time), `PushNotice` (W3), the app delegate (taps), the
Background App Refresh task, W4's prompt and the Accounts row; `FERRY_DEBUG_REFRESH_AFTER_HOME` for the simulator,
whose wake shows everything held. Unit tests: 297 (4 new, on `engine_push.json` from `go test ./push -update`); UI
tests pass on made-up data (the demo never asks or registers).

- **Live:** the prompt came once, as the inbox first showed its chats; after Allow, each account registered its
  channel (`POST /api/v1/web/push/register/`, one each). A text sent while the app was open showed live; after HOME
  the wake drained it and posted the notification: `@sender` as the title, the receiving account's name as the
  subtitle (two accounts), the text.
- **Counts:** one launch, 11 requests: `tamoveska` 5 (inbox page, mailbox query, a folder page, socket, the
  registration), `kivostudio` 6 (the same with two folder pages). No chat opened: no "Seen". `kivostudio`: 1 text.
- **Not verified: the tap.** The simulator's synthesized taps don't open a notification from Notification Center,
  and `simctl push` test banners came and went too fast to catch; the tap moves to step 4, on the phone.
- **Fixed on the way:** the Accounts row started empty while checking, and an empty view never appears, so the check
  never ran (it now shows a placeholder line).

**QA round before the PR (2026-10-24):** a code review, a UX review and a simulator pass on made-up data (agents).

- **Fixed from the review:**
  - A wake that launched the app cold marked "last open" at the wake, so nothing it collected notified: only a real
    open moves it now (`AppModel.isOpen`).
  - A wake of a suspended app resumed the Instagram clients: sockets reconnected, retries and folder paging went on.
    The app now closes every socket in the background and reopens them on return (`IGPause`/`IGUnpause`, with their
    JNI functions; no index reload, as before).
  - Channels made outside a login waited for a cold relaunch to be registered: every return from the background now
    asks (the rule usually says no), and a new account gets its channel before its registration.
  - A drain cut short by its deadline or a dropped connection lost pushes it had acked; read errors looked like quiet.
  - Every return made two Mozilla connections: a setup with nothing to do no longer connects.
  - Smaller ones: wakes are booked only when notifications are on; a group's push never falls back to the sender's
    DM; Mozilla refusing an unregister no longer blocks setup; Remove Account clears its notifications and any
    pending tap; the registration has a 15 s timeout; the push state is updated in place; the demo never asks or
    wakes; a kept camera message without its attachment is still media.
- **From the UX review:** "To <account>" as the subtitle (DESIGN §3.3), "Sent 14:05" on a notification over 10
  minutes late, one sound per wake, honest footer copy, and states that say what's wrong with a glyph (off; can't
  arrive with Background App Refresh off; paused in Low Power Mode). The owner's calls: the explanation card before the
  system prompt, yes (W4 changed); `@handle` stays the title (no contacts' names stored on the phone); requests
  (DESIGN §4.5 has them off; a push can't tell one apart yet) explained, open.
- **Left for step 4 (the phone):** the tap; how often iOS wakes the app; that a wake makes no Instagram request or
  socket connect (log one); whether Low Power Mode reports Background App Refresh as off. Known and left: a re-login's
  registration is remembered in memory only, so an app killed before it registers waits for the weekly renewal.

**Step 4, the first days on the phone (1.6.0, reported 2026-10-25):** no notifications; after a return to the app, no
new messages, typing or own messages in the inbox until a relaunch.

- **The return:** `IGPause` closed the sockets with the library's `Disconnect`, which stops a client's sockets for good
  (dgw's `stopping`), so `IGUnpause`'s `Connect` returned at once. Each connection now has its own context, which
  `IGPause` cancels (`TestASocketReconnectsAfterItsContextEnds` pins both library behaviours). On the way:
  `ResnapshotRequired` (Instagram can't replay what a socket missed) ended the connect loop with nothing else done;
  the core now logs in again, as a launch does (upstream's full reconnect).
- **Live on the simulator (2026-10-25, both dummies; the user sent and typed as `kivostudio` from their phone):** a
  text sent while the app was in the background showed on return in both accounts' rows, same process; "typing" and a
  live text showed with the app open; our own send after a return was the inbox's last message for one account and
  unread for the other. Counts for one launch and two returns: `tamoveska` 3 requests and 3 socket connects,
  `kivostudio` 7 (with a thread read, its message list and the send) and 3 socket connects, 2 typing; no "Seen", no
  index reload on any return. The built-in browser refused instagram.com even after the user allowed it, so the
  other side was the phone again.
- **Notifications:** they did come (Accounts said on, Background App Refresh on), but **every tap crashed the app**,
  warm or cold (three crash reports from the phone, copied with `xcrun devicectl device copy from --domain-type
  systemCrashLogs`): the `async` `didReceive` ran on Swift's pool, which then called UIKit's completion handler there,
  and UIKit asserts the main thread (`_updateSnapshotAndStateRestorationWithAction`). Now the completion-handler form,
  answered on the main actor. The simulator delivers a `simctl push` banner's tap but didn't crash on the old code, so
  only the phone can confirm it.
- **Registrations expire (live 2026-10-26, QA round):** with 10-24's registration, no message reached Mozilla, sent
  with the app open or in the background (the new DEBUG log: "wake: 0 pushes", "opened, 0 pushes taken"). Right after
  registering again (a temporary `registerEvery = 0` build), a message sent in the background was there (1), and still
  after a cold relaunch that didn't register (1). On the phone, 1.6.0's first registration delivered for at least
  2.6 h, then nothing a couple of days later. So Instagram drops a registration somewhere between about 3 h and
  1.5 days; `PushRegister` now renews hourly, on open or return only (never in a wake: notifications last that long
  after the app was last used). The wake log measures the rest on the phone.
- **Live re-check of 1.6.1 (same session):** a text sent with the app in the background arrived on return, same
  process. Counts: 4 cold launches of 3 requests (`tamoveska`) and 4 (`kivostudio`) each, 2 registrations logged and
  most likely 2 more lost (the build was replaced before HOME), about 6 socket connects per account; no "Seen", no
  sends. The notification tap couldn't be checked end to end: no push arrived until the re-registration, and the test
  that followed was about the registration.
- **Three reviews of 1.6.1, fixed:** the push registration never goes out from the background (a login finishing
  after HOME); a retry that comes due in the background waits and starts 30 s after the return, so the app's own
  connect goes first; a removed account is never retried or re-logged in; a client stale after a resnapshot isn't
  reconnected; a login another one overtook doesn't report its failure; an ended session isn't retried on each return.
- **Known and left (review):** Remove Account while a resnapshot's re-login is loading the index brings the account
  back in the engine until a relaunch (hidden in the app; the same window as a retry timer that has fired).

## 4. Risks

- **Late by design.** iOS wakes an app more often the more it's used, perhaps between one wake an hour and a few a
  day (Apple publishes no numbers; step 4 measures); never after it's swiped away in the app switcher (until it's
  opened again), and not in Low Power Mode or with Background App Refresh off. A text older than 6 h (media: 24 h) is
  gone from Mozilla: no notification, though the message is in the chat as usual.
- **Messages Instagram doesn't push** never notify: reactions, and photos and videos taken with Instagram's in-chat
  camera, view-once or kept (step 1). They're in the chat on the next open, as now.
- **Mozilla limits or blocks a client that isn't Firefox** (W1), or **Instagram stops web push to Mozilla**: the app
  works as today, without notifications.
- **A notification for a message already read elsewhere** (on instagram.com or Instagram's app): a wake doesn't ask
  Instagram, so it can't know. Accepted.
- **Two notifications per message** when Instagram's app is also installed with its notifications on: the user's
  setting.
- **Account risk:** a web push registration is what instagram.com sends when a browser allows notifications; at most
  one request an hour per account, only while the app is used. Low.

## 5. Not in this plan

Real-time notifications (they need a server, or the Home Screen web-app route, both set aside 2026-10-24); icon
badges; sender photos; replying from a notification. **Android** could hold the same Mozilla connection in E8's
foreground service instead of Instagram's own socket, sharing `core/push`, for real-time alerts that don't show the
account as active: worth weighing at A8.
