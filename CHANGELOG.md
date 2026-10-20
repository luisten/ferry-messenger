# Changelog

All notable changes to Ferry Messenger are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are `X.Y`, and each release
is a signed tag `vX.Y` ([docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#releases)).

## [Unreleased]

### Fixed

- GIFs and stickers sent from Instagram's GIF picker said the app couldn't show them. They now play in the chat like
  other GIFs, and the chat list says "GIF" or "Sticker".

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

[unreleased]: https://github.com/luisten/ferry-messenger/compare/v1.4...HEAD
[1.4]: https://github.com/luisten/ferry-messenger/compare/v1.3...v1.4
[1.3]: https://github.com/luisten/ferry-messenger/compare/v1.2...v1.3
[1.2]: https://github.com/luisten/ferry-messenger/compare/v1.1...v1.2
[1.1]: https://github.com/luisten/ferry-messenger/compare/v1.0...v1.1
[1.0]: https://github.com/luisten/ferry-messenger/releases/tag/v1.0
