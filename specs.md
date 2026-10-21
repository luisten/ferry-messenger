# Ferry Messenger: as-built behaviour

What the app does today, screen by screen: Ferry's v1.1 (inbox v2, design v3) on `core/`, with no server
([docs/PLAN-core.md](docs/PLAN-core.md); its "Done" blocks hold the live checks with the two dummies). Screen IDs are
DESIGN.md's. Why it differs from the design: PLAN §7 and [m7-design-diff.md](docs/verification/m7-design-diff.md).

## Rules that hold everywhere

| Rule | Detail |
|---|---|
| Color means account | Chrome is monochrome. Each Instagram account has a name, one of 8 colors and a one-character mark, shown on rows, chips, bubbles, tags and the composer. Unique per account; stored on the device (`UserDefaults`). |
| A chat belongs to one account | `split_portals`: one Instagram thread seen by two of your accounts is two chats. The composer says "Message as X"; there is no account choice when sending. |
| Which threads are chats | Every thread in each account's Instagram inbox (Primary, General, Requests), loaded page by page at launch. |
| Requests send nothing | Opening a request sends no "Seen" and no typing. Only Accept, Delete or a reply send. |
| Instagram credentials never touch the app | Login happens on instagram.com in a throwaway web view; the app keeps only the session's cookies, in the Keychain (one item per account). |
| Live only while open | Each account's socket runs while the app is active; on return Instagram's client catches up. No push (D6). No local store beyond Keychain + `UserDefaults` (D8): every launch reloads the inboxes from Instagram. |
| Media on tap | Thumbnails load as rows appear; full media downloads only when tapped, to `Caches/media`, and plays from that file. The folder stays under 500 MB: past that, the least recently opened files go first, down to 400 MB. |
| Order and unread | Newest **message** first (not newest event). A chat is unread while its newest message is incoming and newer than our "Seen", or it's marked unread on Instagram. Requests, archived and General chats don't count toward the main list's or chips' unread. |
| Primary/General | Business and creator accounts (`is_professional_account`) have Instagram's two tabs: their main list is **Primary**, and chats in **General** on Instagram sit in General (Folders menu), from the start and as Instagram reports moves. Moving chats is done in Instagram. |
| Read receipts | Opening an unread chat (and each new incoming message while it's open and the app is active) sends "Seen" on the newest incoming message, and the chat reads as read at once. A re-read of the thread that Instagram answered before that "Seen" arrived can't make it unread again (only "marked unread" can). Typing is sent at most once per 20 s. |

## Onboarding (O1–O6)

Shown when no Instagram account is stored.

| Screen | Behaviour |
|---|---|
| O1 Welcome | "The crossing" (D19). Wordmark "Ferry" (SF Pro Rounded Bold 48, grows with Dynamic Type up to 62), the headline on two lines, then a picture: the icon's white ferry on a calm sea (a haze, a sea band with a wavy lower edge, two swell lines, a wake) carrying two bubbles with marks: your first two accounts in your order, in their colours; with one account, a sample that shares neither its colour nor its mark rides behind it; before any account, Ocean "A" and Ember "S". The ferry glides in, the bubbles board, then it bobs and rolls while the swell drifts (≤ 30 fps). Still (drawn at rest, no entrance) under Reduce Motion or Low Power Mode; paused while the app isn't active or a later step covers it. Increase Contrast: no haze, full-strength swell. Then the three promises in a centred column, "Connect Instagram account" and "Not affiliated with Instagram or Meta." on the plain background; the sea's colours appear nowhere else in the app. At accessibility text sizes the picture shrinks to 70% and the legal line moves to the end of the scroll. VoiceOver: one header ("Ferry. All your Instagram DMs. None of the feed."), the picture as one image ("A ferry carrying messages across calm water."), the promises, the button. |
| O3 Connect | instagram.com in a non-persistent web view (see Accounts). |
| O4 Connecting | The account's avatar on a grey deck (the icon's hull over a wave); avatar and deck bob while the first sync runs, with O1's motion rules. Logged in ✓ → connected as @handle ✓ → syncing (indeterminate, counts chats as they arrive); checkmarks and the failure glyph in the status colours. Continue unlocks at step 2. Errors: "Couldn't finish connecting", Try Again, Copy details. |
| O5 Name this account | Inline title with a ✓ (Save) in the bar; name, 8 swatches (2×4), mark; live preview; taken colors show their owner's mark and can't be picked, a taken name or mark says so. "Add another account" is the last row. All swatches and the Mark field fit on the first screen. Defaults: Instagram name, next free color, first free letter. |
| O6 Add another? | After the first account only: your account's avatar and a dashed "+" seat side by side (never overlapping, design v3) on one deck, "Connect another account" or "Not now". |

