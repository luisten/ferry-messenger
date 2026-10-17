# Ferry: implementation plan (v1)

Drafted 2026-10-12 (as "IG Messenger"; renamed Ferry 2026-10-15, D15). The dummy accounts appear under their
fictional stand-in names, `tamoveska` (personal) and `kivostudio` (professional) (CLAUDE.md). Inputs: [BRIEF](BRIEF.md), [DECISIONS](DECISIONS.md) D1–D7 (settled, built on, not reopened),
[matrix-bridge](research/matrix-bridge.md), [beeper-ux](research/beeper-ux.md), notes on an earlier web-wrapper prototype,
and [design/DESIGN.md](design/DESIGN.md) v1 (skimmed; see §7).

**Executor:** one engineer agent working sequentially. **Effort:** about 13–18 focused days, roughly 3.5k lines of app
Swift plus 1k lines of tests. **Shape:** server first, then real Instagram accounts bridged by the end of M1, then the
app built against real data.

## Verified while planning (scratchpad experiments, Xcode 27.0, iPhone 17 sim on iOS 26.4)

| # | Hypothesis | Result |
|---|---|---|
| P1 | A hand-written `.xcodeproj` using **file-system-synchronized groups** (objectVersion 77) builds and tests with `xcodebuild`, so no generator script is needed | **Yes.** New `.swift` files dropped into the folders were picked up with no project edits. xcodebuild auto-creates the scheme, unit tests included. Two settings were required: `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"` (without it no simulators are offered) and `ALWAYS_SEARCH_USER_PATHS = NO`. Template in Appendix A. |
| P2 | A partial `Info.plist` outside the synced folder merges with `GENERATE_INFOPLIST_FILE` (needed for the ATS dictionary) | **Yes.** `NSAppTransportSecurity.NSAllowsLocalNetworking` appears in the built plist. |
| P3 | iOS plays Ogg/Opus natively, so voice notes need no Ogg parser and no dependency | **Yes on the simulator.** On a synthetic ffmpeg/libopus mono 48 kHz `.ogg`: `AVAudioFile` decoded 96,000 of 96,000 frames; `AVURLAsset` reported playable; `AVPlayer` reached `.playing` and its time advanced. `AVAudioPlayer.prepareToPlay()` returned false in the test host (inconclusive), so **use `AVPlayer`**. Still to confirm: a real bridged file (M2) and a physical device. |
| P4 | `xcodebuild test` leaves the booted simulator alone | **No.** Parallel testing shut down the booted iPhone 17 so it could clone it. **Always pass `-parallel-testing-enabled NO`.** That kept the simulator booted. |
| P5 | `XCTSkip` shows as "skipped", not "failed" | Yes (checked with `xcresulttool`). |

---

## 1. Scope of v1

### In (mapped to the brief's must-haves)

| Must-have | v1 delivers |
|---|---|
| **#1 Two or more IG accounts in one inbox; reply from the right account** | Any number of accounts connected through the in-app instagram.com login (D7). One unified inbox with a scope bar (All, or one account). Every room is locked to its account through `m.bridge` → `fi.mau.receiver`, and the composer shows "Message as X". With `split_portals: true`, the bridge routes each room through its own login, so the app has no account switcher at send time. |
| **#2 Reels as a video in the chat** | Live reels arrive as `m.video` and are tapped to play. Backfilled reels show a "Load video" button that calls `resolve_media`, after which an edit replaces the preview in place. Unavailable and too-large reels get a fallback card with "Open in Instagram". Also covered: post shares, story shares, photos, videos and voice notes (native AVPlayer, P3). |
| **#3 Account-type differences** | **Requests** per account for personal and business accounts: Accept, no read receipts, and a warning that a reply accepts the request. **Primary/General** is decided by a gate: the live capture runs in M2, and if Instagram sends the split, the bridge patch ships in M8 (D5). Account type and private/public are not exposed by the bridge, so they show up only where the data does, mainly as reel availability. |
| **#4 Nice UX** | Screens built to DESIGN.md v1, using its §14 cost fallbacks first. Connection health has a banner and a re-login flow. |

