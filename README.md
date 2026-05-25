# Zyna

**Zyna is an open-source native iOS client for Matrix, focused on encrypted communication, durable messaging, rich media, voice calls, and a custom native UI.**

It is built with Matrix Rust SDK, GRDB, SQLCipher, Texture, Metal, WebRTC, and lightweight companion services for realtime presence and push.

Demo: [YouTube quick tour](https://youtube.com/shorts/Tv3BSCmnINg?feature=share)

<p align="center">
  <img width="340" alt="Zyna app preview" src="https://github.com/user-attachments/assets/0ef25bcc-f1c9-49f6-812e-c9883ad98876">
  &nbsp;
  <img width="240" alt="Zyna message deletion effect" src="https://github.com/user-attachments/assets/a15fb115-059d-4464-86f3-16182afd4c94">
</p>

## Features

- Encrypted Matrix messaging: text, replies, edits, redactions, reactions, forwarding, copy actions, and pinned messages
- Durable local-first sending with optimistic UI, app-owned retry, failed-send states, and recovery after app restarts
- Rich media and attachments: images, grouped photo presentation, captions, videos, voice messages, files, thumbnails, forwarded media, and Quick Look previews
- Rooms and people: DMs, group rooms, public room discovery, unread state, encryption indicators, members, profiles, avatars, presence, and last seen
- Matrix Spaces support presented as Storylines and Tracks, with creation flows, nested organization, and room-space link management
- Room management: invites, member lists, leave flow, security and privacy settings, roles, permissions, access rules, and directory visibility
- Security and recovery flows for verified devices, encrypted key backup, soft logout, device sessions, and trust-aware send failures
- Encrypted local app database and protected per-user local storage for cached messages, media, and outgoing state
- Voice calls using Matrix call events and WebRTC audio
- Custom native UI with responsive Texture-based chat timelines, glass navigation/input bars, Metal-powered effects, chat bubble themes, custom transitions, swipe-to-reply, and persistent voice playback
- VoiceOver support across the main chat, rooms, glass controls, and detail flows

## Architecture

Zyna separates protocol handling, encrypted local storage, outgoing delivery, security/recovery flows, companion services, and native UI rendering into distinct subsystems.

- **Matrix Rust SDK** provides the Matrix protocol layer: sync, end-to-end encryption, rooms, timelines, media APIs, calls, verification, and recovery.
- **Zyna Matrix SDK bindings** add direct send helpers that accept caller-provided transaction IDs and return accepted Matrix event IDs.
- **GRDB + SQLCipher** store the encrypted on-device cache for rooms, messages, outgoing envelopes, pending media, reactions, redactions, and recovery state.
- **App-owned outgoing outboxes** persist user intent before transport, retry safely after restarts, and bind sent items by Matrix event ID once the server accepts them.
- **Texture (AsyncDisplayKit)** keeps room lists, space lists, and chat timelines responsive through asynchronous layout, display, and preloading.
- **Metal** powers the custom glass UI, glyph rendering, voice playback chrome, storyline link hero, and message deletion effect.
- **WebRTC** handles voice call media.
- **KeychainAccess** stores Matrix sessions, crypto store passphrases, database keys, and sensitive local credentials.
- **[Zyna Presence Server](https://github.com/markovsdima/zyna-presence)** provides realtime online status and last seen updates through a lightweight WebSocket service.

This structure lets Zyna render cached timelines, keep pending sends stable, recover after network loss or app termination, protect local data, and keep the UI responsive while sync, media upload, encryption, and retry work continue in the background.

## Implementation Notes

Detailed notes for specific subsystems live in the repo:

- [Navigation](Zyna/Navigation/NAVIGATION.md)
- [Glass renderer](Zyna/Glass/RESEARCH.md)
- [Chat bubble themes](Zyna/Glass/PORTAL.md)
- [Message deletion animation](Zyna/Components/PaintSplash/PAINT_SPLASH.md)
- [Outgoing message layer](Zyna/Chat/OUTGOING_LAYER.md)
- [Direct media sending](Zyna/Chat/MEDIA_DIRECT_SEND.md)
- [Matrix SDK direct-send FFI](Zyna/Chat/MATRIX_SDK_DIRECT_SEND_FFI.md)
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
