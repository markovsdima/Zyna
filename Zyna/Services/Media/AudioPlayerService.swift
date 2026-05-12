//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Combine
import MatrixRustSDK

final class AudioPlayerService: NSObject {

    enum NowPlayingItem: Equatable {
        case voice(NowPlayingVoice)
        case track(NowPlayingTrack)

        var sourceURL: String {
            switch self {
            case .voice(let voice): return voice.sourceURL
            case .track(let track): return track.sourceURL
            }
        }

        var title: String {
            switch self {
            case .voice(let voice): return voice.title
            case .track(let track): return track.title
            }
        }

        var subtitle: String? {
            switch self {
            case .voice(let voice): return voice.subtitle
            case .track(let track): return track.subtitle
            }
        }

        var duration: TimeInterval {
            switch self {
            case .voice(let voice): return voice.duration
            case .track(let track): return track.duration
            }
        }

        var waveform: [Float] {
            switch self {
            case .voice(let voice): return voice.waveform
            case .track: return []
            }
        }

        var roomId: String? {
            switch self {
            case .voice(let voice): return voice.roomId
            case .track: return nil
            }
        }

        var eventId: String? {
            switch self {
            case .voice(let voice): return voice.eventId
            case .track: return nil
            }
        }
    }

    struct NowPlayingVoice: Equatable {
        let sourceURL: String
        let title: String
        let subtitle: String?
        let duration: TimeInterval
        let waveform: [Float]
        let roomId: String?
        let eventId: String?
    }

    struct NowPlayingTrack: Equatable {
        let sourceURL: String
        let title: String
        let subtitle: String?
        let duration: TimeInterval
    }

    struct PlaybackSnapshot: Equatable {
        let sourceURL: String?
        let currentTime: TimeInterval
        let duration: TimeInterval
        let progress: Float
        let remainingTime: TimeInterval
        let playbackRate: Float
        let isPlaying: Bool
        let isLoading: Bool

