# Ferry Messenger: a shared engine, then Android (plan)

> Accepted 2026-10-19; stage 1 done the same day (§3). Account names are the fictional stand-ins (`tamoveska` personal, `kivostudio`
> professional). Builds on [PLAN-core.md](PLAN-core.md) (P0–P7, done) and the Android spike
> ([spikes/2026-10-19-android-core.md](spikes/2026-10-19-android-core.md)).

**Goal:** an Android app with everything in [specs.md](../specs.md), sharing one copy of the Instagram logic with the
iPhone app. Three stages: (1) the engine (`core/`) turns Instagram's data into chats, (2) the engine keeps
Instagram's rules, (3) the Android app, in its own repo, on top of the engine. Stages 1 and 2 change the iPhone app's
insides, not what it does: same screens, same Instagram requests.

**Why first move logic into the engine:** today the engine is thin. It hands Swift Instagram's own JSON (PLAN-core
C1), and the iPhone app does the understanding. An Android app built on today's engine would have to rewrite all of
it in Kotlin, and every Instagram quirk in CLAUDE.md would then be fixed twice, forever. The spike showed the
engine builds and loads on Android unchanged, so moving logic into it costs nothing on that side.

## 1. What moves, what stays

The iPhone app's code by layer, after a full read of the non-UI files (2026-10-19):

| Layer | Files today | Lines | Goes to |
|---|---|---|---|
| Instagram translation: threads, messages, shares, albums, GIFs, deltas → Matrix-style events | `IGAdapter.swift` | 738 | Engine (stage 1) |
| Instagram's three thread IDs, typing's user IDs, upload keys, typing timeouts | `AppModel.swift` (`roomByLongID`, `fbidByUserID`, `threadKeys`, `typing`) | ~120 | Engine (stage 1) |
| Instagram rules: page budget, re-read throttle, "Seen", typing, requests, New Message drafts, retries | `AppModel.swift` | ~300 | Engine (stage 2) |
| What the screens show: the chat store, rows, unread, folders, previews, account health | `Room`, `SyncTypes`, `JSON`, `Timeline`, `Inbox`, `BridgeAPI` | ~1,700 | Stays per app; Android ports it |
| Screens, media capture and playback, login web view, Keychain, local settings | the rest | ~6,500 | Per app anyway |

What stays per app is fine to have twice: it's tied to each platform's design (wording, accessibility labels,
symbols, spacing), it changes when the design changes, not when Instagram does, and the Kotlin port is checked
against the same fixtures (stage 3, A1). About 20 lines of it are the server bridge's leftovers (send statuses,
the bridge bot, `xma_fetch_status`), dead in this app and kept for cherry-picks from Ferry; Android doesn't port them.

## 2. Decisions

Each has a recommendation. E7 and E8 need the user before stage 3.

