//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRTCLiveKit
import MatrixRustSDK

struct NativeMatrixRTCCallPeer {
    let id: String
    let displayName: String
    let avatar: AvatarViewModel
}

struct NativeMatrixRTCCallRoomInfo {
    let id: String
    let displayName: String
    let avatar: AvatarViewModel
}

enum NativeMatrixRTCCallKind {
    case direct(peer: NativeMatrixRTCCallPeer)
    case group(room: NativeMatrixRTCCallRoomInfo)

    var isDirect: Bool {
        if case .direct = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .direct(let peer):
            return peer.displayName
        case .group(let room):
            return room.displayName
        }
    }

    var avatar: AvatarViewModel {
        switch self {
        case .direct(let peer):
            return peer.avatar
        case .group(let room):
            return room.avatar
        }
    }
}

enum NativeMatrixRTCCallMediaIntent {
    case audio
    case video
}

struct NativeMatrixRTCCallLaunchContext {
    let room: Room
    let roomDisplayName: String
    let kind: NativeMatrixRTCCallKind
    let direction: CallDirection
    let initialMedia: NativeMatrixRTCCallMediaIntent

    var roomID: String {
        room.id()
    }
}

enum NativeMatrixRTCVideoTrackHandle {
    case local(MatrixRTCLiveKitLocalVideoTrack)
    case remote(MatrixRTCLiveKitRemoteVideoTrack)

    var id: String {
        switch self {
        case .local(let track):
            return track.id
        case .remote(let track):
            return track.id
        }
    }
}

struct NativeMatrixRTCParticipantTileState {
    let id: String
    let displayName: String
    let avatar: AvatarViewModel
    let videoTrack: NativeMatrixRTCVideoTrackHandle?
    let isAudioMuted: Bool
    let isHandRaised: Bool
    let isLocal: Bool
    let statusText: String?
}

struct NativeMatrixRTCDirectCallStageState {
    let title: String
    let status: String
    let isStatusBusy: Bool
    let primaryTile: NativeMatrixRTCParticipantTileState
    let previewTile: NativeMatrixRTCParticipantTileState?
}

struct NativeMatrixRTCGroupCallStageState {
    let room: NativeMatrixRTCCallRoomInfo
    let tiles: [NativeMatrixRTCParticipantTileState]
    let emptyTitle: String
    let emptyStatus: String
}

enum NativeMatrixRTCCallStageState {
    case direct(NativeMatrixRTCDirectCallStageState)
    case group(NativeMatrixRTCGroupCallStageState)
}

struct NativeMatrixRTCCallTopBarState {
    let title: String
    let status: String
    let isStatusBusy: Bool
}

enum NativeMatrixRTCCallControlKind: CaseIterable {
    case microphone
    case speaker
    case camera
    case switchCamera
    case raiseHand
    case end
}

enum NativeMatrixRTCCallControlStyle {
    case neutral
    case active
    case warning
    case destructive
}

struct NativeMatrixRTCCallControlState {
    let kind: NativeMatrixRTCCallControlKind
    let symbolName: String
    let accessibilityLabel: String
    let style: NativeMatrixRTCCallControlStyle
    let isEnabled: Bool
    let size: CGFloat
}

struct NativeMatrixRTCCallViewState {
    let kind: NativeMatrixRTCCallKind
    let stage: NativeMatrixRTCCallStageState
    let topBar: NativeMatrixRTCCallTopBarState?
    let controls: [NativeMatrixRTCCallControlState]
}
