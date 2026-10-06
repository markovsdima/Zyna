// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Testing
import UIKit
@testable import Zyna

@Suite("Profile tabs", .serialized)
@MainActor
struct RoomProfileTabsTests {
    private func makeTabs() -> RoomProfileTabsView {
        let tabs = RoomProfileTabsView(frame: CGRect(x: 0, y: 0, width: 288, height: 34))
        tabs.setTabs(["Медиа", "Файлы", "Голосовые", "Закреплённые"], selectedIndex: 0, voiceIndex: 2)
        tabs.layoutIfNeeded()
        return tabs
    }

    @Test("The capsule follows fractional paging and reversal without committing selection", arguments: [false, true])
    func paging(rtl: Bool) throws {
        let tabs = makeTabs()
        tabs.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        tabs.setNeedsLayout(); tabs.layoutIfNeeded()
        let selection = try #require(tabs.layer.sublayers?.first { $0.name == "profile.tabs.selection" })
        let buttons = tabs.subviews.compactMap { $0 as? UIButton }
        #expect(!tabs.isAccessibilityElement && tabs.accessibilityTraits.contains(.tabBar))
        #expect(tabs.accessibilityElements as? [UIButton] == buttons)
        #expect(buttons[3].frame.width > buttons[0].frame.width)
        let start = buttons[0].frame.insetBy(dx: 1, dy: 3)
        let end = buttons[1].frame.insetBy(dx: 1, dy: 3)
        for progress: CGFloat in [0.25, 0.7, 0.4, 0] {
            tabs.setPosition(progress)
            #expect(abs(selection.frame.minX - (start.minX + (end.minX - start.minX) * progress)) < 0.01)
            #expect(abs(selection.frame.width - (start.width + (end.width - start.width) * progress)) < 0.01)
            #expect(tabs.selectedIndex == 0 && tabs.position == progress)
            #expect(selection.shadowPath?.boundingBoxOfPath == selection.bounds)
            #expect(selection.animationKeys()?.isEmpty != false)
        }
        var requested: Int?
        tabs.onSelect = { requested = $0 }
        buttons[2].sendActions(for: .touchUpInside)
        #expect(requested == 2 && tabs.selectedIndex == 0)
        tabs.setSelectedIndex(2)
        #expect(tabs.position == 2 && buttons[2].accessibilityTraits.contains(.selected))
        #expect(!buttons[0].accessibilityTraits.contains(.selected))
        tabs.isEnabled = false
        buttons[1].sendActions(for: .touchUpInside)
        #expect(requested == 2)
    }

    @Test("A tab jump interpolates only its endpoint capsules and returns to ordinary swipe geometry", arguments: [false, true])
    func directTransition(rtl: Bool) throws {
        let tabs = makeTabs()
        tabs.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        tabs.setNeedsLayout(); tabs.layoutIfNeeded()
        let selection = try #require(tabs.layer.sublayers?.first { $0.name == "profile.tabs.selection" })
        let buttons = tabs.subviews.compactMap { $0 as? UIButton }
        let start = buttons[0].frame.insetBy(dx: 1, dy: 3)
        let end = buttons[3].frame.insetBy(dx: 1, dy: 3)
        for progress: CGFloat in [0.25, 0.7, 0.4, 0] {
            tabs.setTransition(from: 0, to: 3, progress: progress)
            #expect(abs(selection.frame.minX - (start.minX + (end.minX - start.minX) * progress)) < 0.01)
            #expect(abs(selection.frame.width - (start.width + (end.width - start.width) * progress)) < 0.01)
            #expect(tabs.selectedIndex == 0 && tabs.position == 3 * progress)
            #expect(selection.animationKeys()?.isEmpty != false)
        }
        tabs.setTransition(from: 0, to: 3, progress: 0.25)
        // Reset even when the logical position happens to be identical.
        tabs.setPosition(0.75)
        let neighbor = buttons[1].frame.insetBy(dx: 1, dy: 3)
        #expect(abs(selection.frame.width - (start.width + (neighbor.width - start.width) * 0.75)) < 0.01)
        tabs.setTransition(from: 0, to: 3, progress: 1)
        tabs.setSelectedIndex(3)
        #expect(selection.frame == end && buttons[3].accessibilityTraits.contains(.selected))
    }

