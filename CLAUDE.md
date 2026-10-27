# Ferry Messenger: notes for agents

Ferry Messenger is an iPhone app for Instagram DMs that talks to Instagram straight from the phone through mautrix's
Instagram library (Go, `core/`). It grew out of Ferry, the same SwiftUI app on a self-hosted Matrix server and bridge.
Its history starts fresh at 1.0 (2026-10-17); the earlier history (Ferry's, and this app's first steps) is a private
bundle outside the repo.

**Status:** the app runs on `core/` at parity with Ferry, plus catch-up notifications that Ferry never had
([docs/PLAN-push.md](docs/PLAN-push.md): steps 1–3 done, step 4 is a week on the user's phone) (P0–P7 of
[docs/PLAN-core.md](docs/PLAN-core.md), each checked live with the two dummies; its "Done" blocks hold the results and
request counts). Instagram's data becomes the Matrix-shaped rooms the views always showed (decision C2), in the engine
since stage 1 of [docs/PLAN-android.md](docs/PLAN-android.md) (`core/chat`, so an Android app can share it), so
`Room`, `Timeline` and `Inbox` stay. As built: [specs.md](specs.md). Building, testing, installing, DEBUG switches
and signed releases: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md); the README is for users (plain words, no internals),
and so is [CHANGELOG.md](CHANGELOG.md) ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)): a user-visible
change adds a line under Unreleased.
Feasibility, numbers and push results: [docs/spikes/2026-10-16-on-device.md](docs/spikes/2026-10-16-on-device.md). The
other docs inherited from Ferry ([docs/PLAN.md](docs/PLAN.md), [docs/FOLLOWUPS.md](docs/FOLLOWUPS.md),
[docs/DECISIONS.md](docs/DECISIONS.md), [docs/BRIEF.md](docs/BRIEF.md), `docs/research/`) describe the Matrix version;
their design and UI parts still hold.

## Commands

```sh
SIM=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
t() { xcodebuild -project Ferry.xcodeproj -scheme Ferry -destination id=$SIM \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/FerryMessenger \
  -parallel-testing-enabled NO -collect-test-diagnostics never "$@"; }
t test -only-testing:FerryTests              # 300 unit tests, ~3 s
(cd core && go test ./...)                    # core/chat on P0's captures; -update in ./chat rewrites the golden files
t test -only-testing:FerryUITests            # UI tests on made-up data (live ones opt-in: docs/DEVELOPMENT.md)
t build-for-testing                           # all 3 targets
core/build.sh                                 # Go core -> build/IGCore.xcframework (needs Go 1.27.3 on PATH)
git ls-files | xargs grep -nE 'syt_[A-Za-z0-9_]{8,}|"sessionid"\s*:\s*"[^"]{12,}'   # secret scan: expect nothing
xcrun simctl spawn $SIM log show --last 10m --predicate "subsystem == \"$APP\" AND category == \"instagram\"" | grep requests  # C6 counts
```

The C6 counts (every Instagram request per account, by operation name) are logged when the app goes to the
background: press HOME (`simctl` button or the panel) before anything that kills the app, `xcodebuild test` included,
or that launch's counts are lost (P2–P3).

The project, scheme, targets and folders keep Ferry's names (`Ferry.xcodeproj`, `Ferry/`, `FerryTests/`) on purpose,
so UI fixes cherry-pick between the two repos. Only the display name ("Ferry Messenger") and the bundle ID
(`<prefix>.ferry-messenger`) differ, so both apps install side by side.

## Invariants

**Safety**

- **Never type into instagram.com, never store or log Instagram passwords.** The user does every Instagram login by
  hand, in a web view on a fresh `WKWebsiteDataStore.nonPersistent()`; tell them before each one. The session (cookies
  and the viewer) lives in the Keychain (service `ferry`, account `instagram:<id>`) and nowhere else (no logs, files, `UserDefaults`,
  fixtures). `core/` must never emit its state dump (it holds web tokens) to Swift or logs. Cookies leave `core/`
  only through `IGSession`, whose result Swift writes straight to the Keychain and doesn't keep (Instagram rotates
  some cookies mid-session; decision C3 in [docs/PLAN-core.md](docs/PLAN-core.md)). Never pass cookies through
  environment variables, DEBUG switches or test runners.
