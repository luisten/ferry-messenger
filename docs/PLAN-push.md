# Ferry Messenger: notifications on the iPhone (plan)

> Draft, 2026-10-24: decisions W1–W7 wait for the user, nothing is built. Account names are the fictional stand-ins
> (`tamoveska` personal, `kivostudio` professional). Builds on the on-device spike's web push runs
> ([spikes/2026-10-16-on-device.md](spikes/2026-10-16-on-device.md) "Web push"). Android has its own answer, with no
> relay ([PLAN-android.md](PLAN-android.md) E8).

**Goal:** a banner for each new Instagram message while the app is closed or the phone is locked: who sent it, what
it says, and a tap opens the chat. Nothing else changes: the app still connects to Instagram only while it's open.

**Why it needs a relay.** iOS wakes an app for a push only through APNs, and only whoever holds the app's APNs key
can send one; Instagram pushes to its own app, never to ours. What Instagram will push to someone else is web push
(what instagram.com asks a browser for), and in the spike it delivered only to a standard push service (Mozilla's),
not to our own URL. So something always on holds the push-service connection and turns each push into an APNs push:

```
Instagram ─web push─▶ Mozilla autopush ─websocket─▶ relay ─HTTP/2─▶ APNs ─▶ phone: the extension decrypts, banner
```

The push is encrypted for the phone (web push's `aesgcm`, with keys made on the phone), so Mozilla, the relay and
Apple carry ciphertext. The relay knows each phone's APNs token, how many accounts it has (a channel each) and when
each one gets a push. It never sees what a message says or who sent it, and holds no Instagram IDs.

## 1. Decisions first (the user's)

Each has a recommendation. Nothing is built before W1–W4; W5–W7 can wait until step 4.

| # | Question | Recommendation |
|---|---|---|
| W1 | **A relay at all**, or the Instagram app's own notifications (no code; a tap opens Instagram) | **The relay**, if banners in this app are worth keeping a small server running. It ends the README's "The app talks only to Instagram": the app also talks to your relay (its APNs token, channel requests), and pushes pass through Mozilla and Apple. |
| W2 | **Which push service.** Mozilla's publishes no terms for clients other than Firefox (searched 2026-10-24: its docs only describe it as Firefox's), and it's the only one the spike proved. | **Mozilla's, after one cheap check of our own endpoint** (step 1): the relay answering at its own HTTPS address the way a push service does (`201 Created`). webhook.site got nothing in the spike, but it answers `200` and it was one run, so Instagram may refuse odd answers rather than keep a list of services. If ours works, Mozilla drops out. Asking Mozilla first (the autopush team's #push channel) is yours to do if you want certainty. The other route, Instagram's Android push through FCM, needs the relay to pose as an Android device to Google: more code, the same kind of terms question. |
| W3 | **Where the relay runs.** An always-on machine with an outbound websocket and an HTTPS address the phone can reach (a domain and a certificate). Serverless doesn't fit: nothing there holds a socket open for days. | **An always-on Linux machine you already run** (the one that ran Ferry's server, behind its reverse proxy), as one binary and a systemd unit; otherwise the smallest VPS. A Raspberry Pi at home works with a stable address or a tunnel. |
| W4 | **Who uses it**: your phone only, or friends' too | **Yours until step 5's week passes.** Then friends' phones can register with an invite code (the relay refuses anyone without it). How they install decides whether they get push at all: through your account (ad hoc, with their device IDs, a year at a time) it works; AltStore or SideStore with their own free Apple ID can't sign push, so they get the app as today. A relay for friends means you run a service that sees when they get messages (not what). |
| W5 | **Pushes that aren't messages.** Web push may also carry likes, follows and comments: unknown until step 1. An extension can't drop a push without Apple's filtering entitlement (`com.apple.developer.usernotifications.filtering`), granted on request; Apple's request form lists end-to-end encrypted messaging, which this is as far as the relay goes. | **Apply for it if step 1 shows anything but messages** (you apply, with your account; it can be refused). Until then, turn those categories off in Instagram's own notification settings, and the extension shows whatever still comes as a plain "Instagram" line. |
| W6 | **What a banner shows** | The sender (`@handle`, or the group's name) as the title, the text as the body, the account's name as the subtitle when there are two or more accounts; iOS's "Show Previews" hides the text as usual. While the app is open, a banner only for a chat other than the one on screen. No icon badge at first (each push carries only its own account's count) and no sender photo (a communication notification needs a download in the extension and another capability). |
| W7 | **When the app asks for permission** | Once, right after the first account connects (the end of onboarding), plus a row in Accounts to turn it on later; never at first launch. A "no" costs nothing: the app works as today. |

## 2. What gets built

**The relay** (`relay/`, its own Go module so the server build never pulls mautrix in; one dependency,
`github.com/coder/websocket` at core's pinned v1.8.15, which `core/cmd/autopush` already uses; the standard library
does HTTP/2, JSON and the ES256 token APNs wants). About 300 lines, grown from `core/cmd/autopush`:

- One Mozilla connection for the whole relay (one UAID, kept on disk) and a channel per account per phone, each
  registered with Instagram's VAPID key (`igconnector/push.go`). On every reconnect, `hello` with the saved UAID and
  channels; Mozilla holds a disconnected UAID's pushes until their TTL (Instagram's is 6 h). `ack` once APNs has
  taken the push. One UAID has a ceiling if Mozilla caps channels per UAID: split per phone then.