Also in: text send, reply, react (one per user), edit (own messages, within IG's limits), unsend, typing display,
"Seen", unread counts, archive (as a Matrix room tag), search by chat name, minimal chat info, and Matrix sign-in.

**Late v1** (cut first if behind): N1 New message (`search_users` + `create_dm`) and sending photos (PhotosPicker).

### Out / deferred

| Item | Why / when |
|---|---|
| Push notifications, the app-icon badge, O7 pre-prompt | D6. Needs a paid Apple account, Sygnal and an always-on host. v1 shows unread counts in the app and syncs on open. |
| Primary/General, if the M2 gate says Instagram doesn't send it | D5. v1 ships Chats + Requests. The design already has a slot for the General tile. |
| Account-type labels (business/creator, private) | Not in the bridge. Comes with the M8 patch if it goes ahead. |
| Hidden requests vs Requests | The bridge doesn't distinguish them. |
| Sending voice notes, video, GIFs and stickers; new groups; group management | Not must-haves. Voice recording needs its own gesture work (DESIGN §14). |
| Inline reel autoplay in bubbles, swipe-to-reply, decoded waveform, shimmer | DESIGN §14 fallbacks: tap opens the full-screen player, reply is in the context menu, the waveform is static bars. |
| Message search (server `/search`), mark-unread, merged chats, iPad | Not needed for v1. |
| On-device (iPhone) use, an always-on host, Tuwunel | D3. M9 lists the Tailscale steps as an optional stretch. |
| E2EE, encrypted IG chats | D2 (unencrypted). The bridge can't bridge IG E2EE chats anyway. |

---

## 2. Architecture

### 2.1 Server (`server/`)

```
server/
  docker-compose.yml   3 services, images pinned by tag AND digest, ports bound to 127.0.0.1 only
  bootstrap.sh         the single idempotent setup script (below); ends with a self-check
  mx.sh                ~5 lines: authed curl against Synapse with the CLI token from .env (spikes/debugging)
  .env.example         names only; real .env is generated and gitignored (already in .gitignore)
  data/                gitignored: postgres/, synapse/ (homeserver.yaml, key, media), instagram/
                       (config.yaml, registration.yaml), doublepuppet.yaml
  bridge/              ONLY if the M2/M8 gate says patch: Dockerfile (multi-stage Go build) + *.patch
```

**Images** (D1/D2). Pin `tag@sha256:…`, resolving each digest in M0 with `docker buildx imagetools inspect`:

| Image | Tag |
|---|---|
| Postgres | `postgres:18.6-alpine` (mount `./data/postgres:/var/lib/postgresql`, initdb `--lc-collate=C --lc-ctype=C`) |
| Synapse | `ghcr.io/element-hq/synapse:v1.162.0` |
| Bridge | `dock.mau.dev/mautrix/meta:ig-v26.09@sha256:bdf4b2f7d50f59d1053639d1da31612be72e2fb6fba4c20b2285a0fdeebff2df` (since M8 the base of our patched build, `server/bridge/`, D12) |

Ports: `127.0.0.1:8008` (Synapse) and `127.0.0.1:29330` (bridge provisioning). Nothing is exposed to the LAN.

**`bootstrap.sh`.** Every step checks its own precondition, so re-running it changes nothing. Config edits run as a
small Python heredoc inside the Synapse image, which already ships Python and PyYAML, so nothing is installed on the
Mac.

1. **`.env`** (if missing): `SERVER_NAME`, `PG_PASSWORD`, `BRIDGE_DB_PASSWORD`, `MATRIX_USER`, a random
   `MATRIX_PASSWORD`, the double-puppet `as_token`/`hs_token`, and later `MATRIX_CLI_TOKEN`. Secrets come from
   `openssl rand -hex 32`.
   - `SERVER_NAME` defaults to `igm.home.arpa`. It is **irreversible**: it ends up in every Matrix ID. That name never
     federates and survives moving hosts. See Q2.
2. **Postgres** up and healthy. Create role and database `mautrix_instagram` (UTF8, C locale) only if
   `pg_roles`/`pg_database` don't have them.
3. **Synapse config**: `generate` if `homeserver.yaml` is missing, then patch:
   - `database` → psycopg2 at `postgres`;
   - `app_service_config_files: [/appservices/instagram.yaml, /appservices/doublepuppet.yaml]`;
   - `max_upload_size: 200M`;
   - `enable_registration: false`;
   - `federation_domain_whitelist: []`, `trusted_key_servers: []`;
   - `presence.enabled: false`, `url_preview_enabled: false`, `report_stats: false`.
4. **Bridge config**: if `config.yaml` is missing, start the bridge once to generate it. Then patch (defaults
   confirmed against mautrix-go v0.31.0 `example-config.yaml`; check each key in the generated file):
   - `homeserver` → `http://synapse:8008`, `domain: $SERVER_NAME`;
   - `appservice` → `http://mautrix-instagram:29330`, `hostname 0.0.0.0`;
   - `database` → postgres URI;
   - `bridge.split_portals: true` (**irreversible, set before any login; the script greps and aborts if it isn't
     true**);
   - `bridge.permissions: {$SERVER_NAME: user, @$MATRIX_USER:$SERVER_NAME: admin}` (replacing the default `"*": relay`);
   - `bridge.cleanup_on_logout`: enabled, manual logout → delete, bad credentials → nothing;
   - `matrix.message_status_events: true`, `matrix.message_error_notices: false` (the app shows failures on the
     bubble instead);
   - `matrix.ghost_extra_profile_info: true` (M7b: ghost profiles get the contact's `instagram:<handle>`);
   - `backfill.enabled: true` (default false!), `max_initial_messages: 50`;
   - `double_puppet.secrets.$SERVER_NAME: as_token:…`;
   - `network.disable_xma_always: false`, `network.disable_xma_backfill: true`;
   - `encryption.allow: false` and `provisioning.allow_matrix_auth: true` (both defaults; the shared secret stays on
     the server).

   Start the bridge again to write `registration.yaml`.
5. **`data/doublepuppet.yaml`** (if missing):
   - `id: doublepuppet`, `url: null`;
   - the tokens from `.env`, `sender_localpart` random, `rate_limited: false`;
   - user namespace `@.*:$SERVER_NAME`, `exclusive: false`.
6. **Start Synapse** and wait for `/health`.
7. **Matrix user**: register with `register_new_matrix_user … -a` only if a password login fails. Then mint
   `MATRIX_CLI_TOKEN` (a separate "cli" device) if the stored one fails `/account/whoami`.
8. **Start the bridge.** Self-check:
   - login works;
   - `GET /_matrix/provision/v3/whoami?user_id=…` with the Matrix token returns 200 and `login_flows` contains
     `instagram`;
   - `split_portals: true` is present.

   Print `OK` and the Matrix credentials' location (`server/.env`).

### 2.2 iOS app

- **Project:** `Ferry.xcodeproj`, hand-written with synchronized groups (P1, Appendix A).
- **Targets:**
  - `Ferry` (`$(FERRY_BUNDLE_PREFIX).ferry`; the prefix and the team come from `Config/Local.xcconfig`, gitignored);
  - `FerryTests` (hosted unit tests);
  - `FerryUITests`, added the same way with `TEST_TARGET_NAME` set. This target wasn't covered by P1;
    verify it in M1.
- **Build settings:**
  - your team (`Config/Local.xcconfig`), automatic signing, iPhone only, portrait;
  - **iOS 26.0** deployment target (DESIGN.md targets iOS 26 Liquid Glass; see Q5);
  - **Swift 6** with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (P1 built with it). Pure logic types are marked
    `nonisolated` so tests call them directly.
- **Zero dependencies.** `@Observable`, URLSession, Codable, AVKit, SwiftUI `WebView`/`WebPage` (iOS 26).
- **Tests use XCTest only:** it's the user's existing convention, UI tests need it, and it gives `XCTSkip`.
- **No protocol seams.** Concrete types only; tests target pure functions fed with JSON fixtures, not mocks. There is
  **no `ChatBackend` protocol** (YAGNI; D4 already chose the hand-rolled client).

**Files.** About 22 app files, one primary type each. `nonisolated` marks pure logic that is unit-tested.

| File | Purpose |
|---|---|
| `Ferry/FerryApp.swift` | `@main`. Creates `AppModel` and starts/stops sync on `scenePhase`. `ServerConfig` (homeserver + provisioning URLs). DEBUG env hooks; renders a placeholder under unit tests (a pattern from the earlier web-wrapper prototype). |
| `AppModel.swift` | `@Observable` root: session, `accounts`, `rooms`, the sync loop, the whoami poll, and every user action (send, react, edit, unsend, accept, archive, resolve, connect, logout). |
| `MatrixAPI.swift` | Thin C-S REST: login, filter, sync, messages, event, send, redact, receipt, typing, room tags, media download/thumbnail. Also holds the shared `HTTP.send` helper and `MatrixError`. |
| `BridgeAPI.swift` | Provisioning: whoami, `login/start`, `login/step`, `login/cancel`, logout, `resolve_media`. Late v1: `search_users`, `create_dm`. Bearer is the Matrix token plus `?user_id=`. |
| `JSON.swift` | *(pure)* `enum JSON: Codable, Hashable` with subscripts, for arbitrary event content and passing `unresolved_media` back verbatim. |
| `SyncTypes.swift` | *(pure)* Codable `/sync` response, `Event`, `unsigned`, `unread_notifications`, ephemeral, room account data. |
| `Room.swift` | `@Observable final class`: state map, raw timeline window, `prevBatch`, unread, typing, receipts. *(pure)* Derives `BridgeInfo` (receiver, isRequest, isDM, roomType) plus the name and avatar. |
| `Timeline.swift` | *(pure)* `Message` display model, `MessageKind` (text, image, video, reel states, voice, …) and `Timeline.reduce([Event]) -> [Message]`. |
| `Inbox.swift` | *(pure)* Room ↔ account mapping, scope and folder filtering, sorting, unread counts, request rules (receipts/typing allowed?), archive auto-return. |
| `InstagramLogin.swift` | *(pure)* Codable login step types, `CookieGate.evaluate(step, cookies, url)`, and mapping login errcodes to copy. |
| `AccountIdentity.swift` | Per-account name, color, mark, order and show-in-All, stored in `UserDefaults` (DESIGN §14: local in v1). Also the `AccountMark`/`AccountTag`/`AccountAvatar` views (DESIGN §13 puts them in this one file). |
| `MediaCache.swift` | Authenticated download to `Caches/media/<mediaId>.<ext>`, with progress, in-flight dedupe and thumbnails. Includes the small image view that uses it. |
| `Keychain.swift` | Save, load and delete the Matrix session (token, user ID, device ID). |
| `RootView.swift` | Routes between signed-out, onboarding and the inbox `NavigationStack`. Global connection banners. |
| `OnboardingView.swift` | O1 Welcome, O2 Matrix sign-in, O4 Connecting, O5 Name & color, O6 Add another. |
| `ConnectSheet.swift` | O3/A3: SwiftUI `WebView` + `WebPage` on a non-persistent data store, cookie observation, submit, errors. |
| `InboxView.swift` | I1 list, scope bar, folder tiles and row. The same list serves I2 Requests and I4 Archived. I5 `.searchable` filters by name. |
| `ThreadView.swift` | T1/T2: timeline list (`LazyVStack`, bottom anchor), request bar, composer with the account lock and limits, Seen/typing. T3 minimal chat info. |
| `MessageViews.swift` | Bubbles, reply quote, reactions and status, plus the media cards: reel, video, photo, post, story, voice, link and unavailable. |
| `PlayerView.swift` | M1: AVKit `VideoPlayer` with an author/caption overlay, swipe-down to dismiss, and loop. M2: photo viewer. The small `VoicePlayback` controller that wraps `AVPlayer`. |
| `AccountsView.swift` | A1/A2: list with health, reorder, color/mark editor, Log in again, Remove. |
| `Assets.xcassets` | AppIcon and the account palette colors (DESIGN §8.1 names). |
| `Config/Info.plist` *(outside the synced folder, P2)* | `NSAppTransportSecurity.NSAllowsLocalNetworking = YES`. |
| *(late v1)* `NewMessageSheet.swift` | N1. |
| *(M7b)* `PhotoMessage.swift` | *(pure)* Photo send: JPEG re-encode within 8 MB and the `m.image` content. |
| *(M7b)* `Tokens.swift` | DESIGN §8.1 colour tokens (`inkSecondary`, status colours, bubble/reaction/swipe fills). |
| *(only if the M2 gate says so)* | Snapshot persistence goes into `AppModel` as two methods, not a new file. |

**Tests:** `FerryTests/`

- `Fixtures/*.json`: scrubbed real payloads from M2, plus a tiny `voice.ogg`.
- `SyncDecodingTests`, `RoomTests`, `TimelineTests`, `InboxTests`, `CookieGateTests`, `MediaKindTests`.
- `LiveServerTests`: skipped unless the local server is reachable.

`FerryUITests/SmokeUITests.swift` covers the smoke flow (§4).

### 2.3 Persistence (the least machinery that covers the need)

| Data | Where | Why |
|---|---|---|
| Matrix session | Keychain | It's a secret and must survive a relaunch. |
| Account identity prefs | `UserDefaults` (Codable) | Small and user-edited; the design says local in v1. |
| Archive | Matrix room tag `u.archived` | Kept on the server, so no local state; it arrives in sync's room `account_data`. |
| Scope selection | `@SceneStorage` | Per the design. |
| Media | `Caches/media/` | Can be downloaded again, and the OS may purge it. |
| Rooms + `next_batch` snapshot | **Only if spike S1 says so** (cold sync p50 > 3 s or > 5 MB): one Codable `Caches/snapshot.json`, written when the app backgrounds | No SwiftData. The snapshot is all or nothing, because an incremental sync without the old state is useless. |
| Instagram cookies and passwords | **Never on the device.** Non-persistent WebKit store; cookies exist only in the bridge DB | D7. |

### 2.4 Data flow

```
scenePhase .active ─▶ AppModel.startSync()           (cancelled on .background; D6 "sync on open")
  loop: MatrixAPI.sync(since, filterID, timeout: 30s) ─▶ AppModel.apply(_:) on MainActor
          per joined room: merge state (+ state events in timeline), append timeline
            (limited == true → reset window to this batch, prevBatch = timeline.prev_batch)
          unread_notifications, ephemeral m.typing / m.receipt, room account_data m.tag
          local echo matched by unsigned.transaction_id; rooms in `leave` dropped
        since = next_batch; errors → backoff 1,2,4…30 s, banner after 2 consecutive failures
  whoami poll: on .active, every 60 s while active, after connect/logout ─▶ accounts + health
SwiftUI reads AppModel/Room (Observation) ─▶ Inbox.* (lists) and Timeline.reduce(room.events) (open thread only)
User action ─▶ optimistic local echo ─▶ MatrixAPI/BridgeAPI ─▶ confirmed by the next sync
Open thread ─▶ GET /messages?dir=b&from=prevBatch&limit=50 when scrolled to top (prepend)
```

**Sync filter** (uploaded once with `POST /user/{id}/filter`):

- `room.state.lazy_load_members: true`;
- `room.timeline.limit: 20`. S1 decides the final value;
- ephemeral `m.typing` and `m.receipt`;
- room `account_data` types `["m.tag"]`;
- presence and global account data off.

### 2.5 Accounts ↔ rooms

- **Accounts** come from `GET /v3/whoami` → `logins[]`: `id` (FBID), `name`, `profile.username`/`avatar`,
  `state.state_event`. Identity prefs are joined on `id`.
- **The room → account link** is the room's `m.bridge` state (any state key) with `protocol.id == "instagramgo"` (M2/S7: the bridge's Beeper type, not `"instagram"`).
  `channel["fi.mau.receiver"]` is the login `id`.
- **Inbox inclusion:** a room is shown when it has an IG `m.bridge` **and** `com.beeper.room_type.v2 !=
  "personal_filtering_space"` **and**, once whoami has loaded, its receiver is a current login. That hides the bot
  management room, the per-login spaces and rooms from removed logins.
- **Sending needs no account choice.** The bridge routes a room through its own receiver (`split_portals`). The UI
  only *shows* the lock.
- **Invites:** with double puppeting there should be none. M2 verifies `rooms.invite` is empty. If it isn't, add
  auto-join for invites from the bridge namespace (this is a gate result, not a speculative feature).

### 2.6 Timeline reduction (`Timeline.reduce`, pure, TDD'd)

| Input | Rule |
|---|---|
| `m.room.message`, `m.sticker` without a replace relation | A base message, keyed by `event_id`, in timeline order. |
| **Edit** (`m.relates_to.rel_type == m.replace`) | Applies only if the edit's sender is the target's sender. The latest edit by timeline order wins. Render `m.new_content` in full, **including a msgtype change** (`resolve_media`: `m.image` → `m.video`, new `url`/`info`). Show "Edited" unless `com.beeper.dont_render_edited` is true. An edit that arrives before its target is held until the target loads. Edits to a redacted target are ignored. |
| **Reaction** (`m.annotation`) | Grouped by emoji key. **Keep only the latest reaction per sender per target** (IG allows one per user). Redacted reactions are dropped. Sending: the same emoji again redacts our reaction; a new emoji just sends. M4 checks whether the bridge redacts the old one, and the reducer hides it either way. |
| **Redaction** | Target from top-level `redacts` or `content.redacts` (room v11). A redacted message becomes a `.unsent` tombstone. A redacted reaction or edit is dropped. Events that arrive already redacted (`unsigned.redacted_because`) become tombstones. |
| **Reply** | `m.in_reply_to.event_id` → quote from loaded events. If it isn't loaded, show a placeholder and the view fetches `/rooms/{id}/event/{id}` lazily. Strip the reply fallback (`> ` lines and `<mx-reply>`). |
| **Local echo** | Pending items keyed by `txnId` come after server events. They're removed when an event with `unsigned.transaction_id == txnId` arrives. A failure becomes `.failed` with retry. |
| **Send status** | `com.beeper.message_send_status` (an `m.reference` to our event) sets `.delivered` or `.failed(reason)`. |
| **Seen** | A ghost's `m.read` receipt at or after our last outgoing event shows "Seen" (from ephemeral data in the Room). |
| State and unknown events | Ignored in v1 (no membership notices). |

**Media kinds** (pure classification in `Timeline.swift`):

| Kind | How it's recognized |
|---|---|
| `reel(.ready)` | `m.video` + `external_url` on instagram.com (`/reel/`, `/p/`) |
| `reel(.unresolved)` | `com.beeper.unresolved_media` present |
| `reel(.unavailable)` | `fi.mau.instagram.xma_fetch_status` is a failure |
| `reel(.tooLarge)` | The bridge's too-large notice. M2 confirms the shape. |
| `storyShare` | `external_url` contains `/stories/` |
| `voice` | `m.audio` + `org.matrix.msc3245.voice` |
| Everything else | `image`, `video`, `file`, `sticker`, `text`, `notice` |

The author and caption are parsed from the caption body. M2 captures a real sample (DESIGN §16 Q1).

### 2.7 Media and reels

- **Download:** `GET /_matrix/client/v1/media/download/{server}/{mediaId}` with a Bearer token, saved to
  `Caches/media/<mediaId>.<ext from mimetype>`. The extension matters to AVFoundation (P3).
- **Thumbnails:** `/_matrix/client/v1/media/thumbnail/…?width&height&method=scale`.
- **Playback:** AVPlayer can't add auth headers, so it **always plays from a local file** (`AVPlayer(url: file)`).

**Reel UI states:**

| State | Behaviour |
|---|---|
| Ready | Thumbnail. Tap downloads with progress, then opens M1. Cached, so the next tap is instant. |
| Unresolved | Preview with "Load video". Tap sends `POST /v3/resolve_media/{eventId}?login_id=<receiver>` with body `{"com.beeper.unresolved_media": <verbatim JSON>}` and shows "Fetching from Instagram…". The edit arrives through sync and the card becomes Ready. A 60 s timeout shows an error with retry. The transient "resolving" state lives in `AppModel`, not in the reducer. |
| Unavailable / too large | Preview (if any), caption, and "Open in Instagram" (`external_url`). |

- **Voice:** `AVPlayer` on the cached `.ogg`, with play/pause, progress and rate.
- **No eager downloads** (Beeper reversed theirs). Thumbnails load as rows appear.

### 2.8 Requests

- **`isRequest`** is `m.bridge.channel["com.beeper.message_request"] == true`. Request rooms show only in the
  Requests folder, with their own counts (not in main-list or scope-chip unread).
- **Never send `m.read` or typing in a request room**: the bridge forwards them to IG as "Seen" (bridge §2). This
  is enforced in one pure function, `Inbox.allowsReceipts(room)`, with tests.
  - M6 hypothesis: `m.read.private` clears our unread count without reaching the bridge. It's adopted only if the
    bridge logs and the requester's IG both show nothing.
- **Accept:** send `com.beeper.accept_message_request` with content `{}`, moving the room optimistically. The flag
  flips when the bridge re-sends `m.bridge`.
- **Replying:** the composer warns "Replying accepts this request" (the bridge auto-accepts).
- **Delete:** `com.beeper.delete_chat`. Its shape and IG-side effect get checked in M6 before it's wired up (DESIGN
  §16 Q3).

