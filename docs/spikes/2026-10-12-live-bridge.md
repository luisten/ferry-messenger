# M2 live-bridge spikes (2026-10-12)

> The project was renamed **Ferry** on 2026-10-15 (D15). This is a historical record: it keeps the old name, IG Messenger; account names, IDs and third-party handles in it are fictional stand-ins.

**Status: final (part 2 on 2026-10-13).** S1–S7 are final. One sample is still missing: a reel from a
**private** account (the user's "private" pick, `sample.travels`, turned out to be public), so the Unavailable card is
covered only by hand-made events and the bridge source.

- Part 1 (2026-10-12): the phone samples never reached the bridge. It was watched 14:54–17:26 UTC, stayed healthy and
  received zero IG deltas.
- Part 2 (2026-10-13), from the user's phone:
  - 15:11–15:12 UTC, kivostudio shared into the dummies' thread: two reels, a story and a voice note recorded in the IG
    app;
  - 15:13–15:14, on kivostudio, the thread went Primary → General, tamoveska sent a text, and the thread went
    General → Primary;
  - 15:25, tamoveska shared a post;
  - 15:36, tamoveska shared a reel and then typed a comment.
- Trace logging is still on; the lead reverts it after this analysis.

Setup: mautrix-instagram v26.09 (`ig-v26.09@sha256:bdf4b2f7…`) and Synapse v1.162.0. Both logins are `CONNECTED`:
`tamoveska` (FBID 17841400000000301, personal) and `kivostudio` (FBID 17841400000000302, professional).
Bridge config that matters here: `split_portals: true`, `disable_xma_backfill: true`, `disable_xma_always: false`,
`network.thread_backfill.batch_count: 0`, `backfill.max_initial_messages: 50`. Synapse has `max_upload_size: 200M`.
Bridge source references are to tag `v0.2609.0` of `mautrix/meta`.

## S1. Initial sync — final

Method: `GET /v3/sync?timeout=0` with the PLAN §2.4 filter inline (lazy-load members, ephemeral typing/receipt,
room account data `m.tag`, presence and global account data off). Each timeline limit ran 3 times. Synapse caches
identical initial syncs (a repeated request came back in 6 ms), so each run carried a unique dummy `not_types` entry.

| Timeline limit | Bytes | Seconds (3 runs) | Joined | Invite | Leave |
|---|---|---|---|---|---|
| 1 | 33 932 | 0.036 / 0.030 / 0.030 | 5 | 0 | 0 |
| 20 | 51 165 | 0.029 / 0.033 / 0.030 | 5 | 0 | 0 |
| no filter | 54 637 | 0.036 | 5 | 0 | 0 |

- The 5 joined rooms are 3 portals (tamoveska: 2 DMs; kivostudio: 1 DM) and 2 personal filtering spaces. There is
  no management room and no group.
- Each portal is about 8 KB at limit 1 and 11–15 KB at limit 20. Extrapolated, 100 portals come to about 1.5 MB at
  limit 20.
- `thread_backfill.batch_count: 0` limits first-sync rooms to the first inbox page per account. Both logins logged
  "Only one page in inbox, marking backfill as completed".
- Backfill took about 3 s per login (login complete at 14:49:44, last backfill message at 14:49:47).

**Outcome:** keep `timeline.limit: 20`. The p50 is 0.03 s and 51 KB, two orders of magnitude under the 3 s / 5 MB bar.
**D8: no snapshot persistence in v1.**

## S2. Fixtures — final

Fixtures are in `FerryTests/Fixtures/`.

- Every file was scrubbed with `walk(del(.access_token, .age, .user_id, .device_id, .cookies))`.
- The room with the user's real account was dropped from every fixture, including its
  `m.space.child` entry.
- No media files are included. `mxc://` URIs stay only as strings.

| File | Content | Source |
|---|---|---|
| `sync_initial.json` | Real initial sync (limit 20, PLAN filter): 2 DM portals (one per receiver of the same IG thread) + 2 personal spaces | `/sync` |
| `messages_dm_backfill.json` | `/messages?dir=b` for `!ehE0…` (receiver tamoveska): state, 2 texts, the unresolved reel and its resolve edit | `/messages` |
| `event_text_own.json` | Own text from the IG app: `@me`, `fi.mau.double_puppet_source` | backfill |
| `event_text_incoming.json` | Ghost text `@instagram_<fbid>` | backfill |
| `event_reel_unresolved.json` | Backfilled reel: `m.image`, `xma_fetch_status: "skip"`, `com.beeper.unresolved_media` | backfill |
| `event_reel_resolve_edit.json` | `m.replace` edit from `resolve_media`: `m.image` → `m.video` | S3 |
| `state_bridge_dm.json` | `m.bridge` on a DM | state |
| `state_bridge_space.json` | `m.bridge` on a personal filtering space | state |
| `provisioning_whoami.json` | Provisioning `/v3/whoami` with 2 logins | provisioning |
| `events_send_status.json` | M3 CLI send (with `unsigned.transaction_id`) + the bridge's `message_send_status` SUCCESS | M3 `/messages` |
| `events_m4_tamo.json` | M4 live run, tamoveska's room: send + status, kivostudio's reply, ❤️ → 😂 (bot-redacted ❤️, double-puppet 😂 dedupe), edit + its double-puppet echo, unsend (target arrives pre-redacted) | M4 `/messages` |
| `events_m4_kivo.json` | The same run seen from kivostudio's room (ghost side) | M4 `/messages` |
| `event_photo_incoming.json`, `event_voice_incoming.json` | M5: a JPEG and an AAC voice note sent from tamoveska's room by CLI, as they came back from Instagram into kivostudio's room | M5 `/messages` |
| `events_m5_tamo_own_media.json` | The same two sends in tamoveska's room (own `m.image`, own `m.audio` `audio/mp4` + voice flags) with their `message_send_status` SUCCESS | M5 `/messages` |
| `events_m5_kivo_own_resolve.json` | kivostudio's own backfilled reel and the resolve edit from the app's "Load video" (sent through the double puppet as `@me`) | M5 |
| `voice_sample.ogg` | The bridged voice note itself (Ogg/Opus, 7.2 s, 76 974 bytes; synthesized "IGM voice test" speech) | M5 download |
| `event_reel_live.json` | Live reel shared from the IG app (kivostudio → tamoveska's room): ready `m.video` 720×1280, link-only caption | part 2 `/messages` |
| `event_reel_live_landscape.json` | Live reel whose video is landscape (1276×718) but whose preview is portrait (744×1320) | part 2 |
| `event_story_live.json` | Live story share: an `m.video` (a still story with music), `/stories/sample.stories/<id>?reel_id=…&reel_owner_id=…` | part 2 |
| `event_post_live.json` | Live post share (tamoveska → kivostudio's room): `m.image` 3075×4096 from a carousel, `<strong>{handle} {caption…}</strong>` | part 2 |
| `event_voice_igapp.json`, `voice_igapp.ogg` | Voice note recorded in the IG app: `m.audio` + voice flags, Ogg/Opus **stereo** 48 kHz, 6.79 s, 63 988 bytes | part 2 |
| `events_m2_general_text.json` | S5a: the text tamoveska sent while the thread was in kivostudio's General folder, in both rooms | part 2 |
| `deltas_s5_ig_move_thread.json` | S5b: the two raw `SlideUQPPIGMoveThread` deltas (to General, back to Primary), copied from the trace excerpt above | part 2 log |
| `provisioning_whoami_m8.json` | Provisioning `/v3/whoami` from the M8 patched bridge: `state.info.is_professional_account` true for kivostudio, false for tamoveska | M8 provisioning |

**What the backfilled history covers.** The 3 portals hold 11 backfilled events in total: 6 `m.text`, 4 unresolved
reels (`m.image` + `unresolved_media`), and 1 resolve edit (created in S3).

- **M3** has everything it needs: the sync shape, both `m.bridge` shapes, whoami, own vs ghost senders, and two rooms
  for one IG thread.
- **M4/M5** have text, the unresolved reel and the `m.image`→`m.video` edit.

**Missing (needs live samples next session):**

- ~~reply, reaction, text edit and redaction (unsend)~~ (M4), ~~plain photo~~ and ~~voice plus a short `.ogg`~~ (M5,
  sent from Matrix through Instagram), ~~`com.beeper.message_send_status`~~ (M3);
- ~~live reel, story share, post share, IG-app voice note~~ (part 2, above);
- still missing: unavailable reel (private account), expired story, link preview, view-once. Their cards still rest on
  hand-made events modelled on the bridge source (`MediaKindTests`; each one names the bridge function it mirrors).

**Not obtainable on these accounts:** a group (none exist) and a request room (none exist; D11).

**Secret grep:** `grep -rE 'syt_|sessionid|access_token|csrftoken' FerryTests/Fixtures` finds nothing in any
M2 fixture.

- It still matches the M0 fixture `login_start_cookies.json`, on cookie **field names** (`"id": "sessionid"`). Those
  are the login-step spec, not cookie values.
- PLAN's exit check should exclude that file (`--exclude=login_start_cookies.json`) or search for values
  (`"sessionid": "`).

## S3. Reel media — final (private-account reel still unobserved)

**resolve_media (1 of 3 allowed calls used).** The target was the backfilled reel `$mGkNbgrb…` in `!ehE0…`, whose
receiver is tamoveska.

- **The call.** `POST /_matrix/provision/v3/resolve_media/%24mGkNbgrb…?login_id=17841400000000301&user_id=@me:igm.home.arpa`
  with body `{"com.beeper.unresolved_media": <verbatim object>}` returned **HTTP 200 `{}` after 12.7 s**.
  - The call is **synchronous**. The bridge downloads the whole video (29 MB in 1 MB range chunks, about 11 s) and
    sends the edit before it responds.
  - The edit was already in the next `/sync`.
- **The edit** (`event_reel_resolve_edit.json`):
  - `m.relates_to: {rel_type: m.replace, event_id: <original>}`. The sender is the original sender (the ghost).
  - `m.new_content` has `msgtype: m.video`, a new `url`, `external_url`, the same `body`/`formatted_body`, and
    `info{mimetype: video/mp4, size: 29429419, w: 720, h: 1280, thumbnail_url: <the old preview mxc>,
    thumbnail_info}`.
  - `com.beeper.dont_render_edited: true` is on the **top-level content, not inside `m.new_content`**.
  - `m.new_content` has **no** `xma_fetch_status` and no `unresolved_media`, so classifying `m.new_content` alone
    correctly gives `reel(.ready)`.
- **Download** through `GET /_matrix/client/v1/media/download/igm.home.arpa/<id>`: HTTP 200 in 0.18 s, with
  `Content-Type: video/mp4` and `Content-Disposition: inline; filename=AQN….mp4`.
- **`ffprobe`:** MP4 (`isom`), **H.264 High 720×1280 at 29.97 fps + HE-AAC stereo 44.1 kHz, 59.95 s, 29.4 MB,
  3.9 Mb/s, with `moov` before `mdat`** (fast start). AVPlayer plays this natively.

**Caption format (DESIGN §16 Q1): answered in part 2, see "Live shares" below.** Backfilled reels carry **no author
and no caption**.

- `body` is `[https://www.instagram.com/reel/<code>/](<full URL with ?id=…&is_sponsored=…>)`.
- `formatted_body` is `<p><a href="<full URL>">https://www.instagram.com/reel/<code>/</a></p>`.

When there is caption text, the bridge source (`wrapXMACaption`) builds HTML in this order, and every part is
optional:

`<blockquote>{eyebrow}</blockquote><strong>{title}</strong><br>{subtitle}<p>{caption}</p><p><a href="{full url}">{url without query}</a></p>`

- A title longer than 110 characters is cut to 100 characters plus "…".
- `body` is that HTML converted to Markdown-like text by `format.HTMLToContent`.
- **The parser should read `formatted_body`**, not `body`, and treat every part as optional.

**Live shares (part 2).** Every share was fetched at once (`disable_xma_always: false`) and arrived **ready** in both
rooms, with no `xma_fetch_status`, the media itself as `url`, and the preview image as `thumbnail_url`.

| Sample | IG XMA (raw delta) | Matrix event | Kind | `ffprobe` / size |
|---|---|---|---|---|
| Reel `DSampleRl02` | `SlideMessagePortraitXMA`, `header_title_text: "sample.space and sample.orbit"`, no `title_text`/`caption_body_text` | `m.video` 720×1280, link-only caption | `share(.reel, .ready)` | H.264 High 720×1280 29.97 fps + HE-AAC, 65.6 s, 9.9 MB, fast start |
| Reel `DSampleRl03` (`sample.travels`, public) | same shape, `header_title_text: "sample.travels"` | `m.video` **1276×718**, preview 744×1320 | `share(.reel, .ready)` | H.264 1276×718 30 fps + HE-AAC, 13.8 s, 6.3 MB |
| Story `sample.stories/4000000000000000005` | `SlideMessagePortraitXMA`, `header_title_text: "sample.stories"` | **`m.video`** 720×1280, `external_url` `/stories/sample.stories/<id>?reel_id=…&reel_owner_id=…` | `share(.story, .ready)` | H.264 720×1280 at **1 fps** + HE-AAC, 45 s, 613 KB (a still story with music) |
| Post `DSamplePo01` (carousel) | `SlideMessageStandardXMA`, `header_title_text: "sample.photos"`, `title_text: "sample.photos Morning light over the…"` | `m.image` 3075×4096 JPEG (2.7 MB), `?carousel_share_child_media_id=…` | `share(.post, .ready)` | — |
| Reel `DSampleRl04` + typed comment | XMA (`header_title_text: "sample.reels"`), then a **separate** IG text message | `m.video`, then `m.text` "Reel with a meaaage/caption" 1 s later | `share(.reel, .ready)` + `text` | — |

**DESIGN §16 Q1, answered.** IG puts the author in `header_title_text`, and `wrapXMACaption` never reads that field
(it reads `title_text`, `subtitle_text`, `caption_body_text` and `eyebrow_text`). So:

- **Reels and stories: no author and no caption reach Matrix.** The body is only the link. A story's author is still
  recoverable from its URL (`/stories/<handle>/`).
- **Posts:** IG's `title_text` is `"<handle> <caption>"`, so the bridge sends
  `<strong>sample.photos Morning light over … Walking the old qu…</strong><p><a …>…/p/DSamplePo01/</a></p>` (cut at 100 characters).
- **A comment typed with a share is its own IG message**, so it arrives as an ordinary `m.text` right after the
  share, never inside the share's caption.

The parser was changed to match (`ShareCaption(content:)` in `Timeline.swift`, with regression tests in
`MediaKindTests.testRealLiveCaptions` and `testPreviewSaysWhoMadeTheShare`):

- a post title is split into `@handle` + caption when its first word looks like a handle;
- a story takes its author from the URL;
- a reel shows no author row.

A one-line bridge patch (fall back to `HeaderTitleText` in `wrapXMACaption`) would give reels their author too; it is
listed with the M8 scope.

**Still pending:** a private-account reel. The source says it arrives as `m.image` + `xma_fetch_status: "fetch fail"`.
A public reel from a non-followed account is fetched fine (`sample.travels`).

**Cards in the app** (iPhone 17 sim, tamoveska's room, which holds every sample: the shares and voice incoming,
the post as its own send). Screenshots are `docs/verification/m2b-*.png`.

- Both reels are 220×330 reel cards with no author row and play in the player. The landscape one plays letterboxed,
  14 s.
- **5a cache check:** the second open of the landscape reel showed the player within 0.3 s, and its cache file
  (`Caches/media/vbdYTX….mp4`, 6 299 911 bytes) kept its 22:33:03 mtime, so it wasn't downloaded again.
- The story card reads "Story · @sample.stories" and plays as a video, with "@sample.stories" in the player.
- The post card shows "@sample.photos", the image and two lines of caption; the image opens full screen.
- The IG-app voice note plays (pause, 1×, 0:02 elapsed). The user confirmed audible sound earlier (checklist (c)).
- The inbox reads "You sent a post by @sample.photos" and "Sent a post by @sample.photos".
- **0 Instagram actions** were logged during the check (`action="handle matrix"` count 0 since 15:30:39). kivostudio's
  room was **not opened**: it had an unread incoming message, and opening it would have sent "Seen".

**Second resolve (M5, from the app).** kivostudio's own copy of the same reel (`$d8JNeitV…` in `!o6Pq…`,
`login_id` = kivostudio). HTTP 200 `{}` in **2.9 s** (`request_time_ms=2914`; S3's first call took 12.7 s, so plan for
both). The raw `$` in the path is accepted. The edit's sender is **`@me` with `fi.mau.double_puppet_source`**: the
bridge sends a resolve edit as the original sender (`ForceEditOrigSender`), through the double puppet for our own
messages, so the reducer's same-sender rule holds for own reels too. Same shape otherwise (`dont_render_edited` on top,
new `url`, the preview as `thumbnail_url`). No Instagram-visible action: no Matrix event reaches the bridge's
Matrix→IG handler, it only fetches media.

**`xma_fetch_status` values (from the bridge source):**

- `skip`: the fetch was deferred; it comes with `unresolved_media`.
- `fetch fail`, `empty response`, `item not found in response`, `reupload fail`, `unrecognized url`,
  `unrecognized type`: failures.
- The key is absent on success.

For §2.6, "unavailable" therefore means **present and not `skip`**. A reel too large for the homeserver comes back as
`reupload fail`. A plain attachment that is too large becomes an `m.notice` with body `"Too large attachment"`.

## S4. Voice — final (M5, 2026-10-13)

**Method.** No phone needed: a voice note made with macOS tools (`say -o v.aiff …`, `afconvert -f m4af -d aac` → 7.19 s
AAC, 35 KB) was uploaded with `POST /_matrix/media/v3/upload` and sent from tamoveska's room by `mx.sh` as
`m.audio` with `info.mimetype: audio/mp4`, `org.matrix.msc3245.voice: {}` and `org.matrix.msc1767.audio`
(`duration`, a made-up `waveform`). The bridge uploaded it to Instagram as a voice clip (`IsVoiceClip`); Instagram
delivered it to kivostudio, and the bridge put it into kivostudio's room. One Instagram action (plus the bridge's
implicit read receipt that goes with every send).

