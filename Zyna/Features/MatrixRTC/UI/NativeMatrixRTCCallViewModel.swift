//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Combine
import Foundation
import MatrixRTCLiveKit

private let logNativeCallViewModel = ScopedLog(.call, prefix: "[matrixrtc-native-ui]")

@MainActor
final class NativeMatrixRTCCallViewModel {
    var onDismiss: (() -> Void)?

    @Published private(set) var viewState: NativeMatrixRTCCallViewState

    private let context: NativeMatrixRTCCallLaunchContext
    private let callService: NativeMatrixRTCCallService

    private var cancellables = Set<AnyCancellable>()
    private var startTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var delayedDismissTask: Task<Void, Never>?

    private var serviceState: NativeMatrixRTCCallServiceState
    private var pickupState: NativeMatrixRTCCallPickupState = .inactive
    private var participantsSnapshot = NativeMatrixRTCCallParticipantsSnapshot.empty

    private var hasStartedCall = false
    private var hasSeenActiveState = false
    private var isEndingCall = false
    private var didRequestDismiss = false
    private var areMediaControlsBusy = false
    private var isRaisedHandBusy = false
    private var terminalStatus: String?

    private var isMuted = false
    private var isSpeakerEnabled = false
    private var isCameraEnabled = false

    init(
        context: NativeMatrixRTCCallLaunchContext,
        callService: NativeMatrixRTCCallService = .shared
    ) {
        self.context = context
        self.callService = callService
        self.serviceState = callService.state
        self.viewState = Self.makeViewState(
            context: context,
            serviceState: serviceState,
            pickupState: pickupState,
            participantsSnapshot: participantsSnapshot,
            isMuted: isMuted,
            isSpeakerEnabled: isSpeakerEnabled,
            isCameraEnabled: isCameraEnabled,
            areMediaControlsBusy: areMediaControlsBusy,
            isRaisedHandBusy: isRaisedHandBusy,
            isEndingCall: isEndingCall,
            terminalStatus: terminalStatus
        )

        bindState()
    }

    deinit {
        startTask?.cancel()
        leaveTask?.cancel()
        delayedDismissTask?.cancel()
    }

    func start() {
        guard !hasStartedCall else { return }
        hasStartedCall = true

        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let waitForPickup = context.kind.isDirect && context.direction == .outgoing
                _ = try await callService.startAudioCall(
                    room: context.room,
                    waitForPickup: waitForPickup,
                    autoLeaveWhenOthersLeft: context.kind.isDirect,
                    trackRaisedHands: !context.kind.isDirect
                )
            } catch is CancellationError {
                dismissOnce()
            } catch {
                handleStartFailure(error)
            }
        }
    }

    func handleControl(_ kind: NativeMatrixRTCCallControlKind) {
        switch kind {
        case .microphone:
            toggleMicrophone()
        case .speaker:
            toggleSpeaker()
        case .camera:
            toggleCamera()
        case .switchCamera:
            switchCamera()
        case .raiseHand:
            toggleRaisedHand()
        case .end:
            endCall()
        }
    }
}

private extension NativeMatrixRTCCallViewModel {
    func bindState() {
        callService.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleServiceState(state)
            }
            .store(in: &cancellables)

