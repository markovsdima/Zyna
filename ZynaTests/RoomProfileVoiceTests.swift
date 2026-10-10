// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import MatrixRustSDK
import Testing
@testable import Zyna

enum ProfileVoiceAudioFixture {
    static func make() throws -> URL {
        // Sixty seconds of unsigned 8-bit PCM silence. No network or SDK.
        let samples = 8_000 * 60
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        func long(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); long(UInt32(36 + samples)); ascii("WAVEfmt ")
        long(16); word(1); word(1); long(8_000); long(8_000); word(1); word(8)
        ascii("data"); long(UInt32(samples)); data.append(Data(repeating: 128, count: samples))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID()).wav")
        try data.write(to: url)
        return url
    }
}

@MainActor
private final class VoiceLayoutFixture: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    let count = 3_000
    var measurements = 0

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        measurements += 1
        return CGSize(width: collectionView.bounds.width, height: 92)
    }
}

@Suite("Profile voice playback", .serialized)
@MainActor
struct RoomProfileVoiceTests {
    private let roomID = "!voices:example.org"

    @Test("The track takes horizontal drags, yields vertical scrolling, and wins against the pager")
    func scrubGestures() {
        let node = RoomProfileVoiceSeekNode()
        node.frame = CGRect(x: 0, y: 0, width: 200, height: 44)
        _ = node.view
        #expect(!node.isUserInteractionEnabled)
        #expect(node.view.gestureRecognizers!.allSatisfy { !$0.isEnabled })
        let host = UIView()
        host.addSubview(node.view)
        let parentPan = UIPanGestureRecognizer()
        host.addGestureRecognizer(parentPan)
        #expect(node.gestureRecognizerShouldBegin(parentPan))
        let own = node.view.gestureRecognizers!.first { $0 is UIPanGestureRecognizer }!
        #expect(!node.gestureRecognizerShouldBegin(own))
        node.isEnabled = true
        #expect(node.isUserInteractionEnabled)
        #expect(node.view.gestureRecognizers!.allSatisfy { $0.isEnabled })
        #expect(node.gestureRecognizerShouldBegin(parentPan))
        #expect(RoomProfileVoiceSeekNode.isSeeking(velocity: CGPoint(x: 100, y: 10)))
        #expect(!RoomProfileVoiceSeekNode.isSeeking(velocity: CGPoint(x: 10, y: -100)))
        #expect(!RoomProfileVoiceSeekNode.isSeeking(velocity: .zero))
        #expect(node.gestureRecognizer(own, shouldBeRequiredToFailBy: UIPanGestureRecognizer()))
        node.isEnabled = false
        #expect(!node.isUserInteractionEnabled)
        #expect(node.view.gestureRecognizers!.allSatisfy { !$0.isEnabled })
        #expect(!node.gestureRecognizer(own, shouldBeRequiredToFailBy: UIPanGestureRecognizer()))
    }

    @Test("Player controls veto only their own context press, never an ancestor's pan")
    func ancestorGestures() throws {
        let content = RoomProfileVoiceCell(item: try item(), title: "Alice", subtitle: "Today", images: .init())
        let cell = ListContextMenuCellNode(contentNode: content)
        cell.frame = CGRect(x: 0, y: 0, width: 320, height: RoomProfileVoiceCell.rowHeight(width: 320))
        let host = UIView(frame: cell.frame)
        host.addSubview(cell.view)
        cell.layoutIfNeeded()
        content.apply(.init(phase: .paused, progress: 0.4))
        cell.layoutIfNeeded()
        cell.onContextMenuActivated = { _ in }
        var contextChecks = 0
        cell.shouldBeginContextInteraction = { _ in contextChecks += 1; return false }
        let source = try #require(cell.subnodes?.first)
        let press = try #require(source.view.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer })
        #expect(!source.gestureRecognizerShouldBegin(press))
        #expect(contextChecks == 1)
        let controls = visibleContents(of: content).filter { $0 is ASButtonNode || $0 === content.seekNode }
        #expect(controls.count == 3)
        for pan in [UIPanGestureRecognizer(), UIPanGestureRecognizer(), InteractiveTransitionGestureRecognizer()] {
            host.addGestureRecognizer(pan)
            for control in controls {
                // UIKit consults the hit view, and Texture forwards through
                // the context source before reaching the scroll host.
                #expect(control.view.gestureRecognizerShouldBegin(pan))
            }
        }
        #expect(contextChecks == 1)
    }

