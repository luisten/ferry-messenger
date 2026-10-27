# Ferry Messenger: notifications through a relay (plan)

> Draft, 2026-10-27: R3 (trust) and R4 (a public address) decided the same day; R1, R2 and R5–R7 wait for the user,
> nothing is built. The user's brief: as simple and lightweight as possible, and as secure as that allows. Follows
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
- Apple carries each notification's text (R5), as it does for Instagram's own app.

## 1. Decisions first (the user's)

Each has a recommendation. R1–R4 are needed before step 1; the rest before step 4.

| # | Question | Recommendation |
|---|---|---|
| R1 | **The relay's source: its own live Instagram connection** (assumed from 2026-10-27: web push measured unreliable, the dummy rerun declined) | **Go ahead**, gated on step 1: an always-on web session from the relay's host for several days on the dummies, with no checkpoint or forced logout. Android's A8 is measuring the same question for its foreground service; share the results. |
| R2 | **Which session the relay uses** | **Its own:** a second login by hand in Ferry's web view ("Turn on notifications for @handle"), whose cookies go straight to the relay over TLS and are never stored on the phone. Not a copy of the phone's session: Instagram rotates cookies mid-session (C3), so two clients on one session would drift apart. It shows as one more web session in Instagram's "Where you're logged in". |
| R3 | **Who uses a relay, and whom they trust** | **Decided 2026-10-27: trust in whoever builds and runs the relay is what counts;** no hardware enclave (weeks of work and a cloud machine, for friends' scale). Your accounts first; friends on ad hoc installs later, each told when they turn notifications on that whoever runs the relay could read their DMs; self-builders run their own relay with their own APNs key (the app takes any relay address). |
| R4 | **Where it runs, and how phones reach it** | **Decided 2026-10-27: a public HTTPS address on your own domain** (people shouldn't need your Tailscale). Recommended with it: **an always-on box at home** (a spare computer or a home server that stays on), for the residential IP that D3 and FOLLOWUPS #20 chose for checkpoint risk (Instagram distrusts datacenter IPs); the router forwards port 443 to it, and a DNS name (`relay.<your domain>`, kept current if the home IP changes) points at it. **TLS ends on the relay itself**, with a Let's Encrypt certificate it gets and renews on its own (`golang.org/x/crypto/acme/autocert`, already pinned at v0.57.0, so no new module): pairing carries Instagram cookies, so no proxy in between may decrypt the traffic, which rules out Cloudflare Tunnel's usual setup. If the ISP gives no public IP (carrier-grade NAT), the fallback is a small VPS that forwards the encrypted TCP to the box over WireGuard, again without decrypting. The trade-off: the home IP is public in DNS. The relay runs **isolated** from everything else on that machine and network (§2 "Security"). |
| R5 | **What a notification carries** | **A plain alert:** title the sender's `@handle` (a group's name), subtitle "To <account>" with two or more accounts, body the text or Instagram's line for media, one stack per chat. iOS's "Show Previews" hides the text as usual. Apple sees the text in transit, as it does for Instagram's own app's notifications; encrypting it for the phone would add a Notification Service Extension target and a shared Keychain group, which isn't worth it while the relay's operator can read the messages anyway (R3). |
| R6 | **What notifies** | **Android's rules** (its `Notifier`, DESIGN §4.5): new messages from others as they arrive; not history, the first load, requests, General, reactions or edits. Nothing while Ferry is on screen (the app drops banners in the foreground). |
| R7 | **Android** | **Later:** the same relay can send FCM pushes (Android's E8 option 3), replacing its foreground service if A8 shows battery or Instagram trouble. Not in this plan. |

## 2. What gets built

**The engine, shared** (`core/engine`): today's `core/cmd/igcore/main.go` minus its cgo edges, so the relay reuses the
same login, resume, retry, re-login and socket code (1.6.1's fixes included). `cmd/igcore` becomes the cgo and JNI
shim; no export or behaviour changes for iOS or Android (Android pins a commit). The relay runs it read-only: one
mailbox page per account at start (names for the notifications), then the socket; a new thread's first message reads
that thread once (the engine does that today); never "Seen", typing, sends or folder paging. C6 counts per account
per day in its log.

**The relay** (`core/cmd/relay`, no new dependencies: HTTP/2, ES256 and JSON are in Go's standard library):
- A small HTTPS API for the app at the relay's public name (R4): pair a phone with a one-time invite code from the
  relay's operator, which gives the phone its own random token (in its Keychain; the relay keeps only a hash); then,
  with that token, add an account (relay session cookies, APNs token, sandbox or production), drop it, update the
  APNs token, and status (per account: connected, since when, last error such as a signed-out session).
- Per account, the engine's updates through R6's rules into APNs pushes (`apns-push-type: alert`, `thread-id` per
  chat, the room ID `!ig-<account>-<thread>` in the payload for the tap). APNs' "unregistered" drops the token.
- State: one JSON file (accounts, their cookies, APNs tokens, the phones' token hashes), nothing else on disk.
  Logs counts and errors, never cookies, tokens or message text.
- Config from the environment: the APNs key (`.p8`, yours, on the relay's host only), key ID, team ID, bundle ID,
  listen address.

**Security, kept lightweight** (each measure is a few lines or the platform's own; none needs a new dependency):
- **Read-only by construction:** the engine gets a listen-only mode the relay can't leave, where every send,
  "Seen", typing, edit, unsend, accept and delete is refused before Instagram, with a test for each (as DEBUG's
  `blocked` already does for sends). A bug or a compromised API can't act as an account through the engine.
- **Isolated from the rest of the machine and the home network:** the relay is the one thing reachable from the
  internet, so a break-in there must stop there. It gets its own small virtual machine (a few hundred MB of memory),
  or, if the host has no hypervisor, a hardened rootless container (its own network, non-root, read-only, no
  capabilities, no shared volumes or container socket; weaker, since it shares the host's kernel). It sits on its own
  network segment, and the walls are enforced outside it, by the hypervisor's or the router's firewall, so a
  compromised relay can't rewrite them: inbound, only the forwarded port; outbound, the internet only (Instagram,
  APNs, Let's Encrypt); nothing on the local network, the host or its other services. Inside, the relay runs as a
  sandboxed system service (its own throwaway user, a read-only system with one writable state folder, no new
  privileges) on an unprivileged port, which the router maps from 443. Step 1 opens no port at all, so it can run on
  any machine.
- **A small public surface:** only the relay listens on the box's forwarded port, TLS 1.3 only, with five endpoints.
  Nothing works without a phone token except pairing, which needs a one-time invite code (made on the box by its
  operator, expiring in a day). Tokens are compared in constant time and failed attempts are rate-limited per IP.
  Requests have small size limits and short timeouts. There's nothing to list or browse, and errors say nothing
  about which accounts exist.
- **At rest:** the state file is mode 0600, owned by a user that runs only the relay, on a disk with the OS's own
  full-disk encryption (FileVault or LUKS): a stolen or discarded disk gives nothing. Message text never touches the
  disk; it lives in memory for the second it takes to push.
- **Sessions stay revocable:** each is the relay's own (R2), so ending it in Instagram's "Where you're logged in"
  doesn't touch the phone's. Turning notifications off for an account deletes its cookies on the relay, and Ferry
  says where to end that session at Instagram for good.
- **Problems come as pushes:** a session Instagram ends, or the relay giving up on an account, sends one alert
  ("Notifications for @handle stopped: open Ferry"), so the phone doesn't poll the relay to find out.
- **Keys:** the APNs key lives on the box only (mode 0600), never in the repo; the relay is built from this public
  repo with the pinned Go toolchain, by whoever runs it (R3).

**The app:**
- Push only where signing allows it: an xcconfig switch in `Local.xcconfig` turns on `aps-environment` for the paid
  team; free and CI builds build as today, without notifications.
- Accounts gets a Notifications section (design round first, a UX agent as for 1.5): the relay's address and pairing,
  then per account "Turn on notifications" (the second login, R2), and states: off; on; the relay unreachable since
  … (asked when Accounts opens, with a short timeout); stopped, from the relay's status or its push (log in again
  for notifications). None of it blocks anything else in the app.
- `registerForRemoteNotifications`, the token to the relay; banners dropped while Ferry is in the foreground; a tap
  opens the room in the payload once its account's chats have loaded; reading a chat clears its notifications.
- Remove Account also drops it at the relay (Instagram still isn't told).
- `FERRY_DEBUG_DEMO` and the UI tests never pair, register or ask for permission.

## 3. Steps

Live steps use the dummies only until step 5, with the Android session's LOCK/OK/RELEASED, and report C6 counts.

| Step | What | Who | Estimate |
|---|---|---|---|
| 0 | The paid team in Xcode (a reinstall and new logins if the team changes the Keychain group), an APNs key, R4's box with the relay's isolated VM or container (§2 "Security"), port 443 forwarded to it and a DNS name on your domain (needed from step 3; step 1 needs none of it). | You | — |
| 1 | **Gate: does Instagram tolerate an always-on web session from the relay's host?** A throwaway listener on the box (the spike's ~150 lines on `instameow`, kept outside the app) with a new web session for each dummy, logging connects, reconnects, messages received and any checkpoint, for 5–7 days, a few messages a day from your other phone. **If Instagram signs a session out or asks for a checkpoint, stop:** back to you. | Me, then days elapsed | ½ d + a week |
| 2 | `core/engine` out of `cmd/igcore`, no behaviour change; Go tests and both apps' builds green. | Me | 1–1½ d |
| 3 | The relay: API, store, R6's rules, APNs sender; tests against a fake APNs (`httptest`) and recorded socket events (`core/testdata`). | Me | 1½–2 d |
| 4 | The app: entitlement switch, the Accounts design and flow, token, tap, foreground rule, Remove Account; unit and UI tests on the demo. | Me (UX agent for the design) | 2 d |
| 5 | **A week on your phone:** dummies first, then your accounts. Then README (privacy, opt-in), CHANGELOG, specs, DEVELOPMENT (running a relay), CLAUDE.md (the relay's invariants). | You use it, I check | a week, elapsed |

About 5–6 days of work plus two weeks of soak; a guess, and step 1 decides whether it's worth it.

## 4. Risks

- **Instagram minds an always-on session** (checkpoints, logouts, worse): step 1 is the gate; Android's A8 adds data.
- **The relay or the home connection is down:** no notifications until it's back (messages missed meanwhile don't
  notify); the app is unaffected, and Accounts says so.
- **Whoever runs a relay can read its users' DMs** (R3), and holds sessions that act as them.
- **A relay session ends** (Instagram signs it out): Accounts asks for a new login for notifications only.
- **Two notifications per message** when Instagram's own app is installed with its notifications on: the user's
  setting.
- **APNs environments:** Xcode's Debug builds get sandbox tokens, ad hoc builds production; the app says which.
- **The home IP is public in DNS** and the relay's port is open to the internet: the API is the only thing listening
  (§2 "Security"); a VPS in front (R4's fallback) would hide the IP at the cost of one more machine.

## 5. Not in this plan

Hiding messages from the relay's operator (a hardware enclave; R3), encrypted payloads and a Notification Service
Extension (R5), sender photos, an icon badge, replying from a notification, friends' onboarding (R3), FCM for Android
(R7).
