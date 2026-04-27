//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class ChatPeekOverlayController: UIViewController {

    private let chatController: ChatViewController
    private let sourceFrameInScreen: CGRect?
    private let dimmingView = UIView()
    private let shadowView = UIView()
    private let clippingView = UIView()
    private var didApplyInitialState = false
    private var didAnimateIn = false
    private var isDismissingOverlay = false
    private var currentTargetFrame: CGRect = .zero

    init(chatController: ChatViewController, sourceFrameInScreen: CGRect?) {
        self.chatController = chatController
        self.sourceFrameInScreen = sourceFrameInScreen
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear

        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        dimmingView.alpha = 0
        view.addSubview(dimmingView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        dimmingView.addGestureRecognizer(tap)

        shadowView.backgroundColor = .clear
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOpacity = 0.24
        shadowView.layer.shadowRadius = 26
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 18)
        view.addSubview(shadowView)

        clippingView.clipsToBounds = true
        clippingView.backgroundColor = AppColor.chatBackground
        clippingView.layer.cornerCurve = .continuous
        clippingView.layer.cornerRadius = 24
        shadowView.addSubview(clippingView)

        addChild(chatController)
        clippingView.addSubview(chatController.view)
        chatController.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        dimmingView.frame = view.bounds
        guard !isDismissingOverlay else { return }

        let frame = targetFrame()
        currentTargetFrame = frame
        shadowView.frame = frame
        clippingView.frame = shadowView.bounds
        chatController.view.frame = clippingView.bounds
        shadowView.layer.shadowPath = UIBezierPath(
            roundedRect: shadowView.bounds,
            cornerRadius: clippingView.layer.cornerRadius
        ).cgPath

        if !didApplyInitialState {
            applyInitialState(targetFrame: frame)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateInIfNeeded()
    }

    @objc private func backgroundTapped() {
        dismissAnimated()
    }

    private func targetFrame() -> CGRect {
        let bounds = view.bounds
        let safeArea = view.safeAreaInsets
        let side = max(
            180,
            min(
                420,
                bounds.width - 32,
                bounds.height - safeArea.top - safeArea.bottom - 80
            )
        )

        let x = floor((bounds.width - side) / 2)
        let minY = safeArea.top + 24
        let maxY = max(minY, bounds.height - safeArea.bottom - side - 24)
        let centeredY = floor((bounds.height - side) / 2) - 24
        let y = min(max(centeredY, minY), maxY)

        return CGRect(x: x, y: y, width: side, height: side)
    }

    private func applyInitialState(targetFrame: CGRect) {
        didApplyInitialState = true

        guard let sourceState = sourceState(targetFrame: targetFrame) else {
            shadowView.alpha = 0
            shadowView.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            return
        }

        shadowView.alpha = 0.9
        shadowView.center = sourceState.center
        shadowView.transform = sourceState.transform
    }

    private func sourceState(targetFrame: CGRect) -> (center: CGPoint, transform: CGAffineTransform)? {
        guard let sourceFrameInScreen,
              sourceFrameInScreen.width > 0,
              sourceFrameInScreen.height > 0
        else { return nil }

        let sourceFrame = view.convert(sourceFrameInScreen, from: nil)
        let scale = max(
            0.18,
            min(
                sourceFrame.width / max(targetFrame.width, 1),
                sourceFrame.height / max(targetFrame.height, 1)
            )
        )
        return (
            center: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
            transform: CGAffineTransform(scaleX: scale, y: scale)
        )
    }

    private func animateInIfNeeded() {
        guard !didAnimateIn else { return }
        didAnimateIn = true

        UIView.animate(
            withDuration: 0.24,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.dimmingView.alpha = 1
            self.shadowView.alpha = 1
            self.shadowView.center = CGPoint(x: self.currentTargetFrame.midX, y: self.currentTargetFrame.midY)
            self.shadowView.transform = .identity
        }
    }

    private func dismissAnimated() {
        guard !isDismissingOverlay else { return }
        isDismissingOverlay = true

        let sourceState = sourceState(targetFrame: currentTargetFrame)

        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn]
        ) {
            self.dimmingView.alpha = 0
            self.shadowView.alpha = 0
            if let sourceState {
                self.shadowView.center = sourceState.center
                self.shadowView.transform = sourceState.transform
            } else {
                self.shadowView.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            }
        } completion: { _ in
            self.dismiss(animated: false)
        }
    }
}