        callService.participantsSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.handleParticipants(snapshot)
            }
            .store(in: &cancellables)

        callService.pickupStateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pickupState in
                self?.handlePickupState(pickupState)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSpeakerRouteState()
            }
            .store(in: &cancellables)
    }

    func handleServiceState(_ state: NativeMatrixRTCCallServiceState) {
        serviceState = state

        switch state {
        case .idle:
            guard hasStartedCall, hasSeenActiveState || isEndingCall else {
                publish()
                return
            }

            if terminalStatus == nil {
                dismissOnce()
            }
        case .joining(let roomId):
            guard roomId == context.roomID else { return }
            hasSeenActiveState = true
        case .connected(let roomId):
            guard roomId == context.roomID else { return }
            hasSeenActiveState = true
            refreshSpeakerRouteState()
        case .leaving(let roomId):
            guard roomId == context.roomID else { return }
        }

        publish()
    }

    func handleParticipants(_ snapshot: NativeMatrixRTCCallParticipantsSnapshot) {
        if let roomId = snapshot.roomId, roomId != context.roomID {
            return
        }

        participantsSnapshot = snapshot
        publish()
    }

    func handlePickupState(_ state: NativeMatrixRTCCallPickupState) {
        guard state.applies(to: context.roomID) else { return }

        pickupState = state
        switch state {
        case .declined:
            terminalStatus = String(localized: "Declined")
            scheduleDismiss(after: 1.1)
        case .timedOut:
            terminalStatus = String(localized: "No Answer")
            scheduleDismiss(after: 1.2)
        case .inactive, .ringing, .answered:
            break
        }
        publish()
    }

    func handleStartFailure(_ error: Error) {
        logNativeCallViewModel("Failed starting native MatrixRTC call in room \(context.roomID): \(error)")
        if case NativeMatrixRTCCallServiceError.alreadyActive(let activeRoomId) = error,
           activeRoomId == context.roomID {
            terminalStatus = String(localized: "Finishing Previous Call")
            publish()
            scheduleDismiss(after: 0.8)
            return
        }

        terminalStatus = String(localized: "Could Not Start Call")
        publish()
        scheduleDismiss(after: 2.2)
    }

    func toggleMicrophone() {
        let nextMutedState = !isMuted
        setMediaControlsBusy(true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await callService.setMicrophoneEnabled(!nextMutedState)
                isMuted = nextMutedState
            } catch {
                logNativeCallViewModel("Failed toggling native MatrixRTC microphone: \(error)")
            }
            setMediaControlsBusy(false)
        }
    }

    func toggleSpeaker() {
        let nextSpeakerEnabledState = !isSpeakerEnabled
        setMediaControlsBusy(true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try callService.setSpeakerEnabled(nextSpeakerEnabledState)
                isSpeakerEnabled = nextSpeakerEnabledState
            } catch {
                logNativeCallViewModel("Failed toggling native MatrixRTC speaker output: \(error)")
                refreshSpeakerRouteState()
            }
            setMediaControlsBusy(false)
        }
    }

    func toggleCamera() {
        let nextCameraEnabledState = !isCameraEnabled
        setMediaControlsBusy(true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await callService.setCameraEnabled(nextCameraEnabledState)
                isCameraEnabled = nextCameraEnabledState
            } catch {
                logNativeCallViewModel("Failed toggling native MatrixRTC camera: \(error)")
            }
            setMediaControlsBusy(false)
        }
    }

    func switchCamera() {
        guard isCameraEnabled else { return }
        setMediaControlsBusy(true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await callService.switchCameraPosition()
            } catch {
                logNativeCallViewModel("Failed switching native MatrixRTC camera position: \(error)")
            }
            setMediaControlsBusy(false)
        }
    }

    func toggleRaisedHand() {
        guard !context.kind.isDirect, !isRaisedHandBusy else { return }
        setRaisedHandBusy(true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await callService.toggleRaisedHand()
            } catch {
                logNativeCallViewModel("Failed toggling native MatrixRTC raised hand: \(error)")
            }
            setRaisedHandBusy(false)
        }
    }

    func endCall() {
        guard !isEndingCall else { return }
        isEndingCall = true
        startTask?.cancel()
        publish()

        leaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await callService.leaveActiveCall()
            } catch {
                logNativeCallViewModel("Failed leaving native MatrixRTC call in room \(context.roomID): \(error)")
            }
            dismissOnce()
        }
    }

    func setMediaControlsBusy(_ isBusy: Bool) {
        areMediaControlsBusy = isBusy
        publish()
    }

    func setRaisedHandBusy(_ isBusy: Bool) {
        isRaisedHandBusy = isBusy
        publish()
    }

    func refreshSpeakerRouteState() {
        isSpeakerEnabled = callService.isSpeakerEnabled
        publish()
    }

    func scheduleDismiss(after delay: TimeInterval) {
        delayedDismissTask?.cancel()
        delayedDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            self?.dismissOnce()
        }
    }

    func dismissOnce() {
        guard !didRequestDismiss else { return }
        didRequestDismiss = true
        onDismiss?()
    }

    func publish() {
        viewState = Self.makeViewState(
            context: context,
            serviceState: serviceState,
            pickupState: pickupState,
            participantsSnapshot: participantsSnapshot,
            isMuted: isMuted,
            isSpeakerEnabled: isSpeakerEnabled,
            isCameraEnabled: isCameraEnabled,
            areMediaControlsBusy: areMediaControlsBusy,
            isRaisedHandBusy: isRaisedHandBusy,
            isEndingCall: isEndingCall,
            terminalStatus: terminalStatus
        )
    }
}

