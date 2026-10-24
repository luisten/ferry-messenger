# Changelog

All notable changes to Ferry Messenger are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are `X.Y` (`X.Y.Z` for fixes
only), and each release is a signed tag `v` and its version ([docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#releases)).

## [Unreleased]

### Added

- Notifications for new messages while Ferry is closed. They arrive when iOS lets Ferry check, usually within the
  hour, not instantly. Ferry asks once; Accounts shows whether they're on and turns them on later. Reactions, and
  photos and videos taken with Instagram's camera, don't send any.

## [1.5.1] - 2026-10-22

### Fixed

- Touching and holding a photo, video, GIF, shared post or link preview did nothing (on a shared post, only its thin
  top line worked). It now brings up the reactions, like holding a text message, and a quick tap still opens it.
- Touching and holding a message brings up the reactions sooner.

## [1.5] - 2026-10-21

### Added

- A button to jump to the newest message, when you've scrolled up or a chat opened at "New messages". It shows how
  many new messages have arrived since.
- Tap the mic to record a voice message hands-free, then tap Send, or the trash to cancel. Holding the mic still works.
- Listen to a voice message before sending it: while recording hands-free, tap Stop, play it back, then Send or delete
  it.
- React with any emoji. Touch and hold a message for big buttons with the reactions you used last, and "+" for every
  emoji. Reply, Copy, Edit and Unsend are there too.

### Fixed

- A chat with a few new messages could open with the newest one partly hidden behind the message field. It now opens
  at the bottom unless there's a lot that's new. Then it opens at "New messages", with the last message you'd read
  above it, and the new button takes you down.
- Choosing ❤️ again on a message you'd hearted reacted again instead of removing it, and a reaction removed after
  restarting the app could stay on screen.
- On a reply to a story, a reaction sat by the story's far edge instead of on the reply.
- Holding the mic took a noticeable moment before it started recording a voice message. It now gets ready as soon as
  you touch it, so recording starts sooner.
- A chat with new messages could open without the "New messages" line.
- A message you sent from Instagram's own app pulled the open chat down to the newest message, even while you were
  reading further up. Only what you send from Ferry Messenger does that now.
- GIFs and stickers sent from Instagram's GIF picker said the app couldn't show them. They now play in the chat:
  GIFs like other GIFs, stickers on a loop as in Instagram. The chat list says "GIF" or "Sticker".

## [1.4] - 2026-10-19

### Changed

- The part of the app that talks to Instagram now also reads its messages and follows its rules (when "Seen" and
  "typing…" go out, how often a chat reloads), so a future Android version can share it. Nothing changes in what you
  see, or in what Instagram is asked.

## [1.3] - 2026-10-19

### Fixed

- In light mode, the buttons on photos and videos ("Load video", play, try again) could be white on white over a bright
  picture.
- "typing…" stayed for up to 20 seconds after their message had arrived.
- In group chats, "typing…" could vanish while someone was still typing.

## [1.2] - 2026-10-19

### Added

- In group chats, each reaction shows the pictures of the people who reacted, stacked when several chose the same one.
  Tap the reactions in any chat to see who reacted with what.
- In group chats, "Seen by …" under the newest message.
- A group chat without its own photo shows two of its members' pictures, in the chat list, the chat's header and Chat
  Info.
- Tap someone's picture in a group chat, or a member in Chat Info, to see a bigger picture, their name and @handle, and
  open their Instagram profile.
- A "New messages" line shows where you left off in a chat. When there's more that's new than fits on the screen, the
  chat opens at that line instead of at the bottom.

### Fixed

- Replies and emoji reactions to a story showed only the story. What was sent now shows under it, with Instagram's
  "Replied to …'s story" line above it, and in the chat list.
- The chat list could say "You: " twice, as in "You: You sent an attachment."
- A chat, most often a group, could stay unread after you'd read it.

## [1.1] - 2026-10-18

### Added

- Photos sent together show as a pile. Tap it to spread them out, each opening on its own.
- "Share All" in the menu of photos sent together, to share them all or save them to Photos.

### Fixed

- A message with several photos showed only the first one.
- Instagram's own lines in a chat (a group renamed, someone leaving, a call) showed as messages the app couldn't show.
  They're now lines across the chat. Anything the app really can't show says so and sends you to Instagram.
- Sharing a photo from the full-screen viewer couldn't save it to Photos.

## [1.0] - 2026-10-17

### Added

- First public release: your Instagram direct messages, from all your accounts in one inbox, talking to Instagram
  straight from your iPhone.

[unreleased]: https://github.com/luisten/ferry-messenger/compare/v1.5.1...HEAD
[1.5.1]: https://github.com/luisten/ferry-messenger/compare/v1.5...v1.5.1
[1.5]: https://github.com/luisten/ferry-messenger/compare/v1.4...v1.5
[1.4]: https://github.com/luisten/ferry-messenger/compare/v1.3...v1.4
[1.3]: https://github.com/luisten/ferry-messenger/compare/v1.2...v1.3
[1.2]: https://github.com/luisten/ferry-messenger/compare/v1.1...v1.2
[1.1]: https://github.com/luisten/ferry-messenger/compare/v1.0...v1.1
[1.0]: https://github.com/luisten/ferry-messenger/releases/tag/v1.0
