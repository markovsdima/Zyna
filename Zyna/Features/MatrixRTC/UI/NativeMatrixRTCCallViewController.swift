//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import UIKit

final class NativeMatrixRTCCallViewController: UIViewController {
    var onDismiss: (() -> Void)?

    let roomID: String

    private let callView = NativeMatrixRTCCallRootView()
    private let viewModel: NativeMatrixRTCCallViewModel
    private var cancellables = Set<AnyCancellable>()
    private var didRequestDismiss = false

    init(
        context: NativeMatrixRTCCallLaunchContext,
        callService: NativeMatrixRTCCallService = .shared
    ) {
        self.roomID = context.roomID
        self.viewModel = NativeMatrixRTCCallViewModel(
            context: context,
            callService: callService
        )
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = callView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindViewModel()
        viewModel.start()
    }
}

private extension NativeMatrixRTCCallViewController {
    func bindViewModel() {
        viewModel.onDismiss = { [weak self] in
            self?.dismissOnce()
        }

        viewModel.$viewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.callView.render(state)
            }
            .store(in: &cancellables)

        callView.onControlTapped = { [weak self] kind in
            self?.viewModel.handleControl(kind)
        }

        callView.onDirectPreviewTapped = { [weak self] in
            self?.viewModel.handleDirectPreviewTap()
        }
    }

    func dismissOnce() {
        guard !didRequestDismiss else { return }
        didRequestDismiss = true
        onDismiss?()
    }
}
