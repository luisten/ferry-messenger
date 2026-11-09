# Ferry Messenger: notifications through a relay (plan)

> Draft, 2026-10-27: R1–R4 decided the same day (R3 trust, R4 hosting is the operator's choice); R8–R11 (what people
> are told, §4) on 2026-10-29; R5–R7 wait for the user. Step 1's gate passed (2026-11-09: Instagram tolerated a week
> of always-on sessions); step 2's `core/engine` built (2026-11-05); step 3's relay built on fakes and recordings
> (2026-11-09), R5 and R6 as recommended until the user confirms them. The relay's host: the home Mac Mini for now,
> later a Linux home lab (step 1's MacBook Air is gone).
> The user's brief: as simple and lightweight as possible, and as secure as that allows. Follows
> [PLAN-push.md](PLAN-push.md), whose catch-up notifications were removed in 1.6.3 because Instagram's web push hardly
> ever arrived. Account names are the fictional stand-ins (`tamoveska` personal, `kivostudio` professional).

**Goal:** a notification within seconds for each new Instagram message while Ferry is closed or the phone is locked:
who sent it, what it says, which account it's for, and a tap opens the chat. When the relay is down or not set up,
Ferry works exactly as it does today.

**Why a live connection, not web push.** A relay can only forward what it hears. Listening to Instagram's web push
(the 10-24 draft, in PLAN-push.md's history) would have forwarded the same near-silence the phone measured: one
account's registration refused on every try, the other accepted but silent for a text in Primary. What does hear every
message is Instagram's own socket, the one Ferry uses while open (and Ferry's old bridge used around the clock). So the
relay is a small always-on Instagram client that never reads, sends or marks anything: it listens, and turns each new
message into an APNs push.

```
Instagram ─socket─▶ relay (core/engine, its own web session per account) ─HTTP/2─▶ APNs ─▶ the phone's banner
                       ▲ pairing: relay session + APNs token (once per account)
                     Ferry
```

**What changes for privacy** (README "Privacy" says otherwise today, so this is opt-in and off by default):
- A second Instagram session per account lives on the relay, not only in the iPhone's Keychain.
- The relay reads every incoming message (it has to, to say what it is), and whoever runs it could too: nothing
  short of a hardware enclave hides that from the machine's admin, and the user ruled that out (R3). Worse than
  reading, a copied session acts as the account, so the relay is built to keep its sessions to itself (§2 "Security").
- Apple carries each notification's text (R5), as it does for most apps' notifications.
- **None of this happens unless a person turns notifications on** (R10). Until then Ferry never contacts the relay and
  the relay holds nothing for them: their messages stay private. Turning notifications off ends the relay's session at
  once (§2).

## 1. Decisions first (the user's)

Each has a recommendation. R1–R4 are needed before step 1; the rest before step 4.

| # | Question | Recommendation |
|---|---|---|
| R1 | **The relay's source: its own live Instagram connection** (web push measured unreliable, the dummy rerun declined) | **Decided 2026-10-27: go ahead**, gated on step 1: an always-on web session from the relay's host for several days on the dummies, with no checkpoint or forced logout. Android's A8 is measuring the same question for its foreground service; share the results. |
| R2 | **Which session the relay uses** | **Decided 2026-10-27: its own:** a second login by hand in Ferry's web view ("Turn on notifications for @handle"), whose cookies go straight to the relay over TLS and are never stored on the phone. Not a copy of the phone's session: Instagram rotates cookies mid-session (C3), so two clients on one session would drift apart. It shows as one more web session in Instagram's "Where you're logged in". |
| R3 | **Who uses a relay, and whom they trust** | **Decided 2026-10-27: trust in whoever builds and runs the relay is what counts;** no hardware enclave (weeks of work and a cloud machine, for friends' scale). Your accounts first; friends on ad hoc installs later, each told when they turn notifications on that whoever runs the relay could read their DMs; self-builders run their own relay with their own APNs key (which relay a copy uses is set when it's built, R8). |
| R4 | **Where a relay runs, and how phones reach it** | **Decided 2026-10-27: the operator's choice.** The relay only needs a public HTTPS address the phones can reach (a name on the operator's own domain, say), set in the build (R8); where and how to host it is up to whoever runs it (§3: principles and the VPS-or-home trade-off, nothing prescribed). Your own setup is in your private notes, `docs/local/relay-setup.md` (gitignored). |
| R5 | **What a notification carries** | **Built as recommended in step 3 (2026-11-09), to confirm before step 4. A plain alert:** title the sender's `@handle` (a group's name), subtitle "To <account>" with two or more accounts, body the text or Instagram's line for media, one stack per chat. iOS's "Show Previews" hides the text as usual. Apple sees the text in transit, as it does for most apps' notifications; encrypting it for the phone would add a Notification Service Extension target and a shared Keychain group, which isn't worth it while the relay's operator can read the messages anyway (R3). |
| R6 | **What notifies** | **Built as recommended in step 3 (2026-11-09, `core/chat/notify.go`), to confirm before step 4. Android's rules** (its `Notifier`, DESIGN §4.5): new messages from others as they arrive; not history, the first load, requests, General, reactions or edits. Nothing while Ferry is on screen (the app drops banners in the foreground). |
| R7 | **Android** | **Later:** the same relay can send FCM pushes (Android's E8 option 3), replacing its foreground service if A8 shows battery or Instagram trouble. Not in this plan. |
| R8 | **Where a copy's relay comes from** | **Decided 2026-10-29: the build.** A copy can only get pushes from the relay holding its signer's APNs key, so a typed address would mostly lead nowhere. The relay's address and its operator's display name are build settings in `Local.xcconfig` (`FERRY_RELAY_URL`, `FERRY_RELAY_OPERATOR`), next to the team ID; people never type an address, only the invite code their builder gives them. |
| R9 | **Builds without push or a relay** | **Decided 2026-10-29: no notifications section at all**, not a dead end: a free account's build, an AltStore install, or a paid build without `FERRY_RELAY_URL` shows exactly today's app. The README says why. |
| R10 | **Off by default, private while off, and off at once** | **Decided 2026-10-29.** Ferry makes no contact with the relay (no pairing, status or push token) until a person first turns notifications on for an account, so a friend who never does doesn't exist for the relay. Turning them off ends the relay's session immediately: it disconnects, logs the session out at Instagram and deletes it (§2). The phone's own session never leaves the phone, on or off. |
| R11 | **What people read, and where** | **Decided 2026-10-29: §4.** The in-app wording names who runs the relay and says plainly that they can access the person's messages only while notifications are on; everything stays private while they're off. README for people using Ferry, DEVELOPMENT.md for people building it and running a relay; this plan stays the design record. No other apps are mentioned anywhere. |

## 2. What gets built

**The engine, shared** (`core/engine`): today's `core/cmd/igcore/main.go` minus its cgo edges, so the relay reuses the
same login, resume, retry, re-login and socket code (1.6.1's fixes included). `cmd/igcore` becomes the cgo and JNI
shim; no export or behaviour changes for iOS or Android (Android pins a commit). The relay runs it read-only: one
mailbox page per account at start (names for the notifications), then the socket; a new thread's first message reads
that thread once (the engine does that today); never "Seen", typing, sends or folder paging. C6 counts per account
per day in its log.

**The relay** (`core/cmd/relay`, no new dependencies: HTTP/2, ES256 and JSON are in Go's standard library):
- A small HTTPS API for the app at the relay's public address (R4): pair a phone with a one-time invite code from the
  relay's operator, which gives the phone its own random token (in its Keychain; the relay keeps only a hash); then,
  with that token, add an account (relay session cookies, APNs token, sandbox or production), drop it, update the
  APNs token, and status (per account: connected, since when, last error such as a signed-out session).
- Dropping an account ends its session for good, in this order: the socket closes, the session is logged out at
  Instagram, its cookies are deleted; the answer says which happened. The library has no logout (upstream's bridge
  leaves it a `TODO`), so the relay sends instagram.com's own web logout request with that session, as the website's
  Log out does: it ended both dummies' sessions at the end of step 1 (`relaygate remove`), to be confirmed in step 3.
  Only the session itself proves it: a fresh client on the original cookies must be refused as logged out, whatever
  the logout answered.
- Per account, the engine's updates through R6's rules into APNs pushes (`apns-push-type: alert`, `thread-id` per
  chat, the room ID `!ig-<account>-<thread>` in the payload for the tap). APNs' "unregistered" drops the token.
- TLS, the operator's pick: a certificate the relay gets and renews itself from Let's Encrypt when given a domain
  (`golang.org/x/crypto/acme/autocert`, already pinned at v0.57.0 through mautrix, so no new module); certificate
  files the operator provides; or plain HTTP, only when explicitly told it sits behind the operator's own TLS proxy,
  which the docs warn must not carry the decrypted traffic across machines or services the operator doesn't control
  (pairing carries Instagram cookies).
- State: one JSON file at a path the operator chooses (accounts, their cookies, APNs tokens, the phones' token
  hashes, invite hashes), with an empty lock file beside it (`relay invite` adds a code while the relay runs), and
  Let's Encrypt's certificates cached in `certs` beside it when the relay gets its own; nothing else on disk. Logs
  counts and errors, never cookies, tokens or message text.
- Config from flags or the environment: the path to the APNs key (`.p8`, the operator's, never in the repo), key ID,
  team ID, bundle ID, listen address, TLS mode, state path.

**Security built into the relay** (the same for everyone who runs one; each measure is a few lines, none needs a new
dependency):
- **Read-only by construction:** the engine gets a listen-only mode the relay can't leave, where every send,
  "Seen", typing, edit, unsend, accept and delete is refused before Instagram, with a test for each (as DEBUG's
  `blocked` already does for sends). A bug or a compromised API can't act as an account through the engine. The one
  call that changes anything at Instagram is ending the relay's own session (R10).
- **A small surface:** five endpoints, TLS 1.3 when the relay ends TLS itself. Nothing works without a phone token
  except pairing, which needs a one-time invite code (made by the relay's operator, expiring in a day). Tokens are
  compared in constant time and failed attempts are rate-limited per IP. Requests have small size limits and short
  timeouts. There's nothing to list or browse, and errors say nothing about which accounts exist.
- **At rest:** the relay writes only its state file, readable by its own user alone (0600), and never message text,
  which lives in memory for the second it takes to push.
- **Sessions end when notifications do:** turning notifications off ends the relay's session at Instagram straight
  away (above). Each is the relay's own (R2), so ending it never touches the phone's, and the person can also end it
  themselves in Instagram's "Where you're logged in".
- **Problems come as pushes:** a session Instagram ends, or the relay giving up on an account, sends one alert
  ("Notifications for @handle stopped: open Ferry"), so the phone doesn't poll the relay to find out.
- **Keys:** the relay reads the APNs key from a path its operator gives; the repo never holds one. It's built from
  this public repo with the pinned Go toolchain, by whoever runs it (R3).

**The app:**
- Push only where signing allows it: an xcconfig switch in `Local.xcconfig` turns on `aps-environment` for the paid
  team; free and CI builds build as today, without notifications.
- Accounts gets a Notifications section only in builds with push and a relay (R9; design round first, a UX agent as
  for 1.5): a switch per account. The first one turned on pairs the phone with the builder's invite code; each turn on
  says who runs the relay and what they can access (§4) before the second login (R2). States: off; on; the relay
  unreachable since … (asked when Accounts opens, with a short timeout); stopped, from the relay's status or its push
  (log in again for notifications). None of it blocks anything else in the app.
- Nothing reaches the relay before a switch is first turned on (R10): no pairing, status check or push token.
- Turning a switch off asks the relay to end that session (§2) and stops its notifications on the phone at once,
  whatever the relay answers. If the relay can't be reached, Ferry says its login may still be open, asks again each
  time Ferry opens, and points to "Where you're logged in". With no account left on, Ferry also stops receiving pushes
  (`unregisterForRemoteNotifications`).
- `registerForRemoteNotifications`, the token to the relay; banners dropped while Ferry is in the foreground; a tap
  opens the room in the payload once its account's chats have loaded; reading a chat clears its notifications.
- Remove Account also ends the account's relay session, as turning it off does (the app's own session is still
  only forgotten: Instagram isn't told about that one).
- `FERRY_DEBUG_DEMO` and the UI tests never pair, register or ask for permission.

## 3. Running a relay (the operator's choice)

How and where a relay runs is up to whoever runs it; this plan prescribes no setup. What a relay holds is what's worth
caring about: sessions that can act as their accounts, and every incoming message. So, as principles:

- **Isolate it.** It's the one part facing the internet, so a break-in there should stop there: kept apart from
  anything else on the same machine and from the local network, with the walls enforced outside it. A VM, a
  container, a network segment or a firewall: the operator's pick.
- **Keep TLS ending on infrastructure you control:** pairing carries Instagram cookies.
- **Encrypt the disk and keep the host up to date.**

**VPS or home server, a short disclaimer.** Neither protects against Instagram ending an always-on session (step 1 is
the gate), but they fail differently:
- **A VPS** has a datacenter IP, which Instagram trusts less than a home connection: expect more checkpoints, "new
  login" alerts, or sessions signed out, for every account on it. And the hosting provider controls the machine the
  sessions and messages live on.
- **A home server** has the residential IP Instagram is used to (D3 and FOLLOWUPS #20 chose one for this reason), but
  its address becomes public in DNS and a port opens into the home network, so isolation matters more; its uptime is
  the home's power and internet; a changing home IP needs its DNS kept current; and some providers (carrier-grade
  NAT) allow no incoming connections at all.

## 4. What people are told (R8–R11)

**The rule everything follows from:** a copy of Ferry can only get notifications from the relay run by whoever built
it, because Apple ties push to the paid developer account that signed the copy. Free accounts and AltStore or SideStore
installs can't get push at all.

| Who | What they need | What they get |
|---|---|---|
| Just wants Ferry (the default) | Any copy, nothing to set up | Ferry as it is: messages arrive when it's open; it talks only to Instagram |
| Builds it, free Apple account or AltStore | Nothing more | The same; notifications aren't possible (Apple's rule) |
| Builds it and wants notifications | A paid Apple account, its push key, a relay they run, two build settings | Notifications on their own phone; only they hold their relay sessions |
| Builds it for friends | The same, each friend's iPhone registered for ad hoc installs (up to 100 a year; a new friend means a new build), one relay, an invite code per friend | Friends can turn notifications on; the builder can access the messages of whoever does, and says so |
| Got Ferry from a friend | Nothing; notifications are theirs to turn on | Notifications only through the builder's relay, off until they turn them on, off again at any time |

**In the app** (the content; the UX round words it):
- Off, the default: notifications are off, Ferry talks only to Instagram, and your messages stay private.
- Before turning on: notifications for @handle come through {operator}'s relay, which needs its own login to the
  account. While notifications are on, {operator} can access your messages. Turning them off ends that login right
  away.
- On: on, through {operator}'s relay, which can access your messages while this is on.
- Turned off: off; {operator}'s relay has logged out of @handle. If the relay can't be reached: off on this iPhone,
  but the relay's login may still be open; Ferry will try again, or end it now in Instagram's "Where you're logged in".

**README** (people using Ferry, plain words): the rule, the table without its build details, that notifications are
off unless the person turns them on, and what turning them on means. **DEVELOPMENT.md** (people building Ferry and
running a relay): which Apple account gives what, the build settings, ad hoc installs for friends, §3's principles and
disclaimer, what to tell friends before they turn notifications on, and the AGPL: an unmodified build's source is this
public repo, but a modified relay run for others must offer them its source. Trust in the builder covers the app too:
they sign it. Both are written in step 5, when they describe something real.

## 5. Steps

Live steps use the dummies only until step 5, with the Android session's LOCK/OK/RELEASED, and report C6 counts.

| Step | What | Who | Estimate |
|---|---|---|---|
| 0 | The paid team in Xcode (a reinstall and new logins if the team changes the Keychain group), an APNs key, your relay's host (the Mac Mini for now, later the Linux home lab) set up your way (`docs/local/relay-setup.md`) with its public HTTPS address (needed from step 3; step 1 needs neither). | You | — |
| 1 | **Gate: does Instagram tolerate an always-on web session from the relay's host?** A throwaway listener on the relay's host, which opens no port: `core/cmd/relaygate` (built 2026-10-27; `build.sh` makes both programs for Macs with either chip), with `relaygate-login` for the logins by hand, piping each session straight into it with a new web session for each dummy, logging connects, reconnects, messages received and any checkpoint, for 5–7 days, a few messages a day from your other phone. At the end, `relaygate remove` logs each session out and proves it (R10's logout, tried here first). **If Instagram signs a session out or asks for a checkpoint, stop:** back to you. | Me, then days elapsed | ½ d + a week |
| 2 | `core/engine` out of `cmd/igcore`, no behaviour change; Go tests and both apps' builds green. | Me | 1–1½ d |
| 3 | The relay: API, store, R6's rules, APNs sender, ending a session (R10: the web logout confirmed on the dummies); tests against a fake APNs (`httptest`) and recorded socket events (`core/testdata`). | Me | 1½–2 d |
| 4 | The app: the build settings (R8, R9), the Accounts design and §4's wording, pairing, the switches with off ending the relay's session (R10), token, tap, foreground rule, Remove Account; unit and UI tests on the demo. | Me (UX agent for the design) | 2 d |
| 5 | **A week on your phone:** dummies first, then your accounts. Then README and DEVELOPMENT.md as §4 says, CHANGELOG, specs, CLAUDE.md (the relay's invariants). | You use it, I check | a week, elapsed |

**Step 1 done 2026-11-09** (a home Mac: Intel, macOS 14, the home IP; both dummies added by hand; `relaygate run`
under `caffeinate` from 2026-11-03 13:34 to 2026-11-09 14:07, driven over SSH from the dev Mac with a key limited to
its Tailscale address). **Instagram tolerated it:** no checkpoint, no sign-out, no "trouble", "start failed" or
resnapshot, one process all week. The log and its report are in the gitignored `docs/local/relay-gate-2026-11-09/`.

- **Connected whenever asked:** the hourly check found each account's socket connected 144 times of 144.
- **Every message arrived:** 17 texts went between the dummies (three a day while the dev Mac was on) from Ferry in the
  simulator (`testSendText`, `kivostudio` to `tamoveska` in whichever of their chats had nothing unread, so no "Seen";
  14 requests a launch, once 15). The listener got all 17 on both accounts, the incoming copy and the sender's echo,
  within about 0.7 s of the message's own time. The report's worst delays rose to 1.6 s by 2026-11-07 only because
  the home Mac's clock ran fast (0.36 s on 2026-11-04, 1.12 s on 2026-11-07, then set right by itself that afternoon):
  `relaygate report` doesn't correct for it.
- **Drops are frequent and short:** 79 over the six days (38 `kivostudio`, 41 `tamoveska`; the report's "drops"
  counts each failed retry too, 96), each reconnected by the library on its own: half within 0.7 s, 9 in 10 within
  2.5 s. Six took 15–41 s, all on 2026-11-08 and each hitting both accounts at once, so the home Mac's network, not
  Instagram. No message arrived during one, so what a drop misses is untested. A drop's logged `failures` is the
  library's count from the burst before (it resets only when a working socket drops), so a 3 after a quick reconnect
  is old news.
- **What it cost Instagram,** per account for the week: an index load at the start (inbox page, mailbox query),
  39–42 socket connects, and the logout's requests. Nothing else; no "Seen", no typing.
- **The logout works (R10):** `relaygate remove` sent the website's logout (`/api/v1/web/accounts/logout/ajax/`, the
  first path) for each, then checked that the session no longer works: ended, for both.
- **Trap:** stopping `relaygate run` ends its `caffeinate`, and the laptop slept within seconds; SSH reached it again
  only after a ping on the home network woke it. Run anything after it under `caffeinate` too.
- **Cleaned up:** the listener, its state and log on the home Mac, the SSH key on both sides.
- **Not covered:** a VPS's address (the home IP only), media, requests and groups (texts only), a message during a
  drop, a real account. Android's A8 measures the same question.

**Step 3 done 2026-11-09** (on the Mac Mini; built and tested on fakes and P0's recordings, no Instagram request).
`cd core && go test ./...` passes (race-clean), `core/build.sh` builds the xcframework, `cmd/igcore`'s exports are
unchanged (so is `jni_android.c`).

- **R6 lives in `core/chat`** (`notify.go`, beside `rules.go`, so Android can share it): a message notifies when it's
  from someone else and newer than both the moment the relay started on the account (`Chats.Since`) and anything
  seen in that chat, notified or not. So the first load, a reload after a resnapshot and a request accepted elsewhere
  notify nothing old; requests, General, reactions, edits, unsends and Instagram's own lines never notify. On P0's run
  as `tamoveska`'s socket delivered it, `kivostudio`'s two texts notify and nothing else does; mutating either guard
  fails the tests. Bodies: the text, a story reply's text, else "Sent a photo / video / voice message / sticker / GIF",
  "Sent 3 photos", a share's line.
- **`engine.ListenOnly()`**, for good: send, "Seen", typing, reaction, edit, unsend, accept, delete, upload and "Load
  video" are refused before Instagram (a test per call, on an account with no client at all, so one that got through
  would panic); one mailbox page, no folder paging; the library logs nothing; the queue carries account events and
  `Notify` only.
- **`core/cmd/relay`:** `relay serve` and `relay invite` (a 10-character one-time code, `XXXXX-XXXXX`, 24 h; case,
  dashes and spaces don't matter). Five endpoints: `POST /v1/pair {invite}` → `{token}`; with `Authorization: Bearer`,
  `PUT /v1/apns {token, sandbox}`, `PUT /v1/accounts {cookies}` → `{account, username}` (which account it is comes
  from the session; the app checks it's the one it meant and drops it otherwise; an account already on the relay
  moves to the new session and the old one is ended), `DELETE /v1/accounts/{id}` → `{socket, logout, deleted}`, and
  `GET /v1/status` → per account `{connected, since, error}`. Another phone's account answers exactly as an unknown
  one (404). Tokens are kept as SHA-256 and compared in constant time; 10 failures per IP in 15 minutes, then 429;
  64 KB bodies; TLS 1.3 when it ends TLS (`-tls acme|files|none`).
- **Ending a session** (R10): the current (rotated) cookies, then `engine.Stop` (socket closed), then relaygate's web
  logout and its proof by a fresh client, then the cookies deleted; a phone left with no account loses its device
  token too. A session Instagram ends, or a login it refuses for good, stops the account with one push ("Notifications
  for @handle stopped: open Ferry.") and keeps its cookies until the phone drops it, so turning it off still logs out.
  A network failure never stops one (the engine retries every 30 s).
- **APNs:** HTTP/2 with an ES256 provider token renewed after 50 minutes or on `ExpiredProviderToken`; one more try
  after 429 or 5xx; `410`, `Unregistered` and `BadDeviceToken` forget the device token. R5's alert: title the sender's
  `@handle` (a group's name, and `@sam: text`), "To @account" with two or more accounts on the phone, `thread-id` and
  `room` the chat's room ID, text cut to stay within 4 KB. Tested against an `httptest` HTTP/2 server that verifies
  the token's signature.
- **The log** (stderr, JSON lines) holds events, push statuses and C6 counts (cumulative since each login, logged daily
  and at shutdown); the tests check it holds no cookie, token, invite, device token, text, sender or chat.
- **Choices made without the user** (their "proceed" on the plan): R5 and R6 as recommended; `relaygate` kept as step
  1's record, its logout copied (`cmd/relay/logout.go`, one copy once relaygate goes); the lock file and certificate
  cache beside the state.
- **Left:** R10's live confirmation on the dummies (logins by hand, LOCK/OK/RELEASED); a real push (needs step 0's
  APNs key and step 4's app); `-tls acme` (needs the public name); a message arriving during a drop.

About 5–6 days of work plus two weeks of soak; a guess, and step 1 decides whether it's worth it.

## 6. Risks

- **Instagram minds an always-on session** (checkpoints, logouts, worse): step 1 is the gate; Android's A8 adds data.
- **The relay or its connection is down:** no notifications until it's back (messages missed meanwhile don't
  notify); the app is unaffected, and Accounts says so.
- **Whoever runs a relay can read its users' DMs** (R3), and holds sessions that act as them.
- **A relay session ends** (Instagram signs it out): Accounts asks for a new login for notifications only.
- **Two notifications per message** if the person also gets notifications for the same account elsewhere: their
  setting.
- **Ending a session depends on instagram.com's web logout,** which the library doesn't wrap and Instagram could
  change: if it fails, Ferry says the relay's login may still be open and where to end it (§2).
- **APNs environments:** Xcode's Debug builds get sandbox tokens, ad hoc builds production; the app says which.

## 7. Not in this plan

Hiding messages from the relay's operator (a hardware enclave; R3), encrypted payloads and a Notification Service
Extension (R5), sender photos, an icon badge, replying from a notification, friends' onboarding (R3), FCM for Android
(R7).
