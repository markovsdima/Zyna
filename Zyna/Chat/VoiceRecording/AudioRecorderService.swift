//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Combine

final class AudioRecorderService {

    enum State {
        case idle
        case recording(duration: TimeInterval, waveform: [Float])
        case finished(fileURL: URL, duration: TimeInterval, waveform: [Float])
        case cancelled
        case error(Error)
    }

    @Published private(set) var state: State = .idle

    private let log = ScopedLog(.voiceRecording, prefix: "[VoiceRec]")

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var displayLink: DisplayLinkToken?
    private var waveformSamples: [Float] = []

    // MARK: - Public API

    func startRecording() {
        let session = AVAudioSession.sharedInstance()

        switch session.recordPermission {
        case .granted:
            beginRecording(session: session)
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginRecording(session: session)
                    } else {
                        self?.log("permission denied by user")
                        self?.state = .idle
                    }
                }
            }
        case .denied:
            log("permission denied")
            state = .idle
        @unknown default:
            state = .idle
        }
    }

    func stopRecording() {
        guard let recorder, recorder.isRecording else { return }
        let duration = recorder.currentTime
        recorder.stop()
        displayLink?.invalidate()
        displayLink = nil

        if let url = fileURL {
            log("finished duration=\(String(format: "%.1f", duration))s samples=\(waveformSamples.count)")
            state = .finished(fileURL: url, duration: duration, waveform: waveformSamples)
        }

        self.recorder = nil
    }

    func cancelRecording() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        displayLink?.invalidate()
        displayLink = nil
        self.recorder = nil
        fileURL = nil
        waveformSamples = []
        state = .cancelled
        log("cancelled")
    }

    // MARK: - Private

    private func beginRecording(session: AVAudioSession) {
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            log("session error: \(error)")
            state = .error(error)
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            rec.record()

            self.recorder = rec
            self.fileURL = url
            self.waveformSamples = []

            log("started → \(url.lastPathComponent)")
            state = .recording(duration: 0, waveform: [])

            startWaveformSampling()
        } catch {
            log("recorder error: \(error)")
            state = .error(error)
        }
    }

    private func startWaveformSampling() {
        displayLink = DisplayLinkDriver.shared.subscribe(rate: .fps(15)) { [weak self] _ in
            self?.sampleWaveform()
        }
    }

    private func sampleWaveform() {
        guard let recorder, recorder.isRecording else { return }

        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0) // dB: -160...0
        // Normalize to 0...1 range (voice typically -50...0 dB)
        let normalized = max(0, min(1, (power + 50) / 50))
        waveformSamples.append(normalized)

        let duration = recorder.currentTime
        state = .recording(duration: duration, waveform: waveformSamples)
    }
}
