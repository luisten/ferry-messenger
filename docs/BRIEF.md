# IG Messenger — product brief

> The project was renamed **Ferry** on 2026-10-15 (D15). This is a historical record: it keeps the old name, IG Messenger.

Captured from the user's request (2026-10-12). Source of truth for what we're building.

## Goal
A **native iOS app** (SwiftUI) that is a messaging-only client for **Instagram DMs across multiple
Instagram accounts**, in **one unified inbox** — like Beeper on iOS does. Built on the
**Matrix protocol** (matrix.org) using a bridge to Instagram.

## Lineage
- An earlier web-wrapper prototype (a separate, private project) was the proof of concept: a WKWebView wrapper around
  instagram.com with multi-account, DM-shared reels playing in isolation, feeds blocked.
  It proved the "two Instagram messenger-only interfaces" idea. This app replaces the
  web-wrapper approach with a real native chat client over Matrix.
- **Beeper (iOS)** is the UX reference: it connects multiple Instagram accounts into one
  chat UI.

## Must-haves
1. **Multiple Instagram accounts** (2+), all messages in a single chat interface; reply from
   the right account.
2. **Reels shared in DMs show up as a video in the chat** (downloaded into the chat window,
   like a video message) that can be opened/played there — no need to open Instagram.
3. **Account-type differences handled**:
   - Business / creator accounts have different inboxes: **Primary**, **General**, and
     **Requests** (where spam lands).
   - Personal vs business, and private vs public accounts, behave differently (learned the
     hard way in the earlier web-wrapper prototype).
4. **Nice UX, not bare bones** — a dedicated UX/UI design pass.

## Process the user asked for
1. Research: Matrix/bridges, the Beeper app, and the earlier web-wrapper prototype.
2. Draft a plan.
3. UX/UI designer agent produces a design; fold it into the plan.
4. Develop and test.

## Testing
The user has a few **dummy Instagram accounts** (mix of business/personal, private/public)
for live testing. Instagram login must be performed by the user (Claude does not type
third-party passwords); the app/bridge should only need the resulting session.