### 2.9 Instagram connect flow (D7)

1. `POST /v3/login/start/instagram` (to re-login: `?login_id=<fbid>`) returns a `cookies` step with `url`,
   `fields[]` (`id`, `required`, `sources[{type: cookie, name, cookie_domain}]`) and `wait_for_url_pattern`.
2. **ConnectSheet:** a SwiftUI `WebView(page)` with `WebPage` on a **fresh `WKWebsiteDataStore.nonPersistent()`
   per attempt**, using WebKit's default UA (don't spoof). Load `url`. The user types their own credentials and 2FA.
   Instagram's own UI handles checkpoints.
3. **Each time the URL changes, a load finishes or cookies change**, read `httpCookieStore.allCookies()` and call
   `CookieGate.evaluate`:
   - `.waiting(missing:)`, or `.ready([id: value])` once **all required cookies** (`sessionid`, `csrftoken`,
     `ds_user_id`) are present on a domain matching `cookie_domain` **and** the URL matches the pattern.
     `/accounts/onetap/` doesn't match.
   - Optional cookies (`rur`, `shbid`, `shbts`, `mid`, `ig_did`) are included when present.
   - A "Done" button is enabled once the required cookies exist, because the spec allows submitting on close.
4. **Submit** `POST /v3/login/step/{login_id}/{step_id}/cookies` with the flat map:
   - `complete` → `user_login_id`;
   - an error `errcode` → copy for rate limited, challenge, checkpoint, consent, suspended or token invalidated;
   - any other step → a generic error plus cancel.
