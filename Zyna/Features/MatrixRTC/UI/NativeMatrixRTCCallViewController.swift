//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Combine
import MatrixRTCLiveKit
import MatrixRustSDK
import UIKit

private let log = ScopedLog(.call, prefix: "[matrixrtc-native-ui]")

final class NativeMatrixRTCCallViewController: UIViewController {
    var onDismiss: (() -> Void)?

    let roomID: String

    private let room: Room
    private let roomDisplayName: String
    private let callService: NativeMatrixRTCCallService

    private let remoteVideoContainerView = UIView()
    private let remoteVideoGridView = NativeMatrixRTCRemoteVideoGridView()
    private let localVideoContainerView = UIView()
    private let localVideoView = MatrixRTCLiveKitVideoView()
    private let avatarView = UIView()
    private let avatarImageView = UIImageView()
    private let titleLabel = UILabel()
    private let statusStack = UIStackView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let controlsStack = UIStackView()
    private let muteButton = UIButton(type: .system)
    private let speakerButton = UIButton(type: .system)
    private let cameraButton = UIButton(type: .system)
    private let switchCameraButton = UIButton(type: .system)
    private let endCallButton = UIButton(type: .system)

    private var cancellables = Set<AnyCancellable>()
    private var startTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var hasStartedCall = false
    private var hasSeenActiveState = false
    private var isEndingCall = false
    private var didRequestDismiss = false
    private var participantsSnapshot = NativeMatrixRTCCallParticipantsSnapshot.empty
    private var currentRemoteVideoTrackIds: [String] = []
    private var currentLocalVideoTrackId: String?
    private var titleBelowAvatarConstraint: NSLayoutConstraint?
    private var titleBelowVideoConstraint: NSLayoutConstraint?
    private var localVideoFullConstraints: [NSLayoutConstraint] = []
    private var localVideoPreviewConstraints: [NSLayoutConstraint] = []
    private var isMuted = false {
        didSet {
            updateMuteButton()
            updateConnectedStatus()
        }
    }
    private var isSpeakerEnabled = false {
        didSet {
            updateSpeakerButton()
        }
    }
    private var isCameraEnabled = false {
        didSet {
            updateCameraButton()
            updateConnectedStatus()
        }
    }

    init(
        room: Room,
        roomDisplayName: String,
        callService: NativeMatrixRTCCallService = .shared
    ) {
        self.room = room
        self.roomID = room.id()
        self.roomDisplayName = roomDisplayName
        self.callService = callService
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        startTask?.cancel()
        leaveTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        bindState()
        startCall()
    }
}