    @Test("Voice progress remains in its own capsule, preserves paused position and reuses controls")
    func progress() throws {
        let tabs = makeTabs()
        let buttons = tabs.subviews.compactMap { $0 as? UIButton }
        let identities = buttons.map(ObjectIdentifier.init)
        let track = try #require(tabs.layer.sublayers?.first { $0.name == "profile.tabs.voice" })
        let fill = try #require(track.sublayers?.first)
        let playing = RoomProfileVoiceTabPlayback(sourceURL: "mxc://server/voice", eventID: "$voice",
            progress: 0.42, isPlaying: true, duration: 60, playbackRate: 1)
        tabs.setVoicePlayback(playing)
        #expect(!track.isHidden && abs(fill.transform.m11 - 0.42) < 0.001)
        #expect(track.frame == buttons[2].frame.insetBy(dx: 1, dy: 3))
        tabs.setPosition(0.6)
        tabs.setSelectedIndex(1)
        #expect(!track.isHidden && tabs.voicePlayback == playing)
        #expect(track.frame == buttons[2].frame.insetBy(dx: 1, dy: 3))
        tabs.setVoicePlayback(.init(sourceURL: playing.sourceURL, eventID: playing.eventID,
            progress: 0.42, isPlaying: false, duration: 60, playbackRate: 1))
        #expect(abs(fill.transform.m11 - 0.42) < 0.001 && fill.animationKeys()?.isEmpty != false)
        #expect(buttons[2].accessibilityValue?.contains("42") == true)
        #expect(buttons[2].accessibilityValue?.contains(String(format: String(localized: "Paused: %@", table: "RoomProfile"), "")) == true)
        tabs.setTabs(["Медиа", "Файлы", "Голосовые"], selectedIndex: 1, voiceIndex: 2)
        tabs.layoutIfNeeded()
        #expect(tabs.subviews.compactMap { $0 as? UIButton }.map(ObjectIdentifier.init) == Array(identities.prefix(3)))
        #expect(!track.isHidden && abs(fill.transform.m11 - 0.42) < 0.001)
        tabs.setVoicePlayback(nil)
        #expect(track.isHidden && buttons[2].accessibilityValue == nil)
    }