5. **Cancel** on dismiss: `POST /v3/login/cancel/{login_id}`. **Never navigate to IG logout.** The data store dies
   with the page.
6. **Then** refresh whoami and show O4 (CONNECTING/BACKFILLING → CONNECTED), then O5.

### 2.10 Connection state

| Source | Maps to | UI (DESIGN §7) |
|---|---|---|
| whoami `CONNECTED` | ok | none |
| `CONNECTING`, `BACKFILLING` | syncing | spinner on the chip / O4 |
| `TRANSIENT_DISCONNECT` | transient | quiet glyph; banner only if it lasts more than 2 min |
| `BAD_CREDENTIALS`, `LOGGED_OUT` | needs login | red banner naming the account, with "Log in again" (re-login with `login_id`) |
| `UNKNOWN_ERROR` / other | error | banner with `state.message` |
| Sync failing twice | server unreachable | "Can't reach your server" banner |
| Provisioning fails or `BRIDGE_UNREACHABLE` | bridge offline | "Instagram bridge is offline" banner |

### 2.11 How the app reaches the server

- **v1 (simulator):** the simulator shares the Mac's network, so the app uses `http://localhost:8008` and
  `http://localhost:29330/_matrix/provision`. Docker binds both to 127.0.0.1. ATS is satisfied with
  `NSAllowsLocalNetworking` (P2).
  - DEBUG builds can override both URLs with the env vars `FERRY_HOMESERVER` / `FERRY_PROVISIONING`.
  - A side benefit: the WKWebView login and the bridge come from the **same residential IP**.
- **Later (device):** `tailscale serve` on the Mac gives HTTPS at `https://<mac>.<tailnet>.ts.net`, routing `/` to
  8008 and `/_matrix/provision` to 29330. That means one base URL, a valid certificate and no ATS exception.
  - Avoid LAN HTTP: it needs ports bound to 0.0.0.0 (exposed on the LAN) plus Local Network permission.
  - A free Apple team means device builds expire every 7 days.

---

## 3. Milestones

Every milestone ends with:

- tests green;
- "Verified on simulator" notes;
- docs trio updated (`README.md`, `CLAUDE.md`, `specs.md`);
- one commit (imperative subject, a body with root causes, and a "Verified on simulator / tests" line).

**Shared commands:** see README "App" (a zsh-safe `t()` function). Learned in M1: DerivedData must live **outside
`~/Documents`** (a failing test otherwise hangs the host for 10+ min while symbolicating), and always pass
`-parallel-testing-enabled NO -collect-test-diagnostics never`.

- Screenshot: `xcrun simctl io $SIM screenshot docs/verification/<m>-<screen>.png`

**Install announcements:**

- M0 pulls the three images in §2.1, exact tags and digests stated.
- M2/M8 may pull `golang:<exact version>-alpine`. Announce it before pulling.
- No other installs: `jq` and `ffprobe` are already on the Mac.

