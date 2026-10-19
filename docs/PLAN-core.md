# Ferry Messenger: connecting `core/` to the app (plan)

> Draft, 2026-10-16. Account names are the fictional stand-ins (`tamoveska` personal, `kivostudio` professional).

**Goal:** the app does everything in [specs.md](../specs.md) (Ferry's as-built list) with no Matrix server and no
bridge: Instagram straight from the phone through `core/` (mautrix/meta `v0.2609.0`, `pkg/instameow`). Push stays
out, as in Ferry (D6); the README's open decision on notifications is separate.

Library references are to mautrix/meta `v0.2609.0` (`dec2e1e`): `instameow/` is the client, `igconnector/` is the
bridge glue we replace, so it shows how each call is used.

## 1. Decisions first

Each has a recommendation. C3 and C8 were the user's call: both recommendations accepted 2026-10-17.

| # | Question | Recommendation |
|---|---|---|
| C1 | Where Instagram data becomes app data (**replaced 2026-10-19** by [PLAN-android.md](PLAN-android.md) E1: the engine) | **Swift.** `core/` passes the library's own JSON (threads, messages, deltas) through unchanged, minus anything secret; Swift decodes only the fields it uses (`Codable` ignores the rest) and maps them into the model. One language for logic, fixtures straight from the wire, unit-tested like the rest of the app. Go gets no mapping code (mautrix's own converter, `igconv.ToMatrix`, needs a bridgev2 bridge and database, so it can't be reused). |
| C2 | Where `core/` meets the app | **Keep the Matrix-shaped model for the first cut** (§2): a pure `IGAdapter` turns Instagram data into the `Event` / `JoinedRoom` / `MessagesPage` values `Room` already takes, and `AppModel` keeps its methods but calls `core/` instead of `MatrixAPI`, `BridgeAPI` and the sync loop. Views, `Room`, `Timeline` and `Inbox` stay, about 165 of the 273 tests keep their fixtures, and UI fixes still cherry-pick between the repos. An Instagram-native `Room` (rewriting `reduce` and those tests) can come after parity, if the Matrix vocabulary gets in the way. |
| C3 | **Decided 2026-10-17 (recommendation).** The session in the Keychain vs "`core/` never emits cookies to Swift" | Instagram rotates some cookies while a session runs, so the Keychain copy goes stale unless `core/` hands the current set back. Recommend: `IGSession(account)` returns the cookies only for Swift to write straight to the Keychain (never logged, never kept in memory past that write); the rule becomes "cookies leave `core/` only into the Keychain". The alternative is Go writing the Keychain itself through cgo and the Security framework: more code, same exposure. |
| C4 | A local message store | **None for now** (Ferry's D8): each cold launch loads each account's index and mailbox (what instagram.com does on every page load, 1.4–2.3 s in the spike), history loads when a chat opens. Add `LoadState`/`DumpState` (skips the index load) or a store only if cold launch with two accounts is slow. |
| C5 | Shape of the C API | One `instameow.Client` per account in a map keyed by the Instagram user ID (the bridge's login ID, so `accountIdentities` keys stay valid). JSON in, JSON out, `{"error", "code"}` on failure. Calls block, so Swift makes them off the main actor. One event queue for all accounts, polled with `IGNextEvent(timeout)` as in the spike, each event tagged with its account. |
| C6 | Counting Instagram actions | There's no bridge log any more. `core/` counts every Instagram request by operation name, per account, and DEBUG builds log the count (names only, never content). Live checks report it. |
| C7 | Sending "Seen" and typing | Same rule as Ferry: only where `Inbox.allowsReceipts(room)`. Ferry's other source of "Seen", the bridge marking a chat read before every event we send, goes away: `IGMarkRead` is sent only when a chat opens and while it's open. A reply in a request accepts first, then sends (the bridge did the same, `portal.go:1345`). Typing needs the client created with `DisableTyping: false` (the spike used `true`). |
| C8 | **Decided 2026-10-17 (recommendation).** What DEBUG and UI tests sign in with | Ferry injected a Matrix token. Instagram cookies can't be injected (C3), so live UI tests use the accounts already logged in to the simulator's app (its Keychain survives relaunches), and every other UI test uses fixtures (`FERRY_DEBUG_DEMO`, requests, group), which never touch Instagram. Each live launch costs an index load per account: keep live UI tests opt-in, as `testSendVideoAndVoiceNote` is now. |

## 2. Where `core/` plugs in

The views depend on `AppModel`'s surface, `Room`'s computed properties, `Message` / `Row`, the `Inbox` rules,
`BridgeAPI.Login` (health), `AccountIdentity` and `MediaCache`. Only two view lines touch raw Matrix data
(`ThreadView.swift:180` `room.events.last?.eventID`, `:263` `room.prevBatch`; an Instagram cursor fits the latter).
`DebugFixtures` already builds `Room`s from hand-made events, the same path `IGAdapter` takes.

**Replaced:** `MatrixAPI.swift` (279 lines), `BridgeAPI.swift` (194), `SyncTypes`' sync loop in `AppModel`
(`:182–252`), `Session` (`Keychain.swift`), `ServerConfig` (`FerryApp.swift:35`), O2 `SignInView`.

**New:** `IGCore.swift` (the C calls, off the main actor, and the event poll), `IGAdapter.swift` (pure,
`nonisolated`, fixture-tested): Instagram thread → `JoinedRoom` with a synthetic `m.bridge` (`fi.mau.receiver` = the
account, channel ID, request flag, room type, folder), `m.room.name`, `m.room.member` (names, pictures, handles);
message → `m.room.message` with Ferry's `content` shapes; reactions → `m.reaction`; edits → `m.replace`; unsends →
`m.room.redaction`; read watermarks and typing → ephemeral `m.read` / `m.typing`; the offline threading ID →
`unsigned.transaction_id`, so local echoes clear as they do now. Each account's own Instagram ID maps to the one
"me" user ID the views already compare against (`model.session?.userID`, 6 places), as Ferry's double puppet did.

**Couplings to rework whatever the model** (from the code map):

| Coupling | Where | Change |
|---|---|---|
| Media are `mxc://` URIs through Synapse | `MediaCache.thumbnail/file` take `MatrixAPI`; `fileName` accepts only `mxc://` (`MediaCache.swift:58`, `:93`, `:159`) | Key by Instagram media ID, fetch the CDN URL, refresh on 403. Uploads: no `mxc`; the `local:` echo stays, and the sent file is filed under the media ID that comes back. |
| Views parse `Message.content` | `MediaViews`, `PlayerView`, `MessageViews:277`, `ThreadView:285` | The adapter writes the `content` shapes they read (`msgtype`, `info`, URL, the XMA caption, `com.beeper.linkpreviews`), so the views don't change. |
| Unresolved reels and stories | `AppModel.swift:623–642`, `MediaViews:72` | The adapter marks an XMA without media `com.beeper.unresolved_media`; `IGResolveMedia`'s result arrives as a synthetic edit, the swap the views already handle. |
| Send status and retry | `AppModel.swift:283–301` relies on Synapse's idempotent txn IDs | Retry with the same offline threading ID; P3 checks Instagram doesn't send it twice. Failures become a synthetic `com.beeper.message_send_status`. |
| Requests | Accept/Delete are Matrix events; failure found by scanning events (`Inbox.swift:378`); the optimistic accept clears when `m.bridge` loses the flag (`Room.swift:84`) | Call `core/`, then feed an `m.bridge` without the flag (or a failure status). `allowsReceipts` is unchanged. |
| Archive | `u.archived` tag (`AppModel.swift:520`) | The local store from §4, fed into `Room.tags`. |
| Members, handles | `/joined_members`, `/profile`, `bridgeBot` (`Inbox.swift:103–163`, `AppModel.swift:404–446`) | From the thread's `users`; no bot. The extra `/profile` and `/joined_members` calls go. |
| Reply target outside the window | `/event` (`AppModel.swift:613`) | Messages carry `replied_to_message`: the adapter fills `related` directly. |
| Account health, professional flag | Bridge `state_event` strings (`BridgeAPI.swift:91`), patched whoami | Core's connection events mapped to the same strings; the viewer's `is_professional_account`. |
| Sign-in gate and copy | `RootView.swift:14` (`session == nil`), banners (`Inbox.swift:457`), Accounts footer and Sign Out (`AccountsView.swift:38/52/206`) | Gate on "no accounts"; one "Can't reach Instagram" banner; no Sign Out (each account has Remove). |
| Login | `ConnectSheet` calls `model.bridge` directly; `LoginStep` comes from the bridge | `CookieGate` gets a local cookie list (the eight the bridge asks for, as the spike did) and `ConnectSheet` calls `AppModel`. |

**Tests:** about 165 Matrix-shaped tests keep their fixtures (Timeline, Room, Group, Inbox, MediaKind, Request);
about 90 aren't model tests and stay; `ServerConfigTests` (11) and `LoginStepDecodingTests` (3) go with their code;
`NewMessageTests` (5) and `CookieGateTests`' fixture move to Instagram data. New: `IGAdapterTests` on P0's fixtures,
one per mapping rule.

## 3. The C API

What `core/cmd/igcore` grows into. Every call takes the account (Instagram user ID) except `IGLogin`. "Library"
is the `instameow.Client` method; the `igconnector/` file shows the bridge doing the same.

| C call | Library | Bridge reference | Notes |
|---|---|---|---|
| `IGLogin(cookies)` | `NewClient`, `LoadIndex`, `go Connect` | `login.go`, `client.go:143` | Returns the viewer: ID, username, full name, picture URL, `is_professional_account` (Ferry's patch read the same `ViewerData`). Also used for re-login; Swift refuses a different account ("Log in as @handle"). |
| `IGResume(account, cookies)` | same | | Cold launch, cookies from the Keychain. |
| `IGSession(account)` | `GetCookies` | `client.go:136` | C3: the result goes straight into the Keychain. |
| `IGNextEvent(timeout)` | event handler | `handlemeta.go:92` | `{account, kind, at}` plus a delta's wire JSON (`Delta.Raw`, so `SlideUQPPIGMoveThread`, which upstream doesn't map, arrives too and Swift decodes it), typing, or an error. Built in P0. |
| `IGInboxPage(account, folder, cursor)` | `PaginateMailbox` | `chatsync.go:152` | First page comes with `IGLogin`'s mailbox. Folder `INBOX`; whether requests need `PENDING` is a P0 question. |
| `IGThread(account, thread)` | `GetThread` | `backfill.go:52`, `chatinfo.go:42` | Info, members, latest messages, read watermarks. |
| `IGOlder(account, thread, cursor, message)` | `PaginateMessages` | `backfill.go:155` | After the last page's end cursor, else older than `message`. Built in P0. |
| `IGSend(account, thread, text, replyTo, otid)` | `SendMessage` | `handlematrix.go:163`, `igconv/from-matrix.go` | `otid` from Swift (an epoch ID: ms << 22 + 22 random bits), so the socket's echo replaces the local echo. A new DM sends with `RecipientIGIDs` instead of a thread. |
| `IGSendMedia(account, thread, path, mime, voice, replyTo, otid)` | `GetHTTP().SendMercuryUploadRequest`, then `SendMedia` | `handlematrix.go:165`, `msgconv/mediadl/upload.go:38` | Port `ReuploadFileToMeta` without bridgev2 (it only downloads from Matrix first), including the Android fallback for videos (`upload.go:104`). Go reads the file Swift prepared. |
| `IGReact(account, thread, message, emoji, remove)` | `SendReaction` | `handlematrix.go:205`, `:240` | Remove = `ReactionStatusDeleted`. |
| `IGEdit(account, thread, message, text)` | `EditMessage` | `handlematrix.go:263` | |
| `IGUnsend(account, threadLong, message)` | `UnsendMessage` | `handlematrix.go:289` | |
| `IGMarkRead(account, threadLong, message, ts)` | `MarkRead` + `MarkReadValidation` | `handlematrix.go:323`, `:333` | Both, as the bridge does. Sends "Seen". |
| `IGTyping(account, thread, on)` | `SetTyping` | `handlematrix.go:484` | |
| `IGAccept(account, thread)` | `AcceptMessageRequest` | `handlematrix.go:383` | |
| `IGDeleteThread(account, thread)` | `DeleteThread` | `handlematrix.go:369` | Request Delete. |
| `IGSearch(account, query)` | `SearchUsers` | `startchat.go:165` | |
| `IGFindDM(account, user)` | `FetchThreadID`, else `GetUserForNewDM` | `startchat.go:76`, `handlematrix.go:105` | Existing thread or a user to start one with. |
| `IGResolveMedia(account, …)` | `FetchMedia`, `FetchReel` | `directmedia.go:385`, `igconv/xma.go:202` | Unresolved reels and stories. |
| `IGRefreshMedia(account, thread, message)` | `PaginateMessages` / `GetThread` | `directmedia.go:184` | CDN links expire; refetch the message for fresh ones. |
| `IGSuspend(account)`, `IGStop(account)` | `Disconnect` | `client.go:375` | Suspend when the app leaves the foreground, `Connect` again on return (the spike: catch-up 30 ms after reconnecting). |
| `IGCounts()` | | | C6: requests per account since login, by operation, plus `socket connect` and `typing (socket)`. Built in P0. |
| `IGSetCapture(dir)` | | | DEBUG builds only: writes everything `core/` hands to Swift under `dir/<account>/`, for fixtures. Built in P0. |
| `IGStats()`, `IGFree(p)` | | | As now. |

Never returned: the state dump (web tokens), cookies (except C3), passwords (there are none: the user logs in on
instagram.com).

## 4. Feature map (specs.md, section by section)

**Gone with the server** (deleted, not ported): O2 Sign in and its Server field, `Session.homeserver`,
`ServerConfig`, provisioning URLs, the Matrix Sign Out, the A1 footer's `@me:server · localhost:8008`, the
"Can't reach your server" and "Instagram bridge is offline" banners (replaced by one "Can't reach Instagram"), the
DEBUG token and server switches, `FERRY_DEBUG_AS_REQUEST`'s server-side blocking (requests are blocked in `core/`'s
caller instead), ghost `/profile` lookups and the bridge's echoes the reducer absorbs (harmless to keep).

| specs.md | Today (Matrix) | On device | C calls |
|---|---|---|---|
| Rules: color means account, one chat per account | Room's `fi.mau.receiver` | The account the event came from. A thread both dummies share is two chats, one per account, as with `split_portals`. | — |
| Rules: which rooms are chats | `m.bridge` `instagramgo` | Every thread in the mailbox. | `IGLogin`, `IGInboxPage` |
| Rules: sync only while open | `/sync` long-poll, whoami poll | Socket while active; `IGSuspend` in the background; state from `Connected` / `Disconnected` / `ReconnectionStateUpdate` / `AuthError` mapped to Ferry's login states (`CONNECTED`, `TRANSIENT_DISCONNECT`, `BAD_CREDENTIALS`, …) so the UI is unchanged. | `IGNextEvent`, `IGSuspend` |
| Rules: order and unread | Last message's time; Synapse notification count | Last message's time (`slide_messages`, else `last_activity_timestamp_ms`). Unread: newest incoming message after our read watermark (`slide_read_receipts` for our ID), or `marked_as_unread`; `MarkReadEvent` from another device clears it. | `IGThread`, events |
| Rules: Primary/General | Our bridge patch | `ThreadInfo.folder` / `system_folder` (may give the starting tab Ferry never had, P0 checks) and `SlideUQPPIGMoveThread` live. Professional: the viewer's `is_professional_account`. No patch. | `IGLogin`, events |
| Rules: read receipts, typing | `m.read`, typing | `IGMarkRead`, `IGTyping`, same rules (C7). | |
| O1, O5, O6, app icon, launch screen, composer, M1 player, M2 viewer, voice recording | Local | Unchanged (the player and viewer play local files). | — |
| O3 Connect | Web view → provisioning `login/step` | Same web view and `CookieGate`; cookies → Keychain → `IGLogin`. No `login/cancel` needed. | `IGLogin` |
| O4 Connecting | Login → whoami → first sync | Logged in (cookies) → connected as @handle (`IGLogin`) → syncing (mailbox pages, counting chats). | `IGLogin`, `IGInboxPage` |
| I1 inbox, scope bar, folders menu, badges | Rooms + whoami | Same views over the new source. Paging: load the whole mailbox in the background after the first page, one request per page, as the bridge did (`chatsync.go:91`), so search and counts see everything. | `IGInboxPage` |
| I1 banners | Server, bridge, account | "Can't reach Instagram" (socket down over 2 failed reconnects), signed out (`AuthError`), erroring, reconnecting > 2 min. | events |
| I5 search | Local | Unchanged. | — |
| I2 Requests | `com.beeper.message_request` | `system_folder` `PENDING` / `SPAM` (`chatinfo.go:257`), `UpdateThreadFolderEvent` live. Accept, Delete, reply-accepts as C7. The "seen" marker stays local. | `IGAccept`, `IGDeleteThread`, `IGSend` |
| I3 General | Patch | As in Rules. | — |
| I4 Archived | `u.archived` tag on the server | Local: `UserDefaults` per account, thread ID → archived-at (ms). A new message still brings it back. Lost on reinstall (Ferry's survived on the server). | — |
| N1 New message | `search_users`, `create_dm` | `IGSearch`; an existing DM opens; otherwise `IGFindDM`, and the thread exists on Instagram only after the first message (`RecipientIGIDs`), so until then it's a local draft chat. | `IGSearch`, `IGFindDM`, `IGSend` |
| T1 timeline | Room events → `Timeline.reduce` | Messages carry their reactions, reply target (`replied_to_message`, so no extra fetch), edit history and sender. Live: `NewMessageEvent`, `EditMessageEvent`, `CreateReactionEvent` / `DeleteReactionEvent`, `DeleteMessageEvent` (unsend), `TypingNotification`, `ReadReceiptEvent`. | `IGThread`, `IGOlder`, events |
| T1 status line | Local echo, send status, receipts | Sending (local echo) → Sent (`IGSend` returns) → Seen (the other side's watermark passes it). **Instagram sends no delivered signal** (P0), so the line skips Delivered. | `IGSend`, events |
| T1 context menu | `m.reaction`, `m.replace`, redaction | React (one per person, same emoji again removes), Reply, Copy, Edit (15 min, 5 edits), Unsend. | `IGReact`, `IGEdit`, `IGUnsend` |
| T1 groups | Member events, ghost profiles | `users`, `nicknames` in the thread: real names and handles always, no localpart fallback needed. | `IGThread` |
| T1 header, T3 handle | Ghost `com.beeper.bridge.identifiers` | `username` from the thread: always known. | — |
| T2 request thread | Bridge flags | As I2. | |
| T3 chat info, members | `/joined_members` | The thread's `users` (+ You). Read-only, as now. | `IGThread` |
| Media: incoming photo, video, voice | Matrix media through the bridge | Instagram's CDN links, downloaded on tap to `Caches/media` as now; on 403, `IGRefreshMedia` and retry. Voice notes arrive as `.mp4` with a duration and waveform (P0); videos with a preview image. | `IGRefreshMedia` |
| Media: reels, posts, stories, links | Bridge's `ToMatrix`, `resolve_media` | XMA fields (`igconv/xma.go`): header title is the reel's author (what Ferry's patch added), preview, caption. Unresolved → `IGResolveMedia`. | `IGResolveMedia` |
| Media: view-once | Bridge notice | Message's view-expiry fields → the same "Open Instagram" card. | — |
| Sending photo, video, voice | Upload to Synapse, bridge re-uploads | Same Swift preparation (`PhotoMessage.encode`, `VideoMessage.prepare`, `.m4a`), then `IGSendMedia` with the file. Voice = `IsVoiceClip`, `audio/mp4`, as the bridge sent it. | `IGSendMedia` |
| A1 accounts | whoami | Accounts from the Keychain; avatar, name, handle, professional from the viewer; status from events. Reorder unchanged. | `IGLogin`, events |
| A2 Remove Account | `POST /v3/logout` (deletes rooms) | Stop the client, delete the Keychain item, drop its chats. Instagram isn't told (the web session stays in "Where you're logged in"), as in Ferry. | `IGStop` |
| A3 re-login | Provisioning with `login_id` | Web view, then `IGLogin` must return the same account. | `IGLogin` |
| DEBUG fixtures | Fixture rooms | Unchanged where they build model data; their sends are refused before reaching `core/`. | — |

## 5. Order

Each step ends with the unit tests green, a build, and the live checks listed, with the Instagram action count
from C6. Live checks use the simulator and the two dummies only. Until P3 the other side of a conversation is
the capture app (`core/spike/`, logged in as the other dummy; P0 did this) or the user's phone; Ferry's dev stack
works too, but its bridge marks the chat read before each of its sends.

### P0. Fixtures and the open questions (½–1 d)

- `core/`: the per-account client map (C5), `IGLogin`, `IGNextEvent` pass-through, `IGThread`, `IGInboxPage`, the
  action counter (C6). A DEBUG-only capture (`FERRY_DEBUG_CAPTURE=<host dir>`) writes what arrives as JSON.
- Scrub (names, IDs, URLs to the fictional mapping in `docs/local/test-accounts.md`) and commit as
  `FerryTests/Fixtures/ig_*.json`.
- Answers it must bring: what `folder` / `system_folder` say for each dummy's DM; whether requests come with the
  `INBOX` mailbox or need `PENDING`; whether `IsProfessionalAccountGK: false` (hardcoded in
  `MakeMailboxRequest`) hides General threads on `kivostudio`; any "delivered" signal; the format of an incoming
  voice note; how long a CDN link lives.
- **Live:** `tamoveska`: log in, mailbox, open the DM, capture a text, a reaction, an edit and an unsend sent from
  Ferry as `kivostudio`, and one "Seen" (opened in Ferry). `kivostudio`: log in, mailbox, the same DM from its side.
  About 2 logins, 2 index loads, 4 sends, 1 "Seen".

**Done 2026-10-17.** Ferry's dev stack was down, so the capture app (`core/spike/`, `igcapture://p0`) logged in both
dummies and played both sides; the user did both logins. Fixtures: `FerryTests/Fixtures/ig_*.json` (login and
mailbox, thread, an older page and every event for each account, one response per call). The DM with the user's
own account was dropped, as were third-party shares (P5 captures them).

| Question | Answer |
|---|---|
| `folder` / `system_folder` | Every thread has them, the personal account's too: the DM is `PRIMARY` / `INBOX`. **The starting tab is known** (Ferry never had it, S5(d)). |
| Requests | `PENDING` is a valid folder (empty: neither dummy has one). Whether a request also shows under `INBOX` needs a real one (§6). |
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

### P1. Accounts, login and the inbox, read-only (2 d)

- `core/`: `IGResume`, `IGSuspend`, `IGStop`, `IGSession` (C3).
- App: `IGCore` and `IGAdapter` (§2) for threads, members and the latest messages; `AppModel` on `core/`; Keychain
  per account; `ConnectSheet` and O4 on `IGLogin`; `MediaCache` keyed by media ID (avatars need it from the start);
  account health from core's events; inbox, scopes, chips, unread, order, Folders badge, requests card, General
  from data; O2, `Session`, `ServerConfig` and the server banners deleted with their tests.
- **Tests:** `IGAdapterTests` from the P0 fixtures (inbox order, unread, requests, General, groups, members); the
  existing `Inbox` and `Room` tests unchanged.
- **Live:** `tamoveska` and `kivostudio` both logged in, side by side in the stack: the DM shows once per account;
  unread matches the phone; a cold relaunch comes back without a login; background 60 s → back reconnects and
  catches up. `kivostudio` only: "Professional · Primary and General", the General entry in its scope.

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

### P2. Thread, read side (2 d)

- History and back-pagination, live messages, reactions, edits, unsends, replies, typing and "Seen" displayed;
  groups from fixtures (the dummies have no group).
- **Tests:** `Timeline.reduce` over the new input, using P0's fixtures; the existing timeline tests that still apply.
- **Live:** in `tamoveska`'s DM, from Ferry as `kivostudio`: text, reply, reaction, change of reaction, edit,
  unsend, typing, each appearing live. Opening the chat sends one "Seen" (counter) and Ferry shows it. Nothing is
  sent when opening a chat with nothing unread.

### P3. Thread, write side (1.5 d)

- Send, reply, react, edit, unsend, local echo and retry, typing, mark read, the 1000-character limit, "Message as X".
- **Live, the pair test (Ferry's M4 exit, now both sides in this app):** from `tamoveska`'s chat each action
  mirrors in `kivostudio`'s chat and back; one reaction per person on both sides; "Seen" after the other side
  opens. Ferry's dev stack no longer needed for this.

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

### P4. Requests, General, Archived, New message (1.5 d)

- **Tests:** request detection and Accept/Delete/reply-accepts from fixtures; archive in `UserDefaults`.
- **Live:** archive and unarchive (nothing sent, counter stays); New message as each account finds the other and
  opens the existing DM without a request to Instagram beyond the search; `kivostudio`: user moves the DM to General
  on the phone and back (Ferry's hand-off C), the app follows. Requests live need a real request (§6).

**Done 2026-10-17.** Requests: Accept and Delete through `core/` (`IGAccept`, `IGDeleteThread`), a reply in a request
accepts first, a request accepted or a thread deleted elsewhere re-reads or removes the room. General: Instagram's
`folder` when a thread loads, and the raw `SlideUQPPIGMoveThread` (`ig_inbox_folder`) live, with no re-read. Archive:
on this device (`UserDefaults` `archived`), read as the room's `u.archived` tag, so a new message still brings a chat
back. New Message: `IGSearch`; an existing DM opens without asking Instagram; Instagram's existing thread is read once
(`IGFindDM`); anyone else gets a draft chat (not in the inbox) whose first message makes the thread (`IGSendNew`), and
the draft then leads to the real chat.
Live: archive and unarchive (nothing sent, kept across a relaunch); New Message as `tamoveska` found `kivostudio` and
opened their DM; the Requests card and Folders badge on the DEBUG request fixtures. Requests, groups and a Primary/General
move need a third account or the user's phone (§6); the move is tested with Ferry's captured deltas. The draft path is
checked live in the "new DM missing from the list" repro. Found live and fixed: reopening a read chat sent "Seen" again.

### P5. Media (2 d)

- Incoming photo, video, voice, reels and shares, view-once card; download on tap, expiry refresh; sending photo,
  video and voice, upload ring, retry.
- **Live:** `tamoveska` → `kivostudio`: a photo, a video (`testSendVideoAndVoiceNote`, opt-in) and a voice note
  (`FERRY_DEBUG_VOICE_FILE` if the Mac's audio is down); each plays on the other side. Shares need the phone (§6).

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

### P6. Account health, re-login, remove (1 d)

- Banners, the stack's badges, A3 re-login (same account only), Remove Account.
- **Live:** `tamoveska` signed out on purpose (user removes the web session from Instagram's "Where you're logged
  in" on the phone) → banner, A3, log in again → back with its chats. Remove `kivostudio` and add it again (one
  login). Never Remove Account on a real account.

**Code done 2026-10-17; the live half waits for the user.** Health comes from `core/`'s events (`AuthError` →
`BAD_CREDENTIALS` with Instagram's reason; `Disconnected` → `TRANSIENT_DISCONNECT`, retried every 30 s); A3 logs in
through the same sheet and refuses another account (a stranger's client is stopped); Remove stops the client, deletes
the Keychain item and drops the chats, telling Instagram nothing. Checked in the simulator with
`FERRY_DEBUG_LOGIN_STATE` on `kivostudio`: the stack's and chip's badges, the banner, A3's sheet ("Log in to Kivo
Studio again", "Tamo Veska keeps working."), dismissed without logging in. Still to do with the user: a real sign-out
(the web session removed on the phone) → banner → A3 login, and Remove + re-add of `kivostudio` (one login each).

### P7. Cleanup and docs (1 d)

- Delete what's left of the Matrix layer and its fixtures; UI tests on fixtures plus opt-in live ones; design tour
  in both appearances; README, CLAUDE.md and `specs.md` rewritten as built; CI builds `core/` (Go 1.27.1 on the
  macOS runner) before the unit tests.

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

### Then: on an iPhone

How long a phone-held session stays healthy (README's open decision) needs a real device and days of use; it can
start after P3, with one dummy.

## 6. What the two dummies can't cover

| Check | Needs | Fallback |
|---|---|---|
| A real message request: lands in Requests, opening sends nothing, Accept, Delete | An account neither dummy follows | DEBUG request fixtures; the user forwards one when it happens (Ferry's (e)) |
| A group with both accounts | A third account (Ferry's D11) | `FERRY_DEBUG_GROUP`; group fixtures if the user joins one |
| Reel, post, story and private shares, expired story, view-once | The user, from the phone | Ferry's existing card tests |
| Primary ↔ General move | The user, on the phone (`kivostudio`) | — |
| Session longevity, memory on a device | An iPhone | — |

## 7. Risks

- **Instagram actions.** Every cold launch is an index load per account, so live UI tests that relaunch cost more
  than Ferry's did; C8 keeps them opt-in. Each P-step reports its count.
- **Two sessions per dummy** while Ferry's dev bridge also runs them: fine in the spike. When Ferry is the other side
  (P0–P2), the bridge marks the chat read before each of its sends, so those "Seen"s show up on the dummy too; count
  them separately.
- **Web login from the simulator** may hit checkpoints or rate limits; the user does every login by hand.
- **Library churn:** `v0.2609.0` is pinned; a bump means re-reading `instameow` and rerunning P0's capture.