**What comes back** (`event_voice_incoming.json`):

- `m.audio`, `body: "audioclip-<ms>-<duration>.mp4.ogg"`, `info{mimetype: audio/ogg, duration: 7291, size: 32428}`,
  `org.matrix.msc1767.audio{duration: 7291, waveform: []}`, `org.matrix.msc3245.voice: {}`.
- Instagram stores the clip as MP4/AAC; the bridge converts it to Ogg/Opus with ffmpeg (`needVoiceConvert` in
  `mediadl/reupload.go`) **after** measuring it: `info.size` (32 428) is the MP4's size, the download is 76 974 bytes.
  Don't use `info.size` for progress or for "is it complete".
- **The waveform is dropped** (empty array), so DESIGN §14's static bars are the only option.
- Download: `Content-Type: audio/ogg`, `Content-Disposition: inline; filename=audioclip-….mp4.ogg`.

**`ffprobe`:**

```
Input #0, ogg, from 'voice_sample.ogg':
  Duration: 00:00:07.20, start: 0.000000, bitrate: 85 kb/s
  Stream #0:0(eng): Audio: opus, 48000 Hz, mono, fltp
codec_name=opus sample_rate=48000 channels=1 channel_layout=mono format_name=ogg size=76974 encoder=Lavc62.28.102 libopus
```