private extension NativeMatrixRTCCallViewController {
    func setupView() {
        view.backgroundColor = .systemBackground

        remoteVideoContainerView.translatesAutoresizingMaskIntoConstraints = false
        remoteVideoContainerView.backgroundColor = .black
        remoteVideoContainerView.layer.cornerRadius = 8
        remoteVideoContainerView.clipsToBounds = true
        remoteVideoContainerView.isHidden = true

        remoteVideoGridView.translatesAutoresizingMaskIntoConstraints = false
        remoteVideoGridView.backgroundColor = .black

        localVideoContainerView.translatesAutoresizingMaskIntoConstraints = false
        localVideoContainerView.backgroundColor = .black
        localVideoContainerView.layer.cornerRadius = 8
        localVideoContainerView.layer.borderColor = UIColor.separator.cgColor
        localVideoContainerView.layer.borderWidth = 1
        localVideoContainerView.clipsToBounds = true
        localVideoContainerView.isHidden = true

        localVideoView.translatesAutoresizingMaskIntoConstraints = false
        localVideoView.layoutMode = .fit
        localVideoView.mirrorMode = .auto
        localVideoView.backgroundColor = .black

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.backgroundColor = .secondarySystemFill
        avatarView.layer.cornerRadius = 56
        avatarView.clipsToBounds = true

        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.image = UIImage(
            systemName: "phone.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        )
        avatarImageView.tintColor = .secondaryLabel
        avatarImageView.contentMode = .center

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = roomDisplayName
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.78

        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.axis = .horizontal
        statusStack.alignment = .center
        statusStack.spacing = 8

        activityIndicator.hidesWhenStopped = true

        statusLabel.font = .systemFont(ofSize: 16, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.82

        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.axis = .horizontal
        controlsStack.alignment = .center
        controlsStack.distribution = .equalSpacing
        controlsStack.spacing = 8

        configureControlButton(
            muteButton,
            systemName: "mic.fill",
            backgroundColor: .systemGray,
            size: 56
        )
        muteButton.accessibilityLabel = "Mute"
        muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)

        configureControlButton(
            speakerButton,
            systemName: "speaker.wave.2.fill",
            backgroundColor: .systemGray,
            size: 56
        )
        speakerButton.accessibilityLabel = "Speaker"
        speakerButton.addTarget(self, action: #selector(speakerTapped), for: .touchUpInside)

        configureControlButton(
            cameraButton,
            systemName: "video.fill",
            backgroundColor: .systemGray,
            size: 56
        )
        cameraButton.accessibilityLabel = "Camera"
        cameraButton.addTarget(self, action: #selector(cameraTapped), for: .touchUpInside)

        configureControlButton(
            switchCameraButton,
            systemName: "camera.rotate.fill",
            backgroundColor: .systemGray,
            size: 56
        )
        switchCameraButton.accessibilityLabel = "Switch Camera"
        switchCameraButton.addTarget(self, action: #selector(switchCameraTapped), for: .touchUpInside)

        configureControlButton(
            endCallButton,
            systemName: "phone.down.fill",
            backgroundColor: .systemRed,
            size: 64
        )
        endCallButton.accessibilityLabel = "End Call"
        endCallButton.addTarget(self, action: #selector(endCallTapped), for: .touchUpInside)

        view.addSubview(remoteVideoContainerView)
        remoteVideoContainerView.addSubview(remoteVideoGridView)
        remoteVideoContainerView.addSubview(localVideoContainerView)
        localVideoContainerView.addSubview(localVideoView)
        view.addSubview(avatarView)
        avatarView.addSubview(avatarImageView)
        view.addSubview(titleLabel)
        view.addSubview(statusStack)
        statusStack.addArrangedSubview(activityIndicator)
        statusStack.addArrangedSubview(statusLabel)
        view.addSubview(controlsStack)
        controlsStack.addArrangedSubview(muteButton)
        controlsStack.addArrangedSubview(speakerButton)
        controlsStack.addArrangedSubview(cameraButton)
        controlsStack.addArrangedSubview(switchCameraButton)
        controlsStack.addArrangedSubview(endCallButton)

        titleBelowAvatarConstraint = titleLabel.topAnchor.constraint(
            equalTo: avatarView.bottomAnchor,
            constant: 28
        )
        titleBelowVideoConstraint = titleLabel.topAnchor.constraint(
            equalTo: remoteVideoContainerView.bottomAnchor,
            constant: 18
        )
        titleBelowVideoConstraint?.isActive = false
        localVideoFullConstraints = [
            localVideoContainerView.topAnchor.constraint(equalTo: remoteVideoContainerView.topAnchor),
            localVideoContainerView.leadingAnchor.constraint(equalTo: remoteVideoContainerView.leadingAnchor),
            localVideoContainerView.trailingAnchor.constraint(equalTo: remoteVideoContainerView.trailingAnchor),
            localVideoContainerView.bottomAnchor.constraint(equalTo: remoteVideoContainerView.bottomAnchor)
        ]
        localVideoPreviewConstraints = [
            localVideoContainerView.trailingAnchor.constraint(equalTo: remoteVideoContainerView.trailingAnchor, constant: -10),
            localVideoContainerView.bottomAnchor.constraint(equalTo: remoteVideoContainerView.bottomAnchor, constant: -10),
            localVideoContainerView.widthAnchor.constraint(equalToConstant: 112),
            localVideoContainerView.heightAnchor.constraint(equalTo: localVideoContainerView.widthAnchor, multiplier: 4.0 / 3.0)
        ]

        NSLayoutConstraint.activate([
            remoteVideoContainerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            remoteVideoContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            remoteVideoContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            remoteVideoContainerView.heightAnchor.constraint(equalTo: remoteVideoContainerView.widthAnchor, multiplier: 9.0 / 16.0),

            remoteVideoGridView.topAnchor.constraint(equalTo: remoteVideoContainerView.topAnchor),
            remoteVideoGridView.leadingAnchor.constraint(equalTo: remoteVideoContainerView.leadingAnchor),
            remoteVideoGridView.trailingAnchor.constraint(equalTo: remoteVideoContainerView.trailingAnchor),
            remoteVideoGridView.bottomAnchor.constraint(equalTo: remoteVideoContainerView.bottomAnchor),

            localVideoView.topAnchor.constraint(equalTo: localVideoContainerView.topAnchor),
            localVideoView.leadingAnchor.constraint(equalTo: localVideoContainerView.leadingAnchor),
            localVideoView.trailingAnchor.constraint(equalTo: localVideoContainerView.trailingAnchor),
            localVideoView.bottomAnchor.constraint(equalTo: localVideoContainerView.bottomAnchor),

            avatarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            avatarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 96),
            avatarView.widthAnchor.constraint(equalToConstant: 112),
            avatarView.heightAnchor.constraint(equalToConstant: 112),

            avatarImageView.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarImageView.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),

            titleBelowAvatarConstraint!,
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            statusStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            statusStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),

            controlsStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -56)
        ])

        setStatus("Connecting...", isBusy: true)
        updateControls(canToggleMedia: false, canHangUp: true)
        updateMuteButton()
        updateSpeakerButton()
        updateCameraButton()
    }

    func configureControlButton(
        _ button: UIButton,
        systemName: String,
        backgroundColor: UIColor,
        size: CGFloat
    ) {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(
            systemName: systemName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        )
        configuration.baseBackgroundColor = backgroundColor
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = size / 2
        button.clipsToBounds = true

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size)
        ])
    }

    func bindState() {
        callService.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.update(for: state)
            }
            .store(in: &cancellables)

        callService.participantsSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.updateParticipants(snapshot)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSpeakerRouteState()
            }
            .store(in: &cancellables)
    }

    func startCall() {
        guard !hasStartedCall else { return }
        hasStartedCall = true

        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await callService.startAudioCall(room: room)
            } catch is CancellationError {
                dismissOnce()
            } catch {
                handleStartFailure(error)
            }
        }
    }

    func update(for state: NativeMatrixRTCCallServiceState) {
        switch state {
        case .idle:
            guard hasStartedCall, hasSeenActiveState || isEndingCall else { return }
            dismissOnce()

        case .joining(let roomId):
            guard roomId == roomID else { return }
            hasSeenActiveState = true
            setStatus("Connecting...", isBusy: true)
            updateControls(canToggleMedia: false, canHangUp: true)

        case .connected(let roomId):
            guard roomId == roomID else { return }
            hasSeenActiveState = true
            refreshSpeakerRouteState()
            updateConnectedStatus()
            updateControls(canToggleMedia: true, canHangUp: true)

        case .leaving(let roomId):
            guard roomId == roomID else { return }
            setStatus("Leaving...", isBusy: true)
            updateControls(canToggleMedia: false, canHangUp: false)
        }
    }

    func handleStartFailure(_ error: Error) {
        log("Failed starting native MatrixRTC call in room \(roomID): \(error)")
        if case NativeMatrixRTCCallServiceError.alreadyActive(let activeRoomId) = error,
           activeRoomId == roomID {
            setStatus("Finishing previous call...", isBusy: true)
            updateControls(canToggleMedia: false, canHangUp: false)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.dismissOnce()
            }
            return
        }

        setStatus("Could not start call", isBusy: false)
        updateControls(canToggleMedia: false, canHangUp: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.dismissOnce()
        }
    }

    func updateConnectedStatus() {
        guard case .connected(let roomId) = callService.state, roomId == roomID else { return }
        guard participantsSnapshot.remoteParticipantCount > 0 else {
            setStatus("Calling...", isBusy: true)
            return
        }

        let baseStatus = isMuted
            ? "Microphone muted"
            : "Connected"
        let status = participantStatusSuffix().map { "\(baseStatus) - \($0)" }
            ?? baseStatus
        setStatus(status, isBusy: false)
    }

    func updateParticipants(_ snapshot: NativeMatrixRTCCallParticipantsSnapshot) {
        if let roomId = snapshot.roomId, roomId != roomID {
            return
        }

        participantsSnapshot = snapshot
        updateVideoSurface(
            localVideoTrack: snapshot.localVideoTrack,
            remoteVideoTracks: snapshot.remoteVideoTracks
        )
        updateConnectedStatus()
    }

    func participantStatusSuffix() -> String? {
        let totalCount = participantsSnapshot.totalParticipantCount
        guard totalCount > 1 else { return nil }
        return totalCount == 2
            ? "2 participants"
            : "\(totalCount) participants"
    }

    func updateVideoSurface(
        localVideoTrack: MatrixRTCLiveKitLocalVideoTrack?,
        remoteVideoTracks: [MatrixRTCLiveKitRemoteVideoTrack]
    ) {
        let nextLocalTrackId = localVideoTrack?.id
        let nextRemoteTrackIds = remoteVideoTracks.map(\.id)
        let didChange = currentLocalVideoTrackId != nextLocalTrackId
            || currentRemoteVideoTrackIds != nextRemoteTrackIds

        currentLocalVideoTrackId = nextLocalTrackId
        currentRemoteVideoTrackIds = nextRemoteTrackIds

        if didChange {
            log("Native MatrixRTC video surface local=\(nextLocalTrackId ?? "nil") remote=\(nextRemoteTrackIds)")
        }

        remoteVideoGridView.setRemoteVideoTracks(remoteVideoTracks)
        localVideoView.setLocalVideoTrack(localVideoTrack)

        let hasLocalVideo = localVideoTrack != nil
        let hasRemoteVideo = !remoteVideoTracks.isEmpty
        let hasAnyVideo = hasLocalVideo || hasRemoteVideo

        remoteVideoGridView.isHidden = !hasRemoteVideo
        localVideoContainerView.isHidden = !hasLocalVideo
        remoteVideoContainerView.isHidden = !hasAnyVideo
        avatarView.isHidden = hasAnyVideo
        titleBelowAvatarConstraint?.isActive = !hasAnyVideo
        titleBelowVideoConstraint?.isActive = hasAnyVideo

        NSLayoutConstraint.deactivate(localVideoFullConstraints)
        NSLayoutConstraint.deactivate(localVideoPreviewConstraints)
        if hasLocalVideo {
            NSLayoutConstraint.activate(hasRemoteVideo ? localVideoPreviewConstraints : localVideoFullConstraints)
        }

        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            self.view.layoutIfNeeded()
        }
    }

    func setStatus(_ status: String, isBusy: Bool) {
        statusLabel.text = status
        if isBusy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }

    func updateControls(canToggleMedia: Bool, canHangUp: Bool) {
        muteButton.isEnabled = canToggleMedia
        muteButton.alpha = canToggleMedia ? 1.0 : 0.45
        speakerButton.isEnabled = canToggleMedia
        speakerButton.alpha = canToggleMedia ? 1.0 : 0.45
        cameraButton.isEnabled = canToggleMedia
        cameraButton.alpha = canToggleMedia ? 1.0 : 0.45
        switchCameraButton.isEnabled = canToggleMedia && isCameraEnabled
        switchCameraButton.alpha = canToggleMedia && isCameraEnabled ? 1.0 : 0.35
        endCallButton.isEnabled = canHangUp
        endCallButton.alpha = canHangUp ? 1.0 : 0.45
    }

    func updateMuteButton() {
        var configuration = muteButton.configuration
        configuration?.image = UIImage(
            systemName: isMuted ? "mic.slash.fill" : "mic.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        )
        configuration?.baseBackgroundColor = isMuted ? .systemOrange : .systemGray
        muteButton.configuration = configuration
        muteButton.accessibilityLabel = isMuted
            ? "Unmute"
            : "Mute"
    }

    func updateSpeakerButton() {
        var configuration = speakerButton.configuration
        configuration?.image = UIImage(
            systemName: isSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        )
        configuration?.baseBackgroundColor = isSpeakerEnabled ? .systemBlue : .systemGray
        speakerButton.configuration = configuration
        speakerButton.accessibilityLabel = isSpeakerEnabled
            ? "Speaker Off"
            : "Speaker On"
    }

    func updateCameraButton() {
        var configuration = cameraButton.configuration
        configuration?.image = UIImage(
            systemName: isCameraEnabled ? "video.fill" : "video.slash.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        )
        configuration?.baseBackgroundColor = isCameraEnabled ? .systemBlue : .systemGray
        cameraButton.configuration = configuration
        cameraButton.accessibilityLabel = isCameraEnabled
            ? "Turn Camera Off"
            : "Turn Camera On"
    }

    func refreshSpeakerRouteState() {
        isSpeakerEnabled = callService.isSpeakerEnabled
    }

    func dismissOnce() {
        guard !didRequestDismiss else { return }
        didRequestDismiss = true
        onDismiss?()
    }

    @objc func muteTapped() {
        let nextMutedState = !isMuted
        updateControls(canToggleMedia: false, canHangUp: true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await callService.setMicrophoneEnabled(!nextMutedState)
                isMuted = nextMutedState
            } catch {
                log("Failed toggling native MatrixRTC microphone: \(error)")
            }

            if case .connected(let roomId) = callService.state, roomId == roomID {
                updateControls(canToggleMedia: true, canHangUp: true)
            }
        }
    }

    @objc func speakerTapped() {
        let nextSpeakerEnabledState = !isSpeakerEnabled
        updateControls(canToggleMedia: false, canHangUp: true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try callService.setSpeakerEnabled(nextSpeakerEnabledState)
                isSpeakerEnabled = nextSpeakerEnabledState
            } catch {
                log("Failed toggling native MatrixRTC speaker output: \(error)")
                refreshSpeakerRouteState()
            }

            if case .connected(let roomId) = callService.state, roomId == roomID {
                updateControls(canToggleMedia: true, canHangUp: true)
            }
        }
    }

    @objc func cameraTapped() {
        let nextCameraEnabledState = !isCameraEnabled
        updateControls(canToggleMedia: false, canHangUp: true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await callService.setCameraEnabled(nextCameraEnabledState)
                isCameraEnabled = nextCameraEnabledState
            } catch {
                log("Failed toggling native MatrixRTC camera: \(error)")
            }

            if case .connected(let roomId) = callService.state, roomId == roomID {
                updateControls(canToggleMedia: true, canHangUp: true)
            }
        }
    }

    @objc func switchCameraTapped() {
        guard isCameraEnabled else { return }
        updateControls(canToggleMedia: false, canHangUp: true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await callService.switchCameraPosition()
            } catch {
                log("Failed switching native MatrixRTC camera position: \(error)")
            }

            if case .connected(let roomId) = callService.state, roomId == roomID {
                updateControls(canToggleMedia: true, canHangUp: true)
            }
        }
    }

    @objc func endCallTapped() {
        guard !isEndingCall else { return }
        isEndingCall = true
        startTask?.cancel()
        setStatus("Leaving...", isBusy: true)
        updateControls(canToggleMedia: false, canHangUp: false)

        leaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await callService.leaveActiveCall()
            } catch {
                log("Failed leaving native MatrixRTC call in room \(roomID): \(error)")
            }
            dismissOnce()
        }
    }
}