        static func idle(playbackRate: Float) -> PlaybackSnapshot {
            PlaybackSnapshot(
                sourceURL: nil,
                currentTime: 0,
                duration: 0,
                progress: 0,
                remainingTime: 0,
                playbackRate: playbackRate,
                isPlaying: false,
                isLoading: false
            )
        }
    }

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

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }

        var progress: Float {
            switch self {
            case .playing(_, let p), .paused(_, let p): return p
            default: return 0
            }
        }
    }

    static let availablePlaybackRates: [Float] = [0.5, 1, 1.5, 2]

    @Published private(set) var state: State = .idle {
        didSet { refreshSnapshot() }
    }
    @Published private(set) var nowPlaying: NowPlayingItem? {
        didSet { refreshSnapshot() }
    }
    @Published private(set) var playbackRate: Float = 1 {
        didSet {
            applyPlaybackRate()
            refreshSnapshot()
        }
    }
    @Published private(set) var snapshot: PlaybackSnapshot = .idle(playbackRate: 1)

    private let log = ScopedLog(.voiceRecording, prefix: "[AudioPlayer]")

    override init() {
        super.init()
        setupInterruptionObserver()
    }

    private var player: AVAudioPlayer?
    private var displayLink: DisplayLinkToken?

    // MARK: - Public API

    /// Play audio from a Matrix media source (downloads first).
    func play(
        source: MediaSource,
        mimeType: String = "audio/mp4",
        nowPlaying item: NowPlayingItem? = nil
    ) {
        let sourceKey = source.url()

        // If same source is paused — resume
        if case .paused(let url, _) = state, url == sourceKey {
            if let item { nowPlaying = item }
            resume()
            return
        }

        stopInternal()
        nowPlaying = item
        state = .loading(sourceURL: sourceKey)

        Task { [weak self] in
            guard let self else { return }
            guard let client = MatrixClientService.shared.client else {
                await MainActor.run { self.failLoadingIfCurrent(sourceKey: sourceKey) }
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
                await MainActor.run { self.failLoadingIfCurrent(sourceKey: sourceKey) }
            }
        }
    }

    /// Play a local file (e.g. just-recorded voice message).
    func playLocal(
        url: URL,
        sourceKey: String? = nil,
        nowPlaying item: NowPlayingItem? = nil
    ) {
        stopInternal()
        let resolvedSourceKey = sourceKey ?? url.absoluteString
        nowPlaying = item
        startPlayback(url: url, sourceKey: resolvedSourceKey)
    }

    func pause() {
        guard case .playing(let url, let progress) = state else { return }
        player?.pause()
        displayLink?.pause()
        state = .paused(sourceURL: url, progress: progress)
    }

    func resume() {
        guard case .paused(let url, _) = state else { return }
        applyPlaybackRate()
        player?.play()
        displayLink?.resume()
        state = .playing(sourceURL: url, progress: currentProgress)
    }

    func togglePlayPause(
        source: MediaSource,
        mimeType: String = "audio/mp4",
        nowPlaying item: NowPlayingItem? = nil
    ) {
        let sourceKey = source.url()
        switch state {
        case .playing(let url, _) where url == sourceKey:
            if let item { nowPlaying = item }
            pause()
        case .paused(let url, _) where url == sourceKey:
            if let item { nowPlaying = item }
            resume()
        default:
            play(source: source, mimeType: mimeType, nowPlaying: item)
        }
    }

    func seek(to progress: Float) {
        guard let player, player.duration > 0 else { return }
        let clampedProgress = max(0, min(progress, 1))
        player.currentTime = TimeInterval(clampedProgress) * player.duration
        let resolvedProgress = currentProgress
        switch state {
        case .playing(let url, _):
            state = .playing(sourceURL: url, progress: resolvedProgress)
        case .paused(let url, _):
            state = .paused(sourceURL: url, progress: resolvedProgress)
        default:
            refreshSnapshot()
        }
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = Self.normalizedPlaybackRate(rate)
    }

    func cyclePlaybackRate() {
        let rates = Self.availablePlaybackRates
        guard !rates.isEmpty else { return }
        let currentIndex = rates.firstIndex(of: playbackRate)
            ?? rates.enumerated().min(by: {
                abs($0.element - playbackRate) < abs($1.element - playbackRate)
            })?.offset
            ?? 0
        let nextIndex = rates.index(after: currentIndex)
        playbackRate = rates[nextIndex == rates.endIndex ? rates.startIndex : nextIndex]
    }

    func stop() {
        stopInternal()
        nowPlaying = nil
        state = .idle
    }

    // MARK: - Private

    private func startPlayback(url: URL, sourceKey: String) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.delegate = self
            audioPlayer.enableRate = true
            audioPlayer.rate = playbackRate
            audioPlayer.play()
            self.player = audioPlayer

            state = .playing(sourceURL: sourceKey, progress: 0)
            startProgressTracking(sourceKey: sourceKey)

            log("playing \(url.lastPathComponent)")
        } catch {
            log("playback error: \(error)")
            nowPlaying = nil
            state = .idle
        }
    }

    private func startProgressTracking(sourceKey: String) {
        displayLink = DisplayLinkDriver.shared.subscribe(rate: .fps(30)) { [weak self] _ in
            guard let self, let player = self.player, player.isPlaying else { return }
            guard player.duration > 0 else { return }
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

    private func applyPlaybackRate() {
        guard let player else { return }
        player.enableRate = true
        player.rate = playbackRate
    }

    private func refreshSnapshot() {
        let duration = effectiveDuration
        let currentTime = effectiveCurrentTime(duration: duration)
        let progress: Float
        if duration > 0 {
            progress = Float(max(0, min(currentTime / duration, 1)))
        } else {
            progress = max(0, min(state.progress, 1))
        }
        let next = PlaybackSnapshot(
            sourceURL: state.sourceURL,
            currentTime: currentTime,
            duration: duration,
            progress: progress,
            remainingTime: max(0, duration - currentTime),
            playbackRate: playbackRate,
            isPlaying: state.isPlaying,
            isLoading: state.isLoading
        )
        guard snapshot != next else { return }
        snapshot = next
    }

    private var effectiveDuration: TimeInterval {
        if let player, player.duration.isFinite, player.duration > 0 {
            return player.duration
        }
        return nowPlaying?.duration ?? 0
    }

    private func effectiveCurrentTime(duration: TimeInterval) -> TimeInterval {
        if let player, player.duration > 0 {
            return max(0, min(player.currentTime, player.duration))
        }
        guard duration > 0 else { return 0 }
        return TimeInterval(max(0, min(state.progress, 1))) * duration
    }

    private static func normalizedPlaybackRate(_ rate: Float) -> Float {
        guard let nearest = availablePlaybackRates.min(by: {
            abs($0 - rate) < abs($1 - rate)
        }) else {
            return 1
        }
        return nearest
    }

    private var currentProgress: Float {
        guard let player, player.duration > 0 else { return 0 }
        return Float(player.currentTime / player.duration)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func failLoadingIfCurrent(sourceKey: String) {
        guard state == .loading(sourceURL: sourceKey) else { return }
        nowPlaying = nil
        state = .idle
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
        nowPlaying = nil
        state = .idle
        log("finished")
    }
}