**Playback (P3 on real data).** `MediaKindTests.testRealBridgedVoicePlaysWithAVFoundation`: `AVURLAsset` says
playable, duration 7.2 s; `AVAudioFile` decodes it at 48 kHz (7.2 s of frames); an `AVPlayer` item reaches
`.readyToPlay` and seeks to 3.0 s exactly. So no AVAudioFile → AVAudioPlayerNode fallback is needed for the format.
**Not confirmed: audible playback.** On 2026-10-13 this Mac's default output was an external display, and
it couldn't start audio (`afplay` → `AudioQueueStart failed (0xe0114101)`, also with the display woken). The simulator
inherits the host's default device, so every AVPlayer item with an audio track was dropped
(`RenderPipelineFailedToStart`, HAL "server failed to start"), video included. The app now shows that as "Can't play"
/ "Couldn't play this video" instead of a frozen bubble or a black screen. Re-check once the Mac has a working output.

For sending, `com.beeper.room_features` lists voice as `audio/mp4: 2` (full support) and `audio/ogg: 1` (partial),
and an `audio/mp4` voice note goes through as a real Instagram voice clip (above).

**Recorded in the IG app (part 2,** `event_voice_igapp.json`, `voice_igapp.ogg`**):** same event shape:

- `body: "audioclip-1791904368000-6783.mp4.ogg"`;
- `info{mimetype: audio/ogg, duration: 6783, size: 36940}`;
- `waveform: []`.