- **Catch-up notifications talk to Mozilla, not Instagram** ([docs/PLAN-push.md](docs/PLAN-push.md)): a Background
  App Refresh wake only drains the phone's web push channels (`IGPushDrain`); Instagram hears from them only through
  `IGRegisterPush`, when `rules.go`'s `PushRegister` says so. A wake resumes the whole process, so the app closes every
  Instagram socket and stops retries and folder paging in the background (`IGPause`), and reopens them on return
  (`IGUnpause`). It closes them by cancelling each connection's context: the library's `Disconnect` stops a client's
  sockets for good, so 1.6.0 stayed offline after its first return until a relaunch. The push state (Mozilla's ID, each account's channel and
  private keys) is like the cookies: it leaves `core/` only for the Keychain (service `ferry`, account `push`), never
  logged.
- **Live tests use the two dummy accounts only**, never the user's real ones. Their names are in the gitignored
  `docs/local/test-accounts.md`; tracked files use the fictional stand-ins `tamoveska` (personal) and `kivostudio`
  (professional), `sample.*` for third parties. `git grep` for the real names must stay empty.
- **Live checks cost Instagram actions** (ban risk on the dummies): every login, every launch (an index and mailbox
  load per account, then the rest of the inbox page by page), send, search. Opening a chat with unread incoming
  messages is one ("Seen"), so is each typing burst. Count them (C6, Commands) and report them. The engine decides
  them (`core/chat/rules.go`, stage 2): "Seen" (`IGMarkRead`) only when the chat is unread, typing at most once per
  20 s, neither ever in a request; a chat opened is read again at most every 30 s.
