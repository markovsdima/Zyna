//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import UIKit

final class EmbeddedVoiceTopPlayerHost {

    private enum Metrics {
        static let height: CGFloat = 52
        static let topMargin: CGFloat = 6
        static let sideInset: CGFloat = 8
        static let maxWidth: CGFloat = 560
        static let bottomGap: CGFloat = 4

        static var reservedTopInset: CGFloat {
            topMargin + height + bottomGap
        }
    }

    var onVisibilityChanged: (() -> Void)?
    var accessibilityView: UIView { playerView }

    private weak var viewController: UIViewController?
    private let audioPlayer: AudioPlayerService
    private let playerView = VoiceTopPlayerView(frame: .zero)
    private var cancellables = Set<AnyCancellable>()
    private var isInstalled = false
    private var isVisible = false
    private var hasAppliedInitialState = false
    private var appliedTopInset: CGFloat = 0

    init(viewController: UIViewController, audioPlayer: AudioPlayerService) {
        self.viewController = viewController
        self.audioPlayer = audioPlayer
    }

    deinit {
        removeAppliedTopInset()
    }

    func install() {
        guard let view = viewController?.view, !isInstalled else { return }
        isInstalled = true
        playerView.isHidden = true
        playerView.alpha = 0
        playerView.onPlayPause = { [weak audioPlayer] in
            guard let audioPlayer else { return }
            if audioPlayer.state.isPlaying {
                audioPlayer.pause()
            } else {
                audioPlayer.resume()
            }
        }
        playerView.onClose = { [weak audioPlayer] in
            audioPlayer?.stop()
        }
        playerView.onSeek = { [weak audioPlayer] progress in
            audioPlayer?.seek(to: progress)
        }
        playerView.onSpeed = { [weak audioPlayer] in
            audioPlayer?.cyclePlaybackRate()
        }
        view.addSubview(playerView)

        audioPlayer.$state
            .combineLatest(audioPlayer.$nowPlaying, audioPlayer.$snapshot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, item, snapshot in
                self?.apply(state: state, item: item, snapshot: snapshot, force: false)
            }
            .store(in: &cancellables)

        apply(
            state: audioPlayer.state,
            item: audioPlayer.nowPlaying,
            snapshot: audioPlayer.snapshot,
            force: true
        )
    }

    func refresh() {
        apply(
            state: audioPlayer.state,
            item: audioPlayer.nowPlaying,
            snapshot: audioPlayer.snapshot,
            force: true
        )
    }

    func layout() {
        guard let view = viewController?.view else { return }
        playerView.frame = restingFrame(visible: isVisible, in: view)
        if !playerView.isHidden {
            view.bringSubviewToFront(playerView)
        }
    }

    private func apply(
        state: AudioPlayerService.State,
        item: AudioPlayerService.NowPlayingItem?,
        snapshot: AudioPlayerService.PlaybackSnapshot,
        force: Bool
    ) {
        guard isInstalled else { return }
        let shouldShow = state != .idle && item != nil
        let isOnScreen = viewController?.view.window != nil
        let visibilityChanged = isVisible != shouldShow
        if !force, !isOnScreen, hasAppliedInitialState, !visibilityChanged {
            return
        }

        playerView.configure(state: state, item: item, snapshot: snapshot)
        let animated = hasAppliedInitialState && isOnScreen
        setVisible(shouldShow, animated: animated)
        hasAppliedInitialState = true
    }

    private func setVisible(_ visible: Bool, animated: Bool) {
        guard isVisible != visible else { return }

        isVisible = visible
        updateTopInset()

        guard let view = viewController?.view else { return }
        let isOnScreen = view.window != nil
        if isOnScreen {
            onVisibilityChanged?()
        }
        let targetFrame = restingFrame(visible: visible, in: view)

        if visible {
            playerView.isHidden = false
            playerView.frame = restingFrame(visible: false, in: view)
            view.bringSubviewToFront(playerView)
        }

        let animations = {
            self.playerView.alpha = visible ? 1 : 0
            self.playerView.frame = targetFrame
        }

        if animated {
            UIView.animate(
                withDuration: IOS26Spring.duration,
                delay: 0,
                usingSpringWithDamping: 1,
                initialSpringVelocity: 0,
                options: [.curveEaseOut, .beginFromCurrentState],
                animations: animations,
                completion: { [weak self] _ in
                    guard let self, !self.isVisible else { return }
                    self.playerView.isHidden = true
                }
            )
        } else {
            animations()
            playerView.isHidden = !visible
        }

        if isOnScreen {
            GlassService.shared.captureFor(duration: animated ? IOS26Spring.duration + 0.15 : 0.15)
            GlassService.shared.setNeedsCapture()
        }
    }

    private func updateTopInset() {
        guard let viewController else { return }
        let desiredInset = isVisible ? Metrics.reservedTopInset : 0
        guard abs(desiredInset - appliedTopInset) > 0.5 else { return }
        let externalTopInset = max(0, viewController.additionalSafeAreaInsets.top - appliedTopInset)
        viewController.additionalSafeAreaInsets.top = externalTopInset + desiredInset
        appliedTopInset = desiredInset
    }

    private func removeAppliedTopInset() {
        guard let viewController, appliedTopInset > 0 else { return }
        viewController.additionalSafeAreaInsets.top = max(
            0,
            viewController.additionalSafeAreaInsets.top - appliedTopInset
        )
        appliedTopInset = 0
    }

    private func restingFrame(visible: Bool, in view: UIView) -> CGRect {
        let availableWidth = max(0, view.bounds.width - Metrics.sideInset * 2)
        let width = min(availableWidth, Metrics.maxWidth)
        let x = (view.bounds.width - width) / 2
        let baseSafeTop = max(0, view.safeAreaInsets.top - appliedTopInset)
        let visibleY = baseSafeTop + Metrics.topMargin
        let hiddenY = visibleY - Metrics.height - Metrics.topMargin - 4
        return CGRect(
            x: x,
            y: visible ? visibleY : hiddenY,
            width: width,
            height: Metrics.height
        )
    }
}