`ffprobe`: **Ogg/Opus, 48 kHz, stereo** (the M5 note was mono), 6.79 s, 63 988 bytes, 75 kb/s, encoder
`Lavc62.28.102 libopus`. So `info.size` is again the pre-conversion size.
`MediaKindTests.testRealIGAppVoiceNotePlays` covers it:

- `AVAudioFile` reads 2 channels and 6.79 s;
- an `AVPlayer` item reaches `.readyToPlay` and seeks to 4.0 s.

In the app it plays and seeks, and the user confirmed audible sound.

**Photo, same run** (`event_photo_incoming.json`): a 1200×900 JPEG comes back as `m.image` with Instagram's filename,
`info{w, h, mimetype, size}` (size matches the download) and no `thumbnail_url`.

## S5. Primary/General (kivostudio) — final: gate A for live moves; initial folder unknown

**Part 1 (source reading, 2026-10-12)** expected a folder move to arrive as `SlideUQPPUpdateThreadFolder`. It
recorded a provisional B, because nothing had been captured (the mailbox GraphQL response is never logged, even at
trace).

**(b) Live capture (part 2, 2026-10-13, `server/data/instagram/logs/bridge.log`).** Each move produced one delta on
kivostudio's socket and nothing on tamoveska's. IG calls it **`SlideUQPPIGMoveThread`**, a type v26.09 doesn't
know: it parses as `slidetypes.UnknownEvent`, logs a warning and does nothing else.

