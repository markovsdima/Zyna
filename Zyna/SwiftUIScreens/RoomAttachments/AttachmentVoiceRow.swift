//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import SwiftUI

@MainActor
private final class AttachmentVoicePlaybackObserver: ObservableObject {

    struct Presentation: Equatable {
        let isLoading: Bool
        let isPlaying: Bool
        let hasFailure: Bool
        let progress: Float
        let failureMessage: String?
    }

    @Published private(set) var presentation: Presentation

    private var cancellable: AnyCancellable?

    init(sourceURL: String, eventId: String, audioPlayer: AudioPlayerService) {
        presentation = Self.makePresentation(
            sourceURL: sourceURL,
            eventId: eventId,
            state: audioPlayer.state,
            nowPlaying: audioPlayer.nowPlaying,
            failure: audioPlayer.failure
        )
        cancellable = audioPlayer.$state
            .combineLatest(audioPlayer.$nowPlaying, audioPlayer.$failure)
            .map { state, nowPlaying, failure in
                Self.makePresentation(
                    sourceURL: sourceURL,
                    eventId: eventId,
                    state: state,
                    nowPlaying: nowPlaying,
                    failure: failure
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presentation in
                self?.presentation = presentation
            }
    }

    private static func makePresentation(
        sourceURL: String,
        eventId: String,
        state: AudioPlayerService.State,
        nowPlaying: AudioPlayerService.NowPlayingItem?,
        failure: AudioPlayerService.PlaybackFailure?
    ) -> Presentation {
        let isCurrent = state.sourceURL == sourceURL
            && (nowPlaying?.eventId == nil || nowPlaying?.eventId == eventId)
        let hasFailure = failure?.sourceURL == sourceURL
            && (failure?.eventId == nil || failure?.eventId == eventId)
        return Presentation(
            isLoading: isCurrent && state.isLoading && !hasFailure,
            isPlaying: isCurrent && state.isPlaying,
            hasFailure: hasFailure,
            progress: isCurrent ? state.progress : 0,
            failureMessage: failure?.sourceURL == sourceURL ? failure?.message : nil
        )
    }
}

/// Tap-to-download voice playback backed by the app-wide audio player.
/// The SDK owns the downloaded file cache; this row never prefetches bytes.
struct AttachmentVoiceRow: View {

    let item: AttachmentItem
    let roomId: String
    let roomName: String
    let audioPlayer: AudioPlayerService

    @StateObject private var playback: AttachmentVoicePlaybackObserver

    init(
        item: AttachmentItem,
        roomId: String,
        roomName: String,
        audioPlayer: AudioPlayerService
    ) {
        self.item = item
        self.roomId = roomId
        self.roomName = roomName
        self.audioPlayer = audioPlayer
        _playback = StateObject(
            wrappedValue: AttachmentVoicePlaybackObserver(
                sourceURL: item.sourceMxc,
                eventId: item.id,
                audioPlayer: audioPlayer
            )
        )
    }

    var body: some View {
        Button(action: togglePlayback) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.appAccent.opacity(0.15))
                    buttonContent
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 5) {
                    Text(String(localized: "Voice message"))
                        .font(.body)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(hasFailure ? Color.red : Color.secondary)
                        .lineLimit(1)

                    ProgressView(value: Double(playbackProgress))
                        .progressViewStyle(.linear)
                        .tint(Color.appAccent)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Voice message") + ", " + subtitle)
        .accessibilityHint(buttonAccessibilityLabel)
    }

    @ViewBuilder
    private var buttonContent: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .tint(Color.appAccent)
        } else if hasFailure {
            Image(systemName: "exclamationmark")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.red)
        } else {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .offset(x: isPlaying ? 0 : 1)
        }
    }

    private var isCurrent: Bool {
        isLoading || isPlaying || playbackProgress > 0
    }

    private var isLoading: Bool {
        playback.presentation.isLoading
    }

    private var isPlaying: Bool {
        playback.presentation.isPlaying
    }

    private var hasFailure: Bool {
        playback.presentation.hasFailure
    }

    private var playbackProgress: Float {
        playback.presentation.progress
    }

    private var subtitle: String {
        if isLoading {
            return String(localized: "Loading")
        }
        if hasFailure {
            return playback.presentation.failureMessage
                ?? String(localized: "Download failed. Tap to retry.")
        }

        var parts: [String] = []
        if isCurrent, playbackProgress > 0 {
            let duration = item.durationSeconds ?? 0
            parts.append(MediaDurationFormatter.shortString(
                for: duration * TimeInterval(1 - playbackProgress)
            ))
        } else {
            parts.append(MediaDurationFormatter.shortString(for: item.durationSeconds ?? 0))
        }
        parts.append(item.date.formatted(date: .abbreviated, time: .omitted))
        let sender = item.isOwn
            ? String(localized: "You")
            : (item.senderName ?? item.sender)
        if !sender.isEmpty {
            parts.append(sender)
        }
        return parts.joined(separator: " · ")
    }

    private var buttonAccessibilityLabel: String {
        if isLoading { return String(localized: "Cancel voice message download") }
        if hasFailure { return String(localized: "Retry voice message") }
        return isPlaying
            ? String(localized: "Pause voice message")
            : String(localized: "Play voice message")
    }

    private func togglePlayback() {
        let sender = item.isOwn
            ? String(localized: "You")
            : (item.senderName ?? item.sender)
        let nowPlaying = AudioPlayerService.NowPlayingItem.voice(
            AudioPlayerService.NowPlayingVoice(
                sourceURL: item.sourceMxc,
                title: sender.isEmpty ? String(localized: "Voice message") : sender,
                subtitle: roomName,
                duration: item.durationSeconds ?? 0,
                waveform: [],
                roomId: roomId,
                eventId: item.id
            )
        )
        audioPlayer.togglePlayPause(
            source: item.source,
            mimeType: item.mimetype ?? RoomAttachmentKind.voice.defaultMimetype,
            nowPlaying: nowPlaying
        )
    }
}
