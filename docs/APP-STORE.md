# Submitting to the App Store

Started 2026-11-23, against the earlier call to stay off the App Store (rejection is likely, see
[Risks](#risks)): the user wants to go through the process anyway, and learn it for later apps. Part 1 is the process
for any iPhone app; part 2 is Ferry Messenger's answers to every question App Store Connect asks.

Checked against Apple's pages on 2026-11-23: the [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
(last revised 2026-10-16), [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
and [upcoming requirements](https://developer.apple.com/news/upcoming-requirements/) (in force: built with Xcode 26+
on an iOS 26+ SDK, deployment target iOS 13+, the 2026 age rating questions; nothing new dated before mid-2027 except
the iOS 27.1 SDK screenshot rule, April 2027).

## Part 1: the process, for any app

Who does what: **you** = the Apple Developer account holder, by hand; **agent** = an agent can do it, some only with
your go-ahead at that step.

| # | Step | Where | Who |
|---|------|-------|-----|
| 1 | Paid Apple Developer Program membership, and the latest agreements accepted (a banner on the home page when one is pending) | developer.apple.com/account | you |
| 2 | Business: **EU trader status** (Digital Services Act; without an answer the app isn't offered in the EU), and for a paid app the Paid Apps agreement, tax forms and bank | App Store Connect → Business | you |
| 3 | Register the **bundle ID** as an explicit App ID, with the capabilities the app uses | developer.apple.com → Identifiers | agent (go-ahead) or Xcode does it |
| 4 | Create the **app record**: platform, name (unique on the store, 30 characters), primary language, bundle ID, SKU (any private string) | App Store Connect → Apps → + | agent (go-ahead) |
| 5 | App's code ready: privacy manifest, encryption key, privacy policy link in the app, no links to other ways of installing it, icon without transparency | the repo | agent |
| 6 | Host a **privacy policy** and a **support page** (any public URL; a file on GitHub works) | the web | agent writes, you push |
| 7 | Archive a Release build and **upload** it. The first one creates an **Apple Distribution certificate** and an App Store profile in your team | Xcode or `xcodebuild` | agent (go-ahead for the certificate) |
| 8 | Wait for processing (5–30 min, an email), then optionally **TestFlight**: internal testers (up to 100 people on your team) need no review, external ones need a lighter Beta App Review | App Store Connect → TestFlight | agent/you |
| 9 | Fill the version page: screenshots, description, keywords, URLs, build; App Information (category, age rating, content rights); App Privacy; Pricing and Availability | App Store Connect | agent (go-ahead) |
| 10 | App Review information: a **demo account** the reviewer can log in with, a phone and email, notes | the version page | you give the login, agent writes the notes |
| 11 | **Submit for Review** (usually answered within 24–48 hours), then answer questions in App Review's messages (Resolution Center), fix, resubmit, or appeal to the App Review Board | App Store Connect | you decide, agent drafts |
| 12 | Release: by hand, at once on approval, or on a date | the version page | you |

Things that catch first submissions:

- **Every upload needs a new build number** (`CFBundleVersion`) for its version; the version (`CFBundleShortVersionString`)
  is what users see. A timestamp as the build number never repeats.
- **Encryption:** an app that only uses HTTPS/TLS sets `ITSAppUsesNonExemptEncryption` to `NO` in Info.plist and is
  never asked again. Anything else (its own crypto) needs the export questions answered, and maybe a French declaration.
- **Privacy manifest** (`PrivacyInfo.xcprivacy`): App Store Connect refuses an upload that calls a "required reason"
  API (UserDefaults, file timestamps, system boot time, disk space, active keyboards) without a declared reason. This
  includes calls made by libraries linked in, so check a static library's symbols with `nm -u`.
- **App Privacy** ("nutrition label"): "collected" means sent off the phone where *you or your partners* can keep it.
  Data that goes only to a service the user signs in to themselves, with nothing for you, isn't collected by you.
- **Login:** the reviewer must be able to sign in without your help: a working demo account, no code sent to a phone
  they don't have. A built-in demo mode instead needs Apple's approval first (guideline 2.1).
- **Screenshots:** at least one set for iPhone, at one of the sizes App Store Connect names as required on the page;
  it scales them for the other sizes. PNG or JPEG, no transparency, real app screens (made-up data is fine).
- **Names:** no one else's trademark in the name or keywords; in the description only to say what the app works with,
  plus a "not affiliated" line.
- **Apps with content from users** (chat, posts) must let people filter, report and block abusive users, and publish
  contact details (guideline 1.2).
- **Accounts:** an app where you can *create* an account must let you delete it in the app (5.1.1(v)).

## Part 2: Ferry Messenger's answers

### Code (done on this branch)

- `Ferry/PrivacyInfo.xcprivacy`, the privacy manifest: no tracking, no collected data, and these reasons:

  | API category | Used by | Reason |
  |---|---|---|
  | UserDefaults | archive, unread marks, identities, reactions row | `CA92.1` the app's own data |
  | File timestamp | `MediaCache` (oldest files go first); `core/`'s `stat`, `fstat`, `lstat`, `fstatat` | `C617.1` files in the app's container |
  | System boot time | `core/` (the Go runtime's clock, `mach_absolute_time`) | `35F9.1` time between events in the app |
  | Active keyboards | the emoji keyboard check (`MessageViews.swift`) | `54BD.1` the right UI for the keyboards in use |

  Re-check after a `core/` dependency bump: `nm -u build/IGCore.xcframework/ios-arm64/libigcore.a | grep -E
  '_(f?stat|lstat|fstatat|getattrlist|f?statv?fs|mach_absolute_time)$'`.
- `ITSAppUsesNonExemptEncryption = NO` (Config/Info.plist): only HTTPS/TLS. **Not settled:** App Store Connect asks
  for documentation when an app uses "standard encryption algorithms instead of, or in addition to" the system's,
  and `core/` talks to Instagram with Go's own TLS, not Apple's. Common practice treats HTTPS-only as exempt; the strict
  answer is `YES`, then "standard algorithms", which brings a French import declaration if the app is offered in
  France. Your call before submitting.
- **Privacy Policy** row in Accounts, linking [PRIVACY.md](../PRIVACY.md) (5.1.1 wants it inside the app too).
- An App Store build is stamped `FERRY_DISTRIBUTION=appstore`: like the release `.ipa`, it never asks GitHub for new
  versions and shows neither "… is out" nor "Opens until" (`AppUpdate.fromSource`). Apple doesn't allow pointing
  users to another way of installing.
- Icon: 1024 × 1024, no alpha, light, dark and tinted. iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait.

### App record

| Field | Value |
|---|---|
| Platform | iOS |
| Name | Ferry Messenger: Calm DMs ("Ferry Messenger" is taken on the store; the name under the icon stays Ferry Messenger) |
| Primary language | English (U.S.) |
| Bundle ID | `com.luisten.ferry-messenger` (the release's, `FERRY_BUNDLE_PREFIX=com.luisten`) |
| SKU | `ferry-messenger` |
| User access | Full access |

### App Information

| Field | Value |
|---|---|
| Apple ID | 6838185228 (made 2026-11-23) |
| Subtitle (30) | Direct messages, nothing else |
| Category | Social Networking (primary), none secondary |
| Content rights | Only two choices: "Yes, it contains third-party content, **and I have the necessary rights**", or "No third-party content"; there is no "yes, without rights". The user chose the first (2026-11-23), on the view that users see only their own messages. App Review can still ask for Instagram's authorization (5.2.2) |
| Age rating | see below |
| License agreement | Apple's standard EULA (the AGPL covers the source, see [Risks](#risks)) |

**Age rating questionnaire** (2026 questions, answered 2026-11-23): everything "None"/"No" except **Messaging and
Chat: Yes**. User-Generated Content is "broad distribution" of what users make, and Social Media a feed: neither is
a DM client. No unrestricted web access (the only web view is Instagram's login page), no shared location, no
advertising, no gambling. Apple computed **4+**; overridden to **13+** (Instagram's age limit and PRIVACY.md's, and the
form says a stated minimum must be matched), shown as 12+ in Vietnam.

### App Privacy

**Data Not Collected** (saved 2026-11-23; **Publish** is yours: it attests the answers are accurate). The developer receives nothing; messages go between the phone and Instagram, which the user
signs in to themselves; the App Store build never calls GitHub. Privacy policy URL:
`https://github.com/luisten/ferry-messenger/blob/main/PRIVACY.md`.

### Pricing and Availability

Free (set 2026-11-23, United States as the base). Availability (set 2026-11-23): 174 of 175 regions, all but **China mainland**: it now
needs an AI-generated content declaration and a security assessment (App Compliance), and Instagram isn't reachable
there anyway. Apple silicon Macs: on by default, turned off (untested there). EU: declared **non-trader** under the DSA
(Business → Compliance, 2026-11-23), so nothing is shown publicly. For reference, or leave out the EU if you don't answer trader status (as an individual with a free
app and no income from it you're most likely a **non-trader**; a trader's address, phone and email are shown on the
store page).

### Version page (1.8)

- **Promotional text (170):** Just your Instagram direct messages: no feed, no stories, no ads. Several accounts side
  by side, each in its own colour.
- **Description:**

  > Ferry Messenger is a calm place for your Instagram direct messages, and only them. No feed, no stories, no reels,
  > no ads: you open it, read and answer your chats, and close it.
  >
  > • Several accounts at once, each with its own colour, so you always know who you're writing as.
  > • Chats, photos, videos, voice messages, GIFs, shared posts and reels, replies and reactions.
  > • Requests from people you don't follow wait in Requests until you accept or delete them.
  > • Archive chats and mark them unread, on your iPhone.
  > • Private by design: you log in on Instagram's own page, your session stays in your iPhone's Keychain, and the
  >   app sends nothing to its developer. No analytics, no tracking.
  >
  > Good to know: there are no notifications; new messages arrive while the app is open. End-to-end encrypted chats
  > can't be shown.
  >
  > Ferry Messenger is free and open source (AGPL-3.0). It is not affiliated with, endorsed or sponsored by Instagram
  > or Meta.

- **Keywords (100, no trademarks):** `dm,direct messages,chat,inbox,messenger,multiple accounts,calm,unread,voice notes`
- **Support URL:** `https://github.com/luisten/ferry-messenger/issues`
- **Marketing URL:** `https://github.com/luisten/ferry-messenger` (optional)
- **Copyright:** `2026 <your name as on the developer account>`
- **Screenshots:** see below.
- **Build:** the uploaded one; **Release:** manually.

**App Review information**

- Sign-in required: **yes**. User name and password: an Instagram account kept for review only (not the two test
  accounts), no two-factor login, its email one you watch during review (Instagram may ask a new login to confirm a
  code), with a few chats in it so the reviewer sees something. You type these in yourself.
- Contact: your name, phone, email.
- **Notes:**

  > Ferry Messenger is a client for the user's own Instagram direct messages. To sign in, tap "Add Instagram account"
  > and log in on Instagram's own login page, shown in a web view: the app never sees the password, and stores only
  > the session, in the Keychain. Use the account above. Instagram sometimes asks to confirm a login from a new
  > place; if it does, write to us in App Review's messages and we'll approve it within the hour.
  >
  > There is no server: the app talks only to Instagram, from the phone, while it is open. It has no notifications and
  > no in-app purchases. Messages from people the user doesn't follow arrive in Requests, where they can be deleted
  > without the sender knowing they were read. The source code is public at https://github.com/luisten/ferry-messenger.

### Screenshots

**Done 2026-11-23:** the version page asked for one slot, "iPhone with Dynamic Island (medium display)" (6.3",
1206 × 2622), and scales it to every other iPhone; four from `testDesignTour` on a fresh iPhone 17 Pro simulator
(`CODE_SIGNING_ALLOWED=NO`, no `Local.xcconfig`): inbox, group, Jonas's DM, Lena's request. Not Accounts: a Debug
build shows "(Debug)" and the update switch, which the App Store build hasn't. The 6.9" set below was made too but
isn't needed.

On the Mac Mini, from the made-up data (`FERRY_DEBUG_DEMO`, a Debug build is fine), at full size: one set on an
**iPhone 17 Pro Max** simulator (6.9", 1320 × 2868) and one on an **iPhone 17 Pro** (6.3", 1206 × 2622), so whichever
slot App Store Connect marks required is filled. Status bar as for the README's
(`xcrun simctl status_bar $SIM override --time 9:41 --batteryState charged --batteryLevel 100`), light appearance, no
scaling. `testDesignTour` writes every screen (DEVELOPMENT.md "Design screenshots"); pick 4–6: inbox with both
accounts, a thread with photos and reactions, the group, requests, Accounts, welcome.

### Build and upload

**On the Mac Mini's screen (Screen Sharing), never over SSH:** each attempt to sign or upload over SSH logged the
developer account out of Xcode (2026-11-23), and the upload failed anyway (`exportArchive Failed to Use Accounts`).

1. `git pull` on `main`, then `core/build.sh` (a Terminal over SSH is fine for this: nothing is signed).
2. `Config/Local.xcconfig` gives `FERRY_BUNDLE_PREFIX = com.luisten` and the team ID. For the build, also set
   `FERRY_DISTRIBUTION = appstore` and a new `CURRENT_PROJECT_VERSION` (a timestamp like `202611231324`) there, and take
   them out again afterwards; or archive from Terminal on the Mac Mini's screen:

   ```sh
   xcodebuild archive -project Ferry.xcodeproj -scheme Ferry -configuration Release -destination generic/platform=iOS \
     -archivePath ~/Library/Developer/Xcode/Archives/$(date +%F)/FerryMessenger-$(date +%Y%m%d%H%M).xcarchive \
     -allowProvisioningUpdates FERRY_DISTRIBUTION=appstore CURRENT_PROJECT_VERSION=$(date +%Y%m%d%H%M)
   ```

3. Xcode → Window → Organizer → the archive → **Distribute App** → **App Store Connect** → **Distribute**, signing
   automatic. The first one made the team's Apple Distribution certificate.
4. Apple processes the build (5–30 minutes, an email); then it can be picked on the version page.

The first upload: 1.8 (202611231324), 2026-11-23. For uploads with no screen at all (CI), an App Store Connect API key
(Users and Access → Integrations → Team Keys, role App Manager) passed to `xcodebuild` with `-authenticationKeyPath`,
`-authenticationKeyID` and `-authenticationKeyIssuerID`, and `scripts/ExportOptions-AppStore.plist` for the export.

## Risks

Most likely first, with what each would take:

1. **5.2.2, third-party service.** The app uses Instagram without Instagram's permission, and Apple can ask for it.
   There's no fix short of Meta's written permission; an appeal to the App Review Board won't change it. This is
   the expected outcome.
2. **2.1, login.** If the reviewer can't sign in (Instagram asks for a code, or locks the review account), it's
   rejected as incomplete. Watch the email and App Review's messages while it's in review.
3. **1.2, user-generated content.** Apple can ask for report and block. Ferry can delete requests but can't block
   or report anyone yet; it would need Instagram's web requests for both (not in the library's code we use).
4. **5.2.1 / 2.3.7, trademarks.** "Instagram" appears only in the description and the review notes, never the name,
   subtitle, keywords or icon.
5. **AGPL (not App Review).** The app's own code is yours to license, but `core/` links mautrix-meta, AGPL-3.0, whose
   `LICENSE.exceptions` grants special exceptions to two named companies only, none for the App Store. The Free Software Foundation's
   reading is that the App Store's terms add restrictions the GPL forbids (VLC was pulled over this in 2011). The
   risk is that the library's author asks Apple to take the app down. Ask them before the app goes live.