```
2026-10-13T15:13:12.185Z login 17841400000000302  Handling delta  event_struct=slidetypes.UnknownEvent
  {"__typename":"SlideUQPPIGMoveThread","uq_seq_id":"74","thread_fbid":"1700000000000301","folder":"INBOX","ig_inbox_folder":"GENERAL"}
2026-10-13T15:13:12.186Z warn "Unrecognized event type in socket" typename=SlideUQPPIGMoveThread thread_fbid=1700000000000301
2026-10-13T15:14:05.322Z login 17841400000000302  Handling delta  event_struct=slidetypes.UnknownEvent
  {"__typename":"SlideUQPPIGMoveThread","uq_seq_id":"81","thread_fbid":"1700000000000301","folder":"INBOX","ig_inbox_folder":"PRIMARY"}
2026-10-13T15:14:05.322Z warn "Unrecognized event type in socket" (same fields)
```

- **`folder` stays `"INBOX"` both ways.** Primary and General are both inside IG's INBOX folder, and
  `ig_inbox_folder` is the only field that tells them apart (`GENERAL` / `PRIMARY`). That is why the bridge's
  request logic (`folder == PENDING|SPAM`) is unaffected.
- The `warn` line is logged at any level, so later moves can be spotted without trace (typename and thread only).
- `thread_fbid` 1700000000000301 is the shared IG thread; both logins see the same FBID in their message deltas.
- Nothing reached Matrix: no `m.bridge` change and no room event.

