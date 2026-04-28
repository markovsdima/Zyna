//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class ChatPeekOverlayController: UIViewController {

    private let chatController: ChatViewController
    private let sourceFrameInScreen: CGRect?
    private weak var backgroundSourceView: UIView?
    private let backgroundLensView = ChatPeekMetalBackgroundView()
    private let dimmingView = UIView()
    private let pressureRimView = ChatPeekPressureRimView()
    private let shadowView = UIView()
    private let clippingView = UIView()
    private var didApplyInitialState = false
    private var didAnimateIn = false
    private var isDismissingOverlay = false
    private var currentTargetFrame: CGRect = .zero

    init(
        chatController: ChatViewController,
        sourceFrameInScreen: CGRect?,
        backgroundSourceView: UIView?
    ) {
        self.chatController = chatController
        self.sourceFrameInScreen = sourceFrameInScreen
        self.backgroundSourceView = backgroundSourceView
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

        backgroundLensView.alpha = 0
        backgroundLensView.progress = 0
        backgroundLensView.sourceView = backgroundSourceView
        view.addSubview(backgroundLensView)

        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        dimmingView.alpha = 0
        view.addSubview(dimmingView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        dimmingView.addGestureRecognizer(tap)

        pressureRimView.alpha = 0
        pressureRimView.isHidden = true
        view.addSubview(pressureRimView)

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
        let lensFrame = backgroundLensFrame()
        backgroundLensView.frame = lensFrame
        backgroundLensView.sourceCaptureRect = sourceCaptureRect(for: lensFrame)
        pressureRimView.frame = view.bounds
        guard !isDismissingOverlay else { return }

        let frame = targetFrame()
        currentTargetFrame = frame
        backgroundLensView.cardFrame = view.convert(frame, to: backgroundLensView)
        backgroundLensView.cardCornerRadius = clippingView.layer.cornerRadius
        pressureRimView.cardFrame = frame
        pressureRimView.cornerRadius = clippingView.layer.cornerRadius
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

    private func backgroundLensFrame() -> CGRect {
        var frame = view.bounds
        guard let tabBarFrame = tabBarFrameInOverlay(),
              tabBarFrame.minY > frame.minY,
              tabBarFrame.minY < frame.maxY
        else { return frame }

        frame.size.height = max(1, tabBarFrame.minY - frame.minY)
        return frame
    }

    private func sourceCaptureRect(for lensFrame: CGRect) -> CGRect? {
        guard let backgroundSourceView else { return nil }
        return backgroundSourceView
            .convert(lensFrame, from: view)
            .standardized
            .intersection(backgroundSourceView.bounds)
    }

    private func tabBarFrameInOverlay() -> CGRect? {
        guard let tabBar = backgroundSourceView?
            .subviews
            .first(where: { $0 is ZynaTabBar && !$0.isHidden && $0.alpha > 0.01 })
        else { return nil }

        let frame = view.convert(tabBar.bounds, from: tabBar)
        guard frame.width > 1, frame.height > 1 else { return nil }
        return frame
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

        backgroundLensView.animateProgress(
            to: 1,
            duration: 0.24,
            curve: .easeOut
        )
        UIView.animate(
            withDuration: 0.24,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.backgroundLensView.alpha = 1
            self.dimmingView.alpha = 1
            self.pressureRimView.alpha = 1
            self.shadowView.alpha = 1
            self.shadowView.center = CGPoint(x: self.currentTargetFrame.midX, y: self.currentTargetFrame.midY)
            self.shadowView.transform = .identity
        }
    }

    private func dismissAnimated() {
        guard !isDismissingOverlay else { return }
        isDismissingOverlay = true

        let sourceState = sourceState(targetFrame: currentTargetFrame)
        let closeDuration: TimeInterval = 0.26

        backgroundLensView.alpha = 1
        backgroundLensView.animateProgress(
            to: 0,
            duration: closeDuration,
            curve: .easeOut,
            completion: { [weak self] in
                guard let self else { return }
                self.backgroundLensView.progress = 0
                self.dismiss(animated: false)
            }
        )
        UIView.animate(
            withDuration: closeDuration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut]
        ) {
            self.dimmingView.alpha = 0
            self.pressureRimView.alpha = 0
            self.shadowView.alpha = 0
            if let sourceState {
                self.shadowView.center = sourceState.center
                self.shadowView.transform = sourceState.transform
            } else {
                self.shadowView.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            }
        }
    }
}