- **Remove Account** forgets the account here (Keychain, client, chats) and tells Instagram nothing; adding it back
  takes a new login by the user. Never remove an account without the user, and never a real one. A3's re-login must
  finish as the same account (`AppModel.connect(cookies:reloginID:)` refuses another and stops a stranger's client).
- **No server.** Never run `docker compose` or Ferry's `bootstrap.sh` from this repo. The simulator may also have Ferry
  installed with real accounts: never launch, terminate, install over or uninstall Ferry's bundle from here. This
  app's simulator Keychain holds the dummies; the UI tests run on `FERRY_DEBUG_DEMO` and never touch it (C8).
- **The repo is public** (fresh history from 1.0). Commit freely; **push only when the user asks**, and only after the
  secret scan and the personal-details greps are clean. Commits use the GitHub no-reply author in this repo's git
  config. **Releases are signed tags `vX.Y` the user makes with their own key** (docs/DEVELOPMENT.md "Releases"; the
  release workflow trusts only the `RELEASE_SIGNERS` repository variable): never sign or push a tag on their behalf.
- **Licence: AGPL-3.0** ([LICENSE](LICENSE)), because the app links mautrix's AGPL-3.0 library.

**Code**

- **Dependencies:** none in Swift. The one exception is `core/`: `go.mau.fi/mautrix-meta` pinned to an exact tag in
  `core/go.mod` with `go.sum`, built with Go 1.27.3 (its `toolchain` line). Bump either only on purpose, after
  reading upstream's changelog; say what changes before pulling it.
- **`core/` has a second consumer, the Android app** (ferry-messenger-android, PLAN-android stage 3), which pins a
  commit of it. Its JNI bridge is `core/cmd/igcore/jni_android.c` (E6), one function per export, compiled only for
  Android: change an exported function's signature and it changes too, in the same commit.
- Zero third-party dependencies; no protocol-for-swappability abstractions; pure logic is `nonisolated` and
  unit-tested with real fixtures (`FerryTests/Fixtures`). App target defaults to `MainActor`, test targets to
  `nonisolated`.
- **Instagram's data becomes chats in `core/chat`** (pure Go, tested on the captures in `core/testdata`), which keeps
  its own copy of each chat and is the only writer of what Instagram says (PLAN-android E3): `AppModel` applies its
  updates (`IG.Update`, from `IGNextEvent` only, in order) and keeps only its own state (local echoes, the optimistic
  Accept, archive, request "seen" markers, identities). Calls name chats by room ID. **Instagram's rules live there
  too** (`rules.go`, stage 2: re-reads, "Seen", typing, requests, edits, New Message's drafts, folder paging, login
  retries): a rule that decides whether Instagram is asked goes in Go with a test, never in `AppModel`. A change to the mapping changes
  `FerryTests/Fixtures/engine_*.json` (`go test ./chat -update`), which `EngineTests` read: review that diff like code.
- The thread is `Timeline.reduce(room)`, a pure fold over the raw window: never mutate `Room.events` to apply an edit,
  reaction or redaction. `core/chat` emits Instagram's changes as events (`m.reaction`, `m.replace`, redactions) for it
  to fold; the reducer still absorbs the bridge's old echoes (TimelineTests, real M4 fixtures), harmless here.
- Inbox order is the **last message's** timestamp (`Room.lastActivity`), not the newest event: the engine's state
  events are stamped when made, and edits never bump a chat.
- **Colors live in `Tokens.swift`.** Small text: `.inkSecondary` (not `.secondary`, 3.4:1), and on an incoming-bubble
  card `.inkSecondaryOnBubble` (inkSecondary is 4.30 on #E9E9EB); status text `.statusOK/.statusWarn/.statusError`
  (not system green/orange/red, 2.2–3.5:1 on white).
- DEBUG switches live in `DebugFixtures.swift` (docs/DEVELOPMENT.md): fake request rooms and a fake group (`FERRY_DEBUG_GROUP`; `FERRY_DEBUG_GROUP_EXTRA=<n>` more unread in it, `…_INCOMING=<s>` one arriving every s seconds), an
  account state override, a real chat shown as a request (the engine treats it as one, `IGCore.setDebug`; its sends
  are held back, "Seen" and typing aren't, so the request rule itself keeps them back), onboarding at a given step over the real accounts, made-up data only (`FERRY_DEBUG_DEMO`: two made-up
  accounts stand in for the Keychain's and never connect, identities in memory only; screenshots and the UI tests),
  every send and upload blocked (`FERRY_DEBUG_BLOCK_SENDS`), a voice file standing in for the microphone
  (`FERRY_DEBUG_VOICE_FILE`), stand-in accounts in the toolbar stack only (`FERRY_DEBUG_STACK_EXTRA`), failing
  playback (`FERRY_DEBUG_PLAYER_FAILS`), the fixture capture (`FERRY_DEBUG_CAPTURE`), a Background App Refresh wake
  after HOME (`FERRY_DEBUG_REFRESH_AFTER_HOME`), the inbox's notifications card (`FERRY_DEBUG_NOTIFICATIONS_CARD`) and a session Instagram ends for
  one launch (`FERRY_DEBUG_ENDED_SESSION`: a broken `sessionid`, never saved; Instagram wouldn't let the dummies' new
  web sessions be removed from "Where you're logged in").
  **Fixture rooms (`!debug-…`) never reach Instagram:** the engine refuses a room it didn't make (E4),
  `AppModel.hasThread` skips them (and New Message drafts) and `AppModel.checkSend` refuses them. A new Instagram call
  for a room takes its room ID and goes through `checkSend`; DEBUG's send block is the engine's (`blocked`).
- **Groups (#24):** sender labels only where `BridgeInfo.roomType == .group`, never on our own (`@me`) messages:
  `Timeline.layout(_:isGroup:)` sets `Row.groupSender` (name on the first of a run, avatar on the last, a tombstone
  neither). Names are `.inkSecondary`, never an account colour. Who a user is: `Room.displayName` = member event name
  (`core/chat` makes one per thread participant) → profile (`AppModel.profiles`, from the threads) → in a DM the room
  name; never a raw ID. Members (T3): the joined member events, You last; read-only (a tap shows `PersonCard`). "N
  members" is `Inbox.memberCount`. A group without a photo is `RoomAvatar`'s two faces (`Inbox.faces`), or its people
  glyph with fewer than two others; never its name's initial. Reactions show faces and "Seen by …" sits under the newest
  message (`Message.seenBy`, `Timeline.seenByLine`) only in groups. No group exists on the dummies: the DEBUG group
  (unread, with readers and stacked reactions) and unit tests cover them.
- **The sea is scenery only** (D19, DESIGN principle 10): `Scenery.*` (Tokens.swift, a namespace on purpose) colours
  O1's picture and nothing else: never text, controls, tint or chrome. The icon and `LaunchMark` come from
  `docs/design/ferry-icon-color*.svg` through `swift scripts/make_icon.swift`, which also stops if `FerryShape.swift`
  no longer carries the SVGs' path data verbatim: change the SVG, copy the `d` into `FerryShape.Part`, rerun.
- **O1's motion rules are `Crossing.motion`** (`AmbientMotion` wraps them; O4's deck uses the same): still under Reduce
  Motion or Low Power Mode, paused while the scene isn't active or a pushed step covers the view. Text and buttons
  never move, and nothing waits for the entrance.
- **Your accounts sit side by side, never over each other** (DESIGN principle 9, design v3): the toolbar stack
  (`Inbox.AccountStack` decides shown / "+N" / badges / VoiceOver; `AccountStackButton` draws it), O6, banners.
  `AccountAvatar` draws its ring *outside* its frame (size 24 → 30 pt with the ring), so give it the ring's room.
  Identity in a toolbar sits on glass (the thread header's capsule), and the thread's top scroll edge is `.hard`.


**Instagram behaviour the app relies on** (mautrix/meta v0.2609.0 `pkg/instameow`; shapes in `core/testdata/ig_*`,
captured in P0; mapped in `core/chat`)

- **IDs:** a thread is `ThreadInfo.id` (most calls, a delta's `thread_fbid`, our room ID `!ig-<account>-<id>`);
  unsend, "Seen" and typing take the long `thread_id`, which both of our accounts share for their DM, so anything keyed
  by it is keyed by account too (the engine's per-account `Chats`; P2 showed typing in the wrong account's chat). `thread_key` is the
  other person's ID in a DM and the upload target. People: `interop_messaging_user_fbid` (our account IDs too);
  typing names the Instagram user `id` (mapped as threads load).
- **Our own messages:** the local echo's transaction ID is the offline threading ID Instagram gets
  (`IGNewOTID`), so the socket's echo replaces it. Instagram sends no "delivered": Sending → Sent →
  Seen (the other side's read watermark).
- **Unread:** the newest message is incoming and past our read watermark, or the chat is marked unread; live deltas
  (a new message's `MARK_UNREAD`, `SlideUQPPMarkRead`, `SlideUQPPIGMarkThreadUnread`) and our own `IGMarkRead` keep
  it current. Our watermark is `Room.receipts[@me]` (from `slide_read_receipts`, `SlideUQPPMarkRead`'s
  `read_timestamp_ms`, and `IGMarkRead`, which clears the dot at once, before Instagram is asked, and sends nothing if
the engine already had it read that far). A thread read weighs it too (`readUpTo`):
  opening a chat sends "Seen" and re-reads it together, and a read answered before the "Seen" landed said unread, so
  the dot stayed. The "New messages" line goes after the watermark `ThreadView` took when the chat opened; our receipt
  comes even when every loaded message is newer (a mailbox copy of an unread chat: on the oldest, the app reads only
  its time), or the chat opened with no line (2026-10-20). An empty
  `replied_to_message_id` means no reply (P2: every bubble showed a loading quote).
- **Folders:** requests are `system_folder` `PENDING`/`SPAM`; General is `folder` `GENERAL` (professional accounts, the
  viewer's `is_professional_account`), moved live by `SlideUQPPIGMoveThread` (its `ig_inbox_folder`). Only mailbox
  pages carry `folder`: a thread read (`IGReadChat`) answers with it empty, so a re-read keeps the room's tab. Never
  take the tab from `SlideUQPPUpdateThreadFolder`: the first one for a DM a professional account starts says `GENERAL`
  while Instagram lists the thread `PRIMARY` (live 2026-10-17; Ferry's bridge patch reads it, which filed new DMs
  under General there). Deltas reach
  `core/chat` as Instagram's raw JSON: the library's types drop the fields they don't know.
- **New Message:** `IGOpenDM` opens our DM, else Instagram's (`FetchThreadID`, then a read), else a draft
  (`!ig-<account>-new-<fbid>`, the engine's `Draft` update, kept outside `rooms`, so the inbox and search never show an
  empty chat) until the first message (`IGSend` with `RecipientIGIDs`) makes the thread; its NewMessage delta loads it
  and the engine's `RoomMoved` leads the draft to it (`movedRooms`).
- **Shares (XMA)** become the bridge's shapes, so Ferry's cards work unchanged: `external_url`, `formatted_body`
  `<strong>author</strong><p>caption</p>`, `com.beeper.unresolved_media` → "Load video" (`IGResolveMedia`, a read)
  → a hidden `m.replace`. Instagram's own line about a share (`eyebrow_text`: "Replied to @Name's story", worded so on
  both sides) is a `<blockquote>`, shown above it. A story reply or reaction is `MONTAGE_SHARE_XMA`: the thread's copy
  is the story plus `content.xma_text_body` (kept under `MessageKind.shareTextKey`, shown under the card); the
  mailbox's has `xma: null` and the text only in `text_body`, so it's a text until the thread is read (live
  2026-10-19, `ig_story_replies_kivo`). Any other share's mailbox copy (`xma: null`) is its snippet as a chat event:
  the snippet names the sender ("You sent an attachment."), and the inbox said "You: " again.
- **GIFs** are `content_type` `GIFS` (`animated_media`: WebP and MP4 links, a preview that may be `null`), or
  `INSTAGRAM_MESSAGING_ANIMATED_IMAGE` from Instagram's GIPHY picker, a sticker when `is_sticker` (live 2026-10-20,
  `ig_animated_images_tamo`; `fi.ferry.sticker`, drawn at sticker size and looping, the user's call 2026-10-21); the
  mailbox's copy has `animated_media: null` (only its snippet says "sticker"), the thread's has the links. An uploaded
  animated GIF comes back as one of Instagram's GIFs on both sides (live 2026-10-17), so GIFs from Photos and pasted GIF
  links are sent as files (`PhotoMessage.gif`). A GIF card plays three times once per launch (`MediaCache.playedGIFs`),
  then rests on frame 0 with a play button for one more; none of that by itself in a request (`autoplaysGIFs`) or under
  Reduce Motion. Links to GIFs that others send stay links. No GIF search: no outside service (the user's calls,
  2026-10-17).
- **Instagram's in-chat camera** sends `RAVEN_IMAGE` / `RAVEN_VIDEO` with `view_mode` 0 (view once), 1 (allow replay)
  or 2 (keep in chat) (live 2026-10-24, `ig_camera_media_tamo`). Kept, it carries the camera roll's attachment shape
  and is the same card; otherwise it has no attachment and is the view-once line. Arriving live it's
  `SlideUQPPNewRavenMessage`, a new message like `SlideUQPPNewMessage` (Meta AI's `…NewGenieMessage` too). Web push
  sends nothing for any of them (PLAN-push step 1), and a push's sender is `s` (`u` is the account it's for).
- **Web push registrations expire** between about 3 h and 1.5 days (live 2026-10-26: 10-24's delivered nothing, a
  fresh one survived a cold relaunch), so `PushRegister` renews hourly on open or return. DEBUG builds log what each
  wake and each open collect, counts only (category `push`): the first thing to read when notifications don't come.
- **Several photos sent at once** are one `IMAGES` message with every attachment (live 2026-10-18,
  `ig_message_photos_tamo`); `core/chat`'s `album` keeps the first as the content and all of them under `fi.ferry.album`
  (`MediaInfo.album`), which `AlbumStack` shows as a pile that unfolds in place: one message, so one menu, reaction
  row, reply target and unsend. Ferry showed the first only. The share sheet hides "Save Images" without
  `NSPhotoLibraryAddUsageDescription` (build settings, with the microphone's), so Share All and the viewer's Share
  need it.
- **Chat events:** Instagram's own lines (a group renamed, someone left, a call) are admin text, `text_fragments`
  (upstream's `SlideMessageAdminText`; never captured, no group on the dummies), shown as `MessageKind.event` lines.
  A thread read's copy of a message has an empty `igd_snippet` (the mailbox's and live deltas' say "Sam sent 3
  photos."), so anything unknown is `MessageKind.unsupported` ("… sent a message Ferry can't show"), never its
  snippet, or it would read differently after a relaunch; "a poll" is a guess at Instagram's content type until a poll
  is captured.
- **Archive** is this device's (`UserDefaults` `archived`, room ID → ms), read as the room's `u.archived` tag; Instagram
  isn't told.

**Signing and bundle ID:** the team ID and the bundle ID prefix (`FERRY_BUNDLE_PREFIX`) live in `Config/Local.xcconfig`
(gitignored), included by `Config/Base.xcconfig`, the project's base configuration. Never put them back in
`project.pbxproj`. Without `Local.xcconfig` the app builds for the simulator as `com.example.ferry-messenger`.

## Traps (each one bit us)

**Build and test**

- **`-parallel-testing-enabled NO` always.** Otherwise xcodebuild shuts down the booted simulator to clone it.
- **DerivedData must live outside `~/Documents`.** With `-derivedDataPath build/DD` (inside this repo), the first
  failing assertion hangs the test host forever: XCTest symbolicates the failure by opening `.o` files under
  `~/Documents/…`, and that `open()` never returns from the simulator. Passing runs looked fine.
- **`-collect-test-diagnostics never`.** Otherwise any failure triggers `simctl diagnose` (minutes).
- **zsh doesn't word-split `$T`.** Use the `t()` function above, not `T="xcodebuild …"; $T test`.
- **Hand-written project with file-system-synchronized groups (objectVersion 77), no generator.** Add files by dropping
  them into `Ferry/`, `FerryTests/`, `FerryUITests/`. `Config/Info.plist` must stay outside them.
- **Rebuild before installing after any temporary source change** (e.g. a mutation check): `t test` leaves its build
  of the app in DerivedData, and `simctl install` happily installs that one.
- **The app's data container moves between `xcodebuild test` installs**, so a file put in it beforehand is gone.
  Simulator apps read host paths, so pass one (`FERRY_DEBUG_VOICE_FILE=/abs/path/v.m4a`).
- **All-literal geometry picks the `Int` initialiser:** `CGRect(x: 10, y: 20, width: 150, height: 150 * 128 / 700)` is
  27 tall, not 27.43. Give such an expression a `CGFloat` type first (WelcomeTests).
- `xcodebuild test` relaunches the app as its test host, which kills the app you launched by hand: relaunch (with a
  fresh build) after any test run before checking the simulator again.

**Simulator and live checks**

- **Simulator audio is the Mac's default output device.** When that device can't start (M5 and M9: an external
  display; `afplay -v 0 x.aiff` → `AudioQueueStart failed (0xe0114101)`), AVFoundation silently drops every item with an
  audio track, video included (log: `RenderPipelineFailedToStart`). Check the host before debugging playback. Muting
  doesn't help; don't change the Mac's sound settings for it.
- **…and then holding the mic freezes the app**: `AVAudioRecorder.record()` blocks the main thread for good inside
  AudioToolbox (`AQMixEngine_Base::DevLock`, spindump 2026-10-14) once `.playAndRecord` needs that output. Check the
  simulator's voice notes with `FERRY_DEBUG_VOICE_FILE` (docs/DEVELOPMENT.md) unless `afplay` works; the real recorder can't be
  exercised there in that state (FOLLOWUPS #40).
- **The Photos picker runs in another process**: XCUITest finds its cells (`app.images`, label "Video, six seconds, …";
  newest first) but they aren't hittable, so tap `coordinate(withNormalizedOffset:)`. Its "Location Is Included" is the
  system's; the app strips it (photos re-encoded, videos exported with the sharing filter).
- **Resetting the app's `UserDefaults` from outside** (e.g. the Requests card's `requests.seen`, docs/DEVELOPMENT.md): editing the
  container plist isn't enough while the simulator's cfprefsd caches it; stop `com.apple.cfprefsd.xpc.daemon` first.
  That restarts SpringBoard, after which `simctl ui appearance dark` no longer applies until SpringBoard is restarted
  again (`launchctl stop com.apple.SpringBoard` via `simctl spawn`).
- **iOS caches the launch screen** (per app, in the data container's `Library/SplashBoard/Snapshots`); installing a
  build over the app keeps the old one. Terminate the app, delete that folder's contents
  (`xcrun simctl get_app_container $SIM $APP data`) and launch: the new `UILaunchScreen` shows, without the uninstall
  that would also wipe the app's `UserDefaults` (account identities). It shows for ~0.5 s: start `simctl launch` in
  the background and take `simctl io screenshot` in a loop.
- **The simulator's Home Screen icon style is "Default"**, which shows every app's light icon even in dark appearance.
  To see the dark or tinted icon: long-press the wallpaper → Edit → Customise → Dark / Tinted; set it back to Default
  (tap only the wallpaper, Edit and the sheet: jiggle mode puts a delete badge on every icon).
- **Reduce Motion has no `simctl ui` switch:** `xcrun simctl spawn $SIM defaults write com.apple.Accessibility
  ReduceMotionEnabled -bool true`, then relaunch the app (Welcome's frames 1.5 s apart become identical); write `false`
  afterwards. Increase Contrast does have one (`simctl ui $SIM increase_contrast enabled`).
- `simctl io screenshot` right after a tap often shows the frame before it; wait 1.5–2 s (sheets animate longer).
  **Screenshot before every coordinate tap that depends on state**, and **take tap coordinates only from a full-size
  simulator screenshot** (points = pixels ÷ 3), never from a scaled or side-by-side image. Both mistakes started (then
  cancelled) real logins in Ferry: M7a hit "Add Instagram account", M7b hit A3's "Log in again".
- **Every N1 search is an Instagram request** (`IGSearch`): 300 ms debounce, 2+ characters. A result opens our own
  room when one matches (the engine's `ExistingDM`: receiver + DM channel ID) and only otherwise asks Instagram
  (`IGOpenDM`).
- SwiftUI `WebPage` drops the `Mobile/15E148` UA suffix a stock `WKWebView` sends; without it instagram.com shows a
  "tablet app" interstitial. `ConnectSheet` sets `applicationNameForUserAgent` back to the stock value. Don't
  otherwise change the UA.

**SwiftUI on iOS 26**

- **Several `NavigationLink`s in one `List` row merge into one tap target** (v1's folder tiles opened the wrong
  screen). Use `Button`s with `.borderless` style that push onto the `NavigationStack(path:)`.
- **A view's `.task` cancels its request when the lazy list re-creates the view.** Back-pagination from the top
  spinner's `.task(id: prevBatch)` got URLError -999 and never retried (the token didn't change). `AppModel.loadOlder`
  runs in its own `Task`; do the same for any request a lazy row starts.
- **The thread's bottom pin (#17).** A push (every first open after launch, some reopens) lays the thread's
  `ScrollView` out mid-transition with no insets, settles on the bottom, then **jumps to the top** when the navigation
  bar and composer insets arrive;
  `.defaultScrollAnchor(.bottom)` (and a `ScrollPosition(edge: .bottom)`) don't undo it. `ScrollGeometry.containerSize`
  is the frame *minus* those insets and the offset starts at minus the top inset, so the end is `content − container −
  top inset` (`ThreadView.ScrollEdge`); M4 took `containerSize` for the whole frame, read 208 pt at the end, and its
  re-pin never ran. `ThreadView` keeps `followsEnd` (decided when the user's own scrolling stops) and re-pins on every
  size change while it holds; a `scrollTo` made in the jump's own update can be dropped, so it's repeated in a `Task`.
  Not the media cards: their frames are fixed before the thumbnail loads. Check it with
  `testThreadOpensAtTheBottomAfterColdLaunch` (cold launch, the two DMs). Attaching a photo still scrolls explicitly.
  **The user still saw the jump and the re-pin (2026-10-15)**, plus a bounce: the first layout runs at offset 0, so the
  top spinner pages back on every open, and that page landed ~0.3 s after the tap, above the end, animated by the
  list's `.bouncy` (keyed on every message ID); `.defaultScrollAnchor(.bottom, for: .sizeChanges)` doesn't hold the end
  there (the offset stays, the re-pin catches up a few frames later), nor do the explicit `.initialOffset` /
  `.sizeChanges` roles (same logged geometry). So the thread stays at opacity 0 until `ScrollEdge.restsAtEnd` (insets in
  place, within 20 pt of the end) has held for 100 ms with no page loading (1 s cap; a touch shows it), and only the
  last message ID animates. Logged with a temporary `os.Logger` in the geometry action: the fastest way to see this.
- **No XCUITest query after scrolling a thread up from its end** (`swipeDown`, then any element lookup): the full
  accessibility snapshot sends the thread's LazyVStack into a layout loop (content height flips every frame, 100% CPU)
  and the simulator usually dies with it (backboardd). Idle without the query; also on the pre-#17 code (FOLLOWUPS #39).
  To capture a scrolled thread: a coordinate drag made *before* scrolling, then only `XCUIScreen.main.screenshot()`
  (no query) and `terminate()` (`testDesignTour`).
- **An outer `.accessibilityIdentifier` replaces the inner one of a single-element view:** `MessageRow` tags every
  media card `thread.media`, so `media.reel` / `media.video` never reach XCUITest. Find a ready video by label
  (`ENDSWITH 'Double-tap to play.'`) and take the hittable one; offscreen rows are in the tree too, unhittable.
- **`ToolbarItem.sharedBackgroundVisibility(.hidden)` works on iOS 26.4** (design v3): the account stack and the
  thread header get no system capsule or padding behind their own `.glassEffect(.regular.interactive(), in: .capsule)`
  (measured 78 × 44 pt for two accounts, 112 for three or more). Without it, expect about 20 pt more width.
- `Adding 'UIKitToolbar' as a subview of UIHostingController.view is not supported` shows once in UI test logs; it
  predates design v3 (seen on the code before it too) and nothing visible goes wrong (FOLLOWUPS #50).
- **A horizontal `ScrollView` in the inbox's top safe-area bar that exists at the List's first layout** (accounts
  already loaded, e.g. right after onboarding) draws the chips ~128 pt low, hidden under the list but tappable.
  Inserted later it's fine. Not the large title's fault: v2 (inline title, `safeAreaBar`) still does it (forced-
  ScrollView check after O6 "Not now", 2026-10-14). The scope bar is a plain `HStack` in a `ViewThatFits` and only
  scrolls when the chips don't fit.
- `safeAreaBar(edge: .top)` under a *large* title puts the title in the scroll-edge blur (v1 used `safeAreaInset`);
  under v2's inline title it works, and rows pass under the chips with the edge effect (DESIGN §16 Q6).
- **A toolbar item's `.badge(_:)` is always system red** (iOS 26.4: neither the tint nor `.badgeProminence` changes
  it), which breaks "color means account". A `Label` as a toolbar `Menu`'s label is flattened to a bar-button image,
  so overlays on its icon vanish; a custom label view keeps them but is clipped to the glass circle. The Folders badge
  is an overlay on a fixed 32 pt `Image` label, kept inside that circle (`FoldersMenu.badge`).
- **A `Button` inside a view with `onLongPressGesture` takes the touch: the hold never fires on it** (media cards,
  2026-10-22). A child `onTapGesture` instead makes the parent's hold wait ~0.8 s for the tap to give up, and the
  parent's `highPriorityGesture` stops the child's taps altogether. One view owning both works:
  `LongPressGesture().exclusively(before: TapGesture())` (`TapOrHoldButtonStyle`). `onPressingChanged` stays `true`
  through a scroll that starts on the view, so it can't drive press feedback in the thread.
- **Menu item subtitles:** a `Button` label of `Label(…)` followed by a `Text` shows the `Text` as the subtitle;
  `Label { Text; Text } icon:` doesn't.
- A plain `List`'s first row shows a top separator under the scope bar; the inbox hides it on the first chat row.
- **The thread header's toolbar caps Dynamic Type near XXL** (AX sizes grow the bubbles, not the header), so the
  AccountTag's fallback (first word, then mark) only shows for long names.
- A `Picker(.palette)` in a `.contextMenu` keeps the menu open after a pick; add `.menuActionDismissBehavior(.enabled)`.
  It does render as a horizontal emoji row (DESIGN §16 Q7), drawn small: the message menu was one until 2026-10-21,
  now it's `MessageSheet`.
- **A `String` search never finds U+FE0F inside "❤️"** (one `Character`): compare reaction keys by scalar
  (`Message.Reaction.same`). Instagram echoes "❤" for our "❤️".
- **`.glassProminent` / `.borderedProminent` draw their label white whatever the tint**: with `.tint(.primary)` (white
  in dark mode) or an account ink (light in dark mode) that's white on white. Add `.labelOnTint()` after either style.
- The app-wide `.tint(.primary)` greys out `role: .destructive` buttons with `.bordered`/`.glass` styles: add
  `.foregroundStyle(.red)` (or `.statusError`). Inside a `Button`, `.primary`/`.secondary` foreground styles take the
  tint; use `Color.primary` / `.inkSecondary`. Inside a `List`, a `Label`'s icon takes the row's wide icon column; use
  an `HStack`.
- A `TextField` bound to a binding whose setter rewrites the value (the one-grapheme mark) keeps showing what was
  typed; bind it to its own `@State` and normalize in `onChange` (IdentityEditor).
- A `confirmationDialog` opens as a popover with no Cancel button; dismiss it by tapping outside.
- **`.accessibilityLabel { label in Text("From X: "); label }` reads its parts joined by ", "** ("From X: , hi"), so
  write `Text("From X")`: VoiceOver says "From X, hi" (`SpokenSender`, the group UI test checks the exact label). It
  wraps any element's label (text, link, media cards), which a plain `accessibilityLabel(String)` can't.
- **A view proposed exactly its own width can come back narrower:** a group's reaction pill (❤ from three people with
  their overlapping faces, then 😂) measured 116 pt, was placed at 116, and laid out at 105, shrinking the first emoji's
  `Text` under its faces (a temporary `Layout` that logs proposals showed it, 2026-10-25). `MessageRow.PillPlacement`
  places it at `.unspecified`; the DEBUG group has that pill, and one wider than our own short bubble.
- **A `Canvas` with a taller sibling in a `ZStack` moves down the page:** the stack takes the sibling's height and the
  fixed-height frame around it centres it (O1's 307 pt ferry artboard pushed the 224 pt sea up 42 pt). Put the taller
  part in an `.overlay`, which never sizes its parent.
- **Trait-dependent colours must be built with `traitColor { }` (Tokens.swift).** SwiftUI resolves colours on its async
  render thread; a `UIColor { traits in … }` closure written in this MainActor-default target inherits MainActor
  isolation and Swift's runtime check traps there (device crash 2026-10-15, switching account scope). The simulator
  didn't show it. `TraitColorTests` resolves every token off-main.