private final class NativeMatrixRTCRemoteVideoGridView: UIView {
    private var orderedTrackIds: [String] = []
    private var tileViewsByTrackId: [String: MatrixRTCLiveKitVideoView] = [:]

    func setRemoteVideoTracks(_ remoteVideoTracks: [MatrixRTCLiveKitRemoteVideoTrack]) {
        let nextTrackIds = remoteVideoTracks.map(\.id)
        let nextTrackIdSet = Set(nextTrackIds)

        for trackId in Array(tileViewsByTrackId.keys) where !nextTrackIdSet.contains(trackId) {
            guard let tileView = tileViewsByTrackId.removeValue(forKey: trackId) else { continue }
            tileView.setRemoteVideoTrack(nil)
            tileView.removeFromSuperview()
        }

        for remoteVideoTrack in remoteVideoTracks {
            let tileView = tileViewsByTrackId[remoteVideoTrack.id] ?? makeTileView()
            tileView.setRemoteVideoTrack(remoteVideoTrack)
            tileViewsByTrackId[remoteVideoTrack.id] = tileView
        }

        orderedTrackIds = nextTrackIds
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard !orderedTrackIds.isEmpty else { return }
        let layout = gridLayout(for: orderedTrackIds.count)
        let spacing: CGFloat = 6
        let tileWidth = (bounds.width - CGFloat(layout.columns - 1) * spacing) / CGFloat(layout.columns)
        let tileHeight = (bounds.height - CGFloat(layout.rows - 1) * spacing) / CGFloat(layout.rows)

        for index in orderedTrackIds.indices {
            guard let tileView = tileViewsByTrackId[orderedTrackIds[index]] else { continue }
            let row = index / layout.columns
            let column = index % layout.columns
            tileView.frame = CGRect(
                x: CGFloat(column) * (tileWidth + spacing),
                y: CGFloat(row) * (tileHeight + spacing),
                width: tileWidth,
                height: tileHeight
            )
        }
    }

    private func makeTileView() -> MatrixRTCLiveKitVideoView {
        let tileView = MatrixRTCLiveKitVideoView()
        tileView.backgroundColor = .black
        tileView.layoutMode = .fit
        addSubview(tileView)
        return tileView
    }

    private func gridLayout(for count: Int) -> (columns: Int, rows: Int) {
        switch count {
        case 0, 1:
            return (1, 1)
        case 2:
            return bounds.width >= bounds.height ? (2, 1) : (1, 2)
        case 3, 4:
            return (2, 2)
        default:
            let columns = 3
            let rows = Int(ceil(Double(count) / Double(columns)))
            return (columns, rows)
        }
    }
}
