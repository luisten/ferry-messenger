# Beeper (iOS) UX research for IG Messenger

> The project was renamed **Ferry** on 2026-10-15 (D15). This is a historical record: it keeps the old name, IG Messenger.

Researched 2026-10-12. Current Beeper iOS build at time of writing: **v4.3.11 (#26909), 2026-10-06**.

## How to read this report

- **Method.** Desk research only: Beeper's help center, per-platform changelogs (iOS/Android/Desktop), App Store listing and reviews, Hacker News (Algolia API), mautrix bridge changelogs, Beeper engineering/blog posts. Nothing was installed or downloaded. I could not view screenshots or run the app.
- **Confidence tags.** `[C]` = stated in a primary source (Beeper help/changelog/blog or bridge changelog). `[I]` = my inference from indirect evidence. `[?]` = could not be established; needs hands-on check.
- **Blind spots.** Reddit was not fetchable (tool blocked), so r/beeper evidence is thin and secondhand. Trustpilot is unclaimed and sparse. Visual details (badge placement, colours, exact layouts) are mostly **not** documented in text; where I say "how it looks" I am reconstructing from release notes. Section 9 lists what to verify on a real phone in about 15 minutes.
- **Single biggest caveat.** The help center is internally inconsistent in places (e.g. the iOS Instagram steps say "Beeper Android app"; some search-engine snippets quote an older version of the Instagram page that says reels are unsupported, while the live page says they are supported). I treat the live page plus dated changelogs as authoritative.

---

## 0. Executive summary (the 10 things that matter most)

1. **Reels in chat: confirmed, with a twist.** Beeper's live Instagram guide says "Reels and Story shares sent to you in an Instagram chat are supported and show up in Beeper." In Aug 2026 Desktop v4.3.57 changed this to **thumbnail first, video fetched on tap** ("Reels now load on-demand after you click the thumbnail ... no more videos you never watched piling up on your device"). Android v4.55.1 (Aug 29, 2026) fixed "Instagram Reels would not play in group chats", so reels play in-app. The eager-download model was abandoned for storage/sync reasons. This is the single most useful finding for our must-have #2. (Section 2.2)
2. **Same-network multi-account is a paid, on-device-only feature** in Beeper (Free = 1 account/network; Plus $9.99/mo = 3; Plus Plus $49.99/mo = unlimited). Cloud connections can never be duplicated. (Section 1.3)
3. **"Which account replies" = the avatar in the composer.** Multiple accounts of one network: hover the composer avatar (Desktop, Sep 2025); on iOS, **swipe up/down on the composer avatar** to switch the send target (v4.3.4, Aug 31, 2026). Merged chats default the route to the network of the last incoming message. (Section 1.4)
4. **Beeper does not document any visual badge/colour system that tells two accounts of the same network apart** in the inbox. It does have per-account spaces, a "Count"/detailed inbox mode that shows source network, device icons next to accounts, and a phone-number hint in the iOS share sheet. We must design this ourselves; it is Beeper's weakest-documented area. `[?]`
5. **Message requests are not pulled in for Instagram** unless already accepted/replied to in Instagram. **Primary/General are never mentioned anywhere** in Beeper docs or changelogs. Both are must-haves for us, so this is a differentiation opportunity. (Section 2.1)
6. **Instagram on Beeper is on-device first** (Meta session lives on the phone; "read receipts are only available with the On-Device connection"). iOS push for on-device accounts is the hard problem (NSE memory limits); users report inconsistent IG notifications and missing messages. (Sections 5, 6)
7. **Inbox model worth copying:** Inbox = unread + read-not-archived-not-low-priority + drafts. Archive auto-returns on new activity. Low Priority = archive + mute (mentions/replies only). Pins = bubble row at top. Per-account "Show in Inbox: None / DMs only / All". (Section 1.1)
8. **Connection errors are surfaced as a red X on the network icon + red banner with Reconnect**, plus Settings > Accounts > Reconnect. Account status has an explicit state machine (`connected`, `connecting`, `backfilling`, `reconnect_required`, `attention_required`, ...). (Section 4)
9. **What users love:** "Instagram DMs without the Instagram app / feed" (by far the most repeated praise), clean fast UI, responsive team. **What they complain about:** unreliable IG sync/notifications, ban/checkpoint anxiety, paywall on multi-account, onboarding bugs. (Section 6)
10. **Beeper ships on iOS roughly weekly**; most recent fixes show where the pain is (account setup getting stuck, duplicate chats, new chats created through the wrong account, message requests with no title). We can pre-empt these. (Sections 3, 7)

---

## 1. Information architecture

### 1.1 Inbox structure

Source: Beeper "Inbox - Tips and Tricks" (https://help.beeper.com/inbox-tips-and-tricks-all-apps-guide), iOS "Managing Your Inbox" (https://beeper.helpjuice.com/en_US/ios/beeper-ios-managing-your-inbox), iOS "App Settings" (https://beeper.helpjuice.com/en_US/ios/beeper-ios-app-settings).

| Concept | Behaviour `[C]` |
|---|---|
| **Unified Inbox** | Contains: chats with unread messages; read chats that are not archived and not Low Priority; chats with an unsent draft (text drafts sync across devices since iOS 4.3.10, and draft text now shows in Inbox previews since 4.3.8). |
| **Hidden from Inbox** | Archived chats; Low Priority chats; chats from an account set to hide from All Inbox; chats in a label set to hide from Inbox. |
| **Archive** | Chat leaves Inbox, **returns on new activity** (new message, reaction, or marked unread). Archiving in Beeper does **not** archive on the network (Instagram stays untouched). Mobile: long-press > Archive, or assign Archive to a swipe action. |
| **Low Priority** | Moves chat to the Low Priority space **and mutes it**; you are still notified for @mentions and replies to your messages. Beeper's own recommendation for spam/chats you never want back in Inbox. (No block and no spam filter exist: FAQ https://help.beeper.com/en_US/quick-references/top-beeper-faqs says "mark spam as Low Priority".) |
| **Mute** | Chat stays in Inbox with a silent-bell icon; mentions/replies still notify. |
| **Pins** (formerly "Favorites") | Long-press > Pin. Pinned chats appear as a **row of avatar bubbles at the top** of the Inbox, drag to reorder. Home Screen widget for pinned chats (iOS 4.2.0). |
| **Unread** | Filter, plus "Mark as Unread" via long-press, and since 4.3.6 **"Mark as Unread from this message onward"** on any read message. |
| **Spaces** | Built-in: Inbox, Archive, Requests, Low Priority, Bookmarks, Reminders, Send Later (new Aug 2026), plus **one space per connected network account** and user **Labels**. iOS has a space navigator/bottom tab bar; Spaces sheet was redesigned in iOS 4.3.1 and Android 4.54.1 (Aug 2026). |
| **Labels** | User-defined filtered views with title/icon/colour; created from the space navigator > Spaces > New Label. Free tier = 1 label, Plus = unlimited (paywalled; some users complain). Overhauled in iOS 4.2.8. Can be set to hide from Inbox. |
| **Filters (mobile)** | Filter icon bottom-left: Unread, Drafts, Unanswered, DMs (new Aug 2026), Groups. Search adds network filters, Low Priority/Unread/Archive, and file type (images, videos, links, files). Search results grouped Chats / Groups / Media / Messages. |
| **Bulk select (iOS)** | Inbox dropdown > Select Chats: Archive, Low Priority, Mark read, Mute, Remind Me. Hold-and-scrub multi-select. |
| **Swipe actions** | Configurable left/right: Mark read/unread, Archive/unarchive, Mute/unmute. |
| **Inbox density** | Setting "Appearance": **minimal** (sender + unread) vs **detailed** (adds unread count and **source network**). |
| **Per-account visibility** | Per-account setting **"Show in Inbox"** with three options: **None, DMs only, All messages** (Settings > Accounts > account; also reachable from the Spaces navigation on Android, and Android 4.58.0 fixed it "having no effect" for Instagram). |
| **Per-account filters (Desktop)** | v4.2.692 (2026-03-31): "filter each account by Archived, Requests, and Low Priority". Sidebar shows per-category unread badges for Inbox/Archive/Requests/Low Priority/Reminders/Send Later and each account (https://help.beeper.com/en_US/desktop/how-does-the-badge-count-works). |
| **App icon badge** | Counts unread **chats in the Inbox only**; since iOS 4.3.10, unread chats from **muted accounts no longer inflate the badge**. |
| **Reminders / Send Later** | Plus features, each with its own space. |
| **Merged chats** | iOS 4.3.0 (2026-08-10): one chronological chat per *person* across networks. See 1.4. |

Release-note evidence the model has been churning (all iOS): 4.3.2 "Chats disappearing from the inbox after merged chat creation failed"; 4.3.11 "Duplicate chats appeared in the Inbox but couldn't be opened"; 4.3.9 "Chats unexpectedly archived after being marked read on another device". Inbox state sync across devices is evidently hard.

### 1.2 Mobile navigation shape `[C]/[I]`

- Older help text: stack icon top-left opens Settings/Accounts; compose icon top-right starts a new chat; bottom-of-screen **space navigator** (up/down arrow) for spaces.
- 2026 notes: "bottom tab spacing on larger iPhones so more tabs can stay visible" (4.2.5), "inbox-to-spaces swipe animation" (4.1.13), "soft scrolling" toolbar (4.3.9). `[I]` The shell is Inbox with a bottom space/tab bar plus horizontal swipe between spaces, and a filter button.
- Notification Focus Filter by space (iOS 4.2.9): Focus modes can limit notifications to chosen spaces.

### 1.3 Multiple accounts of the same network

**Plan and connection rules** `[C]` (https://help.beeper.com/en_US/beeper-plus/account-limits-everything-you-need-to-know, https://help.beeper.com/can-i-add-more-than-1-account-for-my-chat-network, App Store listing https://apps.apple.com/us/app/beeper-universal-chat/id6499013100):

| Tier | Accounts per network | Total | Price (App Store) |
|---|---|---|---|
| Free | 1 | 5 | free |
| Plus | up to 3 (on-device only) | 10 | $9.99/mo, $99.99/yr |
| Plus Plus | unlimited (on-device only) | unlimited | $49.99/mo, $499.99/yr |

- Cloud connections cannot be added twice on any plan. Instagram on-device: yes, multiple.
- On-device accounts live **only on the device where they were connected**; they do not appear on Desktop unless connected there too. Chat *states* (archived, pinned, low priority, reminders) sync across devices that share the account; messages do not. iOS v4.0.10 added "Only displays spaces for accounts available on the current device" and "device icons next to network accounts."
- Bug-class to note: iOS 4.2.2 fixed "adding accounts to other networks when one network has reached its account limit"; an App Store reviewer (Sep 23) reports a false "free limit" block after one WhatsApp account and a blank "Add account" screen.

**How two accounts of one network are told apart visually** `[?]` Beeper does **not** document an avatar badge, colour, or label scheme for this. What is documented:
- Each account is a **space** (sidebar/space bar entry). v4.0.19: "Inbox spaces now maintain consistent ordering when there are multiple accounts connected for a given network." "Remote account avatars should now load correctly in the Accounts view."
- Accounts view shows device icons and (via the dev API) `network` human-readable name, `loginID`, `user.username/fullName/imgURL`, status (https://developers.beeper.com/desktop-api-reference/resources/accounts).
- iOS share sheet: "the picker may show a phone number next to a contact's name; this number identifies which of **your own accounts** is being used" (Merge Chats guide). So Beeper's pattern for same-network disambiguation is *identity text on the sender row*, not colour.
- Inbox "detailed" mode shows source *network* (not account).
- Release notes reveal failure modes: "new chats and groups sometimes being created through the wrong account" (iOS 4.2.8), "incorrect self-hosted account labels" (4.2.9), "duplicate self-hosted bridge account entries" (4.2.8). `[C]` These are exactly the multi-account bugs to design against.

### 1.4 Choosing which account replies

- **Composer avatar = send identity.** Desktop v4.1.169 (2025-09-02): "When you have multiple accounts from one chat network, you can switch between them by hovering over your avatar in the chat composer." iOS v4.3.4 (2026-08-31): "Improved switching between chat send targets by swiping up or down on the composer avatar." iOS 4.2.4 fixed "monochrome network icons in the chat composer using the wrong tint colour", so the composer also shows a network icon. `[C]`
- **Merged chats (cross-network, same person)** (https://help.beeper.com/en_US/beeper-plus/merge-chats-getting-started-guide):
  - Default route follows the **latest incoming message's network**; if your message was last, it may revert to the Default Chat after 30 minutes.
  - Tap the composer avatar to pick a specific underlying chat. "Each account appears as a separate option when you choose which chat to reply from."
  - "Network indicators may appear between messages" in the merged timeline. Single combined unread badge and single best-effort read receipt.
  - The Default Chat preference **does not sync** between devices (users must set it per merged chat per device). Android 4.53.1 later mentions "reply networks" and pinned updates in merged chats.
  - Unmerge via Chat Info > Manage.
- **New chat:** compose icon > type name or number > pick a *network* (https://help.beeper.com/en_US/ios/beeper-ios-start-a-new-chat). The doc does not say how an account within a network is chosen. `[?]`
- **Relevance to us:** For two IG accounts a thread belongs to exactly one account, so the correct default is "reply as the account that owns the thread", locked unless the user deliberately overrides. Beeper's swipe-to-switch is designed for the merged/cross-network case.

---

## 2. Instagram specifics

### 2.1 Message requests, Primary/General, and what gets bridged

From the live Instagram guide (https://help.beeper.com/en_US/chat-networks/instagram) `[C]`:
- "New message requests also need to be accepted from Instagram directly and do not get pulled into Beeper unless already accepted or replied to on Instagram."
- No full history: "only messages sent after setup may appear" (history backfill is a separate topic).
- **View-once media does not sync** (Desktop v4.2.330, Dec 9 2025: "Instagram no longer syncs view-once media. Please use the native Instagram app to view.").
- Max attachment 7.6 MiB per the guide. (An App Store reviewer says keeping videos near 30 MB works; the guide's number may be stale.)
- Cannot post to Feed or Stories. Non-US phone-number login unsupported. Facebook login works if linked.
- Read receipts only on the On-Device connection, stored locally.
- Typing indicators received (Oct 2025) and sent (Aug 2025) on On-Device Instagram.
- Instagram calls: bridge only posts notices (mautrix-meta v26.08).

**Primary / General (professional accounts): no mention anywhere** in Beeper's Instagram guide, help center, or any iOS/Android/Desktop changelog `[C: absence]`. Searches for it return only third-party-tool pages (e.g. Vista Social states the Messenger Platform API does not expose folder metadata; Beeper uses a different, unofficial path so this does not necessarily apply). Practical read: Beeper shows whatever the bridge syncs as one list and gives the user no folder control. **Our must-have #3 (Primary / General / Requests) is therefore uncharted by the reference app.**

Beeper-level "Requests" machinery that exists (generic across networks; whether Instagram requests ever land there is `[?]`):
- A **Requests space** and Requests filter exist (Desktop). Per-account Requests filter since Desktop v4.2.692. Notifies on requests that arrived while the app was closed (v4.2.715, 2026-04-07); stops notifying for muted accounts (v4.2.876); fixes for "Requests showing unread when already viewed", "chats stuck in Requests", and "message requests with no title".
- iOS: Accept / Delete buttons on a request (4.2.8 fixed them missing in large chats); iOS 4.3.11 (2026-10-06): "message requests show **who sent them** when the chat has no name"; 4.1.13 improved the request badge accuracy. XDA (2024): replying to a request accepts it, with a warning.
- Instagram's own filtering (sort by follower count, verified) is not mirrored. `[I]`

### 2.2 Shared reels, posts, stories: how they render

**What is confirmed** `[C]`
- Live Instagram guide: reels and story shares "are supported and show up in Beeper"; posting is not supported.
- **Desktop v4.3.57 (2026-08-20): "Instagram: Reels now load on-demand after you click the thumbnail."** Release text: "Faster sync, less data, and no more videos you never watched piling up on your device." https://www.beeper.com/changelog/desktop/4.3.57
- **Android v4.55.1 (2026-08-29): fixed "Instagram Reels would not play in group chats."** https://www.beeper.com/changelog/android
- App Store reviewers describe viewing shared reels in Beeper: "Helped me wean off reels" (uninstalled Instagram "while still messaging and viewing shared reels"); "One app to rule them all" ("gets Instagram reels and messages in one place"); "Saved me from Doomscrolling" (sending posts works well). Year of the reviews not shown on the page (Jun/Aug). https://apps.apple.com/us/app/beeper/id6499013100?see-all=reviews&platform=iphone
- Stories: iOS 4.1.6 (2025-12-17) "Fixed Instagram stories not rendering for on-device Instagram connections." Desktop v4.2.455 (2026-01-10): on-device Instagram now "ensure[s] that a link is included when you receive a story shared with you".
- Bridge side (mautrix-meta, which Beeper's open-source bridges derive from; Beeper's own fork may differ): story/reel/clip shares are bridged incoming; `external_url` carries the Instagram link; if the full video download fails the URL is put in the caption (v0.3.0); reel captions were **removed on purpose** (v0.5.0 "never include caption"); fetching XMA media (reels etc.) can be disabled (v0.3.1); and **v26.09 (2026-09-16) added "downloading reels after bridging with the unresolved media provisioning API"** i.e. the bridge posts the reel and the client asks it to resolve the video later. https://raw.githubusercontent.com/mautrix/meta/main/CHANGELOG.md and https://github.com/mautrix/meta/releases

**Reconstructed interaction** `[I]` (not directly observed): chat shows a reel as a video-style bubble with thumbnail and play affordance; tapping triggers download then plays in the standard fullscreen media viewer; the bubble does not show the author handle or caption (caption bridging was turned off; handle is likely only in the `external_url`). Autoplay inline is **not** documented and the "on-demand" change argues against eager loading. What the user said ("downloaded video in the chat, like a video message, playable without opening Instagram") matches the *behaviour class*, but as of Aug 2026 Beeper download is lazy, not eager.

**Unknown, please verify on device** `[?]`: iOS inline vs fullscreen playback; whether author/caption is shown; whether the reel thumbnail has a "reel" glyph; audio default; whether tapping the thumbnail ever deep-links to Instagram; behaviour for shared *posts* (carousels) vs reels; unavailable/expired reels.

**History of instability** `[unverified, secondhand]`: a Jan 2024 r/beeper post (seen through a mirror, not independently fetched) said Beeper had once let users view and download reels, then removed it twice, speculating about storage. Consistent with the 2026 lazy-load move.

Media-viewer/Media-Browser details from iOS changelogs `[C]`:
- Fullscreen viewer with pinch-to-zoom (4.3.0 fix; 4.2.10 improved transitions), shared-media actions common to chat and Media Browser (4.2.7), Copy Link for links in Media Browser (4.2.7).
- **Chat Info media browser** for media, files, links and audio (4.2.4), searchable files by filename (4.2.8).
- **Consecutive photos/videos grouped into a gallery** (4.3.10, Oct 2026).
- Shimmer placeholders for loading image/video cells (4.1.7). Setting: max video size to auto-download (Preferences > Media).
- Send: image quality options and video compression/quality options (4.2.0, 4.2.9); Live Activity progress for uploads (4.2.0); **captions can be added/edited/removed on sent attachments "where supported"** (4.3.11). Inbox previews have "clearer media labels" (4.3.6).
- Fullscreen video had a muted-icon bug (4.0.0); video kept playing after minimizing (fixed 4.2.0); Lock Screen/Control Center transport controls for audio and video messages (4.1.15).

### 2.3 Voice messages

`[C]` Playback speed adjustment (4.0.6), seek to any position (4.0.5), **consecutive voice notes auto-play** (4.2.9), Lock Screen/Control Center controls (4.1.15), playback stops on send (4.1.17), transcription (Plus; per-message language selection, forwarded voice notes transcribable). Instagram-specific fixes: wrong duration (4.1.6), send failures/retry stuck on "Retrying" with no way to retry (Android 4.53.2), Desktop "Instagram: Can send voice notes again" (v4.0.494). Takeaway: IG voice notes were a recurring bug class.

---

## 3. Chat screen UX

Beeper does not publish a design walkthrough; what follows is assembled from iOS changelogs (all `[C]` unless marked) and shows the *feature surface*, not pixel details.

- **Bubbles / titles.** Refreshed conversation title bar, inbox header, chat bubbles and reaction pills in iOS 4.2.0 (June 2026), plus date separators and scroll controls "on newer iOS versions"; the reactions list uses the Liquid Glass effect (4.1.7). Message sender titles carry colour (4.2.8: "message sender title colours refined for readability on dark backgrounds"), presumably per-sender in groups `[I]`. Edited label ("Edited") shown in DMs and search (4.3.9 refined; 4.3.10 alignment fix).
- **Reactions.** Long-press message menu (with a reply icon, updated 4.2.4) and **configurable double-tap** (react / forward / reply; Settings > Preferences > Double-tap message, 4.1.3). New emoji picker with long-press skin tones (4.0.5), custom emoji reactions (4.3.11 fix), reactions list sheet, **retry a failed reaction** instead of silent failure (4.1.10), setting to **turn off reaction notifications** (4.2.8), reaction notifications deep-link to the right message.
- **Replies.** Swipe-to-reply with refined animation (4.2.1); reply threads with a "reply thread toolbar" and clearer close button (4.2.7); reply lines in conversation view (a "jumping reply lines" bug fixed 4.0.24).
- **Read state.** "Mark as unread from here" on long-press (4.3.6); tapping to **view timestamps of when other members read a message** (4.1.17); read receipts occasionally out of order (4.1.12 fix); merged chats show one best-effort receipt. **Incognito Mode** (Plus) suppresses read receipts, global toggle per device, with a separate "Show recipients I'm typing" toggle (https://help.beeper.com/en_US/beeper-plus/incognito-mode-getting-started-guide); not confirmed for Instagram.
- **Typing indicators.** Supported on Instagram on-device both directions. Copy variants handled for singular/plural (4.2.4).
- **Timestamps.** Date separators (4.2.0), long-press for read timestamps; disappearing-message timers rendered in reply bubbles (4.1.5); send-later and reminder indicators in chat (4.3.8).
- **Link previews.** Beeper generates link previews on outbound messages (4.0.5); "shared links sometimes losing their URL" fixed (4.3.9). Instagram link previews are bridged from Meta in the bridge (v0.2.0).
- **Composer.** Attachment sheet and media picker (hardware keyboard handling in 4.2.1), drag-and-drop into composer, GIF search (updated 4.2.1), compact emoji picker, voice-note controls, @mentions, markdown rendering incl. interactive lists, remembers keyboard language per chat (4.2.7), draft sync (4.3.10), Send Later and Reminders (Plus), Siri Shortcuts for read/mute/archive/schedule (4.2.0), share extension for sharing into a chat, **bookmark a message** (4.3.9), forward (long-press > Forward), polls (Matrix/Signal/WhatsApp only), nicknames/custom chat names and photos synced across Beeper apps (4.3.5).
- **Message states.** "Message bubbles sometimes appearing without content" (4.2.8 fix), "messages stuck sending or immediately failing after returning to the app" (4.3.6 fix), "Report a Problem" on a long-pressed message for send failures (Instagram guide).

---

## 4. Account connection and onboarding (Instagram)

**Beeper account first.** Email + 6-digit code (Sign in with Apple/Google added 2026-10-01), save the **Recovery Code** (stored by you, not Beeper), choose a username. An unskippable "Connect" screen follows; networks can be removed later. https://help.beeper.com/en_US/ios/beeper-mobile-getting-started-guide

**Connecting Instagram on iOS.** Settings > Accounts > Add an Account > Instagram > Connect > Continue > log in (a login window opens; on success it returns to Beeper). https://help.beeper.com/en_US/chat-networks/instagram
- Mechanism is **not documented**. Evidence: iOS 4.2.0 fixed "account connection failures caused by an outdated browser warning" and 4.2.4 fixed "web logins becoming unresponsive", so `[I]` it is an in-app web login (WKWebView or similar). Beeper's bridge uses Instagram web-client requests authenticated by `sessionid`/`ds_user_id` cookies (https://www.beeper.com/engineering/2025/11/24/reverse-engineering-instagram-video-uploads), and the mautrix docs list cookies `sessionid`, `csrftoken`, `mid`, `ig_did`, `ds_user_id` (https://docs.mau.fi/bridges/go/meta/authentication.html). A password login mode ("android") exists in the bridge as of v26.09 (needs bridge v26.10+).
- **Pain points Beeper tells users about:** Meta sees "a new device" (Beeper presents as a Pixel 6 Android phone or a Linux computer, possibly in a different city). **Authenticator-app 2FA is required; SMS and WhatsApp codes are not supported.** Users must approve the login via Instagram email/app prompt, then retry. Non-US phone logins unsupported.
- **Helpers shipped in 2026:** shareable account-setup links/QR codes between devices (iOS 4.1.12, 4.3.9 "improved QR link sharing", 4.3.11 fix when a shared QR code failed to refresh), "clearer verification steps and a more streamlined setup flow" (4.2.7), picture-in-picture instruction videos (4.0.4/4.0.22), Desktop "Import Logins" from browser or other apps (v4.3.104, 2026-09-09), onboarding prompt to connect more accounts if you have 1 or fewer (Desktop 4.0.565). Onboarding stuck states fixed repeatedly: "account connection onboarding sometimes getting stuck during slow provisioning" (4.3.0), "account setup stuck after a shared QR code failed to refresh" (4.3.11).

**Error vocabulary (from the Instagram guide)** `[C]`: "Internal error in login step" (check instagram.com for checkpoints, enable authenticator 2FA), "The login information you entered is incorrect", "Your email is not secure", "M_NOT_FOUND (HTTP 404)" (removed and re-added too quickly, wait minutes), "We suspect automated behavior" (a checkpoint, not a ban; verify Beeper in Instagram login activity), "Disconnected from server, trying to reconnect" (usually transient). Instagram sometimes resets sessions, so re-authenticate under Settings > Accounts.

**How disconnection is surfaced on iOS** (https://help.beeper.com/en_US/ios/chat-network-disconnection) `[C]`:
- **Red X over the network's icon** + **red banner** with a **Reconnect** action. Alternative path: Settings > Accounts > Reconnect > pick the account.
- Cause examples: password change, expired token. "Connecting" for a long time: check connectivity, a bridge may be having issues. No push notification for disconnect is documented.
- iOS 4.0.22 "Improved UX for disconnect account banners"; Desktop 4.0.13 fixed disconnected banners flashing briefly at launch for on-device connections.
- Dev API exposes the state machine: `connected`, `connecting`, `backfilling`, `connection_required`, `reconnect_required`, `attention_required`, `disconnected`, `disabled`, plus `statusText`. Good template for our own account states.

**Removing an account deletes its chats and messages**; logging out of a device deletes its on-device connections. Beeper "is not a backup".

---

## 5. Architecture as it affects Instagram in 2026 (UX-relevant only)

- **Lineage.** Beeper = Matrix + open-source mautrix bridges. Automattic acquired Beeper in April 2024 (reported ~$125M) and Texts.com in 2023; the two products were merged into the new Beeper on 2025-07-16, with a native iOS app built "from scratch" (iOS 4.0.0 shipped 2025-03-18). https://blog.beeper.com/2025/07/16/the-new-beeper/, https://techcrunch.com/2025/07/16/beepers-all-in-one-messaging-app-relaunches-with-an-on-device-model-and-premium-upgrades/
- **On-device is the default for Instagram.** Instagram is available both ways, but multiple accounts and read receipts require **on-device**. Messages do not touch Beeper servers; the session lives on the phone; chat *state* syncs. Beeper says Cloud is being "gradually deprecated" (no sunset date found). https://help.beeper.com/en_US/troubleshooting/beeper-on-device-vs-beeper-cloud-what-goes-to-beeper-servers
- **UX consequences:** (a) per-device account lists (an iPhone-connected IG account is not on Desktop), (b) "Default Chat" and some settings per device, (c) heavier setup per device, (d) notification reliability depends on the iOS Notification Service Extension: Beeper's backend relays the network's own push payload and the NSE decrypts; NSE memory limit (15 MB, raised to 50 MB in iOS beta after a DMA request, 150 MB on Apple Intelligence devices) caused blank notifications. https://blog.beeper.com/2025/10/01/how-beeper-ios-implements-notifications/ The post does not mention Instagram. `[?]` how IG push specifically arrives.
- **Instagram's protocol changed in mid-2026.** The mautrix maintainer split Instagram into a new bridge binary (`mautrix-instagram`, v26.07, 2026-07-16) because Instagram "moved its DMs to a completely new protocol"; Instagram support was removed from mautrix-meta in v26.08 (2026-08-16); reel downloading and password login landed in v26.09 (2026-09-16). https://mau.fi/blog/2026-07-mautrix-release/ Beeper's own changelog shows IG churn consistent with this: "Fixed On-Device Instagram not connecting" (Desktop v4.2.892, 2026-06-02), Android release notes mentioning Instagram connection-stability fixes (Mar 28, 2026, per a search snippet I did not open directly), "messages from an On-Device Instagram account could fail to send after returning to Beeper" (Android 4.53.2, Aug 16). `[I]` Expect further breakage; connection-state UX is not optional.
- **Account-risk framing.** Beeper's help frames Meta checkpoints as normal; HN users report monthly sign-outs, and r/beeper's biggest flair (Help/Troubleshooting, 49 posts) includes "I didn't know bans were possible!" (https://gummysearch.com/r/beeper/). On-device is described by users as lower ban risk than cloud. No Beeper statement quantifying ban risk was found.

---

## 6. What users love and complain about (ranked)

Evidence base is small and skewed to Instagram-as-a-use-case: 10 App Store reviews, ~25 HN comments, Beeper's own changelogs, a few blogs. Rank = how often the theme appears and how directly it affects us.

### Love (ranked)

1. **"Instagram DMs without the Instagram app/feed."** Most repeated praise. App Store: "Beeper lets me keep my DMs even without the instagram app"; "Helped me wean off reels"; "Screen time and mental health have improved drastically." HN (2025-26): Imustaskforhelp, bandedetrappes, e12e, antoferra, iLoveOncall, vincvinc. One user still keeps Instagram installed "because friends send Reels" (halapro, 2026-04), which is exactly what must-have #2 fixes. https://news.ycombinator.com/item?id=45107364 and Algolia comment search
2. **Clean, fast, native, consistent UI** ("clean interface", XDA: "consistent across every platform"; rebuilt natively; ~weekly releases).
3. **Unification and triage tools:** one inbox, archive/low-priority/pins, labels, merged chats, reminders, send later; Tirabassi (Jan 2026) cut a daily sweep from ~20-25 to under 7 minutes and credits platform logos for at-a-glance source identification. https://tirabassi.com/beeper-after-one-year-the-evolution-continues/
4. **Responsive team and support** (developer replies on App Store reviews asking for bug reports; HN: KishanBagaria "We'll improve this!").
5. **Privacy posture** of on-device connections (HN).

### Complain (ranked)

1. **Instagram reliability:** missing messages and inconsistent push (varun_ch, HN 2026-02-17: "extremely inconsistent with push notifications and sometimes has messages missing"); App Store: "doesn't send me notifications when I receive a message from instagram" (Jun), "it works, sometimes doesn't". Changelog confirms churn (see Section 5).
2. **Ban / checkpoint anxiety and security prompts:** "I didn't know bans were possible!" (r/beeper), monthly IG re-auth (ChaseT 2023), "always two lawsuits away" (nunez, 2026-04), ToS caution (psittacus, 2025).
3. **Paywall / account limits:** two accounts of one network require Plus ($9.99/mo or $99.99/yr); labels limited on free; App Store review "Fix the core app first, then ask for money"; Google Play reviewer upset labels became paid; AlternativeTo reviewer calls ~$10/mo "too high".
4. **Instagram feature gaps:** no message-request import, no history before setup, no view-once, no posting, small size limit, no calls, no non-US phone login, **no Primary/General handling**.
5. **Onboarding/account-setup bugs** (stuck setup, blank Add Account, false limit, QR refresh), and multi-account mistakes (new chat created through wrong account).
6. **Data/account lifecycle surprises:** HN (kldx, 2026-01-29) says Beeper may delete inactive bridged accounts without notice; Google Play reviewers hit recovery-code lockouts. Free-tier history cap of 90 days is claimed in one blog (Tirabassi); not verified.
7. **Sync inconsistency across devices** because on-device chats don't sync, and per-device "Default Chat" for merged chats.
8. Minor: no per-network notification customization on iOS (FAQ), no block, no spam filter, view reels spam in DMs (Reddit, unverified).

Trustpilot (3.6/5 from 19, unclaimed, 48% one-star) is too thin to rank anything. App Store: 4.7/5 from ~1.1K ratings (2026-10).

---

## 7. Steal this / avoid this

### Steal (UX patterns worth copying)

1. **Thumbnail-first, fetch-on-tap for reels** with a clear progress/ready state, then standard fullscreen player. Cache after first play; evict old; keep an "auto-download up to N MB" preference. Beeper learned eager download "piles up" videos. (Add: show author handle + caption chip, which Beeper's bridge intentionally drops; we need `external_url` and caption from our own bridge/fork.)
2. **Composer avatar as the "sending as" control**, with swipe up/down to cycle accounts. For two IG accounts, lock to the thread's owning account by default; make override explicit.
3. **Inbox definition**: Inbox = unread + active + drafts; Archive auto-returns on new activity; Low Priority = archive + mute; pinned avatar-bubble row; swipe actions configurable. Cheap, learned, and users understand it.
4. **Per-account "Show in Inbox: None / DMs only / All"** and **per-account mute that also excludes its unread from the app badge**.
5. **Per-account spaces/filters** with Archived / Requests / Low Priority sub-filters, and per-category unread badges.
6. **Requests as a first-class space** with Accept / Delete and "who sent it" fallback when the chat has no name, plus a quiet badge/notification for requests that arrive while closed.
7. **Connection status as a state machine** (connected / connecting / backfilling / reconnect_required / attention_required / disabled) rendered as red X on the account icon + banner with one-tap Reconnect, plus Settings > Accounts entry. Add the helpful part Beeper lacks in docs: tell the user *why* (checkpoint vs password change vs rate limit).
8. **Onboarding helpers**: pre-flight checklist (enable authenticator 2FA first, approve "was this you" prompts), clear verification steps, cross-device setup via QR/link, "Import Logins" idea (we can offer an "I'm already logged in" path through a webview cookie capture, since Instagram login must be done by the user).
9. **Fine-grained chat polish worth matching:** configurable double-tap, "mark unread from here", reaction retry on failure, reaction-notification off switch, grouped consecutive photos/videos as a gallery, caption editing, Lock Screen audio/video controls, autoplay of consecutive voice notes with speed control.
10. **Incognito / read-receipt control** as a global, clearly indicated toggle (Beeper keeps it per device and Plus-gated, which is a weakness to fix).
11. **Local nicknames and custom chat photos** (Beeper nicknames, 4.3.5): useful when handles are cryptic across accounts.

### Avoid (Beeper pitfalls)

1. **Silent "wrong account" sends.** Beeper shipped fixes for new chats created through the wrong account and for duplicate account entries. Always show a persistent sender chip; never infer an account from "last used".
2. **No visual account identity in the inbox.** Not documented in Beeper; we should give each IG account a stable colour + avatar + handle shown on rows, filters, composer and notifications.
3. **Paywalling the core job.** The second account is our must-have; don't tier it.
4. **Ignoring Requests and Primary/General.** Beeper punts ("accept it in Instagram"). Treat IG's three folders (Primary, General, Requests) as first-class, per account, with the right defaults for business vs personal and private vs public accounts.
5. **Per-device accounts and per-device "Default Chat".** Cause confusion; keep account state server-side so inbox/state is the same everywhere (inherent advantage of a Matrix homeserver design; `[I]` this also gives reliable APNs push, whereas Beeper's on-device IG path suffers inconsistent notifications).
6. **Hard-to-diagnose Instagram failures.** Surface checkpoint vs session expiry vs server-side API change distinctly (Instagram changed its DM protocol mid-2026; breakage is a when, not an if).
7. **Eager media download** (storage bloat; Beeper reversed it in Aug 2026).
8. **Removing an account silently deletes its history and logout deletes on-device connections.** Confirm destructive actions clearly; offer "disable" vs "remove".
9. **Dropping reel context.** Beeper's bridge removed reel captions; users lose the point of the share. Keep author, caption, and "open in Instagram" link.
10. **Unclear free-tier limits and false limit blocks**, **inactive-account deletion without notice**, **setup screens that dead-end** (blank Add Account, stuck provisioning).

---

## 8. Mapping to the brief's must-haves

| Must-have | What Beeper gives us | Gap to design |
|---|---|---|
| 2+ IG accounts in one inbox, reply from the right account | Yes (paid, on-device); composer-avatar switching; per-account spaces | Visual account identity, sender lock per thread, unified badge rules |
| Reels as a playable video in chat | Thumbnail + on-demand video; plays in-app | Author/caption/open-in-IG, autoplay policy, cache policy; verify iOS behaviour |
| Primary / General / Requests; account-type differences | Requests space exists generically; IG requests not imported; Primary/General absent | Entire IA for IG folders per account type; empty-state education |
| Nice UX | Strong polish and cadence; weak on docs/visual disambiguation | Dedicated design pass (our designer agent) |

---

## 9. Open questions to verify hands-on (15 minutes on a phone with Beeper)

If the user has Beeper (free tier is enough for one IG account), capture screen recordings of:
1. Receive a shared **reel**: what does the bubble look like before and after tap? Inline autoplay? Author/caption? Mute state? Does a **post (carousel)** differ? What happens with an expired/private source?
2. **Story reply / story share** rendering.
3. Inbox row for an Instagram chat: network glyph, source badge, "detailed" appearance mode, unread styling.
4. With two IG accounts (needs Plus trial; Beeper offers free trials of Plus features): row/space/composer disambiguation, **swipe-to-switch** discoverability, new-chat account chooser.
5. A **message request** from a stranger: does it ever appear? Does a business/creator account's General folder show up?
6. Disconnected state: revoke the session from Instagram's login activity and capture the banner and re-login flow.
7. Notification latency for an IG DM with the app force-quit.

---

## 10. Sources

Beeper primary
- Instagram guide: https://help.beeper.com/en_US/chat-networks/instagram (also https://help.beeper.com/chat-networks/instagram, mirror https://beeper.helpjuice.com/chat-networks/instagram)
- Inbox tips: https://help.beeper.com/inbox-tips-and-tricks-all-apps-guide
- iOS Managing Your Inbox: https://beeper.helpjuice.com/en_US/ios/beeper-ios-managing-your-inbox ; iOS App Settings: https://beeper.helpjuice.com/en_US/ios/beeper-ios-app-settings ; Start a New Chat: https://help.beeper.com/en_US/ios/beeper-ios-start-a-new-chat ; Getting started: https://help.beeper.com/en_US/ios/beeper-mobile-getting-started-guide ; Disconnection: https://help.beeper.com/en_US/ios/chat-network-disconnection
- Account limits: https://help.beeper.com/en_US/beeper-plus/account-limits-everything-you-need-to-know ; multi-account FAQ: https://help.beeper.com/can-i-add-more-than-1-account-for-my-chat-network
- On-device vs Cloud: https://help.beeper.com/en_US/troubleshooting/beeper-on-device-vs-beeper-cloud-what-goes-to-beeper-servers ; https://help.beeper.com/using-on-device-chat-network-connections-in-beeper
- Merge chats: https://help.beeper.com/en_US/beeper-plus/merge-chats-getting-started-guide ; Incognito: https://help.beeper.com/en_US/beeper-plus/incognito-mode-getting-started-guide ; Labels: https://help.beeper.com/en_US/quick-references/how-to-create-and-manage-labels ; Badges: https://help.beeper.com/en_US/desktop/how-does-the-badge-count-works ; FAQs: https://help.beeper.com/en_US/quick-references/top-beeper-faqs ; Notifications: https://help.beeper.com/en_US/quick-references/notifications-beeper-recommendations-after-setup
- Changelogs: iOS https://www.beeper.com/changelog/ios/ (pages 2-7; entries e.g. /ios/4.3.0-21714, /ios/4.3.4-23405, /ios/4.3.5-23679, /ios/4.3.6-24204, /ios/4.2.9-20397, /ios/4.2.8-20309, /ios/4.2.7-19296, /ios/4.2.4-18374, /ios/4.2.0-16859, /ios/4.2.1, /ios/4.3.1-22486); Android https://www.beeper.com/changelog/android ; Desktop https://www.beeper.com/changelog/desktop (pages 1-9; /desktop/4.3.57, /desktop/4.2.692, /desktop/4.3.104); aggregated https://releasebot.io/updates/beeper
- Blog/engineering: https://blog.beeper.com/2025/07/16/the-new-beeper/ ; https://blog.beeper.com/2025/10/01/how-beeper-ios-implements-notifications/ ; https://blog.beeper.com/2025/02/24/try-out-the-new-beeper-desktop-and-ios-beta/ ; https://www.beeper.com/engineering/2025/11/24/reverse-engineering-instagram-video-uploads
- Dev API (account object, statuses): https://developers.beeper.com/desktop-api-reference/resources/accounts
- Store: https://apps.apple.com/us/app/beeper-universal-chat/id6499013100 ; reviews https://apps.apple.com/us/app/beeper/id6499013100?see-all=reviews&platform=iphone

Bridge / Matrix side
- mautrix-meta changelog: https://raw.githubusercontent.com/mautrix/meta/main/CHANGELOG.md ; releases https://github.com/mautrix/meta/releases ; roadmap https://raw.githubusercontent.com/mautrix/meta/main/ROADMAP.md ; auth https://docs.mau.fi/bridges/go/meta/authentication.html ; July 2026 release post https://mau.fi/blog/2026-07-mautrix-release/

Third-party
- TechCrunch relaunch: https://techcrunch.com/2025/07/16/beepers-all-in-one-messaging-app-relaunches-with-an-on-device-model-and-premium-upgrades/
- 9to5Google merge chats: https://9to5google.com/2026/08/11/beeper-merge-chats-update/
- Tirabassi one-year review: https://tirabassi.com/beeper-after-one-year-the-evolution-continues/
- XDA hands-on (May 2024, dated): https://www.xda-developers.com/beeper-hands-on/
- HN: Amber Show HN https://news.ycombinator.com/item?id=45107364 ; Tell HN inactive accounts https://news.ycombinator.com/item?id=46813330 ; comment search via https://hn.algolia.com/api/v1/search?query=beeper%20instagram&tags=comment
- r/beeper topic stats: https://gummysearch.com/r/beeper/ ; Trustpilot https://www.trustpilot.com/review/beeper.com ; AlternativeTo https://alternativeto.net/software/beeper/about/ ; Product Hunt-style listing https://hunted.space/product/beeper-2/launches/beeper-4
