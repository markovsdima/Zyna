# Zyna

**Zyna is an open-source native iOS client for Matrix, focused on encrypted chat, rich media, voice calls, and a custom native UI.**

It is built with Matrix Rust SDK, GRDB, Texture, Metal, WebRTC, and a lightweight companion presence service.

Demo: [YouTube quick tour](https://youtube.com/shorts/Tv3BSCmnINg?feature=share)

<p align="center">
  <img width="640" alt="Zyna app preview" src="https://github.com/user-attachments/assets/0ef25bcc-f1c9-49f6-812e-c9883ad98876">
  &nbsp;
  <img width="240" alt="Zyna message deletion effect" src="https://github.com/user-attachments/assets/a15fb115-059d-4464-86f3-16182afd4c94">
</p>

## Features

- Encrypted Matrix messaging: text, replies, edits, redactions, reactions, forwarding, and copy actions
- Local-first sending with optimistic messages, send queue, and failed-send states
- Media and attachments: images, grouped media, captions, videos, voice messages, files, thumbnails, and Quick Look file previews
- Rooms and people: DMs, group rooms, unread state, encryption indicators, members, profiles, avatars, presence, and last seen
- Companion presence service for realtime online status and last seen updates
- Voice calls using Matrix call events and WebRTC audio
- Custom native UI with asynchronous chat rendering, glass navigation/input bars, chat bubble themes, deletion animation, and custom transitions
- VoiceOver support for the main chat flow

## Architecture

Zyna keeps the Matrix client, local persistence, realtime presence, and UI rendering layers separate.

- **Matrix Rust SDK** provides the Matrix protocol layer: sync, end-to-end encryption, rooms, timelines, and media APIs.
- **GRDB** stores the on-device cache for rooms, messages, and outgoing events.
- **Texture (AsyncDisplayKit)** renders room lists and chat timelines asynchronously.
- **Metal** powers the custom glass UI and message deletion effect.
- **WebRTC** handles voice call media.
- **[Zyna Presence Server](https://github.com/markovsdima/zyna-presence)** provides realtime online status and last seen updates through a lightweight WebSocket service.
- **KeychainAccess** stores session and encryption-related credentials.

This separation lets the app render cached timelines, show pending and failed sends, update presence independently, and keep scrolling responsive while sync, media loading, and uploads continue in the background.

## Implementation Notes

Detailed notes for specific subsystems live in the repo:

- [Navigation](Zyna/Navigation/NAVIGATION.md)
- [Glass renderer](Zyna/Glass/RESEARCH.md)
- [Chat bubble themes](Zyna/Glass/PORTAL.md)
- [Message deletion animation](Zyna/Components/PaintSplash/PAINT_SPLASH.md)
- [Outgoing message layer](Zyna/Chat/OUTGOING_LAYER.md)
- [Media grouping](Zyna/Chat/MEDIA_GROUPING.md)
- [Incoming message assembly](Zyna/Chat/INCOMING_ASSEMBLY.md)
- [Message deletion flow](Zyna/Chat/REDACTION_FLOW.md)
- [Scroll and pagination](Zyna/Chat/SCROLL_AND_PAGINATION.md)
- [Accessibility](Zyna/Accessibility/ACCESSIBILITY.md)

## Requirements

- Xcode 26.3+
- iOS 16.0+
- Carthage 0.39+
- A Matrix account on a compatible homeserver

## Build

```bash
git clone https://github.com/markovsdima/Zyna.git
cd Zyna

carthage bootstrap --use-xcframeworks --platform iOS
open Zyna.xcodeproj
```

Xcode resolves the SPM dependencies on first build.

Build and run the `Zyna` scheme on a simulator or device. On the login screen, enter a Matrix homeserver and sign in with an existing account.

## Collaboration

Open to commercial collaboration around white-label Matrix clients, private deployments, and custom iOS communication products.

Contact: [@markovsdima](https://t.me/markovsdima)

## License

AGPL-3.0-only
