# Developing Ferry Messenger

The technical side: how the app is built, how to run and test it, how to put it on your iPhone, and how releases are
signed. What the app does, screen by screen: [specs.md](../specs.md). Notes for coding agents (rules, traps, how
Instagram behaves): [CLAUDE.md](../CLAUDE.md).

- [How it fits together](#how-it-fits-together)
- [Build and test](#build-and-test)
- [Install on your iPhone](#install-on-your-iphone)
- [Update to a new version](#update-to-a-new-version)
- [DEBUG switches](#debug-switches)
- [Releases](#releases)
- [CI](#ci)

## How it fits together

- **`core/`** is a Go module over [mautrix](https://github.com/mautrix/meta)'s Instagram client
  (`go.mau.fi/mautrix-meta`, pinned in `core/go.mod`). It builds to a static library with a small C API (one client
  per account, every Instagram request counted), wrapped in `build/IGCore.xcframework` (gitignored). The API is
  the `//export`s in `core/cmd/igcore/main.go`, each with its comment ([PLAN-android.md](PLAN-android.md) §3 has the
  envelope its updates come in): `core/chat` turns
  Instagram's answers into Matrix-shaped chat updates (pure Go; `cd core && go test ./...`, on the captures in
  `core/testdata`), `cmd/igcore` is the C API around it.
- **The app** (SwiftUI, no third-party Swift packages) links it through `Ferry/IGCore.swift` and applies the engine's
  updates to the chat model the views show (`Room`, `Timeline`, `Inbox`). `core/chat`'s tests write what it makes of
  each capture to `FerryTests/Fixtures/engine_*.json` (`go test ./chat -update`), which the app's `EngineTests` read.
- **`core/spike/`** is the capture app, a one-file SwiftUI test app on the same API: log in accounts by hand, act as
  either side of a thread, and with `FERRY_DEBUG_CAPTURE=<host dir>` write Instagram's answers and every live event,
  for test fixtures (`core/spike/build.sh`).

The Xcode project, scheme, targets and folders are named `Ferry` (`Ferry.xcodeproj`, `Ferry/`, `FerryTests/`); the app's
display name is "Ferry Messenger" and its bundle ID `<prefix>.ferry-messenger`. The project is hand-written with
synchronized folders: drop a `.swift` file into `Ferry/` (or a test folder) and it builds, with no project edits.

The other documents in `docs/`: [DECISIONS.md](DECISIONS.md) (the decision log, D1–D19 from Ferry's server days, D20
on this app's), [FOLLOWUPS.md](FOLLOWUPS.md) (what's left to do), [design/DESIGN.md](design/DESIGN.md) (the design both
apps follow), the done plans [PLAN-core.md](PLAN-core.md) and [PLAN-android.md](PLAN-android.md) (their decisions, C and
E, and results), [PLAN-push.md](PLAN-push.md) (the notifications 1.6.3 removed, and why), [BRIEF.md](BRIEF.md) and
`spikes/` (the first spike on the phone). Code comments refer to their numbers (D6, C3, E4, FOLLOWUPS #17, DESIGN §3.5).
Ferry's server-era plan, spike, design reviews and research are in the repo at tag v1.8.

## Build and test

You need **Xcode 27** and **Go 1.27.3** ([go.dev/dl](https://go.dev/dl/), on `PATH`). Build the core once, and again
whenever `core/` changes (about 15 s):

```sh
core/build.sh
```

The app's "Check core/" build phase (`core/build.sh --check`) stops the build with "run core/build.sh" when `core/`
has changed since, e.g. after a pull. A build with no `build/IGCore.xcframework` at all fails with "There is no
XCFramework found" and Xcode remembers that: after the first `core/build.sh`, Clean Build Folder (⇧⌘K) once.

### After a pull

Usually nothing: build as before. Two exceptions:

- **The build stops with "run core/build.sh":** `core/` changed. Run `core/build.sh`, then build again.
- **`git pull` refuses because of local changes to `Ferry.xcodeproj/project.pbxproj`:** Xcode made them, by itself or
  through "Update to recommended settings". Unless you changed the project on purpose, drop them and pull again:

  ```sh
  git restore Ferry.xcodeproj/project.pbxproj
  ```

Don't accept "Update to recommended settings" from a checkout of `main`. The project is already current for Xcode
27.2. When a newer Xcode offers it again, take it on a branch, so it's done once for everyone: keep the Ferry target's
`ENABLE_USER_SCRIPT_SANDBOXING = NO` and commit the rest. The "Check core/" phase reads every Go file in `core/`, which
a sandboxed script can't, so with sandboxing on the build fails with `Sandbox: bash … deny … core/build.sh` (1.6.4).

Your Apple team ID and bundle ID prefix go in `Config/Local.xcconfig` (gitignored). Without it the app builds for the
simulator as `com.example.ferry-messenger`; a phone needs your team:

```sh
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

Then, with a simulator booted:

```sh
SIM=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
t() { xcodebuild -project Ferry.xcodeproj -scheme Ferry -destination id=$SIM \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/FerryMessenger \
  -parallel-testing-enabled NO -collect-test-diagnostics never "$@"; }

t test -only-testing:FerryTests           # unit tests (305), on real captured Instagram data
t test -only-testing:FerryUITests         # UI tests on made-up data (below)
```

Keep DerivedData outside `~/Documents`, `-parallel-testing-enabled NO` and `-collect-test-diagnostics never`:
[CLAUDE.md](../CLAUDE.md) "Traps" says why.

### Run in the simulator

```sh
APP_PATH=~/Library/Developer/Xcode/DerivedData/FerryMessenger/Build/Products/Debug-iphonesimulator/Ferry.app
t build && xcrun simctl install $SIM $APP_PATH
APP=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' $APP_PATH/Info.plist)
xcrun simctl launch $SIM $APP
```

The first launch shows onboarding: **Connect** opens Instagram's login page in a web view, and you log in by hand
(the app never types there). Each account's session (its cookies and profile) goes to the Keychain (service `ferry`,
account `instagram:<id>`), so later launches and reinstalls open on the inbox. Use test accounts in the simulator.

Every launch loads each account's inbox from Instagram. DEBUG builds log the requests each account made (by operation
name, nothing else) when the app goes to the background, and the time from launch to the first inbox rows:

```sh
xcrun simctl spawn $SIM log show --last 10m --predicate "subsystem == \"$APP\" AND category == \"instagram\"" | grep requests
xcrun simctl spawn $SIM log show --last 2m --predicate "subsystem == \"$APP\" AND category == \"launch\"" | grep 'cold launch'
```

### UI tests

Most run on `FERRY_DEBUG_DEMO`'s made-up accounts and chats, which never connect: nothing reaches Instagram, and the
simulator's own accounts are left alone. They cover the inbox, an account's chip, a chat and Chat Info; Requests and a
request thread; a group (senders named to VoiceOver, Chat Info's members); where an unread chat opens and its
jump-to-newest button; a short chat opening above the composer; swiping a message to reply; holding a photo for its
sheet; Mark as Unread from the inbox; pasting two photos as one set; the welcome screen; New Message; the mic (a tap
records hands-free and the trash cancels; hold and slide cancels).

These skip unless you opt in:

- **Live** (`TEST_RUNNER_FERRY_UITEST_LIVE=1`): the accounts logged in to the simulator's app, so each launch loads
  their inboxes from Instagram. `testThreadOpensAtTheBottomAfterColdLaunch` opens the first two chats with nothing
  unread, after a cold launch and again. `testSendVideoAndVoiceNote` also needs `TEST_RUNNER_FERRY_UITEST_SEND=1` and
  `TEST_RUNNER_FERRY_UITEST_SEND_CHAT` (the start of a row label): it sends the newest video in Photos and a held voice
  note there (two Instagram messages). Add `TEST_RUNNER_FERRY_UITEST_BLOCK_SENDS=1` to rehearse it with nothing
  leaving the app, and `TEST_RUNNER_FERRY_UITEST_VOICE_FILE=<host path to an .m4a>` when the simulator can't record.
  A video for Photos: ffmpeg's test pattern, or `xcrun simctl io $SIM recordVideo`, then `xcrun simctl addmedia $SIM
  <file>`.
- `testConnectSheetOpensAndCancels` loads Instagram's login page (nothing typed), with `TEST_RUNNER_FERRY_UITEST_LOGIN=1`.
- **Design screenshots** (`testDesignTour`, with `TEST_RUNNER_FERRY_UITEST_TOUR=<folder>`), all on the made-up data. It
  writes `<folder>/v3-<screen>-<suffix>.png`; run it once per appearance:

  ```sh
  xcrun simctl ui $SIM appearance dark
  TEST_RUNNER_FERRY_UITEST_TOUR=$PWD/docs/verification TEST_RUNNER_FERRY_UITEST_TOUR_SUFFIX=dark \
    t test -only-testing:FerryUITests/SmokeUITests/testDesignTour
  ```

The README's screenshots (`docs/screenshots/`) come from `FERRY_DEBUG_DEMO=1` too, with the status bar set to
`xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100`, scaled to 540 px wide.

### App icon and launch screen

The app icon and the launch mark are drawn from the designer's SVGs (`docs/design/ferry-icon-color*.svg`) by
`swift scripts/make_icon.swift`, run from the repo root (CoreGraphics, no packages): AppIcon light, dark and tinted,
and `LaunchMark` @2x/@3x, light and dark. It refuses SVG features it doesn't draw, and stops if `Ferry/FerryShape.swift`
(the welcome screen's picture) no longer carries the SVGs' path data verbatim. The launch screen is `UILaunchScreen` in
`Config/Info.plist`; iOS caches it ([CLAUDE.md](../CLAUDE.md) "Traps").

## Install on your iPhone

1. Create `Config/Local.xcconfig` with your team ID and a bundle prefix of yours (above). Don't pick a team in Xcode's
   Signing & Capabilities: that writes it into `project.pbxproj`.
2. On the phone, turn on **Developer Mode** (Settings → Privacy & Security), connect it to the Mac and trust it.
3. Run:

   ```sh
   scripts/update-iphone.sh
   ```

   It builds the newest release, optimised (Release), in a worktree under `build/update-iphone/`, so your checkout
   stays as it is, and installs it on the phone. It fetches Go 1.27.3 into `~/Library/Caches/ferry-messenger/` (checked
   against its SHA-256) if your `PATH` doesn't have it. With several iPhones paired, pick one with `--device <id>`
   (`xcrun devicectl list devices`); `--no-install` stops after the build. The phone can be on a cable or on the same
   Wi-Fi as the Mac (once it's been paired), unlocked; the script checks it can reach it before it builds.
4. With a free Apple account, the first time: trust the developer in Settings → General → VPN & Device Management.
5. Log in to your Instagram accounts **on your home Wi-Fi** the first time.

**While developing**, build the core (`core/build.sh`), open `Ferry.xcodeproj`, choose your iPhone and press Run. That
installs a Debug build: slower, and Accounts says "(Debug)". For a build you'll keep using from Xcode, set Product →
Scheme → Edit Scheme → Run → Build Configuration to **Release** first, or use the script.

The app needs no special capabilities (no push, no app groups), so a free Apple account can build it:

| | Free (Personal Team) | Paid (Apple Developer Program) |
|---|---|---|
| How long it opens | **7 days**, then run `scripts/update-iphone.sh` again | 1 year |
| Limits | 3 apps you install yourself per device | None that matter here |

With a free account, Accounts shows until when your build opens, and on its last 2 days the command that renews it.

**AltStore or SideStore** renew free-account apps every week on their own: install a release's `.ipa` with them
instead of Xcode (and add its source: next section). They need your Apple ID, and count toward the 3-app limit. Stick
to one way of installing: switching between Xcode and AltStore or SideStore changes how the app is signed, and you
may have to log in to your accounts again.

## Update to a new version

**With AltStore or SideStore:** add Ferry Messenger's source once, and they show each new version. On your iPhone,
open [altstore://source?url=https://github.com/luisten/ferry-messenger/releases/latest/download/source.json](altstore://source?url=https://github.com/luisten/ferry-messenger/releases/latest/download/source.json)
or [sidestore://source?url=https://github.com/luisten/ferry-messenger/releases/latest/download/source.json](sidestore://source?url=https://github.com/luisten/ferry-messenger/releases/latest/download/source.json),
or add `https://github.com/luisten/ferry-messenger/releases/latest/download/source.json` under Sources. Installed
1.7.1 or earlier from a downloaded `.ipa`? Install Ferry Messenger once more from the source and log in to your
accounts again (the app's ID changed, so it's a new app to iOS), then delete the old one.

**Built from source:** once a day, as the app opens, it asks GitHub for the newest release's version (one request that
sends nothing about you or your accounts; turn it off with "Check for new versions" in Accounts). When there's a newer
one, Accounts says "X.Y is out". Then run `scripts/update-iphone.sh`. Running it also renews a free account's 7 days:
when the profile Xcode made has under 3 days left, it moves it aside so Xcode makes a fresh one.

## DEBUG switches

Launch environment switches for DEBUG builds only (none exist in Release builds): add them as `SIMCTL_CHILD_<name>=…`
to the launch line above. They live in `Ferry/DebugFixtures.swift` and `Ferry/AppModel.swift`.

| Variable | Effect |
|---|---|
| `FERRY_DEBUG_DEMO=1` | Made-up data only, for screenshots and the UI tests: two made-up accounts ("Tamo Veska", "Kivo Studio") stand in for the Keychain's and never connect, so nothing reaches Instagram; four made-up chats, a group and three requests. Identities are defaults kept in memory. With `FERRY_DEBUG_ONBOARDING=welcome` it gives a welcome screen with those accounts |
| `FERRY_DEBUG_REQUESTS=1` | Three made-up message requests (they have no Instagram thread, and the app refuses sends to them). The Requests card shows only for requests newer than the last time Requests was opened (`requests.seen` in the app's `UserDefaults`); to see it again, run the snippet below first |
| `FERRY_DEBUG_GROUP=1` | One made-up group, "Saturday Climbs", on the first account: four senders (one who left), a reply, a reaction. Nothing about it leaves the app |
| `FERRY_DEBUG_GROUP_EXTRA=<n>` | n more unread messages in that group (with `FERRY_DEBUG_GROUP` or `FERRY_DEBUG_DEMO`), so what's new overflows the screen: where the thread opens and its jump-to-newest button. On an iPhone 17, 7 overflow by a little (139 pt: it opens at the end), 14 by a lot (807 pt: on the "New messages" line, with the button). Rows grew with the times in bubbles and lower reaction pills (2026-11-11): the UI test now uses 6 for "a little" (not re-measured) |
| `FERRY_DEBUG_GROUP_INCOMING=<seconds>` | One more made-up message arrives in that group that often while the app runs: the jump-to-newest button's count, and that nothing scrolls while you're up the thread |
| `FERRY_DEBUG_GROUP_OLDER=<n>` | That group opens as Instagram's mailbox has it, its newest five messages, and its top spinner loads the rest a page of 20 at a time (half a second each), then n pages of made-up older ones: back-pagination under the "New messages" line, and that scrolling to the top loads one page and stays where you were. With `FERRY_DEBUG_GROUP_EXTRA=14`, all five are unread, as after a busy day in a group |
| `FERRY_DEBUG_LOGIN_STATE=<account id>=<STATE>[,…]` | Shows that account in another state (`BAD_CREDENTIALS`, `TRANSIENT_DISCONNECT`, `UNKNOWN_ERROR`); the real session is untouched |
| `FERRY_DEBUG_ENDED_SESSION=<account id>[,…]` | Connects that account with a broken `sessionid` for this launch, so Instagram answers as it does for a session it ended (the real signed-out banner and re-login). The Keychain keeps the real cookies; a launch without it brings the account back. One rejected inbox load per launch |
| `FERRY_DEBUG_AS_REQUEST=<room id>` | The engine treats one real chat as a request, to check with the request log that opening it sends nothing; sends to it are blocked |
| `FERRY_DEBUG_ONBOARDING=welcome\|connecting\|identity\|another` | Onboarding at that step over the signed-in accounts ("Not now" returns). Don't tap "Connect" in it unless you mean to log in |
| `FERRY_DEBUG_BLOCK_SENDS=1` | Every message send, media upload, reaction, edit, unsend, Accept, Delete and typing notice fails in the engine ("Not sent"), so nothing reaches Instagram; "Seen" still goes |
| `FERRY_DEBUG_VOICE_FILE=<host path to an .m4a>` | Holding the mic "records" without the microphone and sends this file (`say -o v.aiff "…"; afconvert -f m4af -d aac v.aiff v.m4a`). The simulator reads host paths |
| `FERRY_DEBUG_STACK_EXTRA=<STATE>[,…]` | One stand-in account per state ("Extra 1", …) after the real ones, in the inbox's account stack only |
| `FERRY_DEBUG_PLAYER_FAILS=1` | Every video in the player and every voice note fails to play; they still download |
| `FERRY_DEBUG_LATEST=<tag>` | Accounts says that release (`v9.9`) is out, as if GitHub had named it; the app doesn't ask GitHub |
| `FERRY_DEBUG_EXPIRY=<days>` | Accounts' "Opens until" line as if the provisioning profile expired that many days from now (`1.5`: with the renewal command); the simulator has no profile |
| `FERRY_DEBUG_CAPTURE=<host dir>` | Writes Instagram's answers (as `core/chat` reads them) and every live event to that folder, per account (cookies never), for fixtures. Scrub before committing ([CLAUDE.md](../CLAUDE.md) "Invariants") |

To clear the Requests card's "seen" markers, stop the simulator's cfprefsd first, or it serves the cached value. That
restarts SpringBoard, which drops a dark appearance until SpringBoard restarts again:

```sh
xcrun simctl terminate $SIM $APP; xcrun simctl spawn $SIM launchctl stop com.apple.cfprefsd.xpc.daemon
/usr/libexec/PlistBuddy -c "Delete :requests.seen" "$(xcrun simctl get_app_container $SIM $APP data)/Library/Preferences/$APP.plist"
xcrun simctl spawn $SIM launchctl stop com.apple.SpringBoard   # only if `simctl ui $SIM appearance dark` stopped applying
```

## Releases

**Release candidates** carry a label in `Config/Base.xcconfig` (`FERRY_PRERELEASE = RC1`), shown after the version in
Accounts ("Ferry Messenger 1.7-RC1"); `MARKETING_VERSION` stays numbers only, as iOS requires. CI fails on main and
the release workflow refuses a tag while it's set: empty it in the PR that goes to main.

A release is a **signed tag** `vX.Y`. When one is pushed, `.github/workflows/release.yml` checks its signature
against the publisher's key, checks that the app's version (`MARKETING_VERSION`) matches, builds the core and an
unsigned `.ipa`, and publishes a GitHub release with the `.ipa`, its SHA-256 and `source.json`, the AltStore and
SideStore source ([Update to a new version](#update-to-a-new-version)). An unsigned tag, or one signed by another key,
publishes nothing. AltStore and SideStore sign the `.ipa` with the installer's own Apple account. The `.ipa` is
`com.luisten.ferry-messenger` (`FERRY_BUNDLE_PREFIX`, so the source can name it) and stamped `FERRY_DISTRIBUTION=ipa`,
so the app leaves updates to AltStore or SideStore. `scripts/make-source.sh <Ferry.app> <ipa> <tag>` makes the source
from the built app (version, build, minimum iOS, usage descriptions) and the `.ipa` (size, SHA-256); run it on a
Release build to check it (`python3 -m json.tool`).

**Once**, on the Mac you release from:

1. A signing key (with a passphrase), if you don't have one:

   ```sh
   ssh-keygen -t ed25519 -C "release signing" -f ~/.ssh/ferry_release
   ```

2. Tell git to sign with it, in this repo:

   ```sh
   git config gpg.format ssh && git config user.signingkey ~/.ssh/ferry_release
   ```

3. Trust it in GitHub Actions: a repository variable `RELEASE_SIGNERS` (Settings → Secrets and variables → Actions →
   Variables) holding this line. A variable, not a file in the repo, so a push can't change who's trusted:

   ```sh
   echo "ferry-release namespaces=\"git\" $(cut -d' ' -f1,2 ~/.ssh/ferry_release.pub)"
   ```

**Each release:** set the version (Xcode → target Ferry → General → Version, or `MARKETING_VERSION` in
`project.pbxproj`); in [CHANGELOG.md](../CHANGELOG.md) ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)),
move what's under Unreleased into a new `## [X.Y] - YYYY-MM-DD` section dated the day you tag, and add its compare
link at the bottom; commit, then:

```sh
git tag -s v1.0 -m "Ferry Messenger v1.0" && git push origin main v1.0
```

**Check a release yourself:** this repo's releases are signed with this key:

```text
ferry-release namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ0tGhxJ/SkRdKUe31bHZHr3KsAYriOV/AW39lo/v/Er
```

```sh
echo 'ferry-release namespaces="git" ssh-ed25519 …' > /tmp/allowed_signers   # the line above
git -c gpg.ssh.allowedSignersFile=/tmp/allowed_signers tag -v v1.0
```

## CI

`.github/workflows/ci.yml` runs on pull requests to `main`, pushes to `main`, and by hand. It uses no secrets and
never talks to Instagram: a check that `main` carries no release-candidate label (`FERRY_PRERELEASE`), shellcheck,
actionlint and the secret and home-path scans on Ubuntu, then on GitHub's `xcode-27` macOS runner `core/build.sh` (Go
1.27.3, pinned and checksummed), the engine's tests (`go test ./...`) and the unit tests. Actions are pinned by
commit SHA (Dependabot keeps them fresh); downloaded tools by version and SHA-256.
