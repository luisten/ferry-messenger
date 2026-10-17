# M7 exit: every v1 screen next to its mockup

> The project was renamed **Ferry** on 2026-10-15 (D15). This is a historical record: it keeps the old name, IG Messenger; account names, IDs and third-party handles in it are fictional stand-ins.

Captured 2026-10-13 on the iPhone 17 simulator (iOS 26.4), light mode unless named, with the M7b build. The images
are local only (`docs/verification/*.png` is gitignored: they show real accounts):

- `mockup-light-*.png`: each phone frame and component panel of [mockups.html](../design/mockups.html), rendered by
  headless Chrome over its DevTools protocol (a throwaway Node script; no packages).
- `m7b-*.png`: the app. Screens M7b didn't touch reuse M5/M7a captures (`m5-*`, `m7a-*`).
- `m7-compare-*.png`: the mockup on the left, the app to its right, one image per row below.

Screens without a mockup frame (O2, O4, O6, I4, I5, T3, M2, A2) are checked against DESIGN.md's text. Differences
already recorded per milestone in [PLAN §7](../PLAN.md#7-design-integration) (M3 to M7a) aren't repeated unless M7b
changed them.

**Status:** fixed (in M7b) · accepted (with the reason) · deferred (with where it goes).

## Summary

| | Count |
|---|---|
| Fixed | 16 |
| Accepted | 17 |
| Deferred | 3 |

## By screen

| Screen | Compare image | Difference | Status |
|---|---|---|---|
| O1 Welcome | `m7-compare-o1-welcome` | Matches (M7a: static-size illustration, drift-in). | — |
| O2 / O4 / O6 | `m7-compare-o2-o4-o6` | No mockup frame; match DESIGN text (M7a notes). | — |
| O3 Connect | `m7-compare-o3-connect` | Title names the account on re-login ("Log in as @tamoveska", M6); no step dots. | accepted: re-login is the only path that captures this sheet without a new Instagram account |
| O5 Name & color | `m7-compare-o5-identity` | Swatches 2×4, buttons hide under the keyboard (M7a). | — |
| I1 All | `m7-compare-i1-all` | Compose button right of the search field in the bottom bar was missing (M7a). | **fixed**: `square.and.pencil` glass button, opens N1; account ink in an account scope, as in the mockup |
| I1 All | | No filter menu (trailing `line.3.horizontal.decrease`). | accepted (M3): no Unread-only / Select in v1 |
| I1 All | | Search field has no mic glyph. | accepted: the system bottom-bar search field |
| I1 account | `m7-compare-i1-account` | Matches (title, @handle subtitle, wash, ink-colored compose). | — |
| I2 Requests | `m7-compare-i2-requests` | Delete was system red on the grey pill (~3.5:1). | **fixed**: `statusError` (#D70015 / #FF453A, the mockup's `--err`) |
| I2 Requests | | No Select / Delete All. | accepted (M6): bulk delete is risky and wasn't asked for |
| I4 / I5 | `m7-compare-i4-i5` | No mockup frame; unchanged since M7a (no search scopes, name search only). | — |
| N1 New message | `m7-compare-n1-new-message` | Not built before M7b. | **fixed**: From chips (preselected in an account scope, none in All with "Choose an account first"), To field, results with "@handle · Open chat", footer "Searching Instagram from @handle" |
| N1 | | "From" header in sentence case, not uppercase; larger gap between the chips and the To field. | accepted: stock iOS 26 `List` header and section spacing |
| N1 | | Search starts at 2 characters (DESIGN: 300 ms debounce only). | accepted: every search is an Instagram request (ban risk); 300 ms debounce too, live check: 1 request for "kivostudio" |
| N1 | | Picking a result didn't focus the composer (DESIGN: "pushes T1 with the composer focused"). | **fixed**: `AppModel.focusComposer`, verified live |
| N1 | | One recipient, no groups. | accepted: DESIGN N1 (the bridge can't add or remove members) |
| T1 Thread | `m7-compare-t1-thread` | Composer `+` was missing. | **fixed**: glass circle 44 pt, opens PhotosPicker (images) |
| T1 | | No mic button in the composer. | accepted: sending voice is out of v1 (PLAN §1) |
| T1 | | ⋯ menu had no "Open in Instagram". | **fixed**: shown when the contact's handle is known |
| T1 | | Small secondary text (time labels, "Edited", status, reply caption, unsent, reaction count) used system secondary (3.4:1). | **fixed**: `inkSecondary`; on incoming-bubble cards `inkSecondaryOnBubble` (inkSecondary is only 4.30 on #E9E9EB) |
| T1 | | Composer placeholder was the system grey (~2:1). | **fixed**: `inkSecondary`, the mockup's label-2 |
| Composer + photo | `m7-compare-composer` | No mockup for an attached photo. Built: a glass bar above the field (thumbnail, "Photo", ✕; "Your text is sent as a separate message." when there's text). | accepted: DESIGN §6.9 asks for a preview without a caption field; this is it |
| Composer + photo | | The attachment bar covered the newest message (the scroll re-pin doesn't see a growing bottom inset). | **fixed**: scrolls to the end when a photo is attached (`m7b-photo-attached-repinned`) |
| Composer + photo | | `+` opens the photo picker directly: no menu with Camera or GIF. | accepted: photos only in v1 (PLAN §1 late v1) |
| Composer + photo | | Photos always go as JPEG (a GIF's first frame; transparency on white). | accepted: one path, Instagram recompresses anyway; GIF/sticker sending is out of v1 |
| Composer + photo | | The system picker shows "Location Is Included". | accepted: the app re-encodes without metadata (unit test `testMetadataIsDropped`), so no location is sent |
| T2 Request | `m7-compare-composer` | Bar named the requester by display name; the mockup uses "@kestrel.bikes". | **fixed**: "@handle wants to message …" once the ghost profile has the handle; display name before that |
| T2 | | Accept is the account fill, not black; "Reply instead" in account ink. | accepted: inside a thread the tint is the account's (DESIGN §0.1 color means account) |
| T2 | | DEBUG fixture rooms show the history spinner at the top. | accepted: fake rooms have no pagination token; real rooms reach the start |
| T3 Chat info | `m7-compare-t3-m2` | @handle and "Open in Instagram" only for DMs with our own accounts. | **fixed**: also from the ghost profile (`com.beeper.bridge.identifiers`, `ghost_extra_profile_info`) |
| T3 | | Ghosts the bridge hasn't updated since the switch have no identifiers yet (2 of 3 ghosts today). | deferred: they fill in when the bridge next updates the contact (a search finds them, or Instagram sends contact info); a bridge-side resync would be its own task |
| M1 Player | `m7-compare-m1-player` | Unchanged since M5 (PLAN §7 M5). | — |
| M2 Photo viewer | `m7-compare-t3-m2` | Our sent photo opens at once (the upload is filed in `Caches/media`). Close and Share only (M5). | — |
| Media cards | `m7-compare-media` | Voice duration and link host used white/black at 70–80% (white at 0.8 on an account fill fails AA). | **fixed**: full on-color when outgoing, `inkSecondaryOnBubble` incoming (the mockup's `.vd`) |
| Media cards | | Photos 240 pt wide (the mockup sample is narrower). | accepted: DESIGN §6.5 (up to 240×320) |
| A1 Accounts | `m7-compare-a1-a2` | Large title; the mockup has an inline title beside the ✓. | **fixed**: inline |
| A1 / A2 | | "Connected" in system green (2.2:1); signed out / error in system orange / red. | **fixed**: `statusOK` / `statusWarn` / `statusError` (5.2–5.4:1 on white) |
| A1 | | Sign Out in the system destructive red. | accepted: stock destructive role |
| A3 Re-login | `m7-compare-a3-relogin` | No ✕ in the corner. | **fixed**: glass ✕ top-right, far from "Log in again" (see the incident below) |
| Banners | `m7-compare-connection` | A long account name wraps the title onto two lines. | accepted: content length (the mockup's "Studio" is short) |
| Identity system | `m7-compare-identity` | Matches (marks on rows and chips, tags, avatars). | — |
| Tokens | (code) | Status colors have no Increase Contrast variants (DESIGN §11 asks for them on custom colors; `inkSecondary` has them). | deferred: M9 polish |
| Errors elsewhere | (code) | Sign-in error and the Accounts bridge error were system red text. | **fixed**: `statusError` |
| Rest of `.secondary` | (code) | Inbox explainer icon, banner "Later", modeBar ✕ and decorative strokes still use system secondary. | deferred: icons and strokes need 3:1, not 4.5:1; revisit with the HC variants |

## Incident while capturing

Capturing A3, a tap computed from a scaled review image landed on "Log in again" instead of "Not now". It opened the
instagram.com sheet for @tamoveska and the bridge started a login process (`login/start?login_id=…`). Nothing
was typed; the sheet's ✕ sent `login/cancel` 28 s later (HTTP 200) and both logins stayed CONNECTED. This is why A3
now has a ✕ away from the button, and why CLAUDE.md now says to take tap coordinates only from a full-size simulator
screenshot.
