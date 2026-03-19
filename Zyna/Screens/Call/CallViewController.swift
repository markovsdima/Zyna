//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine

// MARK: - Call View Controller

final class CallViewController: ASDKViewController<CallNode> {

    var onDismiss: (() -> Void)?

    private let callService: CallService
    private let roomName: String
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(roomName: String, callService: CallService = .shared) {
        self.callService = callService
        self.roomName = roomName
        super.init(node: CallNode())
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        node.backgroundColor = .systemBackground
        node.updateName(roomName)

        setupActions()
        bindState()
    }

    // MARK: - Actions

    private func setupActions() {
        node.acceptButton.addTarget(self, action: #selector(acceptTapped), forControlEvents: .touchUpInside)
        node.endCallButton.addTarget(self, action: #selector(endCallTapped), forControlEvents: .touchUpInside)
        node.muteButton.addTarget(self, action: #selector(muteTapped), forControlEvents: .touchUpInside)
        node.speakerButton.addTarget(self, action: #selector(speakerTapped), forControlEvents: .touchUpInside)
    }

    @objc private func acceptTapped() {
        callService.acceptCall()
    }

    @objc private func endCallTapped() {
        callService.endCall(reason: .userHangup)
    }

    @objc private func muteTapped() {
        node.muteButton.isSelected.toggle()
        // WebRTC will handle actual audio muting via CallServiceDelegate
    }

    @objc private func speakerTapped() {
        node.speakerButton.isSelected.toggle()
        // WebRTC will handle audio routing
    }

    // MARK: - State Binding

    private func bindState() {
        callService.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateUI(for: state)
            }
            .store(in: &cancellables)
    }

    private func updateUI(for state: CallState) {
        let showAccept = {
            if case .incomingRinging = state { return true }
            return false
        }()

        node.acceptButton.isHidden = !showAccept
        node.setNeedsLayout()

        switch state {
        case .idle:
            break

        case .outgoingRinging:
            node.updateStatus("Calling...")

        case .incomingRinging(_, _, let callerName):
            node.updateStatus("Incoming call from \(callerName ?? "Unknown")")

        case .connecting:
            node.updateStatus("Connecting...")

        case .connected:
            node.updateStatus("Connected")

        case .ended:
            node.updateStatus("Call ended")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.onDismiss?()
            }
        }
    }
}