**(a) A General thread keeps bridging.** At 15:13:40.402 (IG timestamp), while the thread was in General (moved at
15:13:12, back at 15:14:05), tamoveska sent "Sending a text":

- kivostudio's delta arrived at 15:13:40.977 (+0.57 s);
- the event `$f3agzuxGdwH…` was in kivostudio's room `!o6Pq…` at 15:13:41.037 (**+0.64 s** after sending), from the
  ghost `@instagram_17841400000000301`;
- tamoveska's own copy reached `!ehE0…` as `@me` at 15:13:42.08 (`events_m2_general_text.json`).

Whether a thread that is **already** in General at login gets a room is still untested (kivostudio had only this
thread). The move event shows General threads live in folder INBOX, which is the folder the bridge's inbox query
lists, so they most likely do.

**Initial folder state: not available today, and not capturable without a patch.**

- **Inbox query.** `PolarisDirectInboxQuery` (`MakeMailboxRequest`) is sent with `IsProfessionalAccountGK: false`
  (`slidetypes/requests.go:200`). Pagination asks only for folder `"INBOX"` (`chatsync.go:152`).
- **Thread fields.** The list's `ThreadInfo` has `folder` and `messaging_folder_tag` ("only present when listing
  threads", `slidetypes/thread.go:62-66`), but **no `ig_inbox_folder`**. The bridge reads neither field.
  `IGDThreadDetailQuery` (thread resync) has no folder fields at all.
- **Nothing in the logs.** GraphQL responses are never logged (`instameow/graphql.go`), and there is no
  `"Response for thread resync fetch"` line in any log. Unknown: whether `messaging_folder_tag` carries
  PRIMARY/GENERAL, and whether it does only with `IsProfessionalAccountGK: true`.
- **When the inbox is loaded.** Only when the login has **no seq ID**: the first login, or after the bridge drops
  it (`FullReconnect(seqIDOnly)`, e.g. after "please reload page"). Restarts and the 20 h periodic refresh reuse the
  seq ID and only reload the index (`igconnector/client.go:256-300`). So even a patched bridge only learns existing
  threads' folders after a deliberate seq-ID reset or a re-login.

**Verdict: gate A.** IG sends the split live, with distinct values both ways, and General threads keep bridging. M8
goes ahead, in two parts:

1. **Live moves (certain).** Handle `SlideUQPPIGMoveThread` (new `IGMoveThreadEvent{folder, ig_inbox_folder}` in
   `slidetypes/event.go`; a case in `handleDelta`), store `ig_inbox_folder` in portal metadata, and expose it in
   `m.bridge` `channel` through `PortalBridgeInfoFillingNetwork`, under a namespaced key such as
   `com.igmessenger.inbox_folder`. The bridge re-sends `m.bridge` when chat info changes.
2. **Initial state (unknown; it decides how much of M8 is worth it).** First a capture patch: log each thread's
   `folder` / `messaging_folder_tag` from the inbox and pagination queries, with `IsProfessionalAccountGK` false and
   then true, on kivostudio with one thread in General. Trigger it with a seq-ID reset (needs a small admin hook in the
   patch; a re-login risks a checkpoint).
   - If a field tells Primary from General, map it in `wrapChatResync` and resync once.
   - If not, a thread's folder is only known after its first move post-patch. The client must then show
     "unknown" as Primary and label General as "moved to General since …".
3. Optional, cheap: `wrapXMACaption` falls back to `HeaderTitleText` when `TitleText` is empty, so reels and stories
   get their author (S3). Expose `is_professional_account` / `has_tabbed_inbox` in the login's `RemoteProfile`, so
   the General tile shows only for tabbed inboxes.

Raise all three upstream (PLAN M8 Q3). The move handler and the `HeaderTitleText` fallback are small and generic.

**(d) M8 starting-folder experiment (2026-10-13 16:05–16:07 UTC, `kivostudio` only).** A temporary debug build of the
M8 patch logged, for every thread object in the inbox GraphQL responses, its IDs, the scalar values of folder-like
keys and the names of all keys (never content, names or cookies). The inbox was reloaded the way the bridge does it
itself (`FullReconnect(seqIDOnly)` → `DeleteIGSeqID`): with the bridge stopped,
`DELETE FROM meta_instagram_seq_id WHERE bridge_id = '' AND login_id = '17841400000000302'` (row was `seq_id` 103),
then start. Run A with `IsProfessionalAccountGK: false` (upstream), run B with `true` (an env toggle in the debug
build). Run A loaded the inbox web page once and made one `PolarisDirectInboxQuery`; run B made only the query (its
index was under 5 min old). Neither made a Matrix-side Instagram action; tamoveska kept its seq ID and wasn't reloaded. **Undo:** none needed. After processing the
mailbox the bridge wrote the row back itself (`seq_id` 103 both times, unchanged). The DB dump taken first is
`server/data/backups/mautrix_instagram-20261013T1605-pre-m8.dump`. The debug build was replaced by the final image at
16:14.

