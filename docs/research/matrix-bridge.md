# Matrix + Instagram bridge: protocol and infrastructure research

> The project was renamed **Ferry** on 2026-10-15 (D15). This is a historical record: it keeps the old name, IG Messenger.

Researched 2026-10-12. Everything below was checked against source code and official docs as of this date.
Source was read (never built or run) from shallow clones:

| Component | Version checked | Where |
|---|---|---|
| **mautrix-instagram** (new IG bridge; lives in the `mautrix/meta` repo) | latest release **v26.09** (tag `v0.2609.0`, 2026-09-16); `main` @ `a9ca06d` (2026-10-12) | github.com/mautrix/meta |
| mautrix-go `bridgev2` (bridge framework + provisioning API) | v0.31.0 (what v26.09 uses); `main` @ `21d7e51` | github.com/mautrix/go |
| Synapse | **v1.162.0** (2026-09-29); v1.163.0rc1 (2026-10-06) | github.com/element-hq/synapse |
| Tuwunel | v1.9.4 (2026-10-10) | github.com/matrix-construct/tuwunel |
| matrix-rust-components-swift | **26.10.02** (2026-10-02) | github.com/matrix-org/matrix-rust-components-swift |
| Element X iOS | release/26.09.2 (2026-09-23); `main` pins Element's own SDK build 26.09.22 | github.com/element-hq/element-x-ios |
| bbctl (Beeper Bridge Manager) | v0.15.0 (2026-07-16), last commit 2026-10-02 | github.com/beeper/bridge-manager |
| Matrix spec | v1.19 | spec.matrix.org |

All file paths below are relative to the repo named in each section. Line numbers refer to the commits above.

---

## Recommendation (TL;DR)

1. **Bridge: use `mautrix-instagram` v26.09**, from the `mautrix/meta` repo. The Docker image is
   `dock.mau.dev/mautrix/meta:ig-v26.09` (amd64 + arm64).
   - **Do not use `mautrix-meta`** for Instagram. It has been Messenger-only since v26.08.
   - **Do not use github.com/mautrix/instagram.** That is the old Python bridge, archived in March 2024.
   - The new bridge is built on bridgev2. It supports several IG logins per Matrix user, and each portal room
     records which login it belongs to.
2. **Configure the bridge for multiple accounts on day one:**
   - `bridge.split_portals: true`. This is **irreversible** and must be set before the first login.
   - `personal_filtering_spaces: true` (the default).
   - Double puppeting through the appservice method.
   - Encryption off (the default).
   - `network.disable_xma_always: false` and `disable_xma_backfill: true`.
   - `backfill.enabled: true`.
3. **Login:** use an in-app `WKWebView` running the bridge's **`cookies`** flow (flow ID `instagram`). The app
   submits the captured cookies to the bridgev2 provisioning API, authenticated with the user's **Matrix access
   token**. This flow already exists and is what the bridge's `cookies` step type is designed for. The user types
   their credentials only into instagram.com.
4. **Homeserver: Synapse v1.162.0 plus Postgres 18**, run with Docker Compose.
   - It is the reference homeserver for mautrix bridges.
   - Simplified sliding sync has been on by default since Synapse v1.114.
   - Its appservice support (ephemeral events, timestamp massaging) is mature.
   - Tuwunel is a lighter option to look at later, not first.
5. **iOS client: hand-roll a thin Matrix Client-Server REST layer** (unencrypted only, `/sync` v3), behind a
   protocol boundary. Use the Rust SDK only if you choose the Beeper route or ever need encryption.
   - **Reason:** the UX depends on data the Rust SDK does not surface well:
     - which account a room belongs to and whether it is a request (the `m.bridge` state event);
     - the room capability limits (`com.beeper.room_features`);
     - the reel fields (`external_url`, `com.beeper.unresolved_media`).
   - The SDK cannot add custom state types to sliding sync's `required_state`.
   - **This is a decision for you** (see §7).
6. **Primary / General / Requests:**
   - "Requests" works today: a per-room `com.beeper.message_request` flag covers both pending and spam requests.
   - **Primary vs General is not exposed by the bridge.** Getting it needs a small bridge patch, ideally an
     upstream PR. **This is a blocker for must-have #3 as written** (see §2).
