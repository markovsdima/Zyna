
<img width="1206" height="799" alt="ZynaGitHubLogo" src="https://github.com/user-attachments/assets/0ef25bcc-f1c9-49f6-812e-c9883ad98876" /><br>


**Matrix-based iOS messenger with a focus on visual interaction**

Zyna is an iOS client for the Matrix protocol. The core messaging works — text, images, voice messages, VoIP calls. On top of that, it explores what a messenger can look like when you invest in animations and GPU-rendered effects (Metal shaders for message deletion, 120fps scroll, custom transitions).

End-to-end encrypted. Open source. Work in progress.

## 📦 What's Built

**Messaging**
- Text, image, and voice messages
- Voice recording with waveform visualization, lock gesture, and slide-to-cancel
- Emoji reactions with custom context menu
- Message deletion with paint-splash animation (Metal compute shaders)
- Image preprocessing and thumbnail caching

**Calls**
- VoIP calls over WebRTC with ICE candidate exchange

**Authentication**
- Password login and OIDC registration
- Session restore from Keychain
- Device verification

**Rooms**
- Real-time room list with sliding sync
- Unread badges, last message preview, encryption indicators
- DM and group creation

**Profile & Presence**
- Editable profile with avatar upload
- Online / offline / last seen indicators

**Performance**
- 120fps scroll optimization
- Full-screen swipe-to-pop navigation

## 🔧 Tech Stack & Architecture

- **Matrix Rust SDK** — messaging, E2E encryption, sliding sync
- **Texture (AsyncDisplayKit)** — async UI rendering
- **Combine** — reactive state and data flow
- **Metal** — GPU-accelerated visual effects
- **WebRTC** — peer-to-peer voice calls
- **KeychainAccess** — session and credential storage

Coordinator pattern for navigation. Texture nodes for screens, SwiftUI for auth flow.

## 🗺 Up Next

- Settings screen (theme, notifications, account management)
- CallKit integration
- Push notifications
- Local database (GRDB) for offline-first UI
- Visual message styling and color-coded conversations
- App Store release

## ⚡ Getting Started

**Requirements**
- Xcode 16.2+
- iOS 16.0+
- [Carthage](https://github.com/Carthage/Carthage) 0.39+

**Build**

```bash
git clone https://github.com/markovsdima/Zyna.git
cd Zyna

# Rebuild Carthage dependencies if needed (pre-built frameworks are included):
carthage bootstrap --use-xcframeworks --platform iOS

open Zyna.xcodeproj
```

SPM dependencies (Matrix Rust SDK, WebRTC, KeychainAccess, GRDB) resolve automatically on first build.

**Run**

Build and run on a simulator or device. On the login screen, enter any Matrix homeserver (defaults to `matrix.org`). You can use an existing account or register via OIDC if the server supports it.

## License

AGPL-3.0