- Each push's `data`, `crypto_key` and `encryption` go to APNs as they are (`apns-push-type: alert`,
  `mutable-content: 1`, a fallback alert "New message" for when the extension fails), at the environment the phone
  said (Xcode's DEBUG builds: sandbox; ad hoc: production). Instagram's JSON is about 1.6 KB, mostly the picture URL,
  so about 2.5 KB encrypted and encoded, under APNs' 4 KB; anything over sends the fallback alone.
- Three HTTPS calls, each signed with the phone's own secret (made on the phone; the first call also needs the invite
  code): set this phone's APNs token, make a channel (answers its ID and endpoint), drop a channel (and `unregister`
  it at Mozilla). Its state is one JSON file: phones (token, environment, a hash of the secret) and channels.
- Logs counts and errors, never payloads or tokens. Config from the environment: the APNs key (`.p8`: yours, only
  on the relay's host, never in the repo), its key ID, the team ID, the app's bundle ID, the listen address, the
  invite code.
- AGPL like the rest of the repo; as a network service, it links its source.

**The engine** (`core/`):

- `IGRegisterPush(account, endpoint, p256dh, auth)` around `instameow`'s `RegisterPushNotifications`
  (`device_type: web_vapid`). C6 counts it like any request. Its JNI function goes in `jni_android.c` in the same
  commit (CLAUDE.md "Code"), though Android doesn't call it.
- Two rules in `rules.go`, with tests. When to register: a new session (every login, A3's re-login included), a new
  endpoint, or 7 days since the last one; one request per account a week, tuned by step 5. Which room a push opens: a
  DM's `params.u` (an Instagram user ID) through `fbidByUserID` to `ExistingDM`, a group's `params.f` (its thread ID),
  else the inbox. A tap on a cold app waits for that account's first page before opening.

**The app:**

- Push keys per account, made with CryptoKit (P-256 and a 16-byte auth secret), in the Keychain beside the session
  but in a group shared with the extension: service `ferry-push`, account `push:<id>`, holding the private key, the
  auth secret, the channel, the endpoint and the account's name (so the extension needs no App Group). Sessions stay
  in the app's own group: the app's `keychain-access-groups` lists its own group first (the default for items saved
  without one, so `Keychain.save` doesn't change) and the extension lists only the shared one, so the extension can
  never read cookies (CLAUDE.md "Safety"). Both `AfterFirstUnlockThisDeviceOnly`, so a locked phone still decrypts.
- An app delegate adaptor: the APNs token (to the relay), the tap (the engine's room, then the thread), W6's
  foreground rule.
- After an account connects: a channel from the relay if it has none, then the engine decides whether to register.
  Remove Account drops the channel at the relay and deletes the push item; Instagram still isn't told (invariant),
  and its next push gets Mozilla's "gone".
- Push only where signing allows it: an xcconfig switch in `Local.xcconfig` (with the relay's address, yours, not the
  repo's) turns the entitlements on for a paid team; without it, free-account and CI builds build as today.
- `FERRY_DEBUG_DEMO` and the UI tests never ask for permission and never register.

**The extension** (`FerryNotifications/`, a Notification Service Extension, bundle ID
`<prefix>.ferry-messenger.notifications`, added by hand to the project with its synchronized folder and an Embed App
Extensions phase):

- Finds the account by channel, decrypts `aesgcm` with CryptoKit (ECDH, the HMAC-SHA256 steps of
  `messagix/pushcrypto/decrypt.go`, AES-128-GCM, the 2-byte padding length; about 60 lines, `nonisolated`,
  unit-tested on step 1's captured push and its throwaway keys), reads `type`, `message`, `t` and `params`, and fills
  the banner (W6) with a `threadIdentifier` per chat, so iOS groups them.
- No Go in the extension: iOS gives one about 24 MB and 30 s (developer forum reports, not documented), and the
  engine would connect to Instagram. A type it doesn't know shows "New message", never raw JSON.

## 3. Steps

Each ends with tests green. Live steps use the dummies only: the user hears the expected actions first, and the C6
counts are reported (CLAUDE.md "Safety").

| Step | What | Who | Estimate |
|---|---|---|---|
| 0 | The paid team in Xcode, its team ID in `Local.xcconfig`, the app on your phone: a reinstall and new logins, since another team means another Keychain group. An APNs key (Certificates, Identifiers & Profiles → Keys → Apple Push Notifications service), its file on the relay's host only. The host and its HTTPS address (W3). | You | — |
| 1 | **Gate: does Instagram still push to a push service, and what?** The engine's `IGRegisterPush` (moved up from step 3) and a DEBUG switch that registers one account with an endpoint and keys read from a host file (`core/cmd/pushtool gen`: push keys, never cookies); `core/cmd/autopush`, taught to wait for more than one push, listens on the Mac. One launch on the simulator as `tamoveska`, inbox only (no chat opened, so no "Seen"), then from `kivostudio` (the capture app, or Instagram on your phone): a text while the app is open, one 10 s after pressing HOME, a photo, a reaction to a message and one thing that isn't a message (a like on a post). Then a second launch registering at the relay host's own endpoint (W2) and one more text. One push, scrubbed, becomes a fixture with its throwaway keys (the channel is dropped afterwards). About 2 launches, 2 registrations and 7 actions from `kivostudio`. **If nothing arrives, stop**: push doesn't work this way any more. | Me, you watching | ½–1 d |
| 2 | The relay, with one test (a push in, the APNs request out, against a local server); then running on the host. | Me; you deploy | 1–2 d |
| 3 | The engine's rules (Go tests); the app's keys, Keychain groups, token, permission, tap and Remove Account. | Me | 1–2 d |
| 4 | The extension and its decryption tests, the project's new target, the entitlements behind the xcconfig switch; CI still builds. | Me | 1–2 d |
| 5 | **On your phone for a week:** app closed, phone locked, both dummies on it, a few messages a day (do pushes keep coming? does a registration last?). Then the README, CHANGELOG, specs.md, DEVELOPMENT.md (setting up the relay) and CLAUDE.md (the relay's invariants). | You use it, I check | a week, elapsed |

About a week of work plus the soak; a guess, and the extension and the live checks are most of it.

## 4. Risks

- **Instagram stops pushing to anyone but its own apps**, or to Mozilla: step 1 is the gate. After launch the app
  still works without push; nothing depends on it.
- **Mozilla limits or blocks a client that isn't Firefox** (W2).
- **Missed pushes right after leaving the app**, if Instagram counts the session as online until the socket drops
  (step 1's "10 s after HOME").
- **The relay is down:** Mozilla keeps pushes for 6 h, then they're lost; the messages are still there on the next
  open.
- **Two banners per message** when the Instagram app is installed with its notifications on: the user's setting.
- **Account risk:** a web push registration is what instagram.com sends when a browser allows notifications; about
  one request a week per account. Low.

## 5. Not in this plan

Icon badges, sender photos, replying from the banner (that needs the engine connected inside the extension), a
separate setting for requests (W5 decides what's possible), Android (E8).