| # | Question | Recommendation |
|---|---|---|
| E1 | Where Instagram data becomes chats (replaces PLAN-core C1) | **The engine.** `IGAdapter`'s mapping moves to Go, with its tests and the same captures. Go already has the library's typed data (Swift decoded those same structs as JSON); live deltas stay raw JSON, as now (Go's `encoding/json` drops fields the library doesn't know, like `ig_inbox_folder`). |
| E2 | What the engine hands the apps (keeps PLAN-core C2) | **Matrix-style room updates**: the `JoinedRoom` / `Event` / `MessagesPage` values `IGAdapter` builds today, as JSON. The iPhone app's `Room`, `Timeline`, `Inbox` and views don't change (they already decode this shape, `SyncTypes`), and UI fixes still cherry-pick from Ferry. It's a documented chat format, not one we invent. An Instagram-native shape stays possible later, but would change the contract for both apps at once. |
| E3 | Who owns Instagram-derived state | **The engine, as the only writer.** It keeps its own copy of each chat (what `IGAdapter.apply` needs: the window, members, folder, watermarks, unread) and sends every change as an update, as Ferry's server did. The apps apply updates and keep only what's theirs: local echoes, the optimistic Accept, archive, request "seen" markers, identities. Two writers is how copies drift. |
| E4 | How the apps name a chat to the engine | **By room ID only** (`!ig-<account>-<thread>`, made by the engine). The engine knows each thread's three IDs. A room it doesn't know is refused, so DEBUG fixture rooms (`!debug-…`) can't reach Instagram even if `checkSend` misses one. |
| E5 | Where the Instagram rules live (stage 2) | **The engine**, as pure Go functions with unit tests, the network calls a thin shell around them (no fake client). They decide how many Instagram actions the app spends, so a second copy that drifted would be a ban risk, not just a bug. `AppModel`'s rules have no unit tests today. |
| E6 | The Android repo and the engine | **A new repo, `ferry-messenger-android`** (the user creates it on GitHub). Its `go.mod` requires `github.com/luisten/ferry-messenger/core` at a commit (a pseudo-version: no tags until the API settles; tags are the user's to make). Go downloads only `core/`, checksummed. The JNI bridge lives in `core/cmd/igcore/jni_android.c`, beside the C API it wraps, so the two change together; iOS builds ignore it (spike). |
| E7 | **Android libraries (the user's call).** "Zero dependencies" can't hold on Android in practice. | **Google's own only:** Kotlin, Jetpack Compose (Material 3), AndroidX, Media3 for playback, at exact versions, with Gradle's dependency verification on (checksums, as `go.sum` does). No third-party libraries. |
| E8 | **Android notifications (the user's call)** | **A foreground service keeps the engine connected while the app is closed:** no relay, unlike iOS. Costs: a permanent "connected" notification, battery, and phone makers' battery savers (Samsung, Xiaomi) killing it unless exempted. Unknown: whether Instagram minds a connection that never sleeps; checked on the dummies over several days before friends get it (A8). |

## 3. Stage 1: the engine turns Instagram's data into chats

**Go.** A new package `core/chat`, pure (no cgo, no network): the port of `IGAdapter` (thread → room snapshot,
message → events, shares, albums, GIFs, chat events, older pages, "Load video" results, search contacts, offline
threading IDs), the engine's copy of each chat (the state parts of `Room.apply` and `Room.prepend`), live deltas
(`IGAdapter.apply` / `change` / `receipt`) and typing with its timeout. `cmd/igcore` stays the C API: it calls the
library, feeds `chat`, and queues the updates.

**The event queue never drops.** Today it drops events once 1,024 are waiting (`main.go:197`, harmless for raw
data). A dropped room update would leave the app's copy silently wrong, so the queue grows instead (a slice under a
mutex). From stage 2 the background inbox paging (up to 20 pages a folder) goes through it too.

**The contract.** One envelope carries a chat's change: `{"kind": "Room", "room", "update", "profiles", "related"}`,
where `update` is a `JoinedRoom`; the app applies it as `IGAdapter.apply(snapshot:)` does now (`Room.apply`, merge
profiles, file reply targets). `{"kind": "RoomRemoved", "room"}` drops a deleted thread. A call returns the chats
it asked for in its result, as these envelopes, so the app can await them as it does today (open a DM, then show
it); `IGNextEvent` carries the rest, besides today's account events (`Connected`, `Disconnected`, `AuthError`):
live changes, typing and its timeout, and the threads the engine re-reads by itself when a live change needs it (a
reaction from before this launch, a rename, a message in a thread it doesn't have: what `AppModel` does on
`.refresh` today; the same requests, made from Go).

Calls change from Instagram's IDs to room IDs, and return chats instead of Instagram's JSON:

| Today | Stage 1 |
|---|---|
| `IGLogin(cookies)` → account, viewer, mailbox | → account, viewer, and the first page's chats |
| `IGInboxPage(account, folder, cursor)` | same arguments → its chats and the next cursor (gone in stage 2) |
| `IGThread(account, thread)` | `IGReadChat(room)` → the chat, keeping its General tab (`keepingFolder`) and our watermark (`readUpTo`) by itself. A read. |
| `IGFindDM(account, user)` | → the DM's chat if Instagram has one (read, in the result), else not found and the app makes its draft as now |
| `IGOlder(account, thread, cursor, message)` | `IGOlder(room)` → a `MessagesPage`, also prepended to the engine's copy |
| `IGSend`, `IGReact`, `IGEdit`, `IGAccept`, `IGDeleteThread`, `IGTyping` (`account`, `thread`, …) | the same with `room` |
| `IGUnsend(account, threadLong, message)`, `IGMarkRead(account, threadLong, message, ms)` | `IGUnsend(room, message)`, `IGMarkRead(room, message)`: the long ID and the time are looked up; the read shows at once as an update |
| `IGSendMedia(account, threadKey, thread, path, …)` | `IGSendMedia(room, path, mime, voice, replyTo, otid)` |
| `IGResolveMedia(account, target, id)` | `IGResolveMedia(room, message)`: the hidden edit arrives as an update |
| `IGSearch(account, query)` → Instagram's results | → contacts in `BridgeAPI.Contact`'s shape |
| (Swift: `IGAdapter.offlineThreadingID`) | `IGNewOTID()` |

Unchanged: `IGSendNew` (until stage 2), `IGSession`, `IGCounts`, `IGStop`, `IGStats`, `IGFree`, `IGSetCapture`
(which keeps writing Instagram's responses, so new fixtures still come straight from the wire).

**Swift.** `IGAdapter.swift` goes, except what stage 2 takes later: the New Message draft (`draft`, `draftID`, a
small room builder). Its constants (`me`, `@ig_<fbid>`, the start token) and `IGAdapter.login` (the viewer as the
account row, presentation) move to `IGCore.swift` / `BridgeAPI.swift`. `IG`'s decoders shrink to the viewer and
the envelope. In `AppModel`, applying threads, deltas, typing, older pages and resolved media becomes "apply the
engine's update"; the ID maps, `threadID(of:)`, `longID(of:)` and the typing timers go. The rules stay where they
are until stage 2.

**Tests.** The nine Instagram captures (`ig_*.json`) move to `core/testdata/`. Go tests port `IGAdapterTests`' 26
cases on them, and write the engine's output for each capture as golden files into
`FerryTests/Fixtures/engine_*.json` (`go test ./chat -update`; diffs reviewed like code). The Swift halves of those
tests (reducing an adapted thread with `Timeline`) read the golden files, so both languages check the same contract,
and Android reuses it (A1). The other 266 Swift tests are unchanged (only `IGAdapterTests` reads the raw captures).
CI runs `go test ./...` in the macOS job, after `core/build.sh`.

**Done when:** both test suites green; golden files reviewed; the live check (§6) gives the same C6 counts as
today's build; cold launch with both dummies no slower than today's. About 2–3 days.

**Done 2026-10-19.** `core/chat` (pure Go: the port of `IGAdapter`, the engine's copy of each chat, live deltas,
typing and its timeout, the thread IDs) under `cmd/igcore`, which names chats by room ID; `AppModel` applies the
engine's updates. 26 Go tests on the nine captures (`core/testdata`), golden files `FerryTests/Fixtures/engine_*.json`,
15 `EngineTests` on them (FerryTests 292 → 281); CI runs `go test ./...`. Before `IGAdapter` went, a temporary test
applied every golden file with `Room.apply` and compared it with `IGAdapter` on the same captures: the same rooms
(events, state, unread, receipts, typing, paging, reply targets), except an empty transaction ID the old adapter put
on our mailbox copies (it matched no echo). Live, after the user logged both dummies in by hand on today's build (the
simulator's app had never had them): §6 on today's build, then on stage 1, the same counts: `tamoveska` 11 requests
(index 2, folder page 1, thread read 1, older page 1, text, reaction, unsend, socket, typing 2), `kivostudio` 7
(index 2, folder pages 2, thread read 1, older page 1, socket); no "Seen" (nothing was unread). Cold launch to both
first pages: 2.14 s today, 2.45 s stage 1, one launch each; the engine's part of a login page is 0.09 ms (Mac), so
the gap is the network.

Changed from the above, as built:
- **Every change to a chat reaches the app through `IGNextEvent`, in the engine's order**, and a call returns the
  `seq` of its last update instead of the chats; the app waits for it where it needs the chat (a found DM, "Load
  video", a login's first page). A call's fresh window returned directly could land after a newer live update and
  wipe it in the app's copy only. `IGNextEvent` returns everything waiting, as an array.
- `core/chat` reads Instagram's JSON (what the captures hold), not the library's typed structs: typed message content
  loses its `__typename` when marshalled, so captured and live messages would decode differently.
- `IGAdapter.swift` stays, slim (constants, the account row, New Message's draft, applying an update), so `Inbox` and
  its tests don't change.
- `IGMarkRead` sends nothing when the engine already has the chat read that far (the update now takes a hop to the
  app, and a second call in between would send a second "Seen"), and makes the chat unread again itself if Instagram
  refuses (one writer, E3).
- `IGLogin` and `IGInboxPage` leave `next` out at the end (an empty cursor asks for the first page again); `IGOlder`
  takes only the room; `IGDeleteThread` also sends `RoomRemoved`. `IGSetCapture` captures Instagram's answers only.
- The capture app (`core/spike`) used the old API: moved to room IDs; it builds, not run.

## 4. Stage 2: the engine keeps Instagram's rules

Each rule moves from `AppModel` into `core/chat` as a pure function with tests, called by the C API:

| Rule | Today | Engine |
|---|---|---|
| Inbox paging: the rest of Chats, then Requests, then General (professional accounts), at most 20 pages each per launch | `loadFolders` (`AppModel.swift:218`) | After login, by itself. `IGInboxPage` leaves the API. |
| Re-read an opened chat at most every 30 s | `openThread` (`:402`) | `IGOpenChat(room)`, what opening a chat calls, decides. `IGReadChat` stays for fresh media links after a failed download. |
| "Seen" only outside requests, only when unread, on the newest incoming message; unread again if it fails | `markRead` (`:414`), `Inbox.allowsReceipts`, `Timeline.receiptTarget` | `IGMarkRead(room)` picks the message or does nothing. |
| Typing at most once per 20 s, never in requests, off when sending | `setTyping` (`:650`) | `IGTyping(room, on)` throttles. |
| React, edit, unsend only outside requests; edits within 15 minutes, at most 5 | `react`/`edit`/`unsend` (`:630–646`), `Timeline.canEdit` | Refused by the engine. The apps keep `canEdit` to hide the menu item. |
| A reply in a request accepts it first; Accept re-reads the chat; Delete removes it | `send` (`:475`), `accept`, `deleteRequest` (`:720–756`) | `IGSend` on a request room accepts first; Delete sends `RoomRemoved`. |
| New Message: our DM, else Instagram's, else a draft until the first message makes the thread | `openDM` (`:701`), `drafts`, `movedRooms`, `deliver` (`:495`), Swift's draft builder | `IGOpenDM(account, contact)` → the chat (ours, Instagram's or a draft). A send on a draft makes the thread; a new event, `RoomMoved {from, to}`, leads the app there. `IGSendNew` and `IGFindDM` leave the API. |
| Reconnect after a passing failure, every 30 s while open | `failed` (`:261`) | The engine retries; the apps show health as now. |
| DEBUG: every send blocked under `FERRY_DEBUG_BLOCK_SENDS` | `checkSend` (`:676`) | `IGSetBlockSends(on)`, DEBUG builds only. Fixture rooms are refused since stage 1 (E4). |

`AppModel` keeps: accounts and the Keychain (cookies still leave the engine only through `IGSession`, C3),
identities, archive, request "seen" markers, local echoes and Retry, media preparation and the cache, toasts and
errors, how long a disconnect has lasted (health).

**Done when:** tests green; the live check gives the same C6 counts or fewer; a typing burst sends at most one
typing per 20 s; reopening a read chat sends no "Seen". About 2 days.

## 5. Stage 3: Android

Its own repo (E6), Kotlin and Compose (E7). Each step ends with tests green and an emulator check; steps that log
in or send are live checks on the dummies only, counted (C6) and announced to the user first, as on iOS.

| Step | What | Estimate |
|---|---|---|
| A0 | Repo, pinned Gradle wrapper, dependency verification, the script that builds `libigcore.so` (arm64-v8a) from the pinned engine, the JNI bridge (byte arrays, not Java strings: emoji, spike), then **one login** with a dummy on the emulator: does instagram.com treat Android's WebView differently (its user agent carries `wv`)? | 1–2 d |
| A1 | The chat model in Kotlin: `Room`, `Timeline`, `Inbox` ported from Swift, tested on the golden files and the Matrix-style fixtures (copied with the commit they came from) | 2 d |
| A2 | Accounts and the inbox, read-only: scope bar, account stack, folders menu, search | 2–3 d |
| A3 | Thread, read side: bubbles, groups, replies, reactions, "Seen by", start block, back-pagination | 2–3 d |
| A4 | Thread, write side: send, reply, react, edit, unsend, typing, local echo and Retry | 2 d |
| A5 | Requests, General, Archived, New Message | 2 d |
| A6 | Media: photos, albums, GIFs, videos, voice notes, shares and "Load video", in and out; location stripped before sending | 3–4 d |
| A7 | Onboarding, account health, re-login, Remove Account | 2 d |
| A8 | Notifications (E8), and several days on a real phone for battery and battery savers | 2–3 d |
| A9 | A signed APK with the user's own key, and an install guide for friends | 1 d |

About 4–5 weeks of work in all; a guess, the screens are most of it.

**From iOS to Android:**

| iOS | Android |
|---|---|
| Keychain (`ferry`, `instagram:<id>`) | A file in app storage, encrypted with a Keystore key. `android:allowBackup="false"` and data-extraction rules that exclude it, or the cookies go into Google's cloud backup. |
| `WKWebsiteDataStore.nonPersistent()` per login | Android's WebView has no per-view private store, and `CookieManager` is app-wide and saved to disk: clear it (and web storage) before and after every login, then flush. |
| `UserDefaults` | `SharedPreferences` |
| SwiftUI, iOS 26 glass bars | Compose, Material 3. A design pass keeps DESIGN's principles (colour means account, accounts side by side, the sea is scenery). |
| SF Symbols, VoiceOver, Dynamic Type | Material Symbols, TalkBack, font scale |
| Reduce Motion, Low Power Mode (`Crossing.motion`) | "Remove animations" (the animator scale), battery saver (`PowerManager.isPowerSaveMode`) |
| Photos picker, share sheet | Android's photo picker (no permission needed), share intents |
| AVFoundation (playback, recording, export) | Media3 for playback, `MediaRecorder` for voice notes, `MediaCodec` / `MediaMuxer` for video |
| App icon, `UILaunchScreen` | Adaptive icon, splash screen API, from the same SVGs |

**No phone needed until A8.** The emulator (installed for the spike: Android 16, 16 KB pages) covers A0–A7.
Battery and battery savers need a real phone: a friend's, or a cheap used Pixel.

## 6. The live check (stages 1 and 2)

The same steps on today's build first (the baseline), then on the stage's build: cold launch with both dummies,
open their DM on each side (a "Seen" only if unread), send a text, react, unsend it, one typing burst; press HOME,
read the C6 counts (CLAUDE.md "Commands"). The counts must match (stage 2: or be lower). The user hears the expected
count before each run; the baseline costs the same actions once more.

## 7. Risks

- **Stages 1–2 rework a working app's core paths** (inbox, unread, folders, "Seen"). Guarded by the golden files,
  the unchanged Swift tests, the C6 comparison, and the user's own iPhone check before each stage merges.
- **Two copies of a chat** (engine and app) could drift. The engine is the only writer of Instagram-derived state
  (E3), and the queue never drops (stage 1).
- **The engine grows** from ~600 to ~2,000 lines of Go and gets its first tests. UI fixes still cherry-pick from
  Ferry (views, `Room`, `Timeline`, `Inbox` unchanged); `AppModel` drifts further from Ferry's, as it already has.
- **Android unknowns:** Instagram's reaction to logins from Android's WebView (A0), to a connection that never
  sleeps (A8), and phone makers' battery savers (A8).

## 8. Later, not decided

- An Instagram-native chat model instead of the Matrix-style one, if the Matrix vocabulary ever gets in the way
  (changes the contract for both apps).
- `core/` in a repo of its own: about an afternoon (the module path changes), if a third consumer ever appears.
- Notifications on iOS: still need a relay (2026-10-16 spike); separate decision.