    @Test("Only a ready voice from this room contributes tab progress")
    func playbackScope() {
        let roomID = "!room:server", source = "mxc://server/voice"
        func item(room: String) -> AudioPlayerService.NowPlayingItem {
            .voice(.init(sourceURL: source, title: "Alice", subtitle: nil, duration: 60,
                waveform: [], roomId: room, eventId: "$voice"))
        }
        func snapshot(loading: Bool = false, progress: Float = 0.5) -> AudioPlayerService.PlaybackSnapshot {
            .init(sourceURL: source, currentTime: 30, duration: 60, progress: progress, remainingTime: 30,
                playbackRate: 1, isPlaying: false, isLoading: loading)
        }
        #expect(RoomProfileVoiceTabPlayback.make(roomID: roomID, snapshot: snapshot(), item: item(room: roomID))?.progress == 0.5)
        #expect(RoomProfileVoiceTabPlayback.make(roomID: roomID, snapshot: snapshot(), item: item(room: "!other:server")) == nil)
        #expect(RoomProfileVoiceTabPlayback.make(roomID: roomID, snapshot: snapshot(loading: true), item: item(room: roomID)) == nil)
        #expect(RoomProfileVoiceTabPlayback.make(roomID: roomID, snapshot: snapshot(progress: .nan), item: item(room: roomID)) == nil)
        #expect(RoomProfileVoiceTabPlayback.make(roomID: roomID, snapshot: .idle(playbackRate: 1), item: item(room: roomID)) == nil)
        #expect(RoomProfileVoiceTabPlayback.make(roomID: roomID, snapshot: snapshot(),
            item: .track(.init(sourceURL: source, title: "Track", subtitle: nil, duration: 60))) == nil)
    }

    @Test("Voice progress runs continuously between samples and resyncs on playback changes")
    func continuousProgress() throws {
        let tabs = makeTabs()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(tabs)
        window.isHidden = false
        defer { tabs.setVoicePlayback(nil); window.isHidden = true; window.rootViewController = nil }
        let track = try #require(tabs.layer.sublayers?.first { $0.name == "profile.tabs.voice" })
        let fill = try #require(track.sublayers?.first)
        let key = "profile.voiceTab.progress"
        // Advance the layer's local clock explicitly, without sleeps or real audio.
        fill.speed = 0
        fill.timeOffset = 10
        tabs.setPlaybackAnimationEnabled(true)
        func sample(_ progress: Float, time: CFTimeInterval, playing: Bool = true,
                    rate: Float = 1, eventID: String = "$voice") {
            fill.timeOffset = time
            tabs.setVoicePlayback(.init(sourceURL: "mxc://server/voice", eventID: eventID,
                progress: progress, isPlaying: playing, duration: 100, playbackRate: rate))
        }
        func animation() throws -> CABasicAnimation {
            try #require(fill.animation(forKey: key) as? CABasicAnimation)
        }
        sample(0.2, time: 10)
        let initial = try animation()
        #expect(initial.beginTime == 10 && abs(initial.duration - 80) < 0.001)
        #expect(initial.toValue as? CGFloat == 1)
        #expect(!initial.isRemovedOnCompletion)
        for tick in 1...30 {
            let elapsed = Double(tick) / 30
            sample(Float(0.2 + elapsed / 100), time: 10 + elapsed)
            #expect(try animation().beginTime == initial.beginTime)
        }
        // Paging and a layout update must not restart the playback clock.
        tabs.setPosition(0.6)
        tabs.bounds.size.width = 320
        tabs.setNeedsLayout(); tabs.layoutIfNeeded()
        #expect(try animation().beginTime == initial.beginTime)

        sample(0.21, time: 11, playing: false)
        #expect(fill.animation(forKey: key) == nil && abs(fill.transform.m11 - 0.21) < 0.001)
        sample(0.21, time: 12)
        #expect(try animation().beginTime == 12)
        sample(0.215, time: 12.5, rate: 2)
        #expect(abs(try animation().duration - 39.25) < 0.001)
        sample(0.8, time: 13, rate: 2)
        #expect(abs(try animation().duration - 10) < 0.001)
        sample(0.3, time: 13.1, rate: 2)
        #expect(abs(try animation().duration - 35) < 0.001)
        // Even the same bytes in a different event start a new clock.
        sample(0.3, time: 13.11, rate: 2, eventID: "$forwarded")
        #expect(try animation().beginTime == 13.11)

        tabs.setPlaybackAnimationEnabled(false)
        #expect(fill.animation(forKey: key) == nil)
        sample(0.5, time: 23.11, rate: 2, eventID: "$forwarded")
        #expect(fill.animation(forKey: key) == nil)
        tabs.setPlaybackAnimationEnabled(true)
        #expect(abs(try animation().duration - 25) < 0.001)
        tabs.removeFromSuperview()
        #expect(fill.animation(forKey: key) == nil)
        controller.view.addSubview(tabs)
        #expect(fill.animation(forKey: key) != nil)
        tabs.setVoicePlayback(nil)
        #expect(fill.animation(forKey: key) == nil && track.isHidden)
    }

    @Test("Large text stays within the compact tab strip and retains full accessible titles")
    func largeText() {
        let tabs = makeTabs()
        tabs.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        let titles = ["Медиа", "Файлы", "Голосовые", "Закреплённые"]
        tabs.setTabs(titles, selectedIndex: 2, voiceIndex: 2)
        tabs.layoutIfNeeded()
        for (index, button) in tabs.subviews.compactMap({ $0 as? UIButton }).enumerated() {
            #expect((button.titleLabel?.font.lineHeight ?? 0) <= tabs.bounds.height - 6)
            #expect(button.frame.minX >= 0 && button.frame.maxX <= tabs.bounds.width)
            #expect(button.accessibilityLabel == titles[index])
        }
    }
}
