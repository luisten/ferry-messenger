# Ferry Messenger: a shared engine, then Android

> **Done.** Accepted 2026-10-19; stages 1 and 2 done the same day, stage 3 shipped as the Android app
> ([ferry-android](https://github.com/luisten/ferry-android), 1.8 on 2026-11-18). Kept here: the decisions E1–E8,
> the engine's contract as built, each stage's results, and **§7b, the engine changes the Android app must follow**,
> which is still in use. The plan itself is in the repo at tag v1.8. Account names are the fictional stand-ins
> (`tamoveska` personal, `kivostudio` professional). Builds on [PLAN-core.md](PLAN-core.md).

**Goal, met:** an Android app with everything in [specs.md](../specs.md), sharing one copy of the Instagram logic with
the iPhone app. Three stages: (1) the engine (`core/`) turns Instagram's data into chats, (2) the engine keeps
Instagram's rules, (3) the Android app, in its own repo, on top of the engine. Stages 1 and 2 changed the iPhone app's
insides, not what it does: same screens, same Instagram requests.

## 2. Decisions

Each had a recommendation; E7 and E8 were the user's calls, both recommendations taken.

| # | Question | Recommendation |
|---|---|---|
| E1 | Where Instagram data becomes chats (replaces PLAN-core C1) | **The engine.** `IGAdapter`'s mapping moves to Go, with its tests and the same captures. Go already has the library's typed data (Swift decoded those same structs as JSON); live deltas stay raw JSON, as now (Go's `encoding/json` drops fields the library doesn't know, like `ig_inbox_folder`). |
| E2 | What the engine hands the apps (keeps PLAN-core C2) | **Matrix-style room updates**: the `JoinedRoom` / `Event` / `MessagesPage` values `IGAdapter` builds today, as JSON. The iPhone app's `Room`, `Timeline`, `Inbox` and views don't change (they already decode this shape, `SyncTypes`), and UI fixes still cherry-pick from Ferry. It's a documented chat format, not one we invent. An Instagram-native shape stays possible later, but would change the contract for both apps at once. |
| E3 | Who owns Instagram-derived state | **The engine, as the only writer.** It keeps its own copy of each chat (what `IGAdapter.apply` needs: the window, members, folder, watermarks, unread) and sends every change as an update, as Ferry's server did. The apps apply updates and keep only what's theirs: local echoes, the optimistic Accept, archive, request "seen" markers, identities. Two writers is how copies drift. |
| E4 | How the apps name a chat to the engine | **By room ID only** (`!ig-<account>-<thread>`, made by the engine). The engine knows each thread's three IDs. A room it doesn't know is refused, so DEBUG fixture rooms (`!debug-…`) can't reach Instagram even if `checkSend` misses one. |
| E5 | Where the Instagram rules live (stage 2) | **The engine**, as pure Go functions with unit tests, the network calls a thin shell around them (no fake client). They decide how many Instagram actions the app spends, so a second copy that drifted would be a ban risk, not just a bug. `AppModel`'s rules have no unit tests today. |
| E6 | The Android repo and the engine | **A new repo, [`ferry-android`](https://github.com/luisten/ferry-android)** (its Go module is still named `ferry-messenger-android`). Its `go.mod` requires `github.com/luisten/ferry-messenger/core` at a commit (a pseudo-version: no tags until the API settles; tags are the user's to make). Go downloads only `core/`, checksummed. The JNI bridge lives in `core/cmd/igcore/jni_android.c`, beside the C API it wraps, so the two change together; iOS builds ignore it (spike). |
| E7 | **Android libraries (the user's call).** "Zero dependencies" can't hold on Android in practice. | **Google's own only:** Kotlin, Jetpack Compose (Material 3), AndroidX, Media3 for playback, at exact versions, with Gradle's dependency verification on (checksums, as `go.sum` does). No third-party libraries. |
| E8 | **Android notifications (the user's call)** | **A foreground service keeps the engine connected while the app is closed:** no relay, unlike iOS. Costs: a permanent "connected" notification, battery, and phone makers' battery savers (Samsung, Xiaomi) killing it unless exempted. Unknown: whether Instagram minds a connection that never sleeps; checked on the dummies over several days before friends get it (A8). **Chosen 2026-10-22** (the Android repo's "option 1"; its "option 3", a relay and FCM shared with iOS, is left for later). |

## 3. Stage 1: the engine turns Instagram's data into chats

**Go.** A package `core/chat`, pure (no cgo, no network), turns Instagram's data into chats and keeps the engine's
copy of each; `cmd/igcore` is the C API: it calls the library, feeds `chat`, and queues the updates.

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

Changed from that contract, as built:
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

Each rule moved from `AppModel` into `core/chat/rules.go` as a pure function with tests, called by the C API.

**Done 2026-10-19,** stacked on stage 1's branch (the user's call: one refactoring). `core/chat/rules.go` decides
from the engine's copy, with tests that fail when a rule is loosened (re-read at most every 30 s; "Seen" on their
newest message, only when unread and never in a request; typing at most once per 20 s, never in a request, off when
sending; reactions, edits and unsends refused in requests, edits within 15 minutes and 5 texts; drafts and their
move; the forced request; the folders after the first page). `cmd/igcore` pages the folders after each login, accepts
a request before a reply, and retries a stored account's passing failure; `AppModel` lost `loadFolders`, both
throttles, the "Seen" target, the draft builder, the login retry and `markForcedRequest`. FerryTests 281, UI tests
green on made-up data. Live, with the user's OK: the same steps as stage 1's check, on the stage 2 build only, against
that evening's baseline: the same counts (`tamoveska` 11, `kivostudio` 7), one typing (and its "stopped") for the
burst, no "Seen" on the read chats. Cold launch to both first pages 2.98 s, one launch (2.14 s and 2.45 s before, also
one each: the network).

As built, beyond moving each rule:
- **Reconnect:** `IGResume(account, cookies)` connects a stored account and, after a passing failure, tries again every
  30 s by itself, telling the app through `Login` and `LoginFailed` events; `IGLogin` (a new login, the user is there)
  doesn't retry.
- **DEBUG:** `IGSetDebug(blockSends, requestRoom)`. Besides holding back sends, the engine treats
  `FERRY_DEBUG_AS_REQUEST`'s chat as a request, so every request rule applies to it and the app's `markForcedRequest`
  went. Typing stays blocked under `FERRY_DEBUG_BLOCK_SENDS`, as the old code did (DEVELOPMENT.md said it went; fixed).
- **New Message:** the draft arrives as a `Draft` event (the app keeps it out of `rooms`), and `RoomMoved {room, to}`
  when its thread arrives; `IGOpenDM` takes the contact as JSON. `IGSend` sends a draft's first message.
- `IGAccept` and `IGEdit` make their own offline threading IDs; the app keeps `IGNewOTID` for local echoes.
- Stays in the app, not in the table: which emoji a reaction removes (the same one again), and the UI's own checks
  (`Inbox.allowsReceipts` for the read-only menu, `Timeline.canEdit` for the Edit item). `Timeline.receiptTarget` is now
  used only by its tests: the engine picks "Seen"'s message, so Android needn't port it.

## 5. Stage 3: Android

Its own repo (E6), Kotlin and Compose (E7). Every step is done; what's still open (days on a real phone for
A8, A9's install on one) and every Android decision since are in that repo's `CLAUDE.md` and `docs/DECISIONS.md`.

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


**A0 done 2026-10-20** (ferry-messenger-android; this commit adds the bridge). The engine is pinned at 443b80e in
that repo's `go.mod` (plus core's `replace`, which doesn't carry over), built by its `build-engine.sh` with
`cmd/igcore/jni_android.c` from here (one JNI function per export but `IGFree`; byte arrays both ways). Gradle 9.7.1,
AGP 9.4.1, Kotlin 2.4.20, Compose BOM 2026.09.00, activity-compose 1.13.0, all checksummed. **instagram.com treats
Android's WebView like any phone browser:** the usual mobile login form, no app interstitial, the user agent left as
it is (`; wv` and all). It first looked otherwise: the page stayed blank because Compose's `AndroidView` gives a
WebView `WRAP_CONTENT`, which makes CSS's viewport 0 px tall (the app's bug; removing `; wv` changed nothing). One
login by the user (`tamoveska`), then the chat count on screen (2): the engine's requests were the iOS baseline's
(index 2, folder page 1, socket), plus Instagram's own web login. The session is stored encrypted with a Keystore key,
outside backups; the web view's cookies were 0 afterwards.

Changed from the above: Compose 1.12 needs `compileSdk` 37 (SDK Platform 37.0 installed, with the user's OK);
`targetSdk` stays 36. No app library beyond E7's: the platform covers the web view, the Keystore and JSON.

## 6. The live check (stages 1 and 2)

The same steps on today's build first (the baseline), then on the stage's build: cold launch with both dummies,
open their DM on each side (a "Seen" only if unread), send a text, react, unsend it, one typing burst; press HOME,
read the C6 counts (CLAUDE.md "Commands"). The counts must match (stage 2: or be lower). The user hears the expected
count before each run; the baseline costs the same actions once more.

## 7b. Engine changes the Android app must follow

When Android moves its pin past one of these, the Kotlin side changes in the same step. Newest first.

- **A link's card is the link, not Meta's shim (after 1.7, seen on Android 2026-11-17).** A link Instagram previews
  comes in the share's `target_url` behind a redirect: the card's host read `l.facebook.com` on the sender's side and
  `l.instagram.com` on the receiver's, and a tap went through it. `core/chat`'s `share` now unwraps it (`unshim`): on
  `l.instagram.com`, `l.facebook.com`, `lm.facebook.com` or `l.messenger.com`, the `u` parameter, only when it is an
  absolute `http`/`https` link, else the URL as it was. That changes the preview's `matched_url`, the body of a link
  sent without text, `external_url` and the share's kind. On Android: **move the pin; no Kotlin change**, as
  `LinkPreview` already takes `matched_url ?? og:url` and the card draws its host. iOS keeps no converted events (the
  engine rebuilds every chat from Instagram at each launch), so old cards heal on the next launch; if Android stores
  converted events anywhere, those keep the shim until the chat is read again. The engine's tests:
  `TestShimmedLinksAreUnwrapped`, and the shimmed link in `TestSharesBecomeTheBridgesShapes`. Confirmed live on
  Android 2026-11-17: the card reads "example.com" on both sides (no raw shim captured; `lm.facebook.com` and
  `l.messenger.com` are unseen).

- **Reactions bump the chat (iOS 1.7, the user's call 2026-11-10, checked live 2026-11-11).** Instagram logs every
  reaction as a message of its own, `REACTION_LOG_XMAT` ("Liked a message" for ❤, "Reacted 😂 to your message"
  otherwise), and its inbox shows it to the person reacted to as the chat's newest message, unread; the reactor's inbox
  doesn't change, and removing the reaction removes it. `core/chat` used to drop it; it now sends someone else's as an
  ordinary `m.room.message`, an `m.notice` whose content carries `"fi.ferry.reactionLog": true`, in timeline order:
  from a thread read, or made from the live `SlideUQPPCreateReaction` (ID `<log_message_id>~log`), unread; a removal
  redacts it. It counts for unread and "Seen" (`IGMarkRead` marks it read). On Android:
  1. **`Timeline.reduce` drops every base event whose content has `fi.ferry.reactionLog`**, before anything else
     looks at it: no row, no "New messages" line, no jump count, no reply target, no grouping. Without this it shows
     as a plain notice bubble in the thread. iOS: `Timeline.reduce`, the `bases.filter` above `messages`.
  2. **The inbox keeps it:** `Room.lastMessage` (so `lastActivity`, the inbox order and an archived chat coming back)
     and the preview use it as they would any notice: "Reacted 😂 to your message" in a DM, "Sam: Reacted…" in a group,
     "You: …" for ours. Nothing to change if the preview treats an `m.notice` as text.
  3. Unread needs nothing: it comes from the engine (`unread_notifications`).
  4. Tests to port: `InboxTests.testReactionLogIsThePreviewButNoRow`. The engine's own: `TestReactionLogEntriesMakeTheChatUnread`,
     `TestLiveReactionMakesItsLogEntry`.

  Its words are the log's `text_fragments` (else its snippet, else its text); live, `reactionLogLine`. In a group,
  "to a message" for someone else's message is still a guess (no group on the dummies).

## 8. Later, not decided

- An Instagram-native chat model instead of the Matrix-style one, if the Matrix vocabulary ever gets in the way
  (changes the contract for both apps).
- `core/` in a repo of its own: about an afternoon (the module path changes), if a third consumer ever appears.
- Notifications on iOS: none. 1.6's catch-up ones (Mozilla's push queue) were removed 2026-10-27: Instagram's web push
  hardly ever arrived ([PLAN-push.md](PLAN-push.md)), which also weighs against a Mozilla connection for E8.
