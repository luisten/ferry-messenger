# Follow-ups and code smells

What's left to do, found along the way. The numbers are stable: code, CLAUDE.md and the Android repo cite them as
"FOLLOWUPS #N", so a closed item keeps a line below and a new one takes the next free number (65). Items 1–58 were
collected for Ferry (on its Matrix server); those that only applied to the server and its bridge are gone, and their
text is in the repo at tag v1.8. Effort: **S** under half a day, **M** half a day to 2 days, **L** more.

## Open: code and quality

| # | What | Why it matters | Suggested fix | Effort |
|---|---|---|---|---|
| 7 | `AppModel.swift` (827 lines) holds accounts, connections, every thread action, media sends, requests, archive, N1 | Every feature edits it; hardest file to review | Split along its `MARK`s into `AppModel+Thread.swift`, `+Media`, `+Requests` extensions (no new types) | M |
| 8 | `ThreadView.swift` (1339 lines), `InboxView.swift` (748) | Long files mixing several screens' parts | Move `Composer`, `RequestBar`, `RecoveryBar` (already separate structs) to their own file; same for Inbox's `FolderView`/`RequestRow` | S |
| 14 | Status colours have no Increase Contrast variants; a few icons and strokes still use system `.secondary` | DESIGN §11 | Add high-contrast variants in `Tokens.swift`; icons need 3:1 | S |
| 15 | `.gitignore` has no root `/*.png` rule | A screenshot saved at the repo root could be committed, with real accounts in it | Add `/*.png` | S |
| 35 | No DEBUG switch to ignore the Requests card's seen markers | Re-showing the card needs cfprefsd and SpringBoard restarts; the UI test can't assert the card before Requests is opened | `FERRY_DEBUG_RESET_REQUESTS_SEEN=1` clears the markers at launch | S |
| 36 | DEBUG request fixtures are given to accounts by the order the accounts load in, which can vary between launches | Screenshots and tests not reproducible | Assign fixtures by account ID | S |
| 39 | **The app hangs (100% CPU layout loop) when a full accessibility snapshot is taken after scrolling a thread up from its end** | Seen only from XCUITest (any query after `swipeDown` in the thread; idle without one). The LazyVStack's content height flips between two values every frame and never settles. VoiceOver or Voice Control may reach it; normal touch use doesn't | Find the row whose estimate flips (Instruments, AX Inspector); try fixed estimates, or a `VStack` for short windows. UI tests: don't query after scrolling a thread up | M |
| 40 | **Holding the mic freezes the app when the audio route can't start** (simulator with a Mac output that fails): `AVAudioRecorder.record()` blocks the main thread inside AudioToolbox for good | Simulator-only so far (a real iPhone's route starts), but a frozen app is the worst failure | Start the session and recorder off the main actor with a ~2 s timeout ("Couldn't start recording"); the hold rules already allow a late start | S |
| 43 | A prepared video or a recording dropped without sending (thread closed with the attachment still there, app killed mid-upload) stays in `tmp/` | Up to 25 MB each until iOS purges `tmp` | Sweep `tmp/video-*`, `tmp/voice-*` older than a day at launch, next to `MediaCache.trim` | S |
| 44 | The thread's push still jumps to the top when the bars' insets arrive (#17): hidden while the thread waits to appear, not fixed. Older pages no longer move the user's place (1.6.5, `shownFrom`); not re-checked whether a page landing just after the thread appears still flashes | A slow network could show older messages for a moment | Keep the end with `scrollPosition(id:anchor: .bottom)` + `.scrollTargetLayout()`, or don't page back from the hidden first layout (it runs at offset 0, so the top spinner always shows) | M |
| 45 | `testThreadOpensAtTheBottomAfterColdLaunch` takes the first two chats with nothing unread, by position | On a simulator with other accounts it could open a chat that isn't a dummy's | Pick the two dummy DMs by name (passed in like `FERRY_UITEST_SEND_CHAT`, not hard-coded: real names stay out of git) and skip when either is unread | S |
| 46 | "Start a chat" from a group member (T3) | The member list is read-only (`PersonCard` has only "Open in Instagram"); DMing someone from a group means searching for them in New Message | A button on `PersonCard`: our DM with them if we have one, else `IGOpenDM` as the group's account (one Instagram request, like N1) | S |
| 47 | An unnamed Instagram group is called "Instagram chat" (`core/chat/chat.go`, when the thread has no title) | Not checked: no group exists on the dummies | Check a real unnamed group first; if so, name it from its members ("Theo, Maya and 2 others") | S |
| 49 | `AccountAvatar` draws its ring outside its frame (`.padding(-2 * line)`), so layout never counts it | Neighbours can overlap the ring unseen; the stack works around it with a 30 pt frame around a 24 pt photo, O6 with 16 pt spacing | Let the frame include the ring (size = photo + 4 × line) and adjust the call sites (composer, Accounts, A2, A3, Chat Info, banner, O4, O6, IdentityEditor) | S |
| 50 | UI test logs show `Adding 'UIKitToolbar' as a subview of UIHostingController.view is not supported` once per launch | Nothing visible breaks, but UIKit warns of a broken hierarchy | Bisect the toolbars (the inbox's bottom bar with search and compose is the likely one); recheck on the next iOS | S |
| 52 | The thread's start block repeats the AccountTag that the header shows too | Two tags at the top of a short thread; the composer says it as well | Decide with the designer; dropping it is one line in `ThreadView.top` | S |
| 55 | The icon is three PNGs; iOS 26's "Clear" Home Screen style and Liquid Glass depth come from an Icon Composer `.icon` | Under Clear, iOS derives the icon from the light PNG | Build the `.icon` from the four shapes (tile, wave, hull, bubbles) in Icon Composer; it would replace the PNG part of `make_icon.swift` | M |
| 56 | `make_icon.swift` and `FerryPath` each parse the SVG subset (M H V C Z, ~25 lines twice) | The script can't import app code (it runs as `swift scripts/make_icon.swift`); it checks the app's path data is the SVG's, but not that both parsers agree | Fine while the subset stays this small; if it grows, generate `FerryShape.swift` from the script instead | S |
| 57 | `testThreadOpensAtTheBottomAfterColdLaunch` failed once in two full runs (2026-10-15): after Back, the second read chat's row wasn't found within 5 s | Flaky smoke test | Re-find the row by its label after Back instead of by index among read rows, or wait longer | S |
| 58 | At accessibility text sizes Welcome's legal line sits at the end of the scroll content, so VoiceOver reads it before the pinned button, not after (DESIGN O1's order 4–5) | Minor order difference at AX sizes only | `accessibilitySortPriority`, or accept the visual order | S |
| 59 | A reaction pill's tap target is its 24 pt capsule | DESIGN §11 asks 44 pt for reaction pills | A `contentShape` with a negative inset around `ReactionPills` | S |
| 60 | In dark mode a group pill's faces nearly vanish: their grey and their 1.5 pt `reactionBackground` ring match the dark pill | A stack reads as loose letters | A ring in a colour that contrasts with the pill in both appearances | S |
| 62 | A group pill wider than the screen (about 5 emoji with faces) still runs off it | Rare: about 15 people reacting | Past the available width, fall back to DM-style counts ("❤ 3") | S |

## Open: needs a live check

| # | What | Why it matters | Suggested fix | Effort |
|---|---|---|---|---|
| 5 | A private account's reel never seen live | Its card rests on a hand-made event | Share one from a private account to a dummy that doesn't follow it | S |
| 6 | No real request ever handled (D11) | Accept, no "Seen" and reply-accepts are proven only on DEBUG fixtures and a forced request (`IGCore.setDebug`) | A third Instagram account writing to a dummy | S |
| 24 | Groups (sender names and avatars, "From …" for VoiceOver, reply quotes, Chat Info's members) are built and checked on the DEBUG group only (`FERRY_DEBUG_GROUP`, `GroupTests`): the dummies can't form one | Real groups may differ from the hand-made shape: unnamed groups (#47), large groups | Open a real group and check names, avatars, the reply caption and Members against Instagram; then capture a scrubbed one as a fixture | S |
| 26 | Deleting a request: whether the requester sees "Seen" | The engine doesn't mark the chat read before `IGDeleteThread`, but Instagram's side is untested | Check once with a real request (#6) | S |
| 51 | The player's failed state for a **share** (Try Again beside Open in Instagram) never seen on screen | Built in design v3, seen only for a plain video | Look once by hand with `FERRY_DEBUG_PLAYER_FAILS=1` on a reel | S |
| 54 | Not yet recorded on a phone: the launch screen's white status bar (`UIStatusBarStyleLightContent`, DESIGN §18.2 "verify on device"), the icon among real wallpapers, Low Power Mode holding Welcome still (unit-tested rule; the simulator has no Low Power switch) | Device-only behaviour | One cold launch on the iPhone in light and dark; Welcome with Low Power on | S |

## Deferred by decision

| # | What | Why it matters | Suggested fix | Effort |
|---|---|---|---|---|
| 18 | Hidden requests vs Requests | The engine reads `PENDING` and `SPAM` but shows both as requests | A collapsed "Hidden" section at the end of Requests (DESIGN I2) | S |
| 19 | Notifications, app-icon badge (D6) | Messages only show when the app is open | Catch-up notifications from Mozilla's push queue shipped in 1.6 and were removed in 1.6.3: Instagram's web push hardly ever arrived ([PLAN-push.md](PLAN-push.md)). Left: a relay to APNs, only if web push proves reliable | L |
| 22 | Account identity (name, colour, mark, order) is local `UserDefaults` | Lost on reinstall | Keep it in the Keychain, which a reinstall keeps, next to the session | S |
| 28 | Not built: mute, pin, message search, new groups (DESIGN T1, I1) | — | Pick from here when wanted | — |
| 31 | Moving a chat to Primary or General from the app (DESIGN I1/I3) | Only Instagram moves chats; the app follows | Capture Instagram's web request for it first | M |
| 32 | "Business" or "Creator" in Accounts (DESIGN §4.4) | Accounts says "Professional · Primary and General"; Instagram's viewer says nothing finer | Find a field that tells them apart (e.g. `is_business_account`) in a capture | S |

## Closed (kept so their numbers resolve)

| # | What | Closed |
|---|---|---|
| 10 | Contact handles missing on the bridge's ghosts until it updated them | Moot without the bridge; the DEBUG group's handle-less member mirrors that shape |
| 16 | `Timeline.reduce` cost | Measured 2026-10-14: 1.5 ms median over 495 real events (`TimelineCostTests` fails past 16 ms); no memoizing |
| 17 | The thread opened at the top, then jumped and bounced (the bottom pin) | Fixed 2026-10-14 and 2026-10-15: the thread follows its end and stays hidden until it rests there (CLAUDE.md "The thread's bottom pin"); the jump is masked, not removed (#44) |
| 25 | No media cache cap | `MediaCache.trim`: 500 MB, trimmed to 400 MB (`MediaTrimTests`) |
| 34 | A thread opened slightly short of its end | Fixed with #17 |
| 53 | Welcome's bubbles: the user's own first two accounts or fixed samples | The build's behaviour (your accounts once there are any) kept; DESIGN O1 says so since 2026-11-18 |
| 61 | A tapped notification for a chat in Requests or General opened the inbox | Gone with the notifications (1.6.3) |
| 63 | SwiftUI's `<OnScrollGeometryChange Modifier> tried to update multiple times per frame`, once per thread open | Left as is (2026-10-27): SwiftUI's own layout in the push's first frame. Harmless, but never trust the action's `old` (#64) |
| 64 | An unread chat that overflows by a lot opened at its end, not on the "New messages" line (iOS 27.2) | Fixed 2026-11-01 (1.6.4): compare with the last `new` seen (`pin.edge`), decide from measured heights (`pin.heights`), `BottomPin.jumping` (CLAUDE.md) |