private extension NativeMatrixRTCCallViewModel {
    static func makeViewState(
        context: NativeMatrixRTCCallLaunchContext,
        serviceState: NativeMatrixRTCCallServiceState,
        pickupState: NativeMatrixRTCCallPickupState,
        participantsSnapshot: NativeMatrixRTCCallParticipantsSnapshot,
        isMuted: Bool,
        isSpeakerEnabled: Bool,
        isCameraEnabled: Bool,
        areMediaControlsBusy: Bool,
        isRaisedHandBusy: Bool,
        isEndingCall: Bool,
        terminalStatus: String?
    ) -> NativeMatrixRTCCallViewState {
        let status = statusText(
            context: context,
            serviceState: serviceState,
            pickupState: pickupState,
            participantsSnapshot: participantsSnapshot,
            isMuted: isMuted,
            isEndingCall: isEndingCall,
            terminalStatus: terminalStatus
        )
        let controls = controls(
            showsRaisedHand: !context.kind.isDirect,
            serviceState: serviceState,
            isMuted: isMuted,
            isSpeakerEnabled: isSpeakerEnabled,
            isCameraEnabled: isCameraEnabled,
            areMediaControlsBusy: areMediaControlsBusy,
            isRaisedHandRaised: participantsSnapshot.localRaisedHand.isRaised,
            isRaisedHandBusy: isRaisedHandBusy,
            isEndingCall: isEndingCall,
            terminalStatus: terminalStatus
        )

        switch context.kind {
        case .direct(let peer):
            let stage = NativeMatrixRTCDirectCallStageState(
                peer: peer,
                title: peer.displayName,
                status: status.text,
                isStatusBusy: status.isBusy,
                remoteVideoTrack: participantsSnapshot.primaryRemoteVideoTrack,
                localVideoTrack: participantsSnapshot.localVideoTrack
            )
            let hasRemoteVideo = participantsSnapshot.primaryRemoteVideoTrack != nil
            return NativeMatrixRTCCallViewState(
                kind: context.kind,
                stage: .direct(stage),
                topBar: hasRemoteVideo ? .init(
                    title: peer.displayName,
                    status: status.text,
                    isStatusBusy: status.isBusy
                ) : nil,
                controls: controls
            )

        case .group(let room):
            let stage = NativeMatrixRTCGroupCallStageState(
                room: room,
                tiles: groupTiles(from: participantsSnapshot, isMuted: isMuted),
                emptyTitle: room.displayName,
                emptyStatus: status.text
            )
            return NativeMatrixRTCCallViewState(
                kind: context.kind,
                stage: .group(stage),
                topBar: .init(
                    title: room.displayName,
                    status: status.text,
                    isStatusBusy: status.isBusy
                ),
                controls: controls
            )
        }
    }

    static func statusText(
        context: NativeMatrixRTCCallLaunchContext,
        serviceState: NativeMatrixRTCCallServiceState,
        pickupState: NativeMatrixRTCCallPickupState,
        participantsSnapshot: NativeMatrixRTCCallParticipantsSnapshot,
        isMuted: Bool,
        isEndingCall: Bool,
        terminalStatus: String?
    ) -> (text: String, isBusy: Bool) {
        if let terminalStatus {
            return (terminalStatus, false)
        }

        if isEndingCall {
            return (String(localized: "Leaving..."), true)
        }

        switch serviceState {
        case .idle:
            return (String(localized: "Connecting..."), true)
        case .joining:
            return (context.kind.isDirect ? String(localized: "Connecting...") : String(localized: "Joining..."), true)
        case .leaving:
            return (String(localized: "Leaving..."), true)
        case .connected:
            break
        }

        if context.kind.isDirect {
            switch pickupState {
            case .ringing:
                return (String(localized: "Ringing..."), true)
            case .declined:
                return (String(localized: "Declined"), false)
            case .timedOut:
                return (String(localized: "No Answer"), false)
            case .answered, .inactive:
                break
            }

            guard participantsSnapshot.remoteParticipantCount > 0 else {
                let text = context.direction == .outgoing
                    ? String(localized: "Calling...")
                    : String(localized: "Connecting...")
                return (text, true)
            }

            return (isMuted ? String(localized: "Microphone Muted") : String(localized: "Connected"), false)
        }

        guard participantsSnapshot.remoteParticipantCount > 0 else {
            return (String(localized: "Waiting for others"), false)
        }

        let count = participantsSnapshot.totalParticipantCount
        let countText = count == 2
            ? String(localized: "2 Participants")
            : String.localizedStringWithFormat(String(localized: "%lld Participants"), Int64(count))
        if isMuted {
            return ("\(String(localized: "Microphone Muted")) - \(countText)", false)
        }
        return (countText, false)
    }