| | Run A (GK false) | Run B (GK true) |
|---|---|---|
| Mailbox connections | `threads_by_folder` | `threads_by_folder` **and `threads_by_system_folder_and_ig_inbox_folder`** |
| Thread 1700000000000301 | `folder: "PRIMARY"`, `messaging_folder_tag: "INBOX"`, `system_folder: "INBOX"`, `thread_label: 0`, subtype `IG_BUSINESS_ACCOUNT_ONE_TO_ONE` | same, in both connections |
| Other keys | no `ig_inbox_folder` anywhere | same |
| Viewer | `is_professional_account: true`, `is_business_account: true`, **`has_tabbed_inbox: false`** | same |

- In the inbox list, `folder` is **not** the system folder (that's `system_folder`, and `messaging_folder_tag`
  repeats it). It reads `PRIMARY` for a thread in Primary, so it is very likely the tab. (In the move delta, by
  contrast, `folder` is the system folder `INBOX` and the tab is `ig_inbox_folder`.)
- **Not decisive:** the thread was in **Primary** during both runs. No move delta had arrived since the logs begin
  (15:41:56), so the overnight move to General hadn't happened yet. `GENERAL` was never seen in the list, so the
  mapping isn't proven.
- GK true only adds the second, tab-filtered list; it gives no extra field. Upstream's `false` stays.
- `has_tabbed_inbox` is false even for this business account, so it's useless as a signal. The patch exposes only
  `is_professional_account`.

