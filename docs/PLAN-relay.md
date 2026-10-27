# Ferry Messenger: notifications through a relay (plan)

> Draft, 2026-10-27: R1–R4 decided the same day (R3 trust, R4 hosting is the operator's choice); R5–R7 wait for
> the user, nothing is built. The user's brief: as simple and lightweight as possible, and as secure as that
> allows. Follows [PLAN-push.md](PLAN-push.md), whose catch-up notifications were removed in 1.6.3 because Instagram's
> web push hardly ever arrived. Account names are the fictional stand-ins (`tamoveska` personal, `kivostudio`
> professional).

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
| R1 | **The relay's source: its own live Instagram connection** (web push measured unreliable, the dummy rerun declined) | **Decided 2026-10-27: go ahead**, gated on step 1: an always-on web session from the relay's host for several days on the dummies, with no checkpoint or forced logout. Android's A8 is measuring the same question for its foreground service; share the results. |
| R2 | **Which session the relay uses** | **Decided 2026-10-27: its own:** a second login by hand in Ferry's web view ("Turn on notifications for @handle"), whose cookies go straight to the relay over TLS and are never stored on the phone. Not a copy of the phone's session: Instagram rotates cookies mid-session (C3), so two clients on one session would drift apart. It shows as one more web session in Instagram's "Where you're logged in". |
| R3 | **Who uses a relay, and whom they trust** | **Decided 2026-10-27: trust in whoever builds and runs the relay is what counts;** no hardware enclave (weeks of work and a cloud machine, for friends' scale). Your accounts first; friends on ad hoc installs later, each told when they turn notifications on that whoever runs the relay could read their DMs; self-builders run their own relay with their own APNs key (the app takes any relay address). |
| R4 | **Where a relay runs, and how phones reach it** | **Decided 2026-10-27: the operator's choice.** The relay only needs a public HTTPS address the phones can reach (a name on the operator's own domain, say), and Ferry takes any address; where and how to host it is up to whoever runs it (§3: principles and the VPS-or-home trade-off, nothing prescribed). Your own setup is in your private notes, `docs/local/relay-setup.md` (gitignored). |
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
- A small HTTPS API for the app at the relay's public address (R4): pair a phone with a one-time invite code from the
  relay's operator, which gives the phone its own random token (in its Keychain; the relay keeps only a hash); then,
  with that token, add an account (relay session cookies, APNs token, sandbox or production), drop it, update the
  APNs token, and status (per account: connected, since when, last error such as a signed-out session).
- Per account, the engine's updates through R6's rules into APNs pushes (`apns-push-type: alert`, `thread-id` per
  chat, the room ID `!ig-<account>-<thread>` in the payload for the tap). APNs' "unregistered" drops the token.
- TLS, the operator's pick: a certificate the relay gets and renews itself from Let's Encrypt when given a domain
  (`golang.org/x/crypto/acme/autocert`, already pinned at v0.57.0 through mautrix, so no new module); certificate
  files the operator provides; or plain HTTP, only when explicitly told it sits behind the operator's own TLS proxy,
  which the docs warn must not carry the decrypted traffic across machines or services the operator doesn't control
  (pairing carries Instagram cookies).
- State: one JSON file at a path the operator chooses (accounts, their cookies, APNs tokens, the phones' token
  hashes), nothing else on disk. Logs counts and errors, never cookies, tokens or message text.
- Config from flags or the environment: the path to the APNs key (`.p8`, the operator's, never in the repo), key ID,
  team ID, bundle ID, listen address, TLS mode, state path.

**Security built into the relay** (the same for everyone who runs one; each measure is a few lines, none needs a new
dependency):
- **Read-only by construction:** the engine gets a listen-only mode the relay can't leave, where every send,
  "Seen", typing, edit, unsend, accept and delete is refused before Instagram, with a test for each (as DEBUG's
  `blocked` already does for sends). A bug or a compromised API can't act as an account through the engine.
- **A small surface:** five endpoints, TLS 1.3 when the relay ends TLS itself. Nothing works without a phone token
  except pairing, which needs a one-time invite code (made by the relay's operator, expiring in a day). Tokens are
  compared in constant time and failed attempts are rate-limited per IP. Requests have small size limits and short
  timeouts. There's nothing to list or browse, and errors say nothing about which accounts exist.
- **At rest:** the relay writes only its state file, readable by its own user alone (0600), and never message text,
  which lives in memory for the second it takes to push.
- **Sessions stay revocable:** each is the relay's own (R2), so ending it in Instagram's "Where you're logged in"
  doesn't touch the phone's. Turning notifications off for an account deletes its cookies on the relay, and Ferry
  says where to end that session at Instagram for good.
- **Problems come as pushes:** a session Instagram ends, or the relay giving up on an account, sends one alert
  ("Notifications for @handle stopped: open Ferry"), so the phone doesn't poll the relay to find out.
- **Keys:** the relay reads the APNs key from a path its operator gives; the repo never holds one. It's built from
  this public repo with the pinned Go toolchain, by whoever runs it (R3).

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

## 4. Steps

Live steps use the dummies only until step 5, with the Android session's LOCK/OK/RELEASED, and report C6 counts.

| Step | What | Who | Estimate |
|---|---|---|---|
| 0 | The paid team in Xcode (a reinstall and new logins if the team changes the Keychain group), an APNs key, your relay's host set up your way (`docs/local/relay-setup.md`) with its public HTTPS address (needed from step 3; step 1 needs neither). | You | — |
| 1 | **Gate: does Instagram tolerate an always-on web session from the relay's host?** A throwaway listener on the relay's host, which opens no port: `core/cmd/relaygate` (built 2026-10-27; `build.sh` makes both programs for Macs with either chip), with `relaygate-login` for the logins by hand, piping each session straight into it with a new web session for each dummy, logging connects, reconnects, messages received and any checkpoint, for 5–7 days, a few messages a day from your other phone. **If Instagram signs a session out or asks for a checkpoint, stop:** back to you. | Me, then days elapsed | ½ d + a week |
| 2 | `core/engine` out of `cmd/igcore`, no behaviour change; Go tests and both apps' builds green. | Me | 1–1½ d |
| 3 | The relay: API, store, R6's rules, APNs sender; tests against a fake APNs (`httptest`) and recorded socket events (`core/testdata`). | Me | 1½–2 d |
| 4 | The app: entitlement switch, the Accounts design and flow, token, tap, foreground rule, Remove Account; unit and UI tests on the demo. | Me (UX agent for the design) | 2 d |
| 5 | **A week on your phone:** dummies first, then your accounts. Then README (privacy, opt-in), CHANGELOG, specs, DEVELOPMENT (running a relay), CLAUDE.md (the relay's invariants). | You use it, I check | a week, elapsed |

About 5–6 days of work plus two weeks of soak; a guess, and step 1 decides whether it's worth it.

## 5. Risks

- **Instagram minds an always-on session** (checkpoints, logouts, worse): step 1 is the gate; Android's A8 adds data.
- **The relay or its connection is down:** no notifications until it's back (messages missed meanwhile don't
  notify); the app is unaffected, and Accounts says so.
- **Whoever runs a relay can read its users' DMs** (R3), and holds sessions that act as them.
- **A relay session ends** (Instagram signs it out): Accounts asks for a new login for notifications only.
- **Two notifications per message** when Instagram's own app is installed with its notifications on: the user's
  setting.
- **APNs environments:** Xcode's Debug builds get sandbox tokens, ad hoc builds production; the app says which.

## 6. Not in this plan

Hiding messages from the relay's operator (a hardware enclave; R3), encrypted payloads and a Notification Service
Extension (R5), sender photos, an icon badge, replying from a notification, friends' onboarding (R3), FCM for Android
(R7).
