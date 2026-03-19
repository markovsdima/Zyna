//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Combine
import MatrixRustSDK

final class AudioPlayerService: NSObject {

    enum State: Equatable {
        case idle
        case loading(sourceURL: String)
        case playing(sourceURL: String, progress: Float)
        case paused(sourceURL: String, progress: Float)

        var sourceURL: String? {
            switch self {
            case .idle: return nil
            case .loading(let url): return url
            case .playing(let url, _): return url
            case .paused(let url, _): return url
            }
        }

        var isPlaying: Bool {
            if case .playing = self { return true }
            return false
        }

        var progress: Float {
            switch self {
            case .playing(_, let p), .paused(_, let p): return p
            default: return 0
            }
        }
    }

    @Published private(set) var state: State = .idle

    private let log = ScopedLog(.voiceRecording, prefix: "[AudioPlayer]")

    override init() {
        super.init()
        setupInterruptionObserver()
    }

    private var player: AVAudioPlayer?
    private var displayLink: DisplayLinkToken?

    // MARK: - Public API

    /// Play audio from a Matrix media source (downloads first).
    func play(source: MediaSource, mimeType: String = "audio/mp4") {
        let sourceKey = source.url()

        // If same source is paused — resume
        if case .paused(let url, _) = state, url == sourceKey {
            resume()
            return
        }

        stopInternal()
        state = .loading(sourceURL: sourceKey)

        Task { [weak self] in
            guard let self else { return }
            guard let client = MatrixClientService.shared.client else {
                await MainActor.run { self.state = .idle }
                return
            }
            do {
                let handle = try await client.getMediaFile(
                    mediaSource: source,
                    filename: nil,
                    mimeType: mimeType,
                    useCache: true,
                    tempDir: nil
                )
                let path = try handle.path()
                let url = URL(fileURLWithPath: path)
                await MainActor.run {
                    // Guard against race: another play() may have started while downloading
                    guard self.state == .loading(sourceURL: sourceKey) else { return }
                    self.startPlayback(url: url, sourceKey: sourceKey)
                }
            } catch {
                self.log("download failed: \(error)")
                await MainActor.run { self.state = .idle }
            }
        }
    }

    /// Play a local file (e.g. just-recorded voice message).
    func playLocal(url: URL, sourceKey: String? = nil) {
        stopInternal()
        startPlayback(url: url, sourceKey: sourceKey ?? url.absoluteString)
    }

    func pause() {
        guard case .playing(let url, let progress) = state else { return }
        player?.pause()
        displayLink?.pause()
        state = .paused(sourceURL: url, progress: progress)
    }

    func resume() {
        guard case .paused(let url, _) = state else { return }
        player?.play()
        displayLink?.resume()
        state = .playing(sourceURL: url, progress: currentProgress)
    }

    func togglePlayPause(source: MediaSource, mimeType: String = "audio/mp4") {
        let sourceKey = source.url()
        switch state {
        case .playing(let url, _) where url == sourceKey:
            pause()
        case .paused(let url, _) where url == sourceKey:
            resume()
        default:
            play(source: source, mimeType: mimeType)
        }
    }

    func seek(to progress: Float) {
        guard let player else { return }
        player.currentTime = TimeInterval(progress) * player.duration
    }

    func stop() {
        stopInternal()
        state = .idle
    }

    // MARK: - Private

    private func startPlayback(url: URL, sourceKey: String) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.delegate = self
            audioPlayer.play()
            self.player = audioPlayer

            state = .playing(sourceURL: sourceKey, progress: 0)
            startProgressTracking(sourceKey: sourceKey)

            log("playing \(url.lastPathComponent)")
        } catch {
            log("playback error: \(error)")
            state = .idle
        }
    }

    private func startProgressTracking(sourceKey: String) {
        displayLink = DisplayLinkDriver.shared.subscribe(rate: .fps(30)) { [weak self] _ in
            guard let self, let player = self.player, player.isPlaying else { return }
            let progress = Float(player.currentTime / player.duration)
            self.state = .playing(sourceURL: sourceKey, progress: min(progress, 1))
        }
    }

    private func stopInternal() {
        player?.stop()
        player = nil
        displayLink?.invalidate()
        displayLink = nil
        deactivateAudioSession()
    }

    private var currentProgress: Float {
        guard let player, player.duration > 0 else { return 0 }
        return Float(player.currentTime / player.duration)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            if case .playing = state {
                pause()
            }
        case .ended:
            break
        @unknown default:
            break
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlayerService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        displayLink?.invalidate()
        displayLink = nil
        self.player = nil
        deactivateAudioSession()
        state = .idle
        log("finished")
    }
}