### M0. Repo and server stack (0.5–1 d)
- **Goal:** Synapse, Postgres and the bridge running locally, with one idempotent script.
- **Tasks:**
  - `git init` (the repo isn't one yet) and commit the docs.
  - Write `docker-compose.yml` (digests resolved), `bootstrap.sh`, `mx.sh` and `.env.example`.
  - Fetch the bridge's `login/start` response with curl and save it as the first fixture (needed in M1).
- **Exit:**
  - `./server/bootstrap.sh` prints `OK`. A second run prints "already done" for every step and changes nothing
    (`git status` clean, config mtimes unchanged).
  - `docker compose -f server/docker-compose.yml ps` shows 3 services up.
  - `grep -n 'split_portals: true' server/data/instagram/config.yaml` matches.
  - `git check-ignore server/.env server/data` matches both.
  - `docker stats --no-stream` memory recorded in the README (expect under 1.5 GB of the 4 GB).
- **Commit:** "Add self-hosted Synapse + mautrix-instagram stack".

### M1. App skeleton, Matrix sign-in, Connect Instagram, then the user logs in (1–1.5 d)
- **Goal:** real IG accounts bridged as early as possible.
- **Tasks:**
  - Write the hand-made project (Appendix A) with the 3 targets.
  - Build `FerryApp`, `Keychain`, `MatrixAPI` (login, whoami), `BridgeAPI` (whoami, login start/step/cancel),
    `InstagramLogin` (**TDD `CookieGate` first**), `ConnectSheet`, a bare `AccountsView` (name, @username, avatar,
    state) and a bare O2 sign-in.
- **Exit (before hand-off):**
  - `CookieGateTests` pass. Cases:
    - missing required cookie;
    - all required on `/accounts/onetap/`;
    - all required on `/direct/inbox/` → ready, with the optionals present included;
    - a cookie on a foreign domain is ignored;
    - a pattern URL with a query string.
  - The login-step fixture decodes.
  - In the simulator: sign in, and Connect opens the instagram.com login page (screenshot).
  - The UI-test target builds (P1 gap closed).
- **HAND-OFF A (the user, about 20 min).** Prep, *before* logging in:
  - From a **third, non-bridged dummy account**, send a DM to `tamoveska` and to `kivostudio` so each has a
    pending request (S6).
  - On `kivostudio`, make sure one thread is in **General** and one is in **Primary** (S5).
  - Send a voice note and share a reel into a thread on each account (backfill samples).

  Then in the simulator, log in to `tamoveska`, then `kivostudio` (the agent never types IG credentials). After
  login, share **a public reel, a post, a story and a voice note** into the `tamoveska`↔`kivostudio` thread, plus
  a reel from a **private account** that the receiving account doesn't follow.
- **Exit (after hand-off):**
  - `./server/mx.sh`-style provisioning whoami lists 2 logins with `CONNECTED`.
  - Both show in Accounts with their avatars.
  - `docker compose logs mautrix-instagram | grep -iE 'checkpoint|challenge'` is empty.
- **Commit:** "Add Matrix sign-in and Instagram connect flow" (Verified on simulator with both accounts).

### M2. Live-data spikes and fixtures (1 d)

These are curl, jq and log work, with no app UI. The output is `docs/spikes/2026-10-xx-live-bridge.md`: numbered
findings, each with an outcome.

| Spike | Method | Decides |
|---|---|---|
| **S1 initial sync** | `time ./server/mx.sh "/_matrix/client/v3/sync?filter=…" -o /tmp/s.json` ×3, with timeline limits 1 and 20. Record bytes, seconds and room counts. | Final timeline limit. **Snapshot persistence only if p50 > 3 s or > 5 MB** (record it as D8). |
| **S2 fixtures** | Cut a minimal event set from real sync and `/messages` output: DM, group, request room, live reel, unresolved reel, unavailable reel, voice, reaction, edit, redaction, reply, `message_send_status`, `m.bridge` and the personal space. Scrub it, then check that `grep -rE 'syt_\|sessionid\|access_token' FerryTests/Fixtures` returns nothing. | Unit-test inputs for M3–M6. |
| **S3 reel media** | Download a live reel through `/v1/media/download` with curl, then `ffprobe` it. Call `resolve_media` on a backfilled reel and watch the edit arrive (msgtype change). | Confirms the §2.7 paths. Answers DESIGN §16 Q1 (the caption sample). |
| **S4 voice** | Download a bridged voice note, `ffprobe` it (expect Ogg/Opus), and copy a short one into the fixtures. | Confirms P3 on real data. The final check is playback in M5. |
| **S5 Primary/General (`kivostudio`)** | (a) Is the General thread bridged at all? (b) Raise the bridge to `logging.min_level: trace` and grep for `ig_inbox_folder\|messaging_folder_tag\|"folder"`. (c) If those fields don't show, build a debug image (the M8 Dockerfile) that logs those three fields per thread. This brings the Go-in-Docker build risk forward. | **Gate (record as D9):** **A**, IG sends the split → the M8 patch goes ahead. **B**, threads are bridged but there's no folder info → v1 stays All/Requests and the limitation is documented. **C**, General threads aren't bridged at all → escalate to the user (needs a patch to include them, or a documented gap). |
| **S6 pre-existing requests** | Did the pre-login requests become rooms with `message_request: true`? If not, the requester sends again: does a room appear now? | A design footer note (I2); possibly patch scope. |
| **S7 bridge shape** | `jq '.rooms.invite\|length'` is 0 (double puppet works). Your own IG-app sends appear with your MXID. Check what `m.bridge` looks like on DM, group and space rooms. `whoami` state: are there backfill counts? (DESIGN §16 Q4) | Confirms §2.5. Auto-join only if needed. |

- **Exit:**
  - The spike doc is committed.
  - DECISIONS D8 (persistence) and D9 (Primary/General) are added.
  - The fixtures are committed and scrubbed.
- **Commit:** "Record live bridge spike findings and fixtures".

### M3. Sync engine and inbox (2 d)
- **Goal:** a read-only unified inbox on real data, built to DESIGN I1/I2/I4 (stock-first).
- **Tasks:**
  - Spend about 30 minutes reviewing `design/mockups.html` for I1, I2 and the identity components, and note any
    differences in §7.
  - TDD: `SyncDecodingTests`, `RoomTests` (BridgeInfo, naming, avatar) and `InboxTests` (mapping, scope/folder
    filters, sort, unread, requests excluded from main counts, hidden spaces/bot/removed-login rooms, archive
    auto-return).
  - Then the `AppModel` sync loop, the whoami poll, `AccountIdentity` (palette and marks per DESIGN §3), and
    `InboxView` (scope bar, Requests/Archived tiles, rows).
  - Snapshot, if D8 calls for it.
- **Exit:**
  - Tests green.
  - The simulator shows both accounts' chats with the correct marks.
  - The Requests tile count equals `./server/mx.sh … | jq '[…message_request==true]|length'`.
  - Send a test message from `tamoveska`'s room by CLI (`mx.sh PUT …/send/m.room.message/<txn>`). It
    **round-trips through IG** and its room in `kivostudio` jumps to the top with an unread badge within about 5 s.
  - Cold-launch time to inbox recorded.
- **Commit:** "Add sync loop and unified inbox".

### M4. Thread: timeline and sending (2 d)
- **Tasks:**
  - TDD `TimelineTests` for every row of §2.6, using the S2 fixtures. One test per rule, including a backfill edit
    that comes before its target, and the `m.image`→`m.video` edit.
  - Then: `ThreadView`, text bubbles, back-pagination, the composer lock ("Message as X"), the 1000-char limit,
    reply, react (context-menu palette), edit (within 15 min, at most 5 times), unsend, local echo with
    retry/failed, `message_send_status`, "Seen", typing display, and `m.read` on open (non-request rooms only).
- **Exit:**
  - Tests green.
  - In the simulator, in the `tamoveska`↔`kivostudio` pair:
    - a message sent from one account's room shows pending → sent → delivered, and appears as incoming in the
      other account's room;
    - reply, react, change reaction (only one per user shown on both sides), edit and unsend all mirror across;
    - "Seen" appears after the thread is opened on the other side.
- **Commit:** "Add thread view with send, reply, react, edit, unsend".

### M5. Media: reels, video, photos, voice (2 d)
- **Tasks:**
  - TDD `MediaKindTests` (the classification table in §2.6).
  - Then: `MediaCache`, reel/video/photo/post/story/voice/link/unavailable cards, `PlayerView` (VideoPlayer + overlay
    + loop + swipe-down dismiss), resolve_media with the resolving/timeout state, and voice playback with AVPlayer.
- **Exit:**
  - Tests green.
  - The live reel plays. A second tap plays with networking off (file present under the app container's
    `Library/Caches/media`).
  - The backfilled reel goes "Load video" → resolves in place → plays.
  - The private-account reel shows Unavailable with a working "Open in Instagram".
  - A voice note plays and seeks.
  - A photo opens full screen.
  - If voice fails on real data, fall back to `AVAudioFile` decode → `AVAudioPlayerNode` (still zero-dep). Record it
    as a spike finding.
- **Commit:** "Add media cards, reel resolve, players".

### M6. Requests, account management, connection health (1.5 d)
- **Tasks:**
  - TDD request rules (`allowsReceipts`/typing, counts, accept transition).
  - Then: I2/T2 UI, Accept, the reply-accepts warning, and Delete if S6/M6 checks pass.
  - Connection banners (§2.10), A3 re-login (`login_id`), Remove account (with a confirmation that says what is
    deleted).
  - Matrix sign-out.
- **HAND-OFF B (the user, about 10 min):**
  - From the third account, send a new request to each bridged account.
  - While the agent opens those request threads in the app, check on the third account that **no "Seen"** appears.
  - Then the agent taps Accept and the user confirms it on IG.
- **Exit:**
  - Tests green.
  - Bridge logs show no receipt handling for the request rooms.
  - Accept moves the room to Chats in the app and on IG.
  - `docker compose stop mautrix-instagram` → the "bridge offline" banner appears within 60 s; `start` clears it.
  - Re-login via "Log in again" works (the user types their credentials).
  - Answers recorded: does logout revoke the IG session? What does `delete_chat` do on IG? (DESIGN §16 Q2/Q3)
  - The `m.read.private` hypothesis is recorded, adopted or rejected.
  - Remove-account is tested last and optionally (re-adding means another IG login, which is a checkpoint risk).
- **Commit:** "Add requests, account management, connection banners".

### M7. Design pass, onboarding and UI tests (2–3 d)
- **Tasks:**
  - Fold in `mockups.html`.
  - Onboarding O1–O6 (no O7).
  - The full identity system and the color/mark editor.
  - Archive via `u.archived` with auto-return.
  - I5 search by name, T3 chat info, empty and loading states (`ContentUnavailableView`, `.redacted`).
  - Haptics, accessibility labels (DESIGN §3.7, §11), Dynamic Type, app icon (re-paletted `make_icon.py` approach).
  - Then the late-v1 items if time allows: N1 New message, sending photos.
  - Verify DESIGN §16 Q6/Q7 (`safeAreaBar`, `Picker(.palette)` in context menus) on iOS 26.4.
- **Exit:**
  - `$T test -only-testing:FerryUITests` green.
  - Screenshots of every v1 screen in `docs/verification/`, compared side by side with the mockups. Differences are
    listed and either fixed or accepted.
  - VoiceOver spot check on the inbox row and a bubble.
- **Commit:** "Apply design system, onboarding, UI smoke tests".

### M8. Primary/General (only if gate D9 = A) (1–3 d, uncertain)
- **Tasks:**
  - `server/bridge/Dockerfile`: a multi-stage build. A `golang:<pinned>` stage clones `mautrix/meta` at tag
    `v0.2609.0`, runs `git apply` on our patch and builds `./cmd/mautrix-instagram` with upstream's build flags. The
    final stage is `FROM dock.mau.dev/mautrix/meta:ig-v26.09@sha256:…` and copies the binary over `/usr/bin/mautrix-meta`.
  - The patch, kept minimal:
    - put `ig_inbox_folder` into `m.bridge` `channel` through `PortalBridgeInfoFillingNetwork`;
    - expose the professional flag in `RemoteProfile`/state info;
    - fetch the General folder too if S5(a) showed it's missing.
  - Client: a `folder` field in `BridgeInfo`, the General tile, the main list becomes Primary for those accounts, and
    account-type labels.
  - Existing portals may need a chat-info resync for the new field to appear; document how.
- **Exit:**
  - `docker compose build && up -d`. The `kivostudio` General thread shows under the General tile, and Primary
    threads under Chats.
  - `tamoveska` is unchanged.
  - Tests for the new field pass.
- **Commit:** "Patch bridge for Instagram Primary/General folders".
- **Q3:** offer the patch upstream.
- **Done 2026-10-13 (D12, v1.1):** builder `golang:1.27.1-alpine3.24@sha256:8a5910f3…` (upstream's toolchain);
  `inbox-folder.patch` about 75 lines plus a Go test; the `m.bridge` key needed one field in the vendored
  mautrix-go. The professional flag rides in the bridge-state `info` (whoami), not `RemoteProfile` (a closed struct).
  The General thread was never missing (S5a), so no extra fetch. Starting tab not applied: live moves only (spike
  S5(d)). "Existing portals need a resync": not for live moves (each one re-sends `m.bridge`). The live move itself
  is Hand-off C (manual-verification (g)).

### M9. Docs, runbooks, hardening (0.5–1 d)
- **Tasks:**
  - Docs: README (setup, architecture ASCII, known fragility), `CLAUDE.md` (commands, invariants, traps:
    `split_portals`, server name, `-parallel-testing-enabled NO`), `specs.md` (as built).
  - `docs/manual-verification.md` (§4 checklist).
  - `docs/runbook-bridge-upgrade.md` (§5).
  - Optional stretch: the Tailscale device setup (§2.11).
- **Exit:** a fresh clone, `bootstrap.sh`, build, run and the full live checklist passes. Then tag `v1.0`.

---

## 4. Testing strategy

| Layer | What | How |
|---|---|---|
| **Unit (most of the value)** | Sync decoding, room/bridge info, timeline reducer, inbox/account mapping, request rules, cookie gating, media-kind classification | Pure `nonisolated` functions fed with scrubbed real JSON fixtures from M2. No mocks and no network. Table-style cases with a counter-case next to each rule (the earlier web-wrapper prototype's style). |
| **Regression** | Every fixed bug | A test whose doc comment tells the story (root cause plus the fixture that reproduces it). |
| **Live integration** | `LiveServerTests`: login, sync, `whoami` returns ≥1 CONNECTED login, media download | Reads `FERRY_MATRIX_TOKEN` (passed as `TEST_RUNNER_FERRY_MATRIX_TOKEN=…`). `XCTSkip` with an actionable message if the token is missing or `localhost:8008` is unreachable. **Read-only:** it never sends IG messages. |
| **UI (minimal)** | `SmokeUITests`: (1) launch with an injected session → the inbox shows ≥1 row → open it → a bubble exists; (2) open the Connect sheet → a web view exists → cancel | DEBUG session injection, so nothing is typed at all. `XCTSkip` if the server is down. **UI tests never type IG credentials, and nothing anywhere stores IG passwords.** Accessibility identifiers go on every interactive element. |
| **Manual live checklist** | `docs/manual-verification.md`, run at M6, M7 and M9 | See below. Evidence comes from `simctl io screenshot`. |

**Manual live checklist** (each row records a result for personal **`tamoveska`** and business **`kivostudio`**):

1. Connect works; name, @username and avatar are shown; state is CONNECTED.
2. The chats appear under the right account mark; the scope bar filters correctly.
3. A cross-account round trip: sending from A's room arrives in B's room, and vice versa.
4. Reply, react (a changed reaction leaves one per user), edit and unsend mirror across, and in the IG app.
5. Live reel: plays, and works offline the second time. Backfilled reel: Load video, then it plays. A reel from a
   private, non-followed account shows Unavailable plus a link. Also: post share, story share, an expired story.
6. A voice note plays (the real bridged Ogg/Opus).
7. A new request lands in the right account's Requests. No "Seen" on the requester's side. Accept works. Replying
   shows the warning.
8. A pre-existing request (from before login) behaves as recorded in S6.
9. **`kivostudio` only:** where the General and Primary threads land (D9 outcome).
10. A group with both accounts in it gives two rooms, each replying as its own account (`split_portals`).
11. Bridge stopped → banner, then recovery. Synapse stopped → banner, then recovery. Re-login flow works.
12. Reading in the IG app clears unread in our app (double puppet). Unread counts match IG after a relaunch.

Run tests with `-parallel-testing-enabled NO` (P4). Treat flaky externals as skips, never as red.

---

## 5. Risks and mitigations

| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| **IG checkpoint or ban** on the dummy accounts | Medium / high | Dummy accounts only. The user does every login by hand; nothing automated logs in. The simulator and the bridge share the Mac's residential IP. `disable_xma_backfill` stays on. Backfill is capped at 50 messages. No repeated login/remove cycles (M6 remove test is last and optional). Enable 2FA on the dummies. |
| **Meta protocol churn** breaks the bridge | High / high | Images pinned by digest. **Upgrade runbook:** read `CHANGELOG.md`; `pg_dump` the bridge DB (its migrations are forward-only); bump tag and digest; `docker compose pull && up -d`; run `bootstrap.sh` (self-check) plus checklist items 1, 3 and 5; if it fails, roll back to the old digest and restore the dump. The M8 patch, if any, is rebased per release (keep it tiny, upstream it). |
| **`split_portals` and `SERVER_NAME` are irreversible** | Low / high | Both set by bootstrap before the first login. The script aborts if `split_portals` isn't true. The server name is confirmed in Q2 before M0. |
| **Primary/General isn't available, or General threads aren't bridged at all** | Medium / medium | Captured in M2 (S5), not discovered late. The gate (D9) has three explicit outcomes. The design needs no relayout. |
| **The `resolve_media` edit changes msgtype** | Certain / medium | A reducer rule plus fixture tests (§2.6). |
| **Pre-existing requests aren't bridged** | Medium / low | S6 records the behaviour. The I2 footer note, plus maybe a patch line. |
| **Read receipts leak "Seen" in requests** | Certain if unhandled / medium | One pure rule with tests, plus the Hand-off B verification. |
| **Hand-rolled client correctness** (gaps, echo) | Medium / medium | No gap tracking: a `limited` sync resets the window. Pure reducer with fixtures. Local echo keyed on the transaction ID. |
| **Cold start is slow without a store** | Medium / low | S1 measures it. The snapshot ships only if the numbers say so. |
| **Thread-list backfill bug #374** (old chats missing) | Medium / low | Documented. The design has the footer wording. |
| **Voice playback differs on a device** | Low / low | P3 passed on the simulator. Fallback: `AVAudioFile` + `AVAudioPlayerNode`. A dependency only if both fail on hardware. |
| **The Mac sleeps, so the bridge disconnects** | Certain / low (v1) | Accepted for D3. Banners show it. Fixed by the always-on host later. |
| **Cookie or token exposure** | Low / high | The IG session lives only in the bridge DB (`server/data`, gitignored). Provisioning uses the Matrix token, never the shared secret. Ports bound to 127.0.0.1. Backups treated as sensitive. |

---

## 6. Open questions for the user (short)

1. **Third dummy account:** is there an IG account that **isn't** bridged, to send requests to `tamoveska` and
   `kivostudio` (S6, Hand-off B)? Are any of the dummies **private**? *(Asked at design review.)*
2. ~~Matrix server name~~ → **`igm.home.arpa`** (lead's default: never federates; app connects by URL).
3. ~~**If the bridge patch is needed (M8):** upstream PR or local patch?~~ → **local patch now**, small enough to
   upstream later (user, 2026-10-13; D12).
4. ~~Git~~ → **local commits only** (user, 2026-10-12). Never push without asking.
5. ~~iOS target~~ → **iOS 26.0 OK**: the user's paired iPhone runs iOS 27.0 (`devicectl`).

---

## 7. Design integration

**Status:**

- [design/DESIGN.md](design/DESIGN.md) v1 has been read and is already reflected above: screen IDs, the §13 SwiftUI
  mapping, §14 fallbacks first, §15 bridge register.
- `design/mockups.html` (delivered 2026-10-12) reviewed by the lead: consistent with DESIGN.md and this plan;
  shared with the user for review. Mockup elements that are
  **not v1** per §1: inline reel autoplay in bubbles (v1: tap → full-screen player), the General tile (M8 gate),
  Auto-download / Storage settings (v1: no eager downloads, so omit), per-account notification toggles (D6).
  M3–M6 build screens to DESIGN.md + mockups; M7 is the polish pass.
- If the mockups change any screen below, update this section and the affected milestone.
- **M3 differences from the mockups (I1/I2/I4):** the scope bar uses `safeAreaInset`, not `safeAreaBar` (under a large
  title, `safeAreaBar` put the title in the iOS 26 scroll-edge blur: Q6 answered). The Requests tile counts all
  requests in scope, like the mockups and the M3 exit (DESIGN §4.2 text says "unread"). Chip counts hide at 0. Not yet
  built: the trailing filter menu, the bottom search/compose bar (M7), group double avatars (no live group), "by
  @author" in reel previews (M5), I2 Accept/Delete rows (M6), the banner's "Later" (M6), and the custom
  `inkSecondary` token (M7; rows use system `.secondary`). The palette is defined in code (`AccountColor`), not the
  asset catalog.

- **M4 differences from the mockups (T1):** the header is one toolbar row (avatar 30, name, AccountTag) instead of the
  stacked avatar/pill/tag, which doesn't fit a navigation bar. Not yet built: the trailing ⋯ menu, the composer's `+`
  and mic (late v1 / out), the scroll-to-bottom button, the "+" for more reactions, the who-reacted sheet, swipe to
  reply (§14 fallback: context menu), and the 24 pt group avatars (no live group). Added: a status line under our last
  message ("Sending…/Sent/Delivered/Seen") for the M4 exit check, and a start-of-chat header once history is fully
  loaded. Request threads are read-only placeholders until M6 (see CLAUDE.md: the bridge marks chats read on every
  send). DESIGN §16 Q7 answered: `Picker(.palette)` renders as an emoji row in a context menu on iOS 26.4.

- **M5 differences from the mockups (M1, M2, media cards):** the player is a `fullScreenCover` with its own drag (down
  or up, D10) instead of the zoom transition, on `AVPlayerLayer` (not `VideoPlayer`, whose controls would sit under the
  caption and take the drag). It has close, mute, author and caption, "Open in Instagram", "Shared by …" with the
  AccountTag, and a scrubber; no Reply/React/Share row, more menu, first-time hint, double-tap react or long-press hide.
  After "Load video" the card swaps in place but doesn't auto-play (one more tap downloads and plays). Reel cards have
  no author avatar (the bridge sends none) and no duration pill (reels carry no duration). Voice bars are static (the
  bridge drops the waveform). Not built: inline playback, the gallery grid, the 1 GB LRU limit (the OS purges Caches),
  Save, story expiry labels (no expiry time in the event). The photo viewer has close and Share only. View-once and
  plain too-large cards link to the Instagram inbox (no deep link exists).

- **M6 differences from the mockups (I2, T2, A1–A3, banners):** I2 has no "Select" or "Delete All" (not asked for; a
  bulk delete is risky), and its explainer is dismissed once, not per account. T2 matches; "Reply instead" opens the
  composer under a "Replying accepts the request." bar whose ✕ returns to the request bar. The Delete confirmation adds
  "They may see it as read" (the bridge marks the chat read before deleting it). A1 has no drag-to-reorder and no
  Privacy / Reels / Storage sections (M7 or out); its footer shows user and server (whoami carries no bridge version)
  plus Sign Out. A2's identity editor is plain (name, 8 swatches, mark; no live preview, no "Used by"), no
  notification toggles (D6). A3 has no repeat-offender footnote. Banners: the error banner uses DESIGN's copy and the
  bridge's technical message moves to A2's status card (§2.10 said "banner with state.message"); no "Retry now"
  (provisioning has no reconnect endpoint). Added: the thread recovery bar for a signed-out account (DESIGN §7.2), and
  the re-login sheet's title names the account ("Log in as @handle"). `m.read.private` works as hoped at the bridge
  (never forwarded) but isn't used: request rooms send nothing (user's rule); the user can opt in.

- **M7a differences from the mockups (O1–O6, I1/I4/I5, T3, A1/A2, icon):** O1 matches (static-size illustration,
  drift-in spring, fade under Reduce Motion). O2 is shown only without a session and says it isn't the Instagram login;
  no "use a different server" (the server is fixed per build). O3 is unchanged (M1). O4's third step counts the chats
  that have arrived (no backfill counts, S7.8); "Copy details" copies the bridge state. O5 swatches are 2 rows of 4
  (DESIGN text; the mockup row of 8 is too tight for 44 pt targets), and a taken swatch is a 40% fill with the owner's
  mark in the full color (white on the faded fill couldn't be read). O5's buttons hide while the keyboard is up, so
  the "already used" note isn't covered. O6 matches. "Add Instagram account" in A1 opens the new account's A2 page (same
  editor) instead of O4/O5. A1 reorders by touch-and-hold drag (no Edit button); no Privacy/Reels sections. I5 has no
  `.searchScopes` (the scope bar already scopes it) and no Messages section (name search only); archived chats are
  found, requests aren't. Search sits in the bottom bar (iOS 26); no compose button yet (N1, M7b). I1 has the swipe
  and context Archive only (no Mute, Pin, Mark unread, Delete chat). T3 has contact, "In <AccountTag>", "Open in
  Instagram" only when the handle is known (DMs between our own accounts; the bridge doesn't expose usernames), and
  Archive; no mute, search in chat, shared media, members. T1 gained the ⋯ menu (Chat Info, Archive). The scope bar is
  a plain row while the chips fit. Empty scope with archived chats says "All caught up" and points to Archived.
  Not built: the 1 GB media LRU (the OS purges Caches), identity sync via account data (§14: local in v1).

- **M7b (N1, photos, tokens, screenshot exit):** every v1 screen beside its mockup frame in
  [verification/m7-design-diff.md](verification/m7-design-diff.md): 16 fixed, 17 accepted, 3 deferred. N1 matches the
  mockup panel; search starts at 2 characters (each is an Instagram request) and a result we already have a DM with
  opens our room without `create_dm` (the bridge's search omits `dm_room_mxid`). Composer `+` opens PhotosPicker
  directly (no Camera/GIF menu, no mic); the picked photo waits in a bar above the field, text goes as its own message.
  T2 names the requester by @handle once their ghost profile has it (`ghost_extra_profile_info: true`, bootstrap).
  A1 has an inline title; A3 a ✕. Small secondary and status text moved to AA-passing tokens.

- **M8 differences from the mockups (I1 General tile, I3):** the tile uses `tray.full` (DESIGN §8 symbol list; the
  mockup draws a plain tray) and shows the unread General count, 0 included, like Requests. It shows in a professional
  account's scope **and in All** (DESIGN §4.3: All's General lists every professional account's General chats; the
  All mockup predates it), never for a personal account alone, unless a General chat exists ("data wins", §4.4).
  The subtitle gains "· Primary" in a professional account's scope. I3 has Archive/Unarchive but no "Move to
  Primary" (the bridge can't move chats on Instagram; FOLLOWUPS). No account-type labels in Accounts yet.

**Screens the plan assumes:**

| Screen | Milestone | Notes |
|---|---|---|
| O1 Welcome | M7 | |
| O2 Matrix sign-in | bare in M1, polished in M7 | |
| O3 Connect sheet | M1 | |
| O4 Connecting | M7 | |
| O5 Name & color | M7 | |
| O6 Add another | M7 | |
| O7 notification pre-prompt | **skipped** | D6 |
| I1 Inbox + scope bar + folder tiles | M3 | |
| I2 Requests | M3 list, M6 actions | |
| I3 General | M8, gated | |
| I4 Archived | M3 list, M7 actions | |
| I5 Search (by name) | M7 | |
| N1 New message | late v1, M7 | |
| T1 Thread | M4 | |
| T2 Request thread | M6 | |
| T3 Chat info (minimal) | M7 | |
| M1 Reel/video player | M5 | `VideoPlayer` fallback |
| M2 Photo viewer | M5 | |
| A1 Accounts | bare in M1, full in M6/M7 | |
| A2 Account detail | M6/M7 | |
| A3 Re-login | M6 | |

**Components assumed:**

- AccountMark, AccountTag and AccountAvatar (one file);
- scope bar (fallback: segmented `Picker`), folder tiles, chat row, connection banner;
- message bubble with grouping, reply quote, reaction pills and status line;
- reel card (ready / unresolved / resolving / unavailable / too large), video, photo, post and story cards, voice
  bubble (static bars), link card;
- composer (lock chip, 1000-char counter, request warning).

**Engineering findings to feed back to the designer:**

1. Voice needs **no transcode**: `AVPlayer` plays the bridge's Ogg/Opus directly (P3). That replaces DESIGN §6.8/§13
   "AVAudioPlayer + transcode on download".
2. Without push there's no **app-icon badge** in v1; in-app counts only.
3. Answers to DESIGN §16 engineering questions:

   | Question | Answered in |
   |---|---|
   | Q1 caption sample | S3 |
   | Q2 logout revocation | M6: **no**. `POST /v3/logout` → `UserLogin.Logout` → igconnector `LogoutRemote` only disconnects and drops the cookies ("TODO actual logout request?", `pkg/igconnector/client.go:398-402`, v0.2609.0); the session stays valid at Instagram until it expires or is ended in Instagram's login activity. With our `cleanup_on_logout` the login's rooms and space are deleted from the server (`bridgev2/userlogin.go:289-343`). A2 copy says both. |
   | Q3 `delete_chat` | M6: Instagram web's "Delete chat" for this account (`IGDInboxInfoDeleteThreadDialogOffMsysMutation`, `should_move_future_requests_to_spam: false`; groups are left first), then the bridge deletes the portal and its Matrix room (`igconnector/handlematrix.go:350-374`, `bridgev2/portal.go:1988-2032`). The other person keeps the thread; content flags are ignored. The implicit read receipt runs first (`portal.go:874`). |
   | Q4 backfill counts | S7 |
   | Q5 bridge patch | gate D9 |
   | Q6/Q7 iOS 26 APIs | M7 |

4. Identity prefs are stored locally in v1, per DESIGN §14.

---

## Appendix A. Project file template (verified as P1; names changed from the scratch project)

The project is `Ferry.xcodeproj/project.pbxproj`, written by hand in M1. **Objects:**

- `PBXProject`: objectVersion 77, `preferredProjectObjectVersion = 77`, `minimizedProjectReferenceProxies = 1`.
- `PBXFileSystemSynchronizedRootGroup` ×3, one each for paths `Ferry`, `FerryTests` and
  `FerryUITests`.
- `PBXNativeTarget` ×3, each with `fileSystemSynchronizedGroups = (<its group>)` and empty Sources, Frameworks and
  Resources phases. The test targets depend on the app through a `PBXTargetDependency` and `PBXContainerItemProxy`.
- Two `PBXFileReference` products, plus the main and Products `PBXGroup`s.
- An `XCConfigurationList` (Debug/Release) per project and per target.

**Build settings:**

| Level | Settings |
|---|---|
| **Project** | `SDKROOT = iphoneos`, `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"`, `SUPPORTS_MACCATALYST = NO`, `ALWAYS_SEARCH_USER_PATHS = NO`, `IPHONEOS_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`; Debug: `ONLY_ACTIVE_ARCH = YES`, `ENABLE_TESTABILITY = YES`, `SWIFT_OPTIMIZATION_LEVEL = -Onone`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"` |
| **App** | `PRODUCT_BUNDLE_IDENTIFIER = "$(FERRY_BUNDLE_PREFIX).ferry"`, `GENERATE_INFOPLIST_FILE = YES`, `INFOPLIST_FILE = Config/Info.plist`, `INFOPLIST_KEY_UILaunchScreen_Generation = YES`, `INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait`, `TARGETED_DEVICE_FAMILY = 1`, `CODE_SIGN_STYLE = Automatic`, `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1`, `LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks"`, `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` |
| **Unit tests** | `$(FERRY_BUNDLE_PREFIX).ferry.tests`, `BUNDLE_LOADER = "$(TEST_HOST)"`, `TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Ferry.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Ferry"`, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` |
| **UI tests** | `$(FERRY_BUNDLE_PREFIX).ferry.uitests`, product type `com.apple.product-type.bundle.ui-testing`, `TEST_TARGET_NAME = Ferry` (not covered by P1; verify in M1) |

- **Base configuration** (since the Ferry rename): the project's Debug and Release use `Config/Base.xcconfig`
  (`FERRY_BUNDLE_PREFIX = com.example`, empty `DEVELOPMENT_TEAM`), which ends with `#include? "Local.xcconfig"`: the
  gitignored per-developer file (template `Config/Local.example.xcconfig`) sets both.
- **No shared scheme:** `xcodebuild` auto-creates `Ferry` including the test targets. Add a shared
  `.xcscheme` only if a test plan or env vars ever require it.
- **Non-Swift resources** in synced folders (`Assets.xcassets`, fixture JSON, `.ogg`) are bundled automatically.
- **`Config/Info.plist`** must stay **outside** the synced folders, or it gets copied as a resource and the build
  fails.