    static func controls(
        showsRaisedHand: Bool,
        serviceState: NativeMatrixRTCCallServiceState,
        isMuted: Bool,
        isSpeakerEnabled: Bool,
        isCameraEnabled: Bool,
        areMediaControlsBusy: Bool,
        isRaisedHandRaised: Bool,
        isRaisedHandBusy: Bool,
        isEndingCall: Bool,
        terminalStatus: String?
    ) -> [NativeMatrixRTCCallControlState] {
        let isConnected: Bool
        if case .connected = serviceState {
            isConnected = true
        } else {
            isConnected = false
        }

        let canToggleMedia = isConnected && !areMediaControlsBusy && !isEndingCall && terminalStatus == nil
        let canHangUp = !isEndingCall && terminalStatus == nil
        let standardSize: CGFloat = showsRaisedHand ? 48 : 56
        let endSize: CGFloat = showsRaisedHand ? 56 : 64

        var controls: [NativeMatrixRTCCallControlState] = [
            .init(
                kind: .microphone,
                symbolName: isMuted ? "mic.slash.fill" : "mic.fill",
                accessibilityLabel: isMuted ? String(localized: "Unmute") : String(localized: "Mute"),
                style: isMuted ? .warning : .neutral,
                isEnabled: canToggleMedia,
                size: standardSize
            ),
            .init(
                kind: .speaker,
                symbolName: isSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                accessibilityLabel: isSpeakerEnabled ? String(localized: "Speaker Off") : String(localized: "Speaker On"),
                style: isSpeakerEnabled ? .active : .neutral,
                isEnabled: canToggleMedia,
                size: standardSize
            ),
            .init(
                kind: .camera,
                symbolName: isCameraEnabled ? "video.fill" : "video.slash.fill",
                accessibilityLabel: isCameraEnabled ? String(localized: "Turn Camera Off") : String(localized: "Turn Camera On"),
                style: isCameraEnabled ? .active : .neutral,
                isEnabled: canToggleMedia,
                size: standardSize
            ),
            .init(
                kind: .switchCamera,
                symbolName: "camera.rotate.fill",
                accessibilityLabel: String(localized: "Switch Camera"),
                style: .neutral,
                isEnabled: canToggleMedia && isCameraEnabled,
                size: standardSize
            )
        ]

        if showsRaisedHand {
            controls.append(.init(
                kind: .raiseHand,
                symbolName: isRaisedHandRaised ? "hand.raised.fill" : "hand.raised",
                accessibilityLabel: isRaisedHandRaised
                    ? String(localized: "Lower Hand")
                    : String(localized: "Raise Hand"),
                style: isRaisedHandRaised ? .active : .neutral,
                isEnabled: canToggleMedia && !isRaisedHandBusy,
                size: standardSize
            ))
        }

        controls.append(
            .init(
                kind: .end,
                symbolName: "phone.down.fill",
                accessibilityLabel: String(localized: "End Call"),
                style: .destructive,
                isEnabled: canHangUp,
                size: endSize
            )
        )

        return controls
    }