    @Test("Sticky geometry clamps at both edges and leaves an in-range cell in its original slot")
    func stickyGeometry() {
        let viewport = CGRect(x: 0, y: 300, width: 402, height: 500)
        let frame = CGRect(x: 0, y: 420, width: 402, height: 92)
        #expect(RoomProfileListLayout.pinnedFrame(frame, in: viewport) == frame)
        #expect(RoomProfileListLayout.pinnedFrame(frame.offsetBy(dx: 0, dy: -500), in: viewport).minY == 300)
        #expect(RoomProfileListLayout.pinnedFrame(frame.offsetBy(dx: 0, dy: 800), in: viewport).maxY == 800)
    }

    @Test("Scrolling and moving the sticky viewport do not remeasure a large catalog")
    func stickyInvalidation() throws {
        let layout = RoomProfileListLayout(), fixture = VoiceLayoutFixture()
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 402, height: 700),
            collectionViewLayout: layout)
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "row")
        collection.dataSource = fixture
        collection.delegate = fixture
        collection.reloadData()
        collection.layoutIfNeeded()
        let measurements = fixture.measurements
        #expect(measurements >= fixture.count)
        layout.playingPath = IndexPath(item: 2_500, section: 0)
        collection.layoutIfNeeded()
        let context = try #require(layout.invalidationContext(forBoundsChange:
            collection.bounds.offsetBy(dx: 0, dy: 20)) as? UICollectionViewFlowLayoutInvalidationContext)
        #expect(!context.invalidateFlowLayoutDelegateMetrics && !context.invalidateFlowLayoutAttributes)
        #expect(context.invalidatedItemIndexPaths == [layout.playingPath!])
        for step in 1...20 {
            collection.contentOffset.y = CGFloat(step * 30)
            layout.visibleInsets.top = CGFloat(100 - step)
            collection.layoutIfNeeded()
            let frame = try #require(layout.layoutAttributesForItem(at: layout.playingPath!)).frame
            #expect(frame.maxY == collection.bounds.maxY)
        }
        layout.playingPath = IndexPath(item: 2, section: 0)
        collection.layoutIfNeeded()
        #expect(fixture.measurements == measurements)
        collection.frame.size.width = 360
        collection.layoutIfNeeded()
        #expect(fixture.measurements > measurements)
        #expect(layout.naturalAttributes(at: IndexPath(item: 0, section: 0))?.frame.width == 360)
    }

    private func item(_ id: String = "$voice") throws -> AttachmentItem {
        let mxc = "mxc://example.org/voice"
        return AttachmentItem(id: id, uniqueId: id, kind: .voice, timestampMs: 1_790_784_000_000,
            sender: "@alice:example.org", senderName: "Alice", isOwn: false,
            filename: "Voice message.ogg", caption: nil, mimetype: "audio/ogg", sizeBytes: 12_000,
            pixelWidth: nil, pixelHeight: nil, durationSeconds: 60, blurhash: nil, isAnimated: false,
            source: try MediaSource.fromUrl(url: mxc), sourceMxc: mxc, isSourceEncrypted: false, thumbnail: nil)
    }

    private func playing(_ item: AttachmentItem, room: String? = nil) -> AudioPlayerService.NowPlayingItem {
        .voice(.init(sourceURL: item.sourceMxc, title: "Alice", subtitle: "Room", duration: 60,
            waveform: [], roomId: room ?? roomID, eventId: item.id))
    }

    @Test("The same audio file in another event or room never borrows playback or failure state")
    func identities() throws {
        let target = try item(), other = try item("$forwarded")
        let state = AudioPlayerService.State.playing(sourceURL: target.sourceMxc, progress: 0.4)
        func presentation(_ current: AudioPlayerService.NowPlayingItem?, failure: AudioPlayerService.PlaybackFailure? = nil) -> RoomProfileVoicePresentation {
            .make(item: target, roomID: roomID, state: state, nowPlaying: current, failure: failure)
        }
        #expect(presentation(playing(target)) == .init(phase: .playing, progress: 0.4))
        #expect(presentation(playing(other)) == .init())
        #expect(presentation(playing(target, room: "!another:example.org")) == .init())
        #expect(presentation(.track(.init(sourceURL: target.sourceMxc, title: "Track", subtitle: nil, duration: 60))) == .init())
        let failure = AudioPlayerService.PlaybackFailure(sourceURL: target.sourceMxc, eventId: other.id, message: "Failed")
        #expect(presentation(playing(target), failure: failure).phase == .playing)
        #expect(presentation(nil, failure: .init(sourceURL: target.sourceMxc, eventId: target.id, message: "Retry")).phase == .failed("Retry"))
    }

    @Test("Playback ticks update layers without recreating rows; accessibility follows loading, pause and retry")
    func presentation() throws {
        let cell = RoomProfileVoiceCell(item: try item(), title: "Alice", subtitle: "Today", images: .init())
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: 92)
        _ = cell.view
        cell.layoutIfNeeded()
        let originalNodes = cell.subnodes?.map(ObjectIdentifier.init)
        let initialSize = cell.calculateSizeThatFits(CGSize(width: 402, height: 92))
        cell.apply(.init(phase: .loading))
        #expect(cell.accessibilityHint == String(localized: "Cancel voice message download"))
        cell.apply(.init(phase: .playing, progress: 0.5))
        #expect(cell.accessibilityValue == "0:30, 1×")
        #expect(cell.accessibilityHint == String(localized: "Pause voice message"))
        cell.apply(.init(phase: .paused, progress: 0.5))
        #expect(cell.accessibilityHint == String(localized: "Play voice message"))
        #expect(cell.controlsEnabled && cell.seekNode.isEnabled)
        var sought: Float?
        cell.onSeek = { sought = $0 }
        cell.adjustPlayback(forward: true)
        #expect(sought == 0.55)
        cell.adjustPlayback(forward: false)
        #expect(sought == 0.5)
        #expect(cell.calculateSizeThatFits(CGSize(width: 402, height: 92)) == initialSize)
        cell.apply(.init(phase: .failed("Retry download")))
        #expect(cell.accessibilityValue == "Retry download")
        #expect(cell.accessibilityHint == String(localized: "Retry voice message"))
        #expect(cell.subnodes?.map(ObjectIdentifier.init) == originalNodes)
        let wrapper = ListContextMenuCellNode(contentNode: cell)
        var taps = 0
        wrapper.onQuickTap = { taps += 1 }
        #expect(wrapper.accessibilityActivate())
        #expect(taps == 1)
        wrapper.onAccessibilityAdjust = { cell.adjustPlayback(forward: $0) }
        cell.apply(.init(phase: .paused, progress: 0.9))
        wrapper.accessibilityIncrement()
        #expect(abs((sought ?? 0) - 0.95) < 0.001)
        wrapper.accessibilityDecrement()
        #expect(abs((sought ?? 0) - 0.9) < 0.001)
        cell.apply(.init())
        cell.seekNode.onPreview?(0.5) // A cancelled drag must not overwrite the idle state.
        #expect(cell.accessibilityValue == "1:00" && !cell.controlsEnabled)
    }

    @Test("Metadata crossfades inside stationary slots; hidden controls never capture scrolling")
    func controlsTransition() throws {
        let cell = RoomProfileVoiceCell(item: try item(), title: "Alice", subtitle: "Today", images: .init())
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: 92)
        _ = cell.view
        cell.layoutIfNeeded()
        let title = try #require(cell.subnodes?.compactMap { $0 as? ASTextNode }.first)
        let faces = cell.subnodes!.compactMap { $0 as? RoomProfileVoiceFadeNode }
        #expect(faces.count == 4 && faces.allSatisfy { $0.clipsToBounds })
        let initialBounds = cell.bounds, titleFrame = title.frame
        let initialFrames = faces.map(\.frame)
        let nodes = descendants(of: cell).map(ObjectIdentifier.init)
        func trackHit() -> UIView? {
            let point = cell.seekNode.convert(CGPoint(x: cell.seekNode.bounds.midX, y: cell.seekNode.bounds.midY), to: cell)
            return cell.view.hitTest(point, with: nil)
        }
        #expect(trackHit() !== cell.seekNode.view)
        cell.setPlaybackAnimationEnabled(true)
        cell.apply(.init(phase: .playing, progress: 0.25))
        #expect(cell.bounds == initialBounds && title.frame == titleFrame)
        #expect(faces.map(\.frame) == initialFrames)
        #expect(trackHit() === cell.seekNode.view)
        #expect(cell.containsControl(at: cell.seekNode.convert(CGPoint(x: 20, y: 22), to: cell)))
        #expect(faces.filter(\.isShowing).count == 2)
        #expect(title.layer.animationKeys()?.isEmpty != false)
        for face in faces {
            #expect(face.accessibilityElementsHidden && !face.isAccessibilityElement)
            #expect(face.content.layer.animationKeys() == ["voiceContent.opacity"])
            #expect(CATransform3DIsIdentity(face.content.transform))
        }
        cell.apply(.init(phase: .paused, progress: 0.25))
        #expect(title.frame == titleFrame && faces.map(\.frame) == initialFrames)
        for face in faces { face.finishAnimations() }
        cell.apply(.init(phase: .playing, progress: 0.3))
        #expect(faces.allSatisfy { $0.content.layer.animationKeys()?.isEmpty != false })
        cell.apply(.init())
        #expect(title.frame == titleFrame && cell.bounds == initialBounds)
        #expect(faces.map(\.frame) == initialFrames)
        #expect(cell.seekNode.progress == 0.3) // Retiring controls keep their displayed position.
        #expect(trackHit() !== cell.seekNode.view)
        #expect(!cell.containsControl(at: cell.seekNode.convert(CGPoint(x: 20, y: 22), to: cell)))
        #expect(descendants(of: cell).map(ObjectIdentifier.init) == nodes)
        cell.setPlaybackAnimationEnabled(false)
        #expect(faces.allSatisfy { $0.content.layer.animationKeys()?.isEmpty != false })
    }

    @Test("A reversed crossfade continues from the visible opacity and never transforms text")
    func fadeReversal() async throws {
        let content = ASDisplayNode()
        let state = RoomProfileVoiceFadeNode(content: content, initiallyVisible: true)
        state.frame = CGRect(x: 0, y: 0, width: 200, height: 24)
        _ = state.view
        state.layoutIfNeeded()
        state.setShowing(false, animated: true, reduceMotion: false)
        let first = try #require(content.layer.animation(forKey: "voiceContent.opacity") as? CABasicAnimation)
        let pendingStart = try #require(first.fromValue as? Float)
        let visibleOpacity = content.layer.presentation()?.opacity ?? pendingStart
        state.setShowing(true, animated: true, reduceMotion: false)
        if let reversal = content.layer.animation(forKey: "voiceContent.opacity") as? CABasicAnimation {
            #expect(try #require(reversal.fromValue as? Float) == visibleOpacity)
        } else { #expect(visibleOpacity == 1) }
        #expect(content.alpha == 1 && CATransform3DIsIdentity(content.transform))
        state.finishAnimations()
        state.setShowing(false, animated: true, reduceMotion: true)
        let fade = try #require(content.layer.animation(forKey: "voiceContent.opacity") as? CABasicAnimation)
        #expect(fade.duration == 0.16 && CATransform3DIsIdentity(content.transform))
        state.setShowing(true, animated: false)
        #expect(content.layer.animationKeys()?.isEmpty != false && content.alpha == 1)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        window.rootViewController!.view.addSubview(state.view)
        defer { window.isHidden = true }
        state.setShowing(false, animated: true, reduceMotion: false)
        try await wait {
            guard let opacity = content.layer.presentation()?.opacity else { return false }
            return opacity > 0.05 && opacity < 0.95
        }
        let runningOpacity = try #require(content.layer.presentation()).opacity
        state.setShowing(true, animated: true, reduceMotion: false)
        let reversal = try #require(content.layer.animation(forKey: "voiceContent.opacity") as? CABasicAnimation)
        #expect(abs(try #require(reversal.fromValue as? Float) - runningOpacity) < 0.01)
        #expect(content.layer.animationKeys() == ["voiceContent.opacity"])
        #expect(CATransform3DIsIdentity(content.transform))
    }

    private func descendants(of node: ASDisplayNode) -> [ASDisplayNode] {
        (node.subnodes ?? []).flatMap { [$0] + descendants(of: $0) }
    }

    private func visibleContents(of node: ASDisplayNode) -> [ASDisplayNode] {
        guard node.alpha > 0 else { return [] }
        if node is ASTextNode || node is ASButtonNode || node is RoomProfileVoiceSeekNode { return [node] }
        return (node.subnodes ?? []).flatMap { visibleContents(of: $0) }
    }

    @Test("Stop clears the player and preserves a session bookmark until playback successfully restarts")
    func stopAndResume() async throws {
        let target = try item(), player = AudioPlayerService(), session = RoomProfileVoiceSession()
        let playback = RoomProfileVoicePlayback(player: player, roomID: roomID, session: session)
        let cell = RoomProfileVoiceCell(item: target, title: "Alice", subtitle: "Today", images: .init())
        let audioURL = try await Task.detached { try ProfileVoiceAudioFixture.make() }.value
        defer { player.stop(); playback.isActive = false; try? FileManager.default.removeItem(at: audioURL) }
        playback.isActive = true
        playback.setVisible(true, cell: cell)
        player.playLocal(url: audioURL, sourceKey: target.sourceMxc, nowPlaying: playing(target))
        player.seek(to: 0.4)
        player.pause()
        try await wait { cell.controlsEnabled }
        cell.stopPlayback()
        #expect(player.state == .idle && player.nowPlaying == nil)
        #expect(abs(session.progress(for: target.id) - 0.4) < 0.01)
        try await wait { !cell.controlsEnabled && playback.currentEventID == nil }
        player.playLocal(url: URL(fileURLWithPath: "/missing-\(UUID()).ogg"), sourceKey: target.sourceMxc,
            nowPlaying: playing(target), startProgress: session.progress(for: target.id),
            onStarted: { session.didStart(eventID: target.id) })
        #expect(abs(session.progress(for: target.id) - 0.4) < 0.01)
        player.playLocal(url: audioURL, sourceKey: target.sourceMxc, nowPlaying: playing(target),
            startProgress: session.progress(for: target.id), onStarted: { session.didStart(eventID: target.id) })
        player.pause()
        #expect(abs(player.snapshot.currentTime - 24) < 1)
        #expect(session.progress(for: target.id) == 0)
        #expect(RoomProfileVoiceSession().progress(for: target.id) == 0)
        // A stale row's Stop cannot stop a different event using the same file.
        let other = try item("$forwarded")
        player.playLocal(url: audioURL, sourceKey: other.sourceMxc, nowPlaying: playing(other))
        cell.stopPlayback()
        #expect(player.state.isPlaying && player.nowPlaying?.eventId == other.id)
    }

    @Test("Dock styling follows layout attributes and distinguishes both themes")
    func docking() throws {
        let cell = RoomProfileVoiceCell(item: try item(), title: "Alice", subtitle: "Today", images: .init())
        let wrapper = ListContextMenuCellNode(contentNode: cell)
        wrapper.onLayoutAttributesChanged = { cell.setDockEdge(($0 as? RoomProfileListAttributes)?.dockEdge ?? .none) }
        let attributes = RoomProfileListAttributes(forCellWith: IndexPath(item: 1, section: 0))
        attributes.dockEdge = .top
        wrapper.applyLayoutAttributes(attributes)
        #expect(cell.dockEdge == .top)
        let copy = try #require(attributes.copy() as? RoomProfileListAttributes)
        #expect(copy == attributes && copy.dockEdge == .top)
        copy.dockEdge = .none
        #expect(copy != attributes)
        wrapper.applyLayoutAttributes(copy)
        #expect(cell.dockEdge == .none)
        for style: UIUserInterfaceStyle in [.dark, .light] {
            let trait = UITraitCollection(userInterfaceStyle: style)
            var dock: CGFloat = 0, normal: CGFloat = 0
            RoomProfileVoiceCell.dockedBackground.resolvedColor(with: trait).getWhite(&dock, alpha: nil)
            UIColor.appBG.resolvedColor(with: trait).getWhite(&normal, alpha: nil)
            #expect(style == .dark ? dock < normal : dock > normal)
        }
    }

    @Test("Long names and dates do not overlap player controls at narrow widths or large text sizes",
          arguments: [CGFloat(320), 402], [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge])
    func adaptiveLayout(width: CGFloat, category: UIContentSizeCategory) throws {
        let item = try item()
        UITraitCollection(preferredContentSizeCategory: category).performAsCurrent {
            let cell = RoomProfileVoiceCell(item: item, title: "A very long sender display name",
                subtitle: "5 окт. 2026 г., 18:24", images: .init())
            let height = RoomProfileVoiceCell.rowHeight(width: width)
            cell.frame = CGRect(x: 0, y: 0, width: width, height: height)
            _ = cell.view
            cell.layoutIfNeeded()
            let bounds = cell.bounds
            cell.apply(.init(phase: .playing, progress: 0.4, rate: 1.5))
            let visible = visibleContents(of: cell)
            let date = visible.compactMap { $0 as? ASTextNode }
                .first { $0.attributedText?.string == "5 окт. 2026 г., 18:24" }
            #expect(date != nil)
            guard let date else { return }
            let dateFrame = date.convert(date.bounds, to: cell)
            let seekFrame = cell.seekNode.convert(cell.seekNode.bounds, to: cell)
            #expect(date.alpha == 1 && cell.bounds == bounds)
            #expect(dateFrame.maxY <= seekFrame.minY)
            #expect(seekFrame.width >= 64 && seekFrame.minX >= 72)
            let frames = visible.map { $0.convert($0.bounds, to: cell) }
            for (index, frame) in frames.enumerated() {
                #expect(frame.minX >= 0 && frame.maxX <= width)
                #expect(frame.minY >= 0 && frame.maxY <= height)
                for other in frames.dropFirst(index + 1) { #expect(!frame.intersects(other)) }
            }
        }
    }

    @Test("Only visible cells observe the shared player, and returning to the page refreshes its state")
    func visibility() async throws {
        let target = try item(), player = AudioPlayerService()
        let playback = RoomProfileVoicePlayback(player: player, roomID: roomID)
        let cell = RoomProfileVoiceCell(item: target, title: "Alice", subtitle: "Today", images: .init())
        playback.isActive = true
        playback.setVisible(true, cell: cell)
        defer { player.stop(); playback.isActive = false }
        // A nonexistent local file exercises the real failure publisher
        // without touching the account, network or Matrix media cache.
        player.playLocal(url: URL(fileURLWithPath: "/missing-voice-\(UUID()).ogg"),
            sourceKey: target.sourceMxc, nowPlaying: playing(target))
        try await wait { cell.accessibilityHint == String(localized: "Retry voice message") }
        #expect(playback.currentEventID == nil)
        playback.isActive = false
        player.stop()
        #expect(cell.accessibilityHint == String(localized: "Retry voice message"))
        playback.isActive = true
        try await wait { cell.accessibilityHint == String(localized: "Play voice message") }
        #expect(playback.currentEventID == nil)
        playback.setVisible(false, cell: cell)
        player.playLocal(url: URL(fileURLWithPath: "/missing-voice-\(UUID()).ogg"),
            sourceKey: target.sourceMxc, nowPlaying: playing(target))
        #expect(cell.accessibilityHint == String(localized: "Play voice message"))
        playback.setVisible(true, cell: cell)
        #expect(cell.accessibilityHint == String(localized: "Retry voice message"))
        weak var releasedCell: RoomProfileVoiceCell?
        do {
            let temporary = RoomProfileVoiceCell(item: target, title: "Alice", subtitle: "", images: .init())
            releasedCell = temporary
            playback.setVisible(true, cell: temporary)
        }
        #expect(releasedCell == nil)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