7. **Reels:** for live messages the bridge already downloads the reel's best-quality MP4 and posts it as an
   `m.video` (must-have #2 is met).
   - For backfilled history it posts a preview image. The app can then call `POST /v3/resolve_media/{eventID}`
     to fetch the video on demand.
   - Beeper's own config disables up-front fetching entirely and resolves on demand (§3).
8. **Beeper as infrastructure: not recommended.** It would rely on a private login API and need full end-to-end
   encryption (forcing the Rust SDK). The only public Beeper API (Desktop API) runs locally on the desktop (§8).

---

## 1. Instagram bridge: current state

### 1.1 Which bridge, which version

- **Instagram switched its DMs to a new protocol in mid-2026.** As a result mautrix built a new Instagram bridge
  as a separate binary, **`mautrix-instagram`**, in the same `mautrix/meta` repo:
  - code: `cmd/mautrix-instagram/main.go`, `pkg/igconnector/`, `pkg/instameow/`;
  - announced in the release post <https://mau.fi/blog/2026-07-mautrix-release/>.
  - **I confirmed the coordinator's lead** against the tags and changelog. Timeline:
    - **v26.07** (2026-07-16): new IG bridge added. Docker tags carry an `ig-` prefix, e.g. `:ig-v26.07`.
    - **v26.08** (2026-08-16): "Removed Instagram support from the mautrix-meta bridge. Only mautrix-instagram
      can be used for Instagram now." (`CHANGELOG.md`)
    - v26.08.1 (2026-09-10) and **v26.09** (2026-09-16) are the current releases.
      - v26.09 added password login (with a webview fallback).
      - It also added the "download reels after bridging with the unresolved media provisioning API" feature.
  - github.com/mautrix/instagram is the **archived Python bridge** (`archived: true`, last push 2024-03-02).
    Ignore it.
- **It is bridgev2.**
  - `cmd/mautrix-instagram/main.go` uses `bridgev2/matrix/mxmain`, version "26.09", connector
    `igconnector.IGConnector`.
  - The network ID is `instagram` and the Beeper bridge type is `instagramgo`.
  - The default port is **29330** and the command prefix is `!ig` (`pkg/igconnector/connector.go:61-71`).
- **Docker image (verified on the registry):**
  - `dock.mau.dev/mautrix/meta:ig-v26.09`, manifest-list digest
    `sha256:bdf4b2f7d50f59d1053639d1da31612be72e2fb6fba4c20b2285a0fdeebff2df`, platforms amd64 and arm64.
  - Also tagged `ig-v0.2609.0`. Avoid `ig-latest`, which is unpinned.
  - The CI image is `Dockerfile.ci` with `EXECUTABLE=mautrix-instagram`. It installs the binary as
    `/usr/bin/mautrix-meta`, so `docker-run.sh` works unchanged.
  - ffmpeg is included in the image (needed for voice conversion).
- **`main` is already ahead of v26.09.** It adds a third login flow, `android` ("Native Android"). The docs page
  says this mode needs **v26.10**, which is not released yet. Pin v26.09 and upgrade deliberately.

### 1.2 How Instagram login works

From `pkg/igconnector/login.go` and `login_native.go`. On v26.09, `GetLoginFlows` returns `instagram` and
`instagram-password`; `main` adds `android`.

| Flow ID | Name | What happens |
|---|---|---|
| `instagram` | Cookies | Step `fi.mau.meta.cookies`, type `cookies`.<br>URL `https://www.instagram.com/accounts/login/`.<br>Fields are cookies on `instagram.com`.<br>`wait_for_url_pattern`: `^https://www\.instagram\.com/(?:direct/(?:inbox/\|t/[0-9]+/)?)?(?:\?.*)?$` (`login.go:92-110`). |
| `instagram-password` | Native Web | `user_input` step asking for username/email and password (`fi.mau.meta.instagram.credentials`).<br>Then 2FA (`..._web_two_factor`), cookie consent and Account-Manager steps.<br>When Instagram returns a checkpoint, it **falls back to a `cookies` step showing an instagram.com challenge URL in a webview** (`login_native.go:372-395`).<br>The changelog says this "can only be used via mautrix-manager". |
| `android` (main only) | Native Android | Username/password through the IG Android API ("CAA"). It needs the `client_http` proxying feature (§5.4). |

**Cookies** (`pkg/messagix/cookies/cookies.go:34-50`):

- **Required:** `sessionid`, `csrftoken`, `ds_user_id`.
- **Optional:** `rur`, `shbid`, `shbts`, `mid`, `ig_did`.
- The docs list `sessionid, csrftoken, mid, ig_did, ds_user_id` as the set to send
  (<https://docs.mau.fi/bridges/go/meta/authentication.html>).
- **Send all eight whenever they are present.**

**What happens after cookies are submitted** (`loginWithCookies`, `login.go:128-247`):

- The bridge loads the IG index and inbox with those cookies, using a desktop Chrome-on-Linux user agent
  (`pkg/messagix/useragent/useragent.go:7`).
- It maps IG errors to named login errors: `RateLimited`, `Challenge`, `Checkpoint`, `Consent`,
  `AccountSuspended`, `TokenInvalidated`.
- It creates a `UserLogin` whose **ID is the account's numeric "interop messaging FBID"**
  (`metaid.MakeUserLoginID(ownFBID)`, `login.go:183-186`).
- After connecting it fills `RemoteProfile.Name`, `.Username` and `.Avatar` (`client.go:362-366`).

### 1.3 Multiple IG accounts per Matrix user: yes

- bridgev2 keeps a map of logins per user.
- `permissions.<user>.max_logins` defaults to 0, which means unlimited (`bridgev2/user.go:179-181`,
  `bridgeconfig/permissions.go:27`).
- Each `login/start` call adds a new `UserLogin`.
- Logging into the same IG account again replaces the existing login with that ID. To re-authenticate an
  existing login explicitly, call `POST /v3/login/start/{flow}?login_id=<id>`.

### 1.4 How a client tells which IG account a room belongs to

**Portal keys** (`pkg/igconnector/ids.go:41-52`):

- **DMs always get `Receiver = <login ID>`.**
- **Groups get a receiver only if `split_portals: true`.**
- Otherwise a group that two of your accounts are both in becomes **one shared room**. When you send there, the
  bridge picks whichever of your logins it finds first (`bridgev2/portal.go:666-716`, `FindPreferredLogin`).
  That breaks "reply from the right account".
- **→ Set `split_portals: true`.** The example config warns it is irreversible
  (`bridgev2/matrix/mxmain/example-config.yaml:19`).

Signals available to a client (all of them are state events or provisioning data):

| Signal | Content | Source |
|---|---|---|
| **`m.bridge`** state event (also duplicated as `uk.half-shot.bridge`), state key `"<hs domain>/<appservice id>"`, e.g. `example.com/instagram` | Fields:<br>- `bridgebot`<br>- `protocol.id = "instagram"`<br>- `channel.id` = IG thread key<br>- **`channel["fi.mau.receiver"]` = login ID (FBID)**<br>- **`channel["com.beeper.message_request"]`** (bool)<br>- `channel["com.beeper.user_blocked"]`<br>- `com.beeper.room_type` = `"dm"` for DMs<br>- `com.beeper.room_type.v2` | `bridgev2/portal.go:4536-4592`; `event/state.go:247-269`; `bridgev2/matrix/connector.go:700-702` |
| **Personal filtering space** for each login | Space named "Instagram (<name>)". It holds an `m.space.child` for every portal of that login. The bridge does **not** set `m.space.parent` in the portals, because the space is not canonical. The space has its own `m.bridge` with `channel.id = "__personal_filtering_space__"`, `fi.mau.receiver = <login ID>` and `com.beeper.room_type.v2 = "personal_filtering_space"`. | `bridgev2/space.go:59-200` |
| **Provisioning `/v3/whoami`** | `logins[]` gives `{id, name, profile{name, username, avatar}, state{state_event: CONNECTED/BAD_CREDENTIALS/…}, space_room}` | `bridgev2/matrix/provisioning.go:322-372`; `provisioning.yaml` |
| `com.beeper.room_features` state event | Per-room capabilities (§4) | `bridgev2/portal.go:4594+` |

**Recommended mapping:**

- The **room → account** link comes from `m.bridge` → `channel["fi.mau.receiver"]`.
- That login ID is the key into `/whoami` `logins[]`, which provides the account's display name, username,
  avatar and connection state.
- The personal filtering space is the fallback when a client cannot read custom state (relevant for the Rust SDK,
  §7).

---

## 2. Inbox folders: Primary / General / Requests

**What the bridge does:**

- **Requests: supported** for both personal and professional accounts.
  - The bridge maps IG's thread `system_folder` of `"PENDING"` or `"SPAM"` to `ChatInfo.MessageRequest = true`
    (`pkg/igconnector/chatinfo.go:262`).
  - Live folder moves (`SlideUQPPUpdateThreadFolder`) do the same (`pkg/igconnector/handlemeta.go:329-330`,
    `:519-531`).
  - When IG moves a thread into a request folder, the bridge does not create a room for that event alone
    (`CreatePortal: !isRequest`).
  - It **does** create a room when a message arrives in a pending thread. That path sets `CreatePortal: true`
    (`handlemeta.go:370-385`), and the chat info fetched afterwards carries `system_folder`.
  - In Matrix the flag appears as `m.bridge` → `channel["com.beeper.message_request"]`. The bridge resends it when
    the flag changes (`bridgev2/portal.go:5307-5345`).
  - **PENDING ("Requests") and SPAM ("Hidden requests") are not distinguished.** Both are just "request".
- **Accepting a request:**
  - The app sends a `com.beeper.accept_message_request` message event with content `{}` into the room
    (`event/type.go:248`, `bridgev2/portal.go:1970-2007`, `igconnector/handlematrix.go:377-391`).
  - The bridge calls IG's accept mutation and clears the flag.
  - IG advertises `MessageRequest.AcceptWithButton = fully supported` (`igconnector/capabilities.go:151-153`).
  - Sending a message also accepts implicitly (`autoAcceptMessageRequest`).
  - Deleting a chat is `com.beeper.delete_chat` (`DeleteChat: true`).
- **Primary vs General: not supported.**
  - The raw thread object has `folder`, `messaging_folder_tag` and `ig_inbox_folder`
    (`pkg/instameow/slidetypes/thread.go:59-66`, `event.go:137-141`). The bridge never maps them to Matrix.
  - The inbox query hard-codes `IsProfessionalAccountGK: false` (`slidetypes/requests.go:186-200`), so the bridge
    presents itself as a non-professional web client.
  - Thread pagination only asks for folder `"INBOX"` (`igconnector/chatsync.go:152`).
  - The account flags `has_tabbed_inbox`, `is_professional_account`, `is_business_account` and `is_private` are
    parsed (`pkg/messagix/types/account.go:160-185`) but are **not** exposed in the login profile or bridge state.

**Closest signals and options:**

1. **Requests:** use `com.beeper.message_request`. It works today.
2. **Primary/General: options, in order of preference**
   - **(a) Upstream PR to mautrix** (the license is AGPL). Three pieces:
     - fill `folder` / `ig_inbox_folder` into `m.bridge` through the existing `PortalBridgeInfoFillingNetwork`
       hook, or as a room tag;
     - expose `has_tabbed_inbox` / `is_professional_account` in the login's `RemoteProfile` or bridge-state `info`;
     - possibly flip `IsProfessionalAccountGK` for professional accounts.
     - Small, but **unknown**: does IG's web GraphQL even return the Primary/General split when the
       professional-account gate is off? This needs a live capture from your dummy business account (enable the
       bridge's debug logging and inspect the raw `folder` values).
   - **(b) Run a private fork** until upstream merges. That means building your own image, which needs the Go
     toolchain.
   - **(c) Ship v1 with "All / Requests" only**, plus per-account filters, and add Primary/General later.
3. Business vs personal and private vs public are also not exposed. The same patch would carry them.

**Gotchas:**

- **Old requests may not be bridged.** The first-sync mailbox query (`PolarisDirectInboxQuery`) appears to cover
  the main inbox only, so requests that existed **before** login may not appear until a new message arrives.
  Needs a live test.
- **Read receipts leak into requests.** The bridge forwards Matrix read receipts to IG even in request rooms
  (`handlematrix.go:299-330`, no request check). On IG that shows the sender "Seen" (inferred: no request check in
  that code). **The client must not send read receipts in rooms where `message_request` is true.**

---

## 3. Reels, shared posts, story shares and XMA attachments

**Code path:**

- `pkg/msgconv/igconv/from-instagram.go:128-162` handles the `MessageContentXMA` case.
- It calls `pkg/msgconv/igconv/xma.go`:
  - `wrapXMA` builds the preview and caption;
  - `fetchXMA` (line 149) decides what to fetch;
  - `fetchXMAMedia` (289) handles posts and reels;
  - `fetchXMAStory` (254) handles stories;
  - `wrapXMAItem` (324) builds the final part;
  - `FetchUnresolvedXMA` (202) is the on-demand path.

**How it works:**

1. **The XMA is a link share without a target ID** (generic link, profile share and similar).
   - Result: a text message with a `com.beeper.linkpreviews` entry. Any preview image is re-uploaded to Matrix.
2. **The XMA has a target ID.** The bridge first builds a **preview-image part** (`m.image`, re-uploaded). Its body
   is a caption made from the eyebrow, title, subtitle and caption text plus the target link. It sets
   `external_url = <instagram.com URL>`.
   - **Story:** the URL path starts with `/stories/`, and the bridge calls `FetchReel(reel_id, media_id)`.
   - **Post or reel:** the URL is `/p/<code>` or `/reel/<code>` with a numeric target ID, and the bridge calls
     `FetchMedia(id, shortcode)`.
     - It picks the **highest-resolution `video_versions` entry**. If there is none, it uses the best
       `image_versions2` candidate.
     - For carousel shares it selects the child `carousel_share_child_media_id`.
     - It then **re-uploads the file into Matrix media** (`mediadl.ReuploadFileToMatrix`).
     - The result is an **`m.video`** (or `m.image`) carrying the original caption, `external_url`, and the
       preview as its thumbnail.
   - **So yes: a reel shared in a DM becomes a real, playable MP4 in Matrix media.**
3. **When fetching is disabled** (`ShouldFetchXMA` is false, `xma.go:169-181`):
   - The preview `m.image` is sent with `fi.mau.instagram.xma_fetch_status = "skip"`.
   - It also carries **`com.beeper.unresolved_media: {"kind": "permanent", "fi.mau.instagram.base_part": {…}}`**.
   - The fetch target is stored in the bridge DB.
   - **On-demand fetch:** the client calls `POST /_matrix/provision/v3/resolve_media/{eventID}?login_id=<id>` with
     body `{"com.beeper.unresolved_media": <that object>}` (`bridgev2/provisionutil/media.go:25-104`,
     `igconnector/directmedia.go:55`).
     - The bridge downloads the video and posts an **edit** (`m.replace`) of the original event.
     - The new content is the `m.video`, with top-level `com.beeper.dont_render_edited: true`.
     - The msgtype changes from `m.image` to `m.video`, and the client must handle that (§7, risks).
4. **When the fetch fails**, the client sees only the preview and caption, with `xma_fetch_status` set to
   "fetch fail", "empty response" and so on. Typical causes:
   - a reel from a **private account the receiving IG account doesn't follow**;
   - a **story older than 24 hours**;
   - a Facebook reel shared into IG (open issue #266, "meta reel preview should be a video").

**Config** (`pkg/igconnector/config.go:38-39`, `example-config.yaml`):

| Key | Default | Meaning |
|---|---|---|
| `disable_xma_backfill` | **true** | Don't fetch XMA media when backfilling history. Those messages get `unresolved_media`. |
| `disable_xma_always` | false | Don't fetch XMA media at all. |

- **Beeper's own bbctl template sets `disable_xma_always: true`** (`bridgeconfig/instagram.tpl.yaml` in
  beeper/bridge-manager). Beeper clients therefore resolve every reel on demand through `resolve_media`.
- **For us:** set `disable_xma_always: false` so live reels arrive as video (must-have #2), and keep
  `disable_xma_backfill: true` to avoid a flood of extra IG API calls on first sync. Implement `resolve_media`
  ("tap to load video") for older items.

**Size limits:**

- The bridge's download cap (`MaxFileSize`) comes from the homeserver's `m.upload.size`
  (`igconnector/connector.go:58-60`). Synapse's `max_upload_size` defaults to **50M**.
- Longer reels can exceed that and become a "Too large attachment" notice (`from-instagram.go:404-420`).
- **Raise `max_upload_size` to something like 200M.**
- `direct_media` (serving IG CDN files without re-uploading) exists but needs federation-style media serving. Skip
  it.

---

## 4. Other features (IG bridge, v26.09)

Sources: `ROADMAP.md` "Instagram" section, `pkg/igconnector/capabilities.go`, `handlematrix.go`,
`from-instagram.go`.

| Feature | IG → Matrix | Matrix → IG | Notes |
|---|---|---|---|
| Text, formatting, mentions | ✅ | ✅ | Max text 1000 chars |
| Images | ✅ | ✅ jpeg/png/gif/webp, ≤ 8 MB | Captions dropped on send |
| Video | ✅ | ✅ mp4/mov/webm/ogg, ≤ 25 MB | |
| Voice messages | ✅ as `m.audio` + `org.matrix.msc3245.voice` | ✅ `audio/mp4`; `audio/ogg` with ffmpeg | **IG audio is converted to Ogg/Opus** (`mediadl/reupload.go:244`). iOS AVFoundation can't play Ogg/Opus natively; Element X uses `element-hq/swift-ogg` 0.0.4 to transcode. |
| GIFs, stickers | ✅ | ✅ | |
| View-once media | ✅ (or a notice if `disable_view_once`) | n/a | |
| Reels, posts, stories (XMA) | ✅ (§3) | n/a | |
| Reactions | ✅ | ✅ | **One reaction per user** (`ReactionCount: 1`) |
| Replies | ✅ | ✅ | |
| Edits | ✅ | ✅ | Max 5 edits within 15 min |
| Unsend / redaction | ✅ | ✅ | No "delete for me" |
| Read receipts | ✅ | ✅ | With double puppeting, reading in the real IG app clears unread state in Matrix |
| Typing | ✅ | ✅ | Costs 2 extra connections per account; `disable_typing` turns it off |
| Group chats | ✅ (members, title, avatar) | Rename / avatar ✅; invite / kick ❌ | `create_group` provisioning endpoint exists |
| Start new chat | | via `search_users`, then `create_dm/{fbid}` | `resolve_identifier` only accepts numeric IDs (latest commit) |
| History backfill | ✅ | | Needs bridgev2 `backfill.enabled: true`. Thread-list backfill has an open bug (#374, `batch_count: -1` broken) |
| Instagram E2EE chats | ❌ | ❌ | The new IG bridge has no IG E2EE support. "Removed option to use encrypted chats on Instagram" (v26.04). Opt-in encrypted IG chats won't bridge. |

**Encryption:**

- In bridgev2 config `encryption.allow` and `encryption.default` both default to **false**
  (`mxmain/example-config.yaml`), so rooms are created **unencrypted**.
- On your own homeserver that is entirely fine, and it removes the need for any crypto in the client.
- Keep `encryption.require: false`.

**Ban and rate-limit risk (known):**

- The docs warn that Meta may flag "suspicious activity" and demand a captcha, phone verification or password
  reset. They recommend turning on 2FA.
- Issue #44 ("We suspect automated behaviour on your account", for FB) is still open (updated 2026-08-26).
- Things that raise risk:
  - **IP and user-agent mismatch:** login happens in iOS WebKit on the phone's IP, while the bridge then uses a
    desktop Chrome UA from the server's IP.
  - Data-centre IPs: a VPS is riskier than home.
  - XMA fetching: one extra IG request per reel.
  - Thread backfill (there is a `batch_delay` setting "to avoid rate limiting").
  - Full reconnects: every ≥1 h, plus a forced refresh every 20 h.
- **Mitigations:**
  - Run the bridge on a residential connection (Mac at home, later a home server) or use the
    `proxy` / `get_proxy_from` config.
  - Keep backfill modest.
  - Use your dummy accounts first.
- **Protocol churn:** Meta changes broke connectivity in v26.05.1, v26.06 and v26.08.1. The IG bridge itself is
  about 3 months old. Plan for frequent bridge updates.
- **ToS:** any unofficial client breaks Instagram's terms.
- Meta's official Instagram Messaging API (Graph API) only works for business accounts, needs app review, and has
  messaging-window rules. It doesn't fit personal accounts.

---

## 5. Login provisioning for a native client (bridgev2 provisioning API)

Sources: `bridgev2/matrix/provisioning.go:129-154` (routes), `:264-310` (auth); `provisioninglogin.go`;
`provisioning.yaml` (OpenAPI); `bridgev2/login.go:133-310` (JSON types).

### 5.1 Base URL and auth

- **Base:** `{bridge appservice listener}/_matrix/provision`. In Docker this is
  `http://mautrix-instagram:29330/_matrix/provision`.
- **Expose it to the phone** with a reverse proxy rule that forwards **only** `/_matrix/provision/*` on the
  homeserver's hostname to the bridge (Synapse doesn't use that prefix).
- **Auth:** `Authorization: Bearer <token>` plus `?user_id=@you:example.com`.
  - The token can be **the user's Matrix access token** (`provisioning.allow_matrix_auth: true`, the default). The
    bridge checks it with `/whoami` against the homeserver and caches the result for 5 minutes
    (`provisioning.go:202-220`).
  - It can also be the shared secret (≥16 chars). **Never ship the shared secret in the app.**
  - Use the Matrix token.
- The user needs `login` permission in `bridge.permissions` (`"example.com": user`).

### 5.2 Endpoints you need

| Purpose | Request | Response |
|---|---|---|
| Info + logins | `GET /v3/whoami` | `{network{…}, login_flows[], homeserver, bridge_bot, command_prefix, management_room?, logins[{id, name, profile{name, username, avatar}, state{state_event, timestamp, error?, message?}, space_room}]}` |
| Flows | `GET /v3/login/flows` | `{"flows":[{"name":"Cookies","description":"Login using cookies from instagram.com","id":"instagram"}, …]}` |
| List login IDs | `GET /v3/logins` | `{"login_ids":["1784…"]}` |
| Start login | `POST /v3/login/start/instagram` (optional `?login_id=<existing>` to re-login; optional `&client_http=1`) | `{"login_id":"<process id>","type":"cookies","step_id":"fi.mau.meta.cookies","txn_id":"…","instructions":"…","cookies":{"url":"https://www.instagram.com/accounts/login/","fields":[{"id":"sessionid","required":true,"sources":[{"type":"cookie","name":"sessionid","cookie_domain":"instagram.com"}]}, … csrftoken, ds_user_id (required), rur, shbid, shbts, mid, ig_did (optional)],"wait_for_url_pattern":"^https://www\\.instagram\\.com/…$"}}` |
| Submit cookies | `POST /v3/login/step/{login_id}/fi.mau.meta.cookies/cookies?txn_id=…` with body `{"sessionid":"…","csrftoken":"…","ds_user_id":"…","mid":"…","ig_did":"…","rur":"…"}` (flat `id → value` map) | Success: `{"login_id":"…","type":"complete","step_id":"fi.mau.meta.complete","instructions":"Logged in as … (<fbid>)","complete":{"user_login_id":"<fbid>"}}`.<br>Errors are Matrix-style `{errcode, error}`. Codes come from `loginerrors`: missing cookies, rate limited, challenge, checkpoint, consent, suspended, token invalidated. |
| Cancel | `POST /v3/login/cancel/{login_id}` | `{}` |
| Log out | `POST /v3/logout/{loginID}` (or `all`) | `{}` |
| Load reel video | `POST /v3/resolve_media/{eventID}?login_id=<fbid>` with body `{"com.beeper.unresolved_media":{…}}` | `{}`. The video arrives as an edit event. |
| New DM | `POST /v3/search_users?login_id=…` with `{"query":"username"}`, then `POST /v3/create_dm/{id}?login_id=…` | `{id, name, avatar_url, mxid, dm_room_mxid}` |

Other details:

- Login processes time out after **30 minutes** (`provisioninglogin.go:104`).
- Responses always use the general step shape. The client should branch on `type`: `cookies`, `user_input`,
  `display_and_wait`, `client_http` or `complete`. The same client code then also handles the password flow's 2FA
  steps if you ever add it.

### 5.3 The WKWebView flow: feasible (this is what the `cookies` step is for)

1. `POST login/start/instagram`.
2. Open a `WKWebView` at `cookies.url`.
   - Give it a **fresh `WKWebsiteDataStore.nonPersistent()` per login**, so each account logs in clean and
     sessions never mix between accounts.
3. The **user types their own credentials and 2FA into instagram.com**. Checkpoints and captchas are handled by
   Instagram's own UI.
4. On each navigation, read `httpCookieStore.getAllCookies()`. It returns HttpOnly cookies such as `sessionid`.
   Filter to domains ending in `instagram.com`.
5. When all **required** cookies are present **and** the URL matches `wait_for_url_pattern`, close and submit.
   - The spec also allows submitting if the user closes the view after the required cookies exist.
   - IG often shows `/accounts/onetap/…` first, which doesn't match the pattern.
6. Throw the data store away.
   - **Never trigger IG "Log out" in that webview.** That would invalidate the session the bridge now holds.
7. Show the account from `complete.user_login_id`, then refresh `/whoami` for its profile and avatar.

- The same handler covers the challenge step that `instagram-password` can return:
  `step_id = fi.mau.meta.instagram.web_challenge`, plus optional `initial_cookies` to preset.
- **Leave the WKWebView's default user agent alone.** The bridge code has the `user_agent` field deliberately
  commented out (`login.go:98`), so it does not ask clients to spoof a UA. The UA/IP mismatch risk is noted in
  §4.

### 5.4 Not recommended for us: `client_http`

- With `?client_http=1`, the bridge sends its login HTTP requests **to the client to execute**. This is the
  `client_http` step type and `POST /v3/login/client_http/{login_id}/{txn_id}/{req_id}`. It lets IG see the
  user's own IP.
- Each request carries a `fingerprint` hint (`"chrome"` or `"instagram-android"`), which implies a TLS
  fingerprint the client is expected to match. `URLSession` can't do that.
- The cookie flow avoids the problem.

---

## 6. Homeserver choice and Docker Compose

| | **Synapse v1.162.0** | Tuwunel v1.9.4 | Continuwuity (~v0.5.9) |
|---|---|---|---|
| Status | Reference homeserver, Element-maintained, biweekly releases | Successor to conduwuit; claims company and Swiss-government backing | Community conduwuit fork |
| mautrix support | What the docs are written against. The only explicit warning in mautrix docs is against Dendrite. | "Conduit-based" servers are covered by the mautrix registration docs, with no explicit Tuwunel testing statement | same |
| Simplified sliding sync (MSC4186, still an unstable endpoint) | **On by default since v1.114** | Supported (release notes reference sliding-sync extensions used by Element X) | Partial / in progress (inferred) |
| Footprint | Python + **Postgres required** (Postgres must use the C locale) | Single Rust binary with embedded RocksDB, very light | same |
| Appservice details bridgev2 uses (MSC2409 ephemeral events for typing/receipts, `?ts=` massaging, `/ping`) | Mature | Supported, less battle-tested with bridgev2 (inferred) | (unknown) |

**→ Synapse.** It is the least risky option for bridges and sliding sync, at the cost of more RAM (roughly
0.5–1 GB including Postgres for a single user; not measured).

- If the always-on host is tiny, a Tuwunel swap later is reasonable.
- Migrating Synapse → Tuwunel is **not supported**, so decide before accumulating real data.
- MSC4186 core was accepted in July 2026 but is not in spec v1.19. Servers serve it at
  `/_matrix/client/unstable/org.matrix.simplified_msc3575/sync`.

### Minimal compose sketch (dev on macOS; all images are multi-arch, pinned)

```yaml
# docker-compose.yml
name: igmessenger
services:
  postgres:
    image: postgres:18.6-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: synapse
      POSTGRES_PASSWORD: ${PG_PASSWORD:?set in .env}
      POSTGRES_DB: synapse
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --lc-collate=C --lc-ctype=C"   # Synapse refuses non-C locale
    volumes:
      - ./data/postgres:/var/lib/postgresql          # PG18 images: mount the parent dir, not /data
      - ./init/10-bridge-db.sql:/docker-entrypoint-initdb.d/10-bridge-db.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U synapse"]
      interval: 5s
      retries: 20

  synapse:
    image: ghcr.io/element-hq/synapse:v1.162.0
    restart: unless-stopped
    depends_on: { postgres: { condition: service_healthy } }
    volumes:
      - ./data/synapse:/data                          # homeserver.yaml, signing key, media
      - ./data/instagram/registration.yaml:/appservices/instagram.yaml:ro
      - ./appservices/doublepuppet.yaml:/appservices/doublepuppet.yaml:ro
    ports:
      - "8008:8008"                                   # dev only; front with Caddy/Tailscale later

  mautrix-instagram:
    image: dock.mau.dev/mautrix/meta:ig-v26.09        # optionally @sha256:bdf4b2f7d50f…ff2df
    restart: unless-stopped
    depends_on: [synapse, postgres]
    volumes:
      - ./data/instagram:/data                        # config.yaml, registration.yaml
    ports:
      - "29330:29330"                                 # dev only: provisioning API for the iOS app
```

```sql
-- init/10-bridge-db.sql
CREATE USER mautrix_instagram WITH PASSWORD 'change-me';
CREATE DATABASE mautrix_instagram OWNER mautrix_instagram
  ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
```

**Bootstrap:**

1. Generate the Synapse config:
   `docker compose run --rm -e SYNAPSE_SERVER_NAME=<name> -e SYNAPSE_REPORT_STATS=no synapse generate`.
2. Edit `homeserver.yaml`:
   - `database:` → psycopg2 pointing at `postgres`;
   - `app_service_config_files: [/appservices/instagram.yaml, /appservices/doublepuppet.yaml]`;
   - `max_upload_size: 200M`;
   - keep `enable_registration: false`.
3. Create your user with `register_new_matrix_user`.
4. Start `mautrix-instagram` once. It writes `/data/config.yaml` and exits.
5. Edit `config.yaml` (key changes below).
6. Start the bridge again. It writes `registration.yaml` and exits.
7. Start everything.

**Bridge `config.yaml` key changes:**

```yaml
homeserver: { address: http://synapse:8008, domain: <server_name> }
appservice: { address: http://mautrix-instagram:29330, hostname: 0.0.0.0, port: 29330 }
database:   { type: postgres, uri: postgres://mautrix_instagram:change-me@postgres/mautrix_instagram?sslmode=disable }
bridge:
  split_portals: true              # IRREVERSIBLE: set before first login
  personal_filtering_spaces: true
  permissions: { "<server_name>": user, "@you:<server_name>": admin }
backfill: { enabled: true, max_initial_messages: 50 }
double_puppet: { secrets: { "<server_name>": "as_token:<token from doublepuppet.yaml>" } }
encryption: { allow: false }       # default
provisioning: { allow_matrix_auth: true }   # default; shared_secret stays server-side
network:
  disable_xma_always: false        # live reels -> m.video
  disable_xma_backfill: true       # history -> unresolved_media, resolve on demand
```

**Notes:**

- **`doublepuppet.yaml`** follows <https://docs.mau.fi/bridges/general/double-puppeting.html>:
  - `id: doublepuppet`, `url:` present but null, random `as_token` / `hs_token` / `sender_localpart`;
  - a users namespace `@.*:<server_name>` with `exclusive: false`.
  - Double puppeting makes your sends from the real IG app show as you, syncs IG read state into Matrix, and has
    the bridge join portal rooms for you instead of leaving invites.
- **Always-on later:**
  - Same compose file, plus Caddy (TLS) or **Tailscale**, which avoids public exposure.
  - Proxy `/_matrix/client`, `/_matrix/media` and `/_matrix/provision` only.
  - The iPhone needs HTTPS (App Transport Security) except during LAN dev with `NSAllowsLocalNetworking`.
  - Push notifications need a Sygnal push gateway plus an APNs key (Apple Developer account). This is not covered
    here.

---

## 7. iOS client: Rust SDK vs hand-rolled REST

### 7.1 matrix-rust-sdk Swift bindings

**Package facts:**

- SPM package `https://github.com/matrix-org/matrix-rust-components-swift`, `exactVersion: 26.10.02`.
  - It is calendar-versioned and the README says the API is unstable.
  - It targets iOS 16+ and macOS 12+.
- Element X uses **Element's own iOS-only build**, `element-hq/matrix-rust-components-swift`, whose versions
  don't correspond to the official package (`26.09.22`, set in `project.yml`).

**API surface (from the generated `matrix_sdk_ffi.swift` and `Examples/Sources/Walkthrough`):**

- `ClientBuilder().serverNameOrHomeserverUrl(…).sessionPaths(…).slidingSyncVersionBuilder(.discoverNative)`.
  Only `none`, `native` and `discoverNative` exist; there is no proxy option.
- `client.login(username:password:…)` / `restoreSession`.
- `client.syncService().finish()` returns a `SyncService`. From it: `roomListService().allRooms()`, then
  `entriesWithDynamicAdapters(pageSize:listener:)`, with filters `.all / .any / .joined / .invite / .favourite /
  .category(...) / .fuzzyMatchRoomName / …`.
- `SpaceService`: `joinedParentIdsOfChild`, plus space filters that combine with `RoomListService`. This maps
  directly onto the bridge's personal filtering spaces.
- `room.timeline()` with `TimelineListener` diffs. Edits, reactions, replies and receipts are aggregated, and
  there is an offline send queue.
- Media through the client's media APIs.
- `room.sendRaw(eventType:content:)` (for `com.beeper.accept_message_request`).
- `EventTimelineItem.debugInfo().originalJson` gives raw event JSON.

**Problems for this app:**

- **The SDK requires native sliding sync**, and its room list `DEFAULT_REQUIRED_STATE` (`room_list_service/mod.rs`)
  covers only standard state types. `m.bridge` and `com.beeper.room_features` are not included.
  - `Room.stateEvents(eventType:)` documents that a custom type "is empty unless that type is part of the sliding
    sync `required_state`".
  - **No FFI method adds required state.**
  - So the request flag and capabilities would need side REST calls (`GET /rooms/{id}/state/m.bridge/{key}`). The
    account mapping can come from personal-space membership.
- **Custom message fields** (`external_url`, `com.beeper.unresolved_media`, `fi.mau.instagram.xma_fetch_status`)
  are reachable only through the "debug" raw-JSON accessor.
- **Unverified:** how the timeline applies an `m.replace` that changes msgtype from `m.image` to `m.video` (the
  `resolve_media` path).
- **Size:**
  - The xcframework zip is about 280 MB to download.
  - The **`ios-arm64` static archive is 298 MB** before linking. I listed the zip's central directory over HTTP
    range requests; nothing was downloaded in full.
  - The shipped app grows by "tens of MB" after dead-stripping. That is an estimate, not measured.
- Rust panics behind FFI are harder to debug.
- Upgrades come weekly and can break the API.

### 7.2 Hand-rolled C-S REST (unencrypted only)

Endpoints from spec v1.19:

- **Login:** `POST /_matrix/client/v3/login` (password, own server).
- **Sync:** `GET /_matrix/client/v3/sync` with a filter (`lazy_load_members`, small timeline limit) and a `since`
  token, long-polling.
  - It returns **all state, including `m.bridge`**, plus ephemeral events (typing, receipts), account data (tags,
    `m.direct`) and `unread_notifications`.
- **History:** `GET /rooms/{id}/messages?dir=b&from=<prev_batch>` to fill gaps when the timeline is `limited`.
- **Sending:**
  - messages, reactions and edits: `PUT /rooms/{id}/send/{type}/{txnId}`;
  - redactions: `PUT /rooms/{id}/redact/{eventId}/{txnId}`;
  - receipts: `POST /rooms/{id}/receipt/m.read/{eventId}`;
  - typing: `PUT /rooms/{id}/typing/{userId}`;
  - joining invites, if not double-puppeted: `POST /join/{roomId}`.
- **Media:**
  - download: `GET /_matrix/client/v1/media/download/{server}/{mediaId}`;
  - thumbnails: `GET /_matrix/client/v1/media/thumbnail/{server}/{mediaId}`;
  - limits: `GET /_matrix/client/v1/media/config`;
  - upload: `POST /_matrix/media/v3/upload`.
  - The unauthenticated `/_matrix/media/v3/download` routes are deprecated, and Synapse ≥1.120 enforces
    authenticated media by default.
  - AVPlayer can't attach the bearer header in a supported way. **Download to a file, then play** (or use an
    `AVAssetResourceLoaderDelegate`).
- **What you must build:**
  - a local store (SQLite/GRDB);
  - the timeline model: edits (latest `m.replace`), `m.annotation` reaction counts, redactions, reply rendering,
    local echo matched by `unsigned.transaction_id`;
  - gap handling and an unread model;
  - a notification service extension that fetches `/rooms/{id}/event/{id}`.
  - All are well understood. Rough guess: 3–5k lines of Swift.

### 7.3 Trade-off and recommendation

| | Rust SDK | Hand-rolled REST |
|---|---|---|
| Time to a basic working chat | Faster | Slower |
| Correctness of hard parts (gaps, send queue, offline) | Battle-tested | Ours to get right |
| Bridge/Beeper metadata (receiver, request flag, caps, unresolved media) | Awkward (side calls + debug JSON) | First-class |
| Per-account filter | Space filters (good) | Trivial from `m.bridge` |
| Binary size / build | Tens of MB, ~280 MB download per version bump | Negligible |
| API stability | Unstable, weekly | Matrix spec (stable) |
| E2EE | Free | None (fine on own server; rules out the Beeper route) |
| Many rooms (5 accounts × 200 chats) | Sliding sync, instant | `/sync` v3 is fine for one user's few hundred rooms after the initial sync |

**Recommendation: hand-rolled REST over `/sync` v3**, wrapped in a small `ChatBackend` protocol so the Rust SDK
could replace it later. The reasoning:

- Our differentiators (account badges, Requests folder, reel video and on-demand resolve, capability-aware
  composer) all depend on bridge-specific metadata.
- The problem is narrowed to unencrypted rooms, one user and one server.

**Suggested 1–2 day spike first:**

1. Measure the initial `/sync` size and time with 2–3 real accounts bridged.
2. Download and play a bridged reel MP4 through authenticated media.
3. Play an Ogg/Opus voice message, via swift-ogg or an AVAudioConverter path.

**Choose the Rust SDK instead** if you pick the Beeper route (E2EE is mandatory there), or if speed to an MVP
matters more than metadata fidelity.

---

## 8. Beeper infrastructure as an alternative

- **bbctl is still supported** (v0.15.0, 2026-07-16: "Switched to new Instagram bridge"; commits as late as
  2026-10-02). What it does and doesn't do:
  - It runs official bridges, including `instagram`, on **your** machine and connects them to **beeper.com only**.
    It "can not be used with any other Matrix homeserver" (README).
  - Bridges run **in the foreground** only; there is no service mode yet.
  - Support comes from the community room #self-hosting:beeper.com, not normal Beeper support.
  - Its Instagram template sets `disable_xma_always: true` (§3).
- **Beeper's homeserver** is a per-user "hungryserv" at `https://matrix.beeper.com/_hungryserv/<username>`
  (`api/hungryapi/appservice.go`).
  - The README says hungryserv "does not implement the entire Matrix client-server API".
  - The login that bbctl uses is a private API: its request auth header is literally
    `BEEPER-PRIVATE-API-PLEASE-DONT-USE` (`api/beeperapi/login.go:38`). An email code is exchanged for an
    `org.matrix.login.jwt` login.
- **Public Beeper APIs:**
  - The **Beeper Desktop API + MCP** (developers.beeper.com) is a REST API **running locally inside Beeper
    Desktop**, default `localhost:23373`. It requires Desktop to be running and is not reachable from other
    devices by default. It is not usable from an iOS app.
  - Beeper also documents Android intents and content providers.
  - **There is no public remote or cloud API for third-party clients.**
- **Viability as our backend:**
  - Possible in principle: log into hungryserv with a custom client and use Beeper-hosted or bbctl-hosted
    bridges.
  - **Trade-offs:**
    - Beeper's rooms use end-to-bridge **encryption**, so the client needs full E2EE: the Rust SDK plus
      cross-signing and verification with Beeper's other devices.
    - It depends on a private, explicitly do-not-use login API (ToS and stability risk).
    - hungryserv is a partial C-S implementation.
    - With cloud bridges, Beeper holds your IG sessions.
    - With bbctl, a machine you own must stay on anyway, so you are self-hosting the hard part regardless.
    - Upside: no homeserver to operate, and Beeper's tuned bridge ops.
- **Verdict:** not recommended as the primary path. Beeper iOS itself remains the UX benchmark: it already does
  multi-account IG, with on-demand reel resolution.

---

## Open risks / unknowns

1. **Primary/General is not exposed by the bridge (blocker for must-have #3 as written).**
   - It needs an upstream PR or a fork.
   - **Unknown:** whether IG web returns the split when the professional-account gate is off.
   - Capture raw thread JSON from the dummy business account to find out.
2. **Requests from before login** may not bridge until a new message arrives. Needs a live test.
3. **Read receipts in request rooms** would show "Seen" to the requester. The client must suppress them.
4. **Ban / checkpoint risk:**
   - the UA and IP mismatch between WKWebView login and the bridge;
   - a VPS IP is riskier than home;
   - XMA fetches and backfill add API calls.
   - Use dummy accounts, 2FA, a residential IP, and modest backfill.
5. **Protocol churn:** the IG bridge is about 3 months old, and Meta changes broke it several times in 2026.
   Pin versions, but be ready to update quickly.
6. **IG E2EE chats are not bridged.** Users with encrypted IG threads won't see them.
7. **Reel fetch failures** (private author not followed by the receiving account, expired stories, FB reels #266)
   fall back to preview + link. **Large reels** need `max_upload_size` raised.
8. **The `resolve_media` edit changes msgtype** (`m.image` → `m.video`, marked `com.beeper.dont_render_edited`).
   The client must render the edit in place. Rust SDK behaviour here is unverified.
9. **Voice messages arrive as Ogg/Opus**, so iOS needs transcoding. **Authenticated media** needs
   download-then-play.
10. **`split_portals` is irreversible.** Get the config right before the first real login.
11. **Thread-list backfill bug** (#374): older chats beyond the first inbox page may not sync.
12. **The `android` login flow** is only on `main` (the docs say v26.10). Don't depend on it yet.
13. **Push notifications** (Sygnal + APNs + notification service extension) were not researched here. They need an
    Apple Developer account.
14. **Secrets:**
    - Use the Matrix-token auth for provisioning, never the shared secret.
    - Expose only `/_matrix/provision/*`.
    - The bridge stores IG cookies in its Postgres DB; treat backups as sensitive.
15. **Tuwunel / Continuwuity** appservice behaviour with bridgev2 is untested by me. The Synapse → Tuwunel
    migration path does not exist.

## Sources

- Code:
  - github.com/mautrix/meta (`CHANGELOG.md`, `ROADMAP.md`, `pkg/igconnector/*`, `pkg/msgconv/igconv/*`,
    `pkg/instameow/slidetypes/*`, `pkg/messagix/cookies/cookies.go`)
  - github.com/mautrix/go (`bridgev2/matrix/provisioning*.go`, `provisioning.yaml`, `bridgev2/portal.go`,
    `space.go`, `event/state.go`, `mxmain/example-config.yaml`)
  - github.com/matrix-org/matrix-rust-components-swift
  - github.com/beeper/bridge-manager
- Docs:
  - <https://mau.fi/blog/2026-07-mautrix-release/>
  - <https://docs.mau.fi/bridges/go/meta/authentication.html>
  - <https://docs.mau.fi/bridges/general/double-puppeting.html>
  - <https://docs.mau.fi/bridges/general/registering-appservices.html>
  - <https://spec.matrix.org/latest/client-server-api/#content-repository> (v1.19)
  - <https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html>
  - <https://matrix.org/blog/2024/11/14/moving-to-native-sliding-sync/>
  - <https://github.com/matrix-construct/tuwunel>
  - <https://developers.beeper.com/desktop-api/>
  - <https://developers.beeper.com/bridges/self-hosting/>
  - <https://hub.docker.com/_/postgres> (PG18 volume path)
- Registries checked (tags and archs exist): `dock.mau.dev/mautrix/meta:ig-v26.09`,
  `ghcr.io/element-hq/synapse:v1.162.0`, `postgres:18.6-alpine`, `ghcr.io/matrix-construct/tuwunel:v1.9.4`.
- Issues: mautrix/meta #44, #266, #275, #374.