With an account stored, the app opens on the inbox.

## App icon and launch screen

| What | Behaviour |
|---|---|
| App icon | "Two aboard", Deep water (D19): a white ferry carrying two bubbles over a wave, on a petrol-blue sea gradient. Dark: the ferry and wave in sea blue under white and foam bubbles, on iOS's backdrop. Tinted: greys iOS tints. Rendered from `docs/design/ferry-icon-color*.svg` by `scripts/make_icon.swift`. |
| Launch screen | Static (`UILaunchScreen`): the mark centred at 120 pt on sea blue `#12536D` with a white status bar; black with the dark icon's mark in dark mode. iOS cross-fades it into the first screen (cold launches only). |

## Inbox (I1), search (I5)

- **Toolbar:** account stack (design v3) opens Accounts: your accounts' avatars **side by side**, 30 pt each (24 pt photo
  inside the ring), 4 pt apart, in one 44 pt glass capsule of its own (the toolbar's shared glass is hidden), 44, 78 or
  112 pt wide. Up to three accounts show; from four on, the first two in Accounts order and a grey "+N" disc. A 14 pt
  badge sits on the avatar of the account it's about: a warning triangle (signed out or erroring) or a spinner
  (connecting, syncing, reconnecting); a hidden account's goes on "+N", where needs-you wins. VoiceOver: one button,
  "Accounts: Alex, Alex Studio, and 2 more. Alex Studio needs attention." (connecting accounts: "… is connecting.").
  Inline title "Chats", or in an account scope the account name over "@handle" ("@handle · Primary" for a professional
  account; just "Primary" with three or more accounts, where the stack leaves the title about 120 pt); **Folders** menu
  top right. Bottom bar: search field and New Message.
- **Scope bar** (2+ accounts, pinned under the title, rows scroll under it): All plus one chip per account in your
  order, with unread count, or a glyph for needs-attention / connecting. Remembered per scene. An account scope tints
  the screen with its color; a removed account's scope falls back to All.
- **Folders menu:** General (only in a scope with a professional account, or with any General chat; "N unread"),
  Requests ("N waiting") and Archived; subtitles only when non-zero. Each pushes that folder for the current scope.
  Badge (label color, hidden at 0): new requests in scope plus unread General chats in scope.
- **Requests card** (first row): while the scope has requests newer than the last time Requests was opened in All or
  in their account (a local time per scope in `UserDefaults`; nothing is sent; a new message in a request counts).
  "N message requests" and the requesters' names (with account marks in All), no message text; opens Requests, never
  a thread. VoiceOver: "2 message requests, from Lena Ortiz and crypto.wins.daily. Opens Requests." General never gets
  a card.
- **Rows:** avatar (with the account mark in All; a group without a photo shows two of its people, one over the other
  with a ring cut out between them, those with a picture first; with fewer than two others the people glyph on a light
  grey disc, never its name's initial), name, time ("9:41", "Yesterday", weekday, date), two-line preview
  ("You: …", "You sent a reel by @author", media symbols; a story reply or reaction shows what was sent after the
  story's symbol; in groups the sender's first name, "Theo: …", or no name
  when the thread doesn't name them, never an ID), "typing…", unread dot. Swipe or
  long-press: Archive.
- **Banner** (one at a time, most fundamental first): "Can't reach Instagram" (2 failed connects in a row with no
  account connected), one account signed out ("Log in" → A3) or erroring, a reconnect lasting over 2 min, "N
  accounts need attention" ("Open" → Accounts). Layout: the account's avatar, then the title and body at full width,
  then the button and "Later" in a row under them (small). "Later" hides an account banner until the next launch.
  Warning haptic when an account drops while the app is open.
- **States:** redacted placeholder rows until the first inbox loads; "Can't reach Instagram" + Try Again if it never comes;
  empty per scope ("All caught up" when everything is archived or in General, with "Open Folders, top right").
- **I5 search:** filters by chat name in the current scope, ignoring case and accents; finds archived chats, not
  requests. Nothing is sent to Instagram.

## Requests (I2), General (I3), Archived (I4)

- **I2:** opening it (and leaving it) marks its requests as seen for the card and badge. In All with 2+ accounts, one
  section per account. Rows have Delete and Accept. A dismissible explainer (once).
  - **Accept:** the chat moves to Chats at once with "Accepted. This chat is now in X."; it goes back to Requests if
    Instagram refuses (alert).
  - **Delete:** confirmation ("It's deleted from @handle's Instagram inbox too. They may see it as read."); the chat
    hides at once and goes when Instagram has deleted it (this account only). No "Seen" is sent first; whether
    Instagram shows one is untested.
- **I3:** General chats in scope (marks in All), newest first; swipe or long-press Archive. Empty: "Nothing in
  General". No "Move to Primary": moving chats is done in Instagram.
- **I4:** archived chats in scope; swipe or long-press Unarchive. Archive is on this iPhone only (`UserDefaults`;
  Instagram isn't told, and a reinstall forgets it); a new message brings the chat back by itself.

## New message (N1)

From chips first (preselected in an account scope; in All, search stays off until one is picked). The To field
searches Instagram as that account: 300 ms after typing stops, 2+ characters (each search is an Instagram request).
A result you already have a DM with shows "Open chat" and opens it without asking Instagram; for anyone else the app
asks Instagram whether a DM exists (and opens it), else opens a new chat with the composer focused. That chat exists
only on this iPhone until the first message, which makes the thread on Instagram; then it's an ordinary chat. One
recipient, no groups.

## Thread (T1)

- **Header:** one 44 pt glass capsule (its own glass; the toolbar's shared one is hidden): avatar (28 pt), name over a
  small AccountTag (account name only; at large text the mark and first word, then the mark); tap → Chat Info. The
  thread's scroll edge under the toolbar is **hard**, so photos and our coloured bubbles don't show through behind it
  (design v3: the tag was unreadable over media). ⋯ menu: Chat Info, Open in Instagram (when the contact's handle is
  known), Archive/Unarchive.
- **Timeline:** bubbles in the account color (ours) or grey (theirs), grouped runs, time labels, reply quotes (fetched
  if outside the window), reactions (one per person), "Edited", "You unsent a message" tombstones, typing bubble. **Chat
  events** are a line across the thread (`.footnote`, grey, centred; no bubble, menu or status): Instagram's own ("Sam
  named the group Weekend", "… left the group", calls), and anything the app can't show, "Sam sent a message Ferry can't
  show. Open Instagram to see it." ("a poll" when Instagram's content type says so). In the inbox the event as it is, or
  "Sam sent a poll". Status line under our last message: Sending… / Sent / Seen (Instagram has no "delivered"); failed:
  "Not sent. Tap to retry". Reactions are a capsule on the bubble's bottom edge (emoji, and a count when more than one);
  a tap lists who reacted with what (face, name or "You", emoji). A chat that opens unread shows a **"New messages"**
  line (hairlines, `.caption` semibold grey; a VoiceOver heading) above the first message from someone else after our
  "Seen" and after our own last message; it starts a new run, stays while the chat is open and goes once we reply. Older
  history loads at the top; at the very start a **start block**: the chat's avatar (64 pt), its name (`.title3`
  semibold), "@handle" in a DM (when known) or "N members" in a group, the AccountTag, 22 pt above and 20 pt below;
  "You're messaging from X." only while the chat has no messages (otherwise the composer says it). Opens on the newest
  message (also the first open after launch) and stays on it as rows, the keyboard or the typing bubble change its size,
  until you scroll up. When what's new overflows the screen by more than a quarter of it, it opens with the "New
  messages" line near the top instead, under the last message you'd read, and holds it there the same way until you scroll, reply, attach or tap a quote; by
  less, it opens at the end (the line goes under the header), so the newest message is never cut off by the composer.
  A **jump-to-newest button** (44 pt glass circle, `chevron.down`, never the account's colour; "Jump to newest
  message") sits bottom-right above the composer and keyboard while the thread rests away from its end: held on the
  line, or after a scroll that stopped more than 60 pt up. It hides near the end; a tap goes there (animated, not
  under Reduce Motion), as does a send from this device (our own message sent from Instagram's app or website doesn't
  move the thread). Nothing scrolls when a message arrives while you're up the thread: the button counts what
  others have sent since it appeared (not chat events; a capsule with the number, monospaced, "99+" at most, no red
  badge; VoiceOver "3 new messages"); a chat that opens on the line starts with no count. The bubbles appear (a 0.15 s fade, none under Reduce
  Motion) only once the thread rests there under the bars with no older page loading, so the push never shows it
  jumping; at the latest after 1 s or on touch. Only a new last message animates; older pages land without animation.
- **Groups:** the sender's display name (`.caption`, grey: never an account
  colour) above the first bubble of each run of their messages, their avatar (28 pt, the initial without a picture)
  beside its last bubble, every incoming bubble indented for it (tombstones too, without either; chat events are
  neither: they span the thread and end a run). Our own messages
  get nothing, as in DMs. A reply that starts a run says "Sam Lee replied to Theo" instead of a separate name.
  A tap on someone's picture opens their card (sheet, medium): picture at 120 pt, name, @handle, Open in Instagram.
  Each reaction shows the faces of who chose it (16 pt, stacked, up to three, then "+N"; ours is our account's
  picture); VoiceOver: "👍 from Theo, Maya and you". Under the newest message (right-aligned, `.caption2` grey) "Seen
  by Maya", "Seen by Maya and Sam", "Seen by Maya, Sam + 2", or "Seen by everyone" once all of three or more have:
  everyone but us and its sender whose "Seen" is at or past it, first reader first; under our own newest message
  it replaces "Seen".
  VoiceOver reads every incoming group bubble as "From Theo Park, …" and skips the visible name and avatar. Names
  come from the thread (Instagram always names its participants). DMs look exactly as before.
- **Context menu:** reaction palette ❤️ 😂 😮 😢 🔥 👍 (same emoji again removes ours; double-tap = ❤️), Reply, Copy,
  Edit (own text, within 15 min, at most 5 edits), Share All ("3 photos": photos sent together; downloads them all,
  then the share sheet, whose "Save 3 Images" asks for Photos access once), Open in Instagram (shares), Unsend (own;
  confirmation, removed for everyone), Delete (a failed send that never reached Instagram).
- **Composer:** account avatar (tap: "This chat belongs to X. Replies always come from this account."), "Message as
  X", counter from 900 characters, Send off past 1000. Reply and edit modes show a bar with ✕. With the field empty
  the mic sits where Send is.
- **Photos and videos:** `+` opens the photo picker (one image or video). The item waits above the field ("Video ·
  0:12" with its thumbnail), then sends with an upload ring (tap cancels; a failure says "Not sent. Tap to retry.");
  text typed with it goes as its own message (Instagram drops captions). Photos go as a JPEG (≤ 2048 px, ≤ 8 MB, no
  metadata). Videos stay files: an mp4/mov within 25 MB (25,000,000 bytes, the bridge's limit, kept) is only
  remuxed to drop its location, anything else is re-encoded to H.264 MP4 at 1280×720, then 960×540, then 640×480
  until it fits; otherwise "This video is too long to send to Instagram. Trim it first." The `m.video` carries size,
  pixels, duration and a JPEG thumbnail (≤ 720 px) for our own card. Our sent file is filed in the media cache, so
  it opens without a download.
- **GIFs:** an animated GIF from Photos stays a GIF ("GIF" in the bar; written again frame by frame, no metadata,
  ≤ 8 MB), and Instagram makes it one of its own GIFs, so the other person sees a GIF. A message that is nothing but an
  `https` link to a `.gif` or `.webp` ("Copy image address") is fetched only when you tap Send ("Getting GIF…", ✕ puts
  the link back, ≤ 20 MB) and goes as that GIF; anything that doesn't load as an animated image goes as the link.
  Links to GIFs that others send stay links (the user's call: no fetching what someone else linked). No GIF search
  (no outside service).
- **Voice notes:** touch and hold the mic: after 0.3 s it records (AAC `.m4a`, mono, 44.1 kHz; the microphone gets ready
  from the touch, unless another app is playing audio) with a red dot, the time and a level meter; lift to send (a reply
  when replying); slide left 120 pt to cancel at once ("Cancelled", medium haptic); at 5 min it sends by itself. A quick
  tap only turns the field's placeholder into "Hold to record" for 2 s (no microphone prompt, nothing over the thread);
  under 1 s it's dropped with the same hint. Sent to Instagram as a voice clip (`audio/mp4`, no waveform). The first
  hold asks for the microphone; when it's off, an alert explains and opens Settings. VoiceOver: activate to start, again
  to send, or the "Cancel recording" action.
- Photos, videos and voice notes aren't offered while editing or in requests (`AppModel.sendMedia` refuses them
  there too).
- **Signed-out account:** the composer is replaced by "X is signed out" + "Log in again".

## Request thread (T2)

The composer is replaced by a bar of about 150 pt: "@handle wants to message" with the AccountTag at the end of the
line (under it when both don't fit; display name until the handle is known; VoiceOver reads "… wants to message X."),
"They won't see that you've read this until you accept.", Delete and Accept (44 pt), and "Reply instead · replying
accepts".
Reply instead opens the composer under "Replying accepts the request."; ✕ goes back. Sending moves the chat like
Accept. Failures show an alert.

## Chat info (T3)

Contact avatar, name, @handle (from the thread), **Account** with its AccountTag (and your @handle when it fits), **Folder: General** for a chat in General,
"Replies always come from this account.", Open in Instagram (when the handle is known), Archive.

Groups: the group's avatar (two of its people without a photo, as in the inbox) and name over "N members", Account,
then **N Members**: avatar, display name and @handle, sorted by name; you last as "You" with your account's avatar, ring
and mark and its @handle. A tap on someone else opens their card (as in the thread). Source: the thread's participants.
Footer: "To add or remove people, use Instagram." No other actions on members.

## Media

| Kind (from the event) | Card | Tap |
|---|---|---|
| Reel / video ready (after "Load video") | Thumbnail, author (Instagram's header title) and caption | Download (ring, tap cancels) → M1 |
| Reel / story (every share arrives unresolved) | Preview, author, caption + "Load video" → "Getting video…" | Instagram's media lookup (a read, allowed in requests) swaps the card in place, then it opens |
| Unavailable / too large / expired story / view-once | Neutral card, dimmed preview | "Open in Instagram" |
| Story reply or reaction (the story plus what was sent: Instagram's `xma_text_body`) | Instagram's own line above it (`.caption` grey: "Replied to @Name's story", "Reacted to @Name's story"), the story's card (or "Story unavailable"), then the text as a bubble under it (an emoji alone at 48 pt, no bubble). One message: one menu (Copy copies the text), reaction row and unsend. In the inbox, what was sent ("You: Droopy") | As the story |
| Post / other share | Author, image, two caption lines | Open in Instagram |
| Photo | Up to 240×320 | M2 |
| Photos sent together (one message; videos mixed in alike) | A pile: the first on top at a photo's size, up to four more tilted behind it (±3°, ±6°), "3 photos" on it; only those previews load. One menu and one row of reactions for the set | Unfolds in place into a card each, stacked like a run, each opening on its own (M2 / M1), and "Show less" under them folds it back. While "Share All" downloads, the pile shows the ring and a tap cancels |
| GIF (Instagram's `GIFS`, and `INSTAGRAM_MESSAGING_ANIMATED_IMAGE` from its GIPHY picker) | Up to 240×320 (its WebP, downloaded as it appears, like a photo; Instagram's still preview first when it sends one). Plays three times the first time it's on screen in a launch, then rests on its first frame with a play button (the video card's) that plays it once more. In a request, or under Reduce Motion, only the button. In the inbox, "GIF" | M2 (first frame) |
| Sticker (the GIPHY picker's, `is_sticker`) | Like a GIF, up to 140×140 with no grey behind it, but plays on a loop each time it's on screen, as in Instagram (in a request or under Reduce Motion, the button only, once). In the inbox, "Sticker" | M2 (first frame) |
| Voice (`m.audio` + voice flag) | Play/pause, static bars (drag to seek), 1×/1.5×/2×, duration; our own while sending: the upload ring in the play circle; after a failed play "Can't play" and a retry arrow in the circle (a tap retries) | Plays in the bubble (AVPlayer on Instagram's `.mp4`, or our own `.m4a`) |
| Video (not a share) | Like a reel without author: Instagram's preview image, duration pill; ours while sending: the upload ring | Download (ring, tap cancels) → M1 |
| Link preview | Text with a preview card | Opens the link |

View-once photos show a "View-once photo · Open Instagram to view it" card; other kinds the app doesn't show
(view-once videos, polls and the like) are chat events (Thread): "Sam sent a message Ferry can't show. Open
Instagram to see it."

- **M1 player:** full screen, one video, loops; swipe down or up (or ✕) returns to the chat. Mute, scrubber (only once
  the video has a duration), author, caption, "Open in Instagram", "Shared by X · time". Sound plays even with the
  silent switch. Failed: "Couldn't play this video", "It downloaded, but this device couldn't play it.", then Try Again
  and, for a share, Open in Instagram, as glass capsules; no scrubber, author row or caption.
- **M2 photo viewer:** pinch and double-tap zoom, pan; swipe down or up to close; Share.
- Media links are Instagram's CDN URLs. Live checks covered photos, videos, voice notes and an old shared reel
  (PLAN-core P5); live post, story, private-reel and link shares are pending (the user, from the phone).

## Accounts (A1, A2, A3) and connecting (O3)

- **A1** (sheet from the account stack): each account with avatar (its Instagram profile picture, as of the last
  login or launch), name, @handle, "Professional · Primary and
  General" for a business or creator account, status glyph + label (Connected,
  Connecting…, Syncing history…, Reconnecting…, Signed out, Can't connect) and an inline "Log in" when signed out.
  Touch-and-hold drag reorders the scope bar. "Add Instagram account" (O3, then the new account's A2). Footer: "Ferry
  Messenger 1.0" (the version). No sign-out: each account has Remove.
- **A2:** a compact header row (avatar, @handle, status), the O5 identity editor (saved as you go when valid; its
  suggestion chips scroll edge to edge inside their card; mark suggestions are letters of the name, then ✦ ⛵️ 🌊), status (state, since when, Instagram's reason,
  "Log in again" when signed out), an E2EE note, and Remove Account (confirmation: the account's chats and session
  leave this iPhone; Instagram isn't told, so the web session stays in its "Where you're logged in"; re-adding needs a
  new login).
- **A3 re-login:** why the session ended, "Your chats are safe", Log in again (O3 for that account), Not now, ✕.
  Closes itself once the account is back. Logging in as another account is refused ("That was @x. Log in as @y to
  fix it.").
- **O3 Connect sheet:** instagram.com's login (titled "Log in as @handle" on re-login) on a fresh non-persistent
  store with WebKit's stock UA. Cookies are checked on every URL change and load; once `sessionid`, `csrftoken`,
  `ds_user_id` exist on instagram.com and the URL is the home page or the inbox (the bridge's pattern), the app logs
  in with them; with cookies but no matching URL (e.g. "Save login info?") a "Logged in. Continue" button appears.
  Navigation to Instagram logout is blocked. Instagram's refusals map to plain copy (checkpoint, consent, suspended,
  ended session).

## DEBUG builds only

Fixtures for states the live accounts can't produce (made-up accounts and chats that never connect, fake request
rooms, a fake group, a forced login state, a session Instagram ends for one launch, a real chat shown as a request with sends blocked, onboarding at a step,
stand-in accounts in the toolbar stack, failing playback) and the fixture capture:
docs/DEVELOPMENT.md "DEBUG switches". None of it exists in Release builds.

## Not in v1

Moving chats between Primary and General, account-type labels in Accounts, push and badge (D6), a GIF search, a camera in `+`, "slide up to lock" a recording, mute/pin/mark unread, message
search, new groups and group management (members are read-only; no "Start a chat" from a member yet), inline reel autoplay, swipe to reply, real waveforms, a media size cap,
identity sync across devices, a verified run on the iPhone, E2EE chats (the library can't show them).