**Outcome: live moves only** (D12). The patch doesn't apply `folder` at sync. Settling it takes one reload while a
thread is in General (Hand-off C, [manual-verification](../manual-verification.md#pending-user)). If the list then
says `folder: "GENERAL"`, the sync mapping is about 3 lines in `wrapChatInfo`
(`ExtraUpdates: setIGInboxFolder(thread.Folder)` for `PRIMARY`/`GENERAL`). It still applies only at a full inbox
load (first login or a seq-ID reset), never on restarts.

## S6. Pre-existing requests — final

- Rooms with `channel["com.beeper.message_request"] == true`: **0 of 2** (tamoveska) and **0 of 1** (kivostudio).
- On these portals the key is **absent**, not `false`. The client must treat a missing key as "not a request".
- Per D11 there was no third account, so no request was pending before login (the two dummies already share a
  thread). The research gotcha (pre-login requests may not be bridged until a new message arrives) is still untested.

**Outcome:** no change to §2.8. The Requests tile stays empty on these accounts until a real request arrives. Request
behaviour stays covered by unit tests and by the bridge code (`system_folder` PENDING/SPAM → `message_request`).

## S7. Bridge shape — final

1. **Invites:** `jq '.rooms.invite|length'` is **0** on every initial sync. Double puppeting joins `@me` directly: its
   `m.room.member` content has `fi.mau.double_puppet_source: "mautrix-instagram"`. No auto-join is needed.
2. **Own sends from the IG app appear as `@me:igm.home.arpa`**, with `content["fi.mau.double_puppet_source"]`.
   Verified on backfill and, in part 2, live: kivostudio's shares show as `@me` in `!o6Pq…`, and tamoveska's text
   and post show as `@me` in `!ehE0…`. The other side is a ghost, `@instagram_<fbid>:igm.home.arpa`.
3. **One IG thread, two rooms.** With both dummies bridged and `split_portals`, the tamoveska↔kivostudio thread
   becomes two rooms:
   - `!ehE0…`, whose receiver is tamoveska;
   - `!o6Pq…`, whose receiver is kivostudio.

   In each room, `@me` is that room's receiver. The inbox shows the thread twice, once per account. That matches
   DESIGN §16 assumption 3 (no merged chats), and M3's round-trip test and M4's two-sided checks rely on it.
4. **`m.bridge` on a DM.** State key `igm.home.arpa/instagram`, duplicated as `uk.half-shot.bridge`. Fields:
   - `channel{id: <other FBID>, displayname, avatar_url, fi.mau.receiver: <login FBID>}`;
   - `com.beeper.room_type: "dm"` and `com.beeper.room_type.v2: "dm"`;
   - `bridgebot` and `creator`;
   - **`protocol.id: "instagramgo"`**, not `"instagram"`.

   `com.beeper.message_request` is absent when false.
5. **`m.bridge` on the personal filtering space.** State key **`""`**, with no `uk.half-shot.bridge` twin. Fields:
   - `channel{id: "__personal_filtering_space__", fi.mau.receiver}`;
   - `com.beeper.room_type.v2: "personal_filtering_space"`, and no `com.beeper.room_type`;
   - `protocol.id: "instagramgo"`.

   `m.room.create.type` is `m.space`.
6. **Groups:** none exist on either account, so the shape is unobserved. From the source (`chatinfo.go:183-188` and
   bridgev2 `portal.go:4561-4565`), an IG group has room type `""`, so **both `com.beeper.room_type` and
   `room_type.v2` are absent**. The client must read "no room_type" as a group, not as an error.
7. **Room version 12.** Room IDs have no `:server` suffix (`!ehE0v9MxOfM_NXqxrNmHqfZ048PGl7MYoaGvwMU_5XA`). Never
   parse a server name out of a room ID.
8. **Provisioning `whoami` has no backfill counts** (DESIGN §16 Q4: no).
   - Login fields: `id`, `name`, `profile{username, name, avatar?}`,
     `state{state_event, timestamp, ttl, source, info.personal_filtering_space}`, `state_event`, `state_ts` and
     `space_room`.
   - `profile.avatar` is missing for tamoveska (no IG avatar), so it is optional.
   - Use an indeterminate spinner for CONNECTING/BACKFILLING.
9. Backfilled messages are marked read (`mark_read_past_threshold`), so every room starts at
   `notification_count: 0`.
10. **Transient disconnects are short.**
    - kivostudio got a DGW drain frame (reason SLB) at 15:13, and the server closed the socket at 15:31:55.
    - The bridge went from `TRANSIENT_DISCONNECT` back to `CONNECTED` in 0.6 s and logged "Not sending delayed
      transient disconnect notice".
    - This supports §2.10's rule of showing a banner only after 2 minutes.

**Outcome:** §2.5 holds except for the protocol match. **Match `protocol.id == "instagramgo"`** (or, more robustly,
`bridgebot == "@instagrambot:<hs>"`), never `"instagram"`. Inbox inclusion via
`room_type.v2 != "personal_filtering_space"` works as planned. No auto-join code is needed.

## Recommended decisions

- **D8 (persistence):** *No snapshot persistence in v1. A cold start does a fresh initial sync with
  `timeline.limit: 20`. Measured on 2026-10-12: 51 KB and p50 0.03 s for 5 rooms, about 1.5 MB extrapolated for
  100 rooms. Revisit if a real account's initial sync passes 3 s or 5 MB.*
- **D9 (Primary/General gate), proposed final wording:** *Gate **A** (2026-10-13, S5). On a professional account,
  Instagram sends every Primary ↔ General move live as `SlideUQPPIGMoveThread` with `folder: "INBOX"` and
  `ig_inbox_folder: "GENERAL" | "PRIMARY"`; v26.09 drops it as an unknown event. A General thread keeps bridging
  (a message arrived in 0.6 s while the thread was in General). M8 goes ahead:*
  1. *a move handler that puts `ig_inbox_folder` into `m.bridge`;*
  2. *a capture step for the initial folder (`messaging_folder_tag` with `IsProfessionalAccountGK` false/true; only
     loaded at first login or after a seq-ID reset).*

  *If the capture shows no initial folder, v1.x labels only threads moved since the patch, and treats the rest as
  Primary.*
  (Superseded: the provisional B of 2026-10-12, from the source alone.)

## Changes for PLAN M3–M8

- **§2.5 / M3:**
  - Match `protocol.id == "instagramgo"` (or `bridgebot`).
  - `channel.com.beeper.message_request` may be absent.
  - A missing `room_type` means a group.
  - Room IDs (v12) have no server part.
- **§2.6 / M4–M5:**
  - For an edit, read the classification fields from `m.new_content`, and `com.beeper.dont_render_edited` from the
    top-level content.
  - "Unavailable" means `xma_fetch_status` is present and is not `"skip"`.
  - A too-large XMA shows as `reupload fail`. Too-large plain media is an `m.notice` "Too large attachment".
  - The caption parser reads `formatted_body`, with every part optional (backfilled reels have only the link).
- **§2.7 / M5:**
  - `resolve_media` is synchronous: about 13 s for a 60 s / 29 MB reel. `await` the POST with a timeout of at least
    60 s, then let sync deliver the edit. Keep the "Fetching from Instagram…" state for the whole call.
  - Reels are large (about 0.5 MB per second of video), so the tap-to-download progress UI matters.
- **M2 exit grep:** exclude `login_start_cookies.json` (it contains cookie field names), or grep for values.
- **S5(c):** not needed. The live moves showed the split without a patch.
- **Part 2 (2026-10-13), done:** `ShareCaption(content:)` takes a post's handle from its title and a story's from its
  URL; reels have no author. Inbox, cards and player use it.
- **M8, new scope** (S5):
  - a `SlideUQPPIGMoveThread` handler that puts `ig_inbox_folder` into `m.bridge`;
  - an initial-folder capture before any resync design;
  - optionally, the `HeaderTitleText` caption fallback (reel and story authors) and the professional flag in
    `RemoteProfile`.

  The Dockerfile plan in PLAN M8 is unchanged. Drop "flip `IsProfessionalAccountGK`" as a given; it is now one
  arm of the capture.
