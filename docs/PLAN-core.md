# Ferry Messenger: connecting `core/` to the app

> **Done, 2026-10-17** (P0–P7; P6's live half: "After parity"). What's left here is the record: the decisions C1–C8,
> which code and CLAUDE.md cite, and each step's results and request counts. Account names are the fictional stand-ins
> (`tamoveska` personal, `kivostudio` professional). The plan itself (where `core/` plugs in, the feature map, the
> order, the risks) is in the repo at tag v1.8.

**Goal, met:** the app does everything in [specs.md](../specs.md) with no Matrix server and no bridge: Instagram
straight from the phone through `core/` (mautrix/meta `v0.2609.0`, `pkg/instameow`).

The results are as of their date. Since then `IGAdapter` became the engine, `core/chat` ([PLAN-android.md](PLAN-android.md)
stage 1), its rules moved there too (stage 2), and some calls changed: `IGFindDM` became `IGOpenDM`, `IGSendNew` became
`IGSend` with `RecipientIGIDs`, `IGSuspend` became `IGPause`/`IGUnpause`, `IGThread` became `IGOpenChat` and
`IGReadChat` (which also stands in for `IGRefreshMedia`), and `IGInboxPage` went: the engine pages the folders itself.

## 1. Decisions first

Each had a recommendation. C3 and C8 were the user's call: both recommendations accepted 2026-10-17.

| # | Question | Recommendation |
|---|---|---|
| C1 | Where Instagram data becomes app data (**replaced 2026-10-19** by [PLAN-android.md](PLAN-android.md) E1: the engine) | **Swift.** `core/` passes the library's own JSON (threads, messages, deltas) through unchanged, minus anything secret; Swift decodes only the fields it uses (`Codable` ignores the rest) and maps them into the model. One language for logic, fixtures straight from the wire, unit-tested like the rest of the app. Go gets no mapping code (mautrix's own converter, `igconv.ToMatrix`, needs a bridgev2 bridge and database, so it can't be reused). |
| C2 | Where `core/` meets the app | **Keep the Matrix-shaped model for the first cut:** a pure `IGAdapter` turns Instagram data into the `Event` / `JoinedRoom` / `MessagesPage` values `Room` already takes, and `AppModel` keeps its methods but calls `core/` instead of `MatrixAPI`, `BridgeAPI` and the sync loop. Views, `Room`, `Timeline` and `Inbox` stay, about 165 of the 273 tests keep their fixtures, and UI fixes still cherry-pick between the repos. An Instagram-native `Room` (rewriting `reduce` and those tests) can come after parity, if the Matrix vocabulary gets in the way. |
| C3 | **Decided 2026-10-17 (recommendation).** The session in the Keychain vs "`core/` never emits cookies to Swift" | Instagram rotates some cookies while a session runs, so the Keychain copy goes stale unless `core/` hands the current set back. Recommend: `IGSession(account)` returns the cookies only for Swift to write straight to the Keychain (never logged, never kept in memory past that write); the rule becomes "cookies leave `core/` only into the Keychain". The alternative is Go writing the Keychain itself through cgo and the Security framework: more code, same exposure. |
| C4 | A local message store | **None for now** (Ferry's D8): each cold launch loads each account's index and mailbox (what instagram.com does on every page load, 1.4–2.3 s in the spike), history loads when a chat opens. Add `LoadState`/`DumpState` (skips the index load) or a store only if cold launch with two accounts is slow. |
| C5 | Shape of the C API | One `instameow.Client` per account in a map keyed by the Instagram user ID (the bridge's login ID, so `accountIdentities` keys stay valid). JSON in, JSON out, `{"error", "code"}` on failure. Calls block, so Swift makes them off the main actor. One event queue for all accounts, polled with `IGNextEvent(timeout)` as in the spike, each event tagged with its account. |
| C6 | Counting Instagram actions | There's no bridge log any more. `core/` counts every Instagram request by operation name, per account, and DEBUG builds log the count (names only, never content). Live checks report it. |
| C7 | Sending "Seen" and typing | Same rule as Ferry: only where `Inbox.allowsReceipts(room)`. Ferry's other source of "Seen", the bridge marking a chat read before every event we send, goes away: `IGMarkRead` is sent only when a chat opens and while it's open. A reply in a request accepts first, then sends (the bridge did the same, `portal.go:1345`). Typing needs the client created with `DisableTyping: false` (the spike used `true`). |
| C8 | **Decided 2026-10-17 (recommendation).** What DEBUG and UI tests sign in with | Ferry injected a Matrix token. Instagram cookies can't be injected (C3), so live UI tests use the accounts already logged in to the simulator's app (its Keychain survives relaunches), and every other UI test uses fixtures (`FERRY_DEBUG_DEMO`, requests, group), which never touch Instagram. Each live launch costs an index load per account: keep live UI tests opt-in, as `testSendVideoAndVoiceNote` is now. |

## 3. The C API

The calls are the `//export`s in [`core/cmd/igcore/main.go`](../core/cmd/igcore/main.go), `IG<Name>` for each
`engine.<Name>` in [`core/engine`](../core/engine/engine.go), whose comments say what each does, and
[`Ferry/IGCore.swift`](../Ferry/IGCore.swift) wraps them for the app (Android: `jni_android.c`, PLAN-android E6). Every
call except `IGLogin` takes the account (Instagram user ID). Never returned: the state dump (web tokens), cookies
(except through `IGSession`, C3), passwords (there are none: the user logs in on instagram.com).

## 5. The steps, as done

Each step ended with the unit tests green, a build, and live checks with the two dummies, with C6's count.

### P0. Fixtures and the open questions

**Done 2026-10-17.** Ferry's dev stack was down, so the capture app (`core/spike/`, `igcapture://p0`) logged in both
dummies and played both sides; the user did both logins. Fixtures: `FerryTests/Fixtures/ig_*.json` (login and
mailbox, thread, an older page and every event for each account, one response per call). The DM with the user's
own account was dropped, as were third-party shares (P5 captures them).

| Question | Answer |
|---|---|
| `folder` / `system_folder` | Every thread has them, the personal account's too: the DM is `PRIMARY` / `INBOX`. **The starting tab is known** (Ferry never had it, Ferry's live capture). |
| Requests | `PENDING` is a valid folder (empty: neither dummy has one). Whether a request also shows under `INBOX` needs a real one (FOLLOWUPS #6). |
| General on `kivostudio` | `GENERAL` is valid and empty (the DM sits in Primary); `PRIMARY` isn't a folder (error). Whether the mailbox's `IsProfessionalAccountGK: false` hides General chats needs a move on the phone (P4). The viewer says `is_professional_account: true`, `has_tabbed_inbox: false`. |
| "Delivered" | **None.** Each new message is followed by two empty `SlideUQPPNotYetImplementedMutation`s. The status line becomes Sending → Sent → Seen. |
| "Seen" | `IGMarkRead` gives the other side `SlideUQPPReadReceipt` (participant FBID + watermark) and the reader `SlideUQPPMarkRead` + `SlideUQPPIGMarkThreadUnread`. A read on another device arrives the same way (captured 3 min after the run). New messages carry `thread_read_state_effect`: `MARK_READ` on our own, `MARK_UNREAD` on incoming. |
| Echo of our sends | The `SlideUQPPNewMessage` carries our `offline_threading_id`, so local echoes clear as planned. |
| Reactions | Changing an emoji arrives as a delete then a create: one per person, kept by Instagram. |
| Typing | `TypingNotification` with the sender's **Instagram user ID** (not the FBID) and the thread's long ID (`thread_id`), so the adapter maps both. Typing goes over the socket: C6 counts it at the C call. |
| Voice notes | `AUDIOS`: an `.mp4` link (AVPlayer plays it), `playable_duration_ms` and `waveform_data`, so real waveforms become possible. |
| Videos, photos | `.mp4` / `.jpg` links with a `preview_cdn_url` and its size: Instagram's videos now get a thumbnail (they didn't through the bridge). View-once is `RAVEN_IMAGE` with no attachment. |
| CDN link lifetime | `oe=` expiry: profile pictures and thumbnails ~4.5 days, attachments 33 h to 30 days. The expiry refresh (`IGRefreshMedia`) is needed. |
| IDs | A delta's `thread_fbid` is `ThreadInfo.id`; in a DM `thread_key` is the other person's FBID; messages send with `id`, unsend and mark read with `thread_id`. |

Instagram actions, from C6: 2 logins and index loads, 2 socket connections, 3 texts, 3 reaction calls, 1 edit, 1
unsend, 1 mark read (2 requests), 2 typing; reads: 7 thread loads, 1 older page, 6 inbox pages.

### P1. Accounts, login and the inbox, read-only

**Done 2026-10-17.** The app runs on `core/` (`IGCore`, `IGAdapter`, `AppModel`); `MatrixAPI`, `ServerConfig`,
`Session`, O2 and their 14 tests are gone, `BridgeAPI` keeps only its types. CI builds `core/` (Go 1.27.1, pinned).
Live, with both dummies logged in by the user: both accounts in the stack and scopes, their DM once per account,
`@handle · Primary` and General for `kivostudio`, "Professional · Primary and General" in Accounts, threads open with
voice notes and video previews from the CDN; a cold relaunch came back from the Keychain without a login, and 60 s
in the background came back connected. Instagram requests per account for a cold launch (C6): the index, the
mailbox, 1–2 folder pages, the socket; opening a chat added its older pages. Nothing was sent.
Found live and fixed: every message carries `replied_to_message_id: ""` (every bubble showed a reply quote), and
"Reacted 😂 to your message" is a log entry (`REACTION_LOG_XMAT`), not a row. Left for P2: the mailbox's copy of a
message has no reactions or edit history, so opening a chat re-reads the thread.

### P2 and P3. The thread, read and write sides

**P2 and P3 done 2026-10-17** (one live check, the app playing both sides). Opening a chat re-reads the thread (at most
every 30 s) for reactions, edit history and reply targets; reactions, edits, unsends, typing, "Seen" and group changes
apply live through `IGAdapter.apply`, which the tests replay P0's whole run through. Sending: text and replies with
a local echo keyed by the offline threading ID (the socket's echo replaces it), retry with the same ID, react and
unreact, edit, unsend, typing (once per 20 s), "Seen" when a chat opens, never in requests (C7).
Live, in the dummies' DM, each action from one account checked in the other's chat: text and reply arrive with their
quote, ❤️ shows on both sides, the edit shows "Edited", "Seen" appears once the other side opens the chat, the unsend
leaves "You unsent a message" on the sender's side (Instagram drops it on the other side's re-read). Unread shows on
the scope chips and clears on open.
Found live and fixed: typing was matched to a thread by its long ID only, which both accounts' rooms share; a reply
whose target was unsent showed "Loading…" (now "Unsent message"); unsending the only unread message left the chat
unread. Not checked live: typing shown on the receiving side (both sides are one app on one screen; the mapping is
unit-tested and typing notices were seen arriving). The request counts of that session were lost (a test run
replaced the app before it logged them); about 3 texts, 1 reaction, 1 edit, 1 unsend, 2 "Seen", a few typing notices.

### P4. Requests, General, Archived, New message

**Done 2026-10-17.** Requests: Accept and Delete through `core/` (`IGAccept`, `IGDeleteThread`), a reply in a request
accepts first, a request accepted or a thread deleted elsewhere re-reads or removes the room. General: Instagram's
`folder` when a thread loads, and the raw `SlideUQPPIGMoveThread` (`ig_inbox_folder`) live, with no re-read. Archive:
on this device (`UserDefaults` `archived`), read as the room's `u.archived` tag, so a new message still brings a chat
back. New Message: `IGSearch`; an existing DM opens without asking Instagram; Instagram's existing thread is read once
(`IGFindDM`); anyone else gets a draft chat (not in the inbox) whose first message makes the thread (`IGSendNew`), and
the draft then leads to the real chat.
Live: archive and unarchive (nothing sent, kept across a relaunch); New Message as `tamoveska` found `kivostudio` and
opened their DM; the Requests card and Folders badge on the DEBUG request fixtures. Requests, groups and a Primary/General
move need a third account or the user's phone (FOLLOWUPS #6, #24); the move is tested with Ferry's captured deltas. The draft path is
checked live in the "new DM missing from the list" repro. Found live and fixed: reopening a read chat sent "Seen" again.

### P5. Media

**Done 2026-10-17.** Incoming photos, videos and voice notes load from Instagram's CDN (thumbnails as rows appear,
files on tap); a failed download re-reads the thread for fresh links. Shares (XMA) map to the bridge's shapes: a
reel or story waits for "Load video" (`IGResolveMedia`: `FetchMedia`/`FetchReel`, the best video, else image), which
swaps the card through a hidden edit; a post is its image; a link off Instagram is a link preview; an expired story
its notice. Sending: `IGSendMedia` uploads the file Swift prepared (`SendMercuryUploadRequest` to the thread key, then
`SendMedia`), with the local echo and ring; when the echo arrives our file is filed under Instagram's link and type.
Live, `tamoveska` → `kivostudio`: a voice note (the DEBUG voice file), a photo and a 6 s video all arrived; the video
downloaded on the other side (Instagram's 207 KB MP4) and an old shared reel resolved and downloaded (a 59.9 s MP4).
Not checked: sound. The Mac's audio output couldn't start (`AudioQueueStart failed`), so AVFoundation refused to play
anything with sound (the CLAUDE.md trap); the files themselves are valid. Requests per account: 3 uploads and 3 media
sends; 1 media fetch for the reel. No Android upload fallback for videos yet (the web upload worked).

### P6. Account health, re-login, remove

**Code done 2026-10-17; the live half waits for the user.** Health comes from `core/`'s events (`AuthError` →
`BAD_CREDENTIALS` with Instagram's reason; `Disconnected` → `TRANSIENT_DISCONNECT`, retried every 30 s); A3 logs in
through the same sheet and refuses another account (a stranger's client is stopped); Remove stops the client, deletes
the Keychain item and drops the chats, telling Instagram nothing. Checked in the simulator with
`FERRY_DEBUG_LOGIN_STATE` on `kivostudio`: the stack's and chip's badges, the banner, A3's sheet ("Log in to Kivo
Studio again", "Tamo Veska keeps working."), dismissed without logging in. Still to do with the user: a real sign-out
(the web session removed on the phone) → banner → A3 login, and Remove + re-add of `kivostudio` (one login each).

### P7. Cleanup and docs

**Done 2026-10-17.** Gone: `JoinedMember(s)` (members come from the thread), `trackingTransient` (the bridge re-stamped
its state; `AppModel.setStatus` keeps the first time), whoami's type in the app (a test helper now), two unused
captures, the Requests footer about requests from before login (the whole Requests folder loads now), and the
DEBUG comments about `MatrixAPI`. `FERRY_DEBUG_DEMO` now stands two made-up accounts in for the Keychain's and never
connects, so the UI tests run on it (C8): 6 run on made-up data, 4 opt-in (2 live, the Connect sheet, the design
tour). The live send test expects "Sent" (no "delivered" on Instagram). The design tour ran in both appearances
(14 screens each, `docs/verification/p7-tour/`, gitignored); it caught request fixtures stuck on a top spinner (they
now start at the chat's start). README, CLAUDE.md and `specs.md` describe the app as built. 279 unit tests.

### After parity (2026-10-17)

- **"A new DM doesn't show in the list until they reply"** (reported on Ferry): not in Ferry Messenger. Live:
  kivostudio → a third test account with no thread: the draft's first message made the thread, the socket loaded it,
  and the chat showed in Chats, live and after a relaunch (Instagram lists it `PRIMARY`/`INBOX`). The cause is Ferry's
  bridge patch: Instagram's first `UpdateThreadFolder` for a DM a professional account starts says `GENERAL`, and the
  patch stores it as the tab. Found on the way: a re-read cleared a General chat's tab here (fixed, `keepingFolder`).
- **P6 live:** `FERRY_DEBUG_ENDED_SESSION` on kivostudio: Instagram rejected the session, and the banner, badges, A2
  ("Signed out") and A3 came from that answer; a plain launch brought it back with no login. A3's login and Remove +
  re-add still wait for the user. Seen on the way: a signed-out account's chats aren't shown at all (nothing is
  stored, D8), though A3 says "Your chats are safe".
- **GIFs, no outside service:** incoming GIFs play in the chat; GIFs from Photos and pasted GIF links go as GIFs,
  which Instagram turns into its own GIFs (live, both directions: a made-up GIF from Photos and a public-domain GIF
  from Wikimedia). Cost: 2 uploads, 2 media sends, 1 "Seen" between the dummies.

What the two dummies can't cover (a real request, a group, a Primary ↔ General move on the phone) is in
[FOLLOWUPS.md](FOLLOWUPS.md) #5, #6 and #24.
