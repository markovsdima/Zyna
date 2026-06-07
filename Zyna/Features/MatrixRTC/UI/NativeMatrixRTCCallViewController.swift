//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import MatrixRustSDK
import UIKit

private let log = ScopedLog(.call, prefix: "[matrixrtc-native-ui]")

final class NativeMatrixRTCCallViewController: UIViewController {
    var onDismiss: (() -> Void)?

    let roomID: String

    private let room: Room
    private let roomDisplayName: String
    private let callService: NativeMatrixRTCCallService

    private let avatarView = UIView()
    private let avatarImageView = UIImageView()
    private let titleLabel = UILabel()
    private let statusStack = UIStackView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let controlsStack = UIStackView()
    private let muteButton = UIButton(type: .system)
    private let endCallButton = UIButton(type: .system)

    private var cancellables = Set<AnyCancellable>()
    private var startTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var hasStartedCall = false
    private var hasSeenActiveState = false
    private var isEndingCall = false
    private var didRequestDismiss = false
    private var isMuted = false {
        didSet {
            updateMuteButton()
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
        controlsStack.spacing = 36

        configureControlButton(
            muteButton,
            systemName: "mic.fill",
            backgroundColor: .systemGray,
            size: 64
        )
        muteButton.accessibilityLabel = "Mute"
        muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)

        configureControlButton(
            endCallButton,
            systemName: "phone.down.fill",
            backgroundColor: .systemRed,
            size: 72
        )
        endCallButton.accessibilityLabel = "End Call"
        endCallButton.addTarget(self, action: #selector(endCallTapped), for: .touchUpInside)

        view.addSubview(avatarView)
        avatarView.addSubview(avatarImageView)
        view.addSubview(titleLabel)
        view.addSubview(statusStack)
        statusStack.addArrangedSubview(activityIndicator)
        statusStack.addArrangedSubview(statusLabel)
        view.addSubview(controlsStack)
        controlsStack.addArrangedSubview(muteButton)
        controlsStack.addArrangedSubview(endCallButton)

        NSLayoutConstraint.activate([
            avatarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            avatarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 96),
            avatarView.widthAnchor.constraint(equalToConstant: 112),
            avatarView.heightAnchor.constraint(equalToConstant: 112),

            avatarImageView.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarImageView.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 28),
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
        updateControls(canToggleMute: false, canHangUp: true)
        updateMuteButton()
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
            updateControls(canToggleMute: false, canHangUp: true)

        case .connected(let roomId):
            guard roomId == roomID else { return }
            hasSeenActiveState = true
            updateConnectedStatus()
            updateControls(canToggleMute: true, canHangUp: true)

        case .leaving(let roomId):
            guard roomId == roomID else { return }
            setStatus("Leaving...", isBusy: true)
            updateControls(canToggleMute: false, canHangUp: false)
        }
    }

    func handleStartFailure(_ error: Error) {
        log("Failed starting native MatrixRTC call in room \(roomID): \(error)")
        setStatus("Could not start call", isBusy: false)
        updateControls(canToggleMute: false, canHangUp: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.dismissOnce()
        }
    }

    func updateConnectedStatus() {
        guard case .connected(let roomId) = callService.state, roomId == roomID else { return }
        let status = isMuted
            ? "Microphone muted"
            : "Connected"
        setStatus(status, isBusy: false)
    }

    func setStatus(_ status: String, isBusy: Bool) {
        statusLabel.text = status
        if isBusy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }

    func updateControls(canToggleMute: Bool, canHangUp: Bool) {
        muteButton.isEnabled = canToggleMute
        muteButton.alpha = canToggleMute ? 1.0 : 0.45
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

    func dismissOnce() {
        guard !didRequestDismiss else { return }
        didRequestDismiss = true
        onDismiss?()
    }

    @objc func muteTapped() {
        let nextMutedState = !isMuted
        updateControls(canToggleMute: false, canHangUp: true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await callService.setMicrophoneEnabled(!nextMutedState)
                isMuted = nextMutedState
            } catch {
                log("Failed toggling native MatrixRTC microphone: \(error)")
            }

            if case .connected(let roomId) = callService.state, roomId == roomID {
                updateControls(canToggleMute: true, canHangUp: true)
            }
        }
    }

    @objc func endCallTapped() {
        guard !isEndingCall else { return }
        isEndingCall = true
        startTask?.cancel()
        setStatus("Leaving...", isBusy: true)
        updateControls(canToggleMute: false, canHangUp: false)

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