    static func groupTiles(
        from snapshot: NativeMatrixRTCCallParticipantsSnapshot,
        isMuted: Bool
    ) -> [NativeMatrixRTCParticipantTileState] {
        var candidates: [NativeMatrixRTCParticipantTileCandidate] = []

        for participant in snapshot.remoteParticipants {
            let identity = participant.identity ?? participant.sid ?? participant.id
            let participantDisplayName = displayName(for: identity)
            let videoTrack = firstRemoteVideoTrack(in: participant).map {
                NativeMatrixRTCVideoTrackHandle.remote($0)
            }
            let avatar = AvatarViewModel(
                userId: identity,
                displayName: participantDisplayName,
                mxcAvatarURL: nil
            )
            candidates.append(NativeMatrixRTCParticipantTileCandidate(
                tile: NativeMatrixRTCParticipantTileState(
                    id: participant.id,
                    displayName: participantDisplayName,
                    avatar: avatar,
                    videoTrack: videoTrack,
                    isAudioMuted: !participant.hasSubscribedAudio,
                    isHandRaised: participant.raisedHand.isRaised,
                    isLocal: false,
                    statusText: participantStatusText(participant)
                ),
                speaking: participant.speaking,
                raisedHand: participant.raisedHand,
                stableName: participantDisplayName
            ))
        }

        let identity = snapshot.localIdentity ?? "local"
        let localDisplayName = String(localized: "You")
        let localVideoTrack = snapshot.localVideoTrack.map {
            NativeMatrixRTCVideoTrackHandle.local($0)
        }
        candidates.append(NativeMatrixRTCParticipantTileCandidate(
            tile: NativeMatrixRTCParticipantTileState(
                id: "local",
                displayName: localDisplayName,
                avatar: AvatarViewModel(
                    userId: identity,
                    displayName: localDisplayName,
                    mxcAvatarURL: nil
                ),
                videoTrack: localVideoTrack,
                isAudioMuted: isMuted,
                isHandRaised: snapshot.localRaisedHand.isRaised,
                isLocal: true,
                statusText: nil
            ),
            speaking: snapshot.localSpeaking,
            raisedHand: snapshot.localRaisedHand,
            stableName: localDisplayName
        ))

        return candidates.sorted(by: tileCandidatePrecedes).map(\.tile)
    }

    static func tileCandidatePrecedes(
        _ lhs: NativeMatrixRTCParticipantTileCandidate,
        _ rhs: NativeMatrixRTCParticipantTileCandidate
    ) -> Bool {
        if lhs.speaking.isSpeaking != rhs.speaking.isSpeaking {
            return lhs.speaking.isSpeaking
        }

        if lhs.raisedHand.isRaised != rhs.raisedHand.isRaised {
            return lhs.raisedHand.isRaised
        }

        switch (lhs.raisedHand.raisedAt, rhs.raisedHand.raisedAt) {
        case (.some(let lhsDate), .some(let rhsDate)) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }

        switch (lhs.speaking.lastSpokeAt, rhs.speaking.lastSpokeAt) {
        case (.some(let lhsDate), .some(let rhsDate)) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }

        if lhs.stableName != rhs.stableName {
            return lhs.stableName < rhs.stableName
        }
        return lhs.tile.id < rhs.tile.id
    }

    static func firstRemoteVideoTrack(
        in participant: NativeMatrixRTCCallParticipantState
    ) -> MatrixRTCLiveKitRemoteVideoTrack? {
        for track in participant.sortedTracks where track.isVideo && track.isSubscribed && !track.isMuted {
            if let remoteVideoTrack = track.remoteVideoTrack {
                return remoteVideoTrack
            }
        }
        return nil
    }

    static func participantStatusText(_ participant: NativeMatrixRTCCallParticipantState) -> String? {
        if participant.tracks.values.contains(where: { $0.subscriptionError != nil }) {
            return String(localized: "Media unavailable")
        }
        if participant.tracks.values.contains(where: { $0.streamState?.localizedCaseInsensitiveContains("paused") == true }) {
            return String(localized: "Paused")
        }
        return nil
    }

    static func displayName(for identity: String) -> String {
        guard !identity.isEmpty else { return String(localized: "Unknown") }
        return identity
    }
}

private struct NativeMatrixRTCParticipantTileCandidate {
    let tile: NativeMatrixRTCParticipantTileState
    let speaking: NativeMatrixRTCCallSpeakingState
    let raisedHand: NativeMatrixRTCCallRaisedHandState
    let stableName: String
}

private extension NativeMatrixRTCCallPickupState {
    func applies(to roomID: String) -> Bool {
        switch self {
        case .inactive:
            return true
        case .ringing(let roomId, _, _),
             .answered(let roomId),
             .declined(let roomId),
             .timedOut(let roomId):
            return roomId == roomID
        }
    }
}
