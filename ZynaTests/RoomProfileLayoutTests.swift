// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import GRDB
import MatrixRustSDK
import Testing
import UIKit
@testable import Zyna

/// UIKit's pan reports zero without real touches. Supply physical movement
/// independently of the content offset that the controller corrects.
@MainActor
private final class ProfileDragInput {
    private var translations: [ObjectIdentifier: CGFloat] = [:]
    func translation(_ scrollView: UIScrollView) -> CGFloat {
        translations[ObjectIdentifier(scrollView), default: 0]
    }
    func drag(_ scrollView: UIScrollView, down distance: CGFloat) {
        translations[ObjectIdentifier(scrollView), default: 0] += distance
        scrollView.contentOffset.y -= distance
    }
}

private final class ProfileFixtureSource: AttachmentSource, @unchecked Sendable {
    var onSnapshot: ((AttachmentTimelineStore.Snapshot, AttachmentTimelineStore.ApplySummary) -> Void)?
    var onPaginationStatus: ((PaginationStatus) -> Void)?
    var onAttachmentsDiscovered: (([StoredRoomAttachment]) -> Void)?
    var onAttachmentsInvalidated: (([String]) -> Void)?
    var media = (0..<120).map { item($0) }
    var files = [item(500, kind: .file)]
    var voice: [AttachmentItem] = []
    let starts = Atomic(0)
    private var generation = 0

    static func item(_ index: Int, kind: RoomAttachmentKind = .image) -> AttachmentItem {
        let mxc = "mxc://profile.invalid/\(index)"
        return AttachmentItem(id: "$photo\(index)", uniqueId: "sdk\(index)", kind: kind,
            timestampMs: 1_790_784_000_000, sender: "@alice:example.org", senderName: "Alice", isOwn: false,
            filename: kind == .file ? "Design notes.pdf" : "Photo \(index)", caption: nil,
            mimetype: kind == .file ? "application/pdf" : "image/jpeg", sizeBytes: nil,
            pixelWidth: 300, pixelHeight: 300, durationSeconds: nil,
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj", isAnimated: false,
            source: try! MediaSource.fromUrl(url: mxc), sourceMxc: mxc, isSourceEncrypted: true, thumbnail: nil)
    }

    @MainActor func publish() {
        generation += 1
        func groups(_ items: [AttachmentItem]) -> [AttachmentMonthGroup] {
            items.isEmpty ? [] : [.init(id: "2026-09", title: "September 2026", items: items)]
        }
        onSnapshot?(.init(generation: generation, rowCount: media.count + files.count + voice.count,
            media: groups(media), voice: groups(voice), files: groups(files), mediaCount: media.count,
            voiceCount: voice.count, fileCount: files.count, pendingCount: 0, pendingSessionIds: []), .init())
    }

    func start() async throws { starts.modify { $0 += 1 }; await publish() }
    func stop() {}
    func loadMore(numEvents: UInt16) async throws -> Bool { true }
    func retryDecryption(sessionIds: [String]) {}
    func describeTimelineItem(eventId: String) async -> String? { nil }
    func storeRowDescription(uniqueId: String) -> String? { nil }
}

@Suite("Texture profile layout", .serialized)
@MainActor
struct RoomProfileLayoutTests {
    @Test("The Voice tab observes playback without a voice page and suspends updates while the profile is hidden")
    func voiceTabProgress() async throws {
        let audioURL = try await Task.detached { try ProfileVoiceAudioFixture.make() }.value
        let source = ProfileFixtureSource(), player = AudioPlayerService()
        let target = ProfileFixtureSource.item(1_000, kind: .voice)
        source.voice = [target]
        let model = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        let controller = RoomProfileViewController(room: nil, title: "Room", subtitle: "", model: model,
            actions: .none, audioPlayer: player, initialSection: .files)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { player.stop(); model.stop(); window.isHidden = true; window.rootViewController = nil
            try? FileManager.default.removeItem(at: audioURL) }
        controller.view.layoutIfNeeded()
        let tabs = try #require(find(RoomProfileTabsView.self, in: controller.view, id: "profile.sections"))
        #expect(find(ASCollectionView.self, in: controller.view, id: "profile.voice") == nil)
        player.playLocal(url: audioURL, sourceKey: target.sourceMxc,
            nowPlaying: .voice(.init(sourceURL: target.sourceMxc, title: "Alice", subtitle: "Room",
                duration: 60, waveform: [], roomId: model.roomId, eventId: target.id)))
        player.seek(to: 0.42)
        player.pause()
        try await wait { abs((tabs.voicePlayback?.progress ?? 0) - 0.42) < 0.01 && tabs.voicePlayback?.isPlaying == false }
        controller.selectSection(.media, animated: false)
        controller.didReceiveMemoryWarning()
        #expect(find(ASCollectionView.self, in: controller.view, id: "profile.voice") == nil)
        player.seek(to: 0.6)
        try await wait { abs((tabs.voicePlayback?.progress ?? 0) - 0.6) < 0.01 }
        controller.beginAppearanceTransition(false, animated: false); controller.endAppearanceTransition()
        player.seek(to: 0.8)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(abs((tabs.voicePlayback?.progress ?? 0) - 0.6) < 0.01)
        controller.beginAppearanceTransition(true, animated: false); controller.endAppearanceTransition()
        try await wait { abs((tabs.voicePlayback?.progress ?? 0) - 0.8) < 0.01 }
        player.stop()
        try await wait { tabs.voicePlayback == nil }
    }

    @Test("Recreated lists keep their anchor and accept a catalog seen before eviction",
          arguments: [RoomProfileScrollState.Section.files, .voice])
    func recreatedListCatalog(section: RoomProfileScrollState.Section) async throws {
        let source = ProfileFixtureSource()
        let kind: RoomAttachmentKind = section == .voice ? .voice : .file
        let original = (1_000..<1_060).map { ProfileFixtureSource.item($0, kind: kind) }
        if section == .voice { source.voice = original } else { source.files = original }
        let model = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        let controller = RoomProfileViewController(room: nil, title: "Room", subtitle: "", model: model,
            actions: .none, audioPlayer: AudioPlayerService(), initialSection: section)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let id = section == .voice ? "profile.voice" : "profile.files"
        var list = try #require(find(ASCollectionView.self, in: controller.view, id: id))
        var page = try #require(list.collectionNode?.delegate as? RoomProfileListPage)
        try await wait { itemCount(list) == 62 && !page.isAdjusting }
        list.contentOffset.y = 950
        let anchor = try #require(page.captureAnchor())
        controller.selectSection(.media, animated: false)
        controller.didReceiveMemoryWarning()
        #expect(find(ASCollectionView.self, in: controller.view, id: id) == nil)
        let changed = [ProfileFixtureSource.item(1_100, kind: kind)] + original
        if section == .voice { source.voice = changed } else { source.files = changed }
        source.publish()
        try await wait { (section == .voice ? model.voice : model.files).flatMap(\.items).count == 61 }
        controller.selectSection(section, animated: false)
        list = try #require(find(ASCollectionView.self, in: controller.view, id: id))
        page = try #require(list.collectionNode?.delegate as? RoomProfileListPage)
        try await wait { itemCount(list) == 63 && !page.isAdjusting }
        let restored = try #require(page.captureAnchor())
        #expect(restored.id == anchor.id && abs(restored.offset - anchor.offset) < 1)
        // X -> evicted Y -> recreated Y -> X must not lose the final X
        // to the deduplicator's memory from the old page.
        if section == .voice { source.voice = original } else { source.files = original }
        source.publish()
        try await wait { itemCount(list) == 62 && !page.isAdjusting }
        #expect(page.captureAnchor()?.id == anchor.id)
    }

    @Test("The same voice cell pins at both edges without moving content, and keeps pause, seek and speed controls")
    func stickyVoicePlayer() async throws {
        let audioURL = try await Task.detached { try ProfileVoiceAudioFixture.make() }.value
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let source = ProfileFixtureSource(), player = AudioPlayerService()
        source.voice = (1000..<1080).map { ProfileFixtureSource.item($0, kind: .voice) }
        let model = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        let controller = RoomProfileViewController(room: nil, title: "Room", subtitle: "", model: model,
            actions: .none, audioPlayer: player, initialSection: .voice)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller; window.isHidden = false
        defer { player.stop(); model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let list = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.voice"))
        let page = try #require(list.collectionNode?.delegate as? RoomProfileListPage)
        let layout = try #require(list.collectionViewLayout as? RoomProfileListLayout)
        try await wait { itemCount(list) == 82 && !page.isAdjusting }
        let offset = list.contentOffset, contentSize = list.contentSize, inset = list.contentInset
        let safeArea = controller.additionalSafeAreaInsets
        let target = source.voice[10], path = IndexPath(item: 11, section: 0)
        let natural = try #require(layout.naturalAttributes(at: path)).frame
        player.playLocal(url: audioURL, sourceKey: target.sourceMxc,
            nowPlaying: .voice(.init(sourceURL: target.sourceMxc, title: "Alice", subtitle: "Room",
                duration: 60, waveform: [], roomId: model.roomId, eventId: target.id)))
        try #require(player.state.isPlaying)
        player.pause()
        try await wait { layout.playingPath == path }
        list.layoutIfNeeded()
        try await wait { page.node.nodeForItem(at: path)?.isVisible == true }
        let cell = try #require(page.node.nodeForItem(at: path) as? ListContextMenuCellNode)
        let voiceCell = try #require(cell.subnodes?.first?.subnodes?.first as? RoomProfileVoiceCell)
        try await wait { cell.accessibilityTraits.contains(.adjustable) }
        #expect(voiceCell.dockEdge == .bottom)
        #expect(list.contentOffset == offset && list.contentSize == contentSize && list.contentInset == inset)
        #expect(controller.additionalSafeAreaInsets == safeArea)
        let bottom = try #require(layout.layoutAttributesForItem(at: path)).frame
        #expect(abs(bottom.maxY - (list.bounds.maxY - layout.visibleInsets.bottom)) < 1)
        #expect(bottom.height == natural.height)
        cell.accessibilityIncrement()
        #expect(abs(player.state.progress - 0.05) < 0.01)
        let speedAction = try #require(cell.accessibilityActionsProvider?().last)
        #expect(speedAction.name == String(localized: "Playback speed"))
        #expect(speedAction.actionHandler?(speedAction) == true && player.playbackRate == 1.5)
        list.contentOffset.y = 150
        list.layoutIfNeeded()
        let topButton = try #require(find(UIButton.self, in: controller.view, id: "profile.scrollToTop"))
        let normalButtonY = controller.view.bounds.height - controller.view.safeAreaInsets.bottom - 64
        let playerFrame = try #require(layout.layoutAttributesForItem(at: path)).frame
        #expect(!topButton.isHidden)
        #expect(topButton.frame.minY < normalButtonY)
        #expect(!topButton.frame.intersects(list.convert(playerFrame, to: topButton.superview)))
        for y: CGFloat in [650, 1_500, 650, 150] {
            if y == 150 {
                // Let the button reach its lower position before testing
                // a new ascent; same-frame reversal may need no motion.
                try await wait { topButton.layer.animation(forKey: "profile.topButton.position") == nil }
            }
            list.contentOffset.y = y
            list.layoutIfNeeded()
            #expect(page.node.nodeForItem(at: path) === cell)
            let frame = try #require(layout.layoutAttributesForItem(at: path)).frame
            let viewport = list.bounds.inset(by: layout.visibleInsets)
            #expect(frame == RoomProfileListLayout.pinnedFrame(natural, in: viewport))
            #expect(layout.layoutAttributesForElements(in: list.bounds)?.filter { $0.indexPath == path }.count == 1)
            #expect(layout.naturalAttributes(at: path)?.frame == natural)
            #expect(voiceCell.dockEdge == (frame.minY > natural.minY ? .top : (frame.minY < natural.minY ? .bottom : .none)))
            if voiceCell.dockEdge == .bottom {
                #expect(page.bottomDockedPlayerHeight == frame.height)
                #expect(topButton.frame.minY < normalButtonY)
                #expect(!topButton.frame.intersects(list.convert(frame, to: topButton.superview)))
                #expect((topButton.layer.animation(forKey: "profile.topButton.position") != nil)
                    == !UIAccessibility.isReduceMotionEnabled)
            } else {
                #expect(page.bottomDockedPlayerHeight == nil)
                #expect(topButton.frame.minY == normalButtonY)
            }
        }
        list.contentOffset.y = 1_500
        list.layoutIfNeeded()
        #expect(page.captureAnchor()?.id != target.id)
        let anchor = try #require(page.captureAnchor())
        source.voice.insert(ProfileFixtureSource.item(1100, kind: .voice), at: 0)
        source.publish()
        let shiftedPath = IndexPath(item: 12, section: 0)
        try await wait { itemCount(list) == 83 && !page.isAdjusting && layout.playingPath == shiftedPath }
        #expect(page.node.nodeForItem(at: shiftedPath) === cell)
        #expect(page.captureAnchor()?.id == anchor.id)
        // The live content can still be extracted and restored by its menu.
        let beforeMenu = list.contentOffset
        cell.onContextMenuActivated?(CGPoint(x: 20, y: 20))
        #expect(!list.isScrollEnabled)
        page.dismissContextMenu()
        try await wait { list.isScrollEnabled }
        #expect(list.contentOffset == beforeMenu)
        controller.selectSection(.files, animated: false)
        #expect(!page.voicePlayback!.isActive && list.accessibilityElementsHidden)
        #expect(player.state.sourceURL == target.sourceMxc)
        controller.selectSection(.voice, animated: false)
        #expect(page.voicePlayback!.isActive && !list.accessibilityElementsHidden)
        #expect(list.contentOffset == beforeMenu)
        let next = source.voice[25]
        player.playLocal(url: audioURL, sourceKey: next.sourceMxc,
            nowPlaying: .voice(.init(sourceURL: next.sourceMxc, title: "Alice", subtitle: "Room",
                duration: 60, waveform: [], roomId: model.roomId, eventId: next.id)))
        player.pause()
        try await wait { layout.playingPath == IndexPath(item: 26, section: 0) }
        #expect(!cell.accessibilityTraits.contains(.adjustable))
        #expect(list.contentOffset == beforeMenu && cell.frame.height == natural.height)
        let nextPath = IndexPath(item: 26, section: 0)
        try await wait { page.node.nodeForItem(at: nextPath)?.isVisible == true }
        let nextCell = try #require(page.node.nodeForItem(at: nextPath) as? ListContextMenuCellNode)
        try await wait { nextCell.accessibilityTraits.contains(.adjustable) }
        let stop = try #require(nextCell.accessibilityActionsProvider?().first {
            $0.name == String(localized: "Stop playback", table: "RoomProfile")
        })
        #expect(stop.actionHandler?(stop) == true)
        try await wait { layout.playingPath == nil }
        #expect(player.state == .idle && list.contentOffset == beforeMenu)
        #expect(topButton.frame.minY == normalButtonY)
        player.playLocal(url: audioURL, sourceKey: next.sourceMxc,
            nowPlaying: .voice(.init(sourceURL: next.sourceMxc, title: "Alice", subtitle: "Room",
                duration: 60, waveform: [], roomId: model.roomId, eventId: next.id)))
        player.pause()
        try await wait { layout.playingPath == nextPath }
        // A retained player can move beyond UIKit's old/new index boundary
        // when filtering removes most of the catalog around it.
        source.voice = [next]
        source.publish()
        try await wait { itemCount(list) == 3 && !page.isAdjusting && layout.playingPath == IndexPath(item: 1, section: 0) }
        #expect(player.state.sourceURL == next.sourceMxc)
        source.voice.removeAll()
        source.publish()
        try await wait { itemCount(list) == 1 && !page.isAdjusting && layout.playingPath == nil }
    }

    @Test("Voice uses shared discovery, preserves its anchor across inserts and opens the source message")
    func voicePage() async throws {
        let source = ProfileFixtureSource()
        source.voice = (1000..<1060).map { ProfileFixtureSource.item($0, kind: .voice) }
        let model = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        let controller = RoomProfileViewController(room: nil, title: "Room", subtitle: "", model: model,
            actions: .none, audioPlayer: AudioPlayerService(), initialSection: .voice)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let list = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.voice"))
        let page = try #require(list.collectionNode?.delegate as? RoomProfileListPage)
        try await wait { itemCount(list) == 62 && !page.isAdjusting }
        #expect(model.tab == .voice && source.starts.wrappedValue == 1)
        #expect(page.voicePlayback?.isActive == true)
        page.scrollView.contentOffset.y = 950
        let anchor = try #require(page.captureAnchor())
        let offset = page.scrollView.contentOffset.y
        controller.selectSection(.files, animated: false)
        #expect(page.voicePlayback?.isActive == false)
        controller.selectSection(.voice, animated: false)
        #expect(page.voicePlayback?.isActive == true)
        #expect(abs(page.scrollView.contentOffset.y - offset) < 1)
        source.voice.insert(ProfileFixtureSource.item(1100, kind: .voice), at: 0)
        source.publish()
        try await wait { itemCount(list) == 63 && !page.isAdjusting }
        let restored = try #require(page.captureAnchor())
        #expect(restored.id == anchor.id && abs(restored.offset - anchor.offset) < 1)
        #expect(source.starts.wrappedValue == 1)
        var openedID: String?
        controller.onShowInChat = { id, kind in
            #expect(kind.accepts("voice"))
            openedID = id
            return PreparedPollNavigation { true }
        }
        let path = IndexPath(item: restored.previousIndex, section: 0)
        try await wait { page.node.nodeForItem(at: path) != nil }
        let cell = try #require(page.node.nodeForItem(at: path) as? ListContextMenuCellNode)
        let action = try #require(cell.accessibilityActionsProvider?().first)
        #expect(action.actionHandler?(action) == true)
        try await wait { openedID != nil }
        #expect(openedID == restored.id)
        // Removing a voice is a catalog change, independent of playback.
        source.voice.removeAll()
        source.publish()
        try await wait { itemCount(list) == 1 && !page.isAdjusting }
        #expect(model.tab == .voice)
    }

    @Test("An emptied Pinned tab stays after a tap or completed swipe, but not a cancelled swipe",
          arguments: ["tap", "swipe", "cancelled swipe"])
    func retainsVisitedPins(route: String) async throws {
        let db = try await Task.detached {
            let queue = try DatabaseQueue()
            try DatabaseService.migrator.migrate(queue)
            return AccountDatabase(queue)
        }.value
        let source = PinnedTestSource()
        let pins = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        let controller = RoomProfileViewController(room: nil, title: "Pins", subtitle: "", model: nil,
            actions: .none, pinnedModel: pins)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { pins.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let tabs = try #require(find(RoomProfileTabsView.self, in: controller.view, id: "profile.sections"))
        let pager = try #require(find(RoomProfilePagerScrollView.self, in: controller.view, id: "profile.pager"))
        try await wait { !pins.isLoading && tabs.numberOfTabs == 4 }
        controller.selectSection(.voice, animated: false)
        let visited = route != "cancelled swipe"
        if route == "tap" {
            controller.selectSection(.pinned, animated: false)
        } else {
            controller.scrollViewWillBeginDragging(pager)
            pager.contentOffset.x = pager.bounds.width * 2.75
            pager.contentOffset.x = pager.bounds.width * (visited ? 3 : 2)
            controller.scrollViewDidEndDragging(pager, willDecelerate: false)
        }
        #expect(tabs.selectedIndex == (visited ? 3 : 2))
        source.send(.init(eventIDs: [], canUnpin: true))
        try await wait { pins.items.isEmpty }
        controller.selectSection(.files, animated: false)
        try await wait { tabs.numberOfTabs == (visited ? 4 : 3) }
        #expect(tabs.selectedIndex == 1)
    }

    @Test("Known pins reserve their tab before loading, while a stale hint is removed", arguments: [false, true])
    func initialPinnedHint(hasPins: Bool) async throws {
        let db = try await Task.detached {
            let queue = try DatabaseQueue()
            try DatabaseService.migrator.migrate(queue)
            return AccountDatabase(queue)
        }.value
        let source = PinnedTestSource(), gate = ProfileTestRequest<RoomPinnedSnapshot>()
        source.state.modify { $0.read = gate }
        let pins = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        let controller = RoomProfileViewController(room: nil, title: "Pins", subtitle: "", model: nil,
            actions: .none, pinnedModel: pins, initiallyHasPinnedMessages: true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { pins.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let tabs = try #require(find(RoomProfileTabsView.self, in: controller.view, id: "profile.sections"))
        #expect(tabs.numberOfTabs == 4 && tabs.selectedIndex == 0)
        try await wait { await gate.isPending }
        #expect(tabs.numberOfTabs == 4)
        await gate.finish(.init(eventIDs: hasPins ? ["$event-0"] : [], canUnpin: true))
        await pins.waitForOperationsForTesting()
        try await wait { !pins.isLoading && tabs.numberOfTabs == (hasPins ? 4 : 3) }
        #expect(find(ASCollectionView.self, in: controller.view, id: "profile.pinned") == nil)
    }

    @Test("Unknown empty pins do not flash a tab; paging creates only nearby pages")
    func lazyPinnedPage() async throws {
        let db = try await Task.detached {
            let queue = try DatabaseQueue()
            try DatabaseService.migrator.migrate(queue)
            return AccountDatabase(queue)
        }.value
        let source = PinnedTestSource(), gate = ProfileTestRequest<RoomPinnedSnapshot>()
        source.state.modify { $0.read = gate }
        let pins = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        let controller = RoomProfileViewController(room: nil, title: "Pins", subtitle: "", model: nil,
            actions: .none, pinnedModel: pins)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { pins.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let tabs = try #require(find(RoomProfileTabsView.self, in: controller.view, id: "profile.sections"))
        let pager = try #require(find(RoomProfilePagerScrollView.self, in: controller.view, id: "profile.pager"))
        #expect(tabs.numberOfTabs == 3)
        try await wait { await gate.isPending }
        await gate.finish(.init(eventIDs: [], canUnpin: true))
        await pins.waitForOperationsForTesting()
        #expect(!pins.isLoading && tabs.numberOfTabs == 3)
        source.send(.init(eventIDs: ["$event-0"], canUnpin: true))
        try await wait { tabs.numberOfTabs == 4 }
        #expect(find(ASCollectionView.self, in: controller.view, id: "profile.pinned") == nil)
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width * 0.5
        #expect(find(ASCollectionView.self, in: controller.view, id: "profile.files") != nil)
        #expect(find(ASCollectionView.self, in: controller.view, id: "profile.pinned") == nil)
        pager.contentOffset.x = 0
        controller.scrollViewDidEndDragging(pager, willDecelerate: false)
        // A nonadjacent tab tap must still build its destination and the
        // intermediate page before either becomes visible.
        controller.selectSection(.pinned, animated: true)
        try await wait { tabs.selectedIndex == 3 && pager.contentOffset.x == pager.bounds.width * 3 }
        let list = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.pinned"))
        #expect(!list.accessibilityElementsHidden && list.bounds.width == pager.bounds.width)
    }

    @Test("An unpin failure stays on its message when a sheet covers the profile")
    func coveredUnpinFailure() async throws {
        let db = try await Task.detached {
            let queue = try DatabaseQueue()
            try DatabaseService.migrator.migrate(queue)
            try queue.write { try TimelineWriteFixture.message(0).insert($0) }
            return AccountDatabase(queue)
        }.value
        let source = PinnedTestSource()
        source.state.modify { $0.snapshot = .init(eventIDs: ["$event-0"], canUnpin: true); $0.failWrite = true }
        let pins = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: source, isCurrentSession: { true })
        let controller = RoomProfileViewController(room: nil, title: "Pins", subtitle: "", model: nil,
            actions: .none, pinnedModel: pins, initialSection: .pinned)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { pins.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let list = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.pinned"))
        let page = try #require(list.collectionNode?.delegate as? RoomProfileListPage)
        try await wait { pins.items.count == 1 && itemCount(list) == 1 && !page.isAdjusting }
        let sheet = UIViewController()
        sheet.modalPresentationStyle = .pageSheet
        await withCheckedContinuation { continuation in
            controller.present(sheet, animated: false) { continuation.resume() }
        }
        pins.unpin("$event-0")
        await pins.waitForOperationsForTesting()
        let failure = try #require(pins.items.first?.unpinError)
        let label = [try #require(pins.items.first?.title), failure].joined(separator: ", ")
        try await wait {
            page.node.nodeForItem(at: IndexPath(item: 0, section: 0))?.accessibilityLabel == label
        }
        #expect(controller.presentedViewController === sheet)
        #expect(sheet.presentedViewController == nil && pins.items.first?.unpinError != nil)
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: false) { continuation.resume() }
        }
        #expect(controller.presentedViewController == nil)
        source.state.modify { $0.failWrite = false }
        pins.unpin("$event-0")
        await pins.waitForOperationsForTesting()
        try await wait { pins.items.isEmpty && pins.actionError == nil }
    }

    @Test("Pinned entry opens the third page, preserves depth and keeps its empty result visible")
    func pinnedPage() async throws {
        let db = try await Task.detached {
            let queue = try DatabaseQueue()
            try DatabaseService.migrator.migrate(queue)
            try queue.write { db in
                for index in 0..<30 { try TimelineWriteFixture.message(index).insert(db) }
            }
            return AccountDatabase(queue)
        }.value
        let pinnedSource = PinnedTestSource()
        pinnedSource.state.modify { $0.snapshot = .init(eventIDs: (0..<30).map { "$event-\($0)" }, canUnpin: true) }
        let pins = RoomPinnedMessagesModel(roomID: TimelineWriteFixture.roomID, database: db,
            source: pinnedSource, isCurrentSession: { true })
        let source = ProfileFixtureSource()
        let attachments = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        let controller = RoomProfileViewController(room: nil, title: "Pins", subtitle: "", model: attachments,
            actions: .none, pinnedModel: pins, initialSection: .pinned)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { pins.stop(); attachments.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let tabs = try #require(find(RoomProfileTabsView.self, in: controller.view, id: "profile.sections"))
        let pager = try #require(find(RoomProfilePagerScrollView.self, in: controller.view, id: "profile.pager"))
        let list = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.pinned"))
        let page = try #require(list.collectionNode?.delegate as? RoomProfileListPage)
        try await wait { itemCount(list) == 30 && !page.isAdjusting }
        #expect(source.starts.wrappedValue == 0)
        #expect(tabs.numberOfTabs == 4 && tabs.selectedIndex == 3)
        #expect(pager.contentOffset.x == pager.bounds.width * 3)
        var openedID: String?
        controller.onShowInChat = { id, kind in
            #expect(kind.accepts("text"))
            openedID = id
            return PreparedPollNavigation { true }
        }
        try await wait { page.node.nodeForItem(at: IndexPath(item: 0, section: 0)) != nil }
        let cell = try #require(page.node.nodeForItem(at: IndexPath(item: 0, section: 0)) as? ListContextMenuCellNode)
        cell.onQuickTap?()
        try await wait { openedID != nil }
        #expect(openedID == "$event-0")
        page.scrollView.contentOffset.y = 950
        let offset = page.scrollView.contentOffset.y
        controller.selectSection(.files, animated: false)
        try await wait { source.starts.wrappedValue == 1 }
        controller.selectSection(.pinned, animated: false)
        #expect(abs(page.scrollView.contentOffset.y - offset) < 1)
        #expect(!list.accessibilityElementsHidden)
        pinnedSource.send(.init(eventIDs: [], canUnpin: true))
        try await wait { itemCount(list) == 1 && !page.isAdjusting }
        #expect(tabs.selectedIndex == 3 && tabs.numberOfTabs == 4)
        controller.view.layoutIfNeeded()
        #expect(abs(page.scrollView.contentOffset.y + 48) < 1)
        controller.selectSection(.media, animated: false)
        #expect(pager.canStartBackFromAnywhere?() == true)
    }

    private func find<T: UIView>(_ type: T.Type, in root: UIView, id: String) -> T? {
        if root.accessibilityIdentifier == id { return root as? T }
        return root.subviews.lazy.compactMap { find(type, in: $0, id: id) }.first
    }

    private func itemCount(_ view: UICollectionView) -> Int {
        view.numberOfSections > 0 ? view.numberOfItems(inSection: 0) : 0
    }

    private func wait(sourceLocation: SourceLocation = #_sourceLocation,
                      diagnostics: () -> String = { "Condition did not become true" },
                      _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(await condition(), "\(diagnostics())", sourceLocation: sourceLocation)
    }

    @Test("Avatar follows dragging, snaps on release and collapses continuously toward a deep page")
    func avatarExpansion() async throws {
        let input = ProfileDragInput()
        let source = ProfileFixtureSource()
        let attachments = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        var snapshot = ProfileTestSource.snapshot()
        snapshot.avatarURL = "mxc://profile.invalid/avatar"
        let profileSource = ProfileTestSource(snapshot)
        let profile = RoomProfileViewModel(snapshot: snapshot, source: profileSource,
            notifications: RoomNotificationSettingsService(settings: ProfileTestNotificationSettings()),
            isCurrentSession: { true })
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            UIColor.systemMint.setFill(); context.fill(CGRect(x: 48, y: 0, width: 32, height: 128))
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 48, width: 128, height: 32))
        }
        let controller = RoomProfileViewController(room: nil, title: snapshot.title, subtitle: "",
            model: attachments, actions: .none, profileModel: profile, avatarLoader: { _, _ in photo },
            avatarDragTranslation: { scrollView, _ in input.translation(scrollView) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { profile.stop(); attachments.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let avatar = try #require(find(RoomProfileAvatarView.self, in: controller.view, id: "profile.avatar"))
        let grid = try #require(controller.mediaGrid)
        let media = grid.scrollView
        let pager = try #require(find(RoomProfilePagerScrollView.self, in: controller.view, id: "profile.pager"))
        let tabs = try #require(find(RoomProfileTabsView.self, in: controller.view, id: "profile.sections"))
        let expansion = RoomProfileAvatarGeometry.expansionHeight(width: controller.view.bounds.width)
        try await wait { controller.view.layoutIfNeeded(); return avatar.isAccessibilityElement && grid.geometry?.count == 120 }
        #expect(avatar.bounds.width == 88)
        #expect(avatar.layer.cornerRadius == 44)
        #expect(abs(media.contentOffset.y + media.contentInset.top - expansion) < 1)
        #expect(avatar.hitTest(CGPoint(x: avatar.bounds.midX, y: avatar.bounds.midY), with: nil) == nil)

        func release(decelerate: Bool = false, velocity: CGFloat = 0) {
            var target = media.contentOffset
            grid.scrollViewWillEndDragging(media, withVelocity: CGPoint(x: 0, y: velocity), targetContentOffset: &target)
            #expect(target == media.contentOffset)
            grid.scrollViewDidEndDragging(media, willDecelerate: decelerate)
        }
        let circularOffset = media.contentOffset.y
        let circularTabsY = tabs.superview!.frame.minY
        let subscriptions = DisplayLinkDriver.shared.activeSubscriptionsCount
        // A short pull returns to the circle; insets stay fixed while dragging.
        grid.scrollViewWillBeginDragging(media)
        let inset = media.contentInset.top
        input.drag(media, down: 50)
        #expect(avatar.bounds.width > 88 && avatar.bounds.width < controller.view.bounds.width)
        #expect(abs(tabs.superview!.frame.minY - circularTabsY - 75) < 1)
        #expect(media.contentInset.top == inset)
        input.drag(media, down: -25)
        #expect(abs(tabs.superview!.frame.minY - circularTabsY - 37.5) < 1)
        input.drag(media, down: -25)
        #expect(abs(media.contentOffset.y - circularOffset) < 1)
        input.drag(media, down: 50)
        release()
        try await wait { avatar.bounds.width == 88 && DisplayLinkDriver.shared.activeSubscriptionsCount <= subscriptions }
        #expect(abs(media.contentOffset.y - circularOffset) < 1)

        // Speed alone must not turn a tiny accidental movement into a snap.
        grid.scrollViewWillBeginDragging(media)
        input.drag(media, down: 6)
        release(decelerate: true, velocity: -1.5)
        try await wait { avatar.bounds.width == 88 && DisplayLinkDriver.shared.activeSubscriptionsCount <= subscriptions }
        grid.scrollViewWillBeginDragging(media)
        input.drag(media, down: 20)
        release(decelerate: true, velocity: -0.7)
        try await wait { avatar.bounds.width == controller.view.bounds.width && DisplayLinkDriver.shared.activeSubscriptionsCount <= subscriptions }
        grid.scrollViewWillBeginDragging(media)
        input.drag(media, down: -20)
        release(decelerate: true, velocity: 0.7)
        try await wait { avatar.bounds.width == 88 && DisplayLinkDriver.shared.activeSubscriptionsCount <= subscriptions }

        grid.scrollViewWillBeginDragging(media)
        input.drag(media, down: 80)
        #expect(abs(tabs.superview!.frame.minY - circularTabsY - 120) < 1)
        release(decelerate: true)
        try await wait { avatar.bounds.width == controller.view.bounds.width && DisplayLinkDriver.shared.activeSubscriptionsCount <= subscriptions }
        #expect(avatar.frame.minY == pager.frame.minY)
        #expect(avatar.layer.cornerRadius == 0)
        #expect(abs(media.contentOffset.y + media.contentInset.top) < 1)

        // A metadata update for the same image must not briefly remove its
        // expansion geometry or reset the open square.
        snapshot.title = "Renamed group"
        profileSource.send(snapshot)
        try await wait { profile.snapshot.title == snapshot.title }
        controller.view.layoutIfNeeded()
        #expect(avatar.bounds.width == controller.view.bounds.width)
        #expect(avatar.accessibilityActivate())
        try await wait { avatar.bounds.width == 88 }

        media.contentOffset.y = 1152
        let deepOffset = media.contentOffset.y
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        let files = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.files"))
        try await wait { itemCount(files) == 3 }
        // The Texture file page must forward the same release velocity.
        files.contentOffset.y = expansion - files.contentInset.top
        files.delegate?.scrollViewWillBeginDragging?(files)
        input.drag(files, down: 20)
        var fileTarget = files.contentOffset
        files.delegate?.scrollViewWillEndDragging?(files, withVelocity: CGPoint(x: 0, y: -0.7), targetContentOffset: &fileTarget)
        files.delegate?.scrollViewDidEndDragging?(files, willDecelerate: true)
        try await wait { avatar.bounds.width == controller.view.bounds.width && DisplayLinkDriver.shared.activeSubscriptionsCount <= subscriptions }
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width * 0.8
        let intermediateSize = avatar.bounds.width
        #expect(intermediateSize > 88 && intermediateSize < controller.view.bounds.width)
        pager.contentOffset.x = pager.bounds.width * 0.9
        #expect(avatar.bounds.width > intermediateSize)
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        #expect(avatar.bounds.width == controller.view.bounds.width)
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = 0
        controller.scrollViewDidEndDecelerating(pager)
        #expect(avatar.bounds.width == 88)
        #expect(abs(media.contentOffset.y - deepOffset) < 1)
        #expect(abs(tabs.superview!.frame.minY - pager.frame.minY) < 1)
    }

    @Test("Scroll to top opens the regular header and preserves the other page", arguments: [false, true])
    func scrollToTopWithAvatar(filesSelected: Bool) async throws {
        let source = ProfileFixtureSource()
        source.files = (500..<560).map { ProfileFixtureSource.item($0, kind: .file) }
        let model = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        var snapshot = ProfileTestSource.snapshot()
        snapshot.avatarURL = "mxc://profile.invalid/avatar"
        let profile = RoomProfileViewModel(snapshot: snapshot, source: ProfileTestSource(snapshot),
            notifications: nil, isCurrentSession: { true })
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image {
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let controller = RoomProfileViewController(room: nil, title: snapshot.title, subtitle: "",
            model: model, actions: .none, profileModel: profile, avatarLoader: { _, _ in photo })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { profile.stop(); model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let avatar = try #require(find(RoomProfileAvatarView.self, in: controller.view, id: "profile.avatar"))
        let grid = try #require(controller.mediaGrid)
        let media = grid.scrollView
        let pager = try #require(find(RoomProfilePagerScrollView.self, in: controller.view, id: "profile.pager"))
        let tabs = try #require(find(RoomProfileTabsView.self, in: controller.view, id: "profile.sections"))
        let top = try #require(find(UIButton.self, in: controller.view, id: "profile.scrollToTop"))
        try await wait { controller.view.layoutIfNeeded(); return avatar.isAccessibilityElement && grid.geometry?.count == 120 }
        let circularTabsY = tabs.superview!.frame.minY
        let expansion = grid.avatarExpansionHeight

        // Give both pages a saved position before resetting just one of them.
        media.contentOffset.y = 900
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        let files = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.files"))
        try await wait { itemCount(files) == source.files.count + 2 && files.contentSize.height > 1500 }
        files.contentOffset.y = 700
        if !filesSelected {
            controller.scrollViewWillBeginDragging(pager)
            pager.contentOffset.x = 0
            controller.scrollViewDidEndDecelerating(pager)
        }
        let selected = filesSelected ? files : media
        let other = filesSelected ? media : files
        let otherDepth = other.contentOffset.y + other.contentInset.top - grid.headerHeight
        let start = selected.contentOffset.y
        #expect(!top.isHidden)
        top.sendActions(for: .touchUpInside)
        #expect(selected.contentOffset.y > expansion - selected.contentInset.top + 1)
        try await wait { selected.contentOffset.y < start - 1 }
        try await wait { abs(selected.contentOffset.y + selected.contentInset.top - expansion) < 0.1 }
        #expect(abs(tabs.superview!.frame.minY - circularTabsY) < 1)
        #expect(avatar.bounds.width == 88 && avatar.layer.cornerRadius == 44)
        #expect(abs(other.contentOffset.y + other.contentInset.top - expansion - otherDepth) < 1)
    }

    @Test("Avatar animation and interrupted drag settle when leaving; initials never expand")
    func avatarInterruption() async throws {
        let input = ProfileDragInput()
        let source = ProfileFixtureSource()
        let attachments = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        var snapshot = ProfileTestSource.snapshot()
        let profileSource = ProfileTestSource(snapshot)
        let profile = RoomProfileViewModel(snapshot: snapshot, source: profileSource,
            notifications: RoomNotificationSettingsService(settings: ProfileTestNotificationSettings()),
            isCurrentSession: { true })
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let controller = RoomProfileViewController(room: nil, title: snapshot.title, subtitle: "",
            model: attachments, actions: .none, profileModel: profile, avatarLoader: { _, _ in photo },
            avatarDragTranslation: { scrollView, _ in input.translation(scrollView) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 690))
        window.rootViewController = controller; window.isHidden = false
        defer { profile.stop(); attachments.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let avatar = try #require(find(RoomProfileAvatarView.self, in: controller.view, id: "profile.avatar"))
        let grid = try #require(controller.mediaGrid)
        let media = grid.scrollView
        try await wait { profileSource.isObserving && grid.geometry?.count == 120 }
        #expect(!avatar.accessibilityActivate())
        grid.scrollViewWillBeginDragging(media)
        media.contentOffset.y = -media.contentInset.top - 120
        #expect(avatar.bounds.width == 88)
        grid.scrollViewDidEndDragging(media, willDecelerate: false)
        media.contentOffset.y = 600
        let anchor = try #require(grid.captureAnchor())
        snapshot.avatarURL = "mxc://profile.invalid/avatar"
        profileSource.send(snapshot)
        try await wait { controller.view.layoutIfNeeded(); return avatar.image === photo }
        controller.view.layoutIfNeeded()
        let loadedAnchor = try #require(grid.captureAnchor())
        #expect(anchor.id == loadedAnchor.id && abs(anchor.offset - loadedAnchor.offset) < 1)

        let extra = RoomProfileAvatarGeometry.expansionHeight(width: controller.view.bounds.width)
        media.contentOffset.y = extra - media.contentInset.top
        let subscriptions = DisplayLinkDriver.shared.activeSubscriptionsCount
        // Cancellation can deliver didEndDragging without willEndDragging.
        grid.scrollViewWillBeginDragging(media)
        input.drag(media, down: 80)
        grid.scrollViewDidEndDragging(media, willDecelerate: false)
        try await wait { avatar.bounds.width == 88 }
        #expect(abs(media.contentOffset.y + media.contentInset.top - extra) < 1)
        grid.scrollViewWillBeginDragging(media)
        input.drag(media, down: 80)
        #expect(avatar.bounds.width > 88)
        controller.viewWillDisappear(false)
        #expect(avatar.bounds.width == 88)
        #expect(abs(media.contentOffset.y + media.contentInset.top - extra) < 1)
        controller.viewWillAppear(false)
        #expect(avatar.accessibilityActivate())
        controller.viewWillDisappear(false)
        #expect(avatar.bounds.width == controller.view.bounds.width)
        #expect(DisplayLinkDriver.shared.activeSubscriptionsCount <= subscriptions)
        #expect(abs(media.contentOffset.y + media.contentInset.top) < 1)

        controller.viewWillAppear(false)
        #expect(avatar.accessibilityActivate())
        try await wait { avatar.bounds.width == 88 }
        grid.scrollViewWillBeginDragging(media)
        input.drag(media, down: 80)
        var target = media.contentOffset
        grid.scrollViewWillEndDragging(media, withVelocity: .zero, targetContentOffset: &target)
        grid.scrollViewDidEndDragging(media, willDecelerate: false)
        // Leave before the deferred snap has obtained its first frame.
        controller.viewWillDisappear(false)
        #expect(avatar.bounds.width == controller.view.bounds.width)
        #expect(abs(media.contentOffset.y + media.contentInset.top) < 1)
        #expect(DisplayLinkDriver.shared.activeSubscriptionsCount <= subscriptions)
    }

    @Test("Video opens with the displayed grid image even when the legacy cache has no matching size")
    func videoPreview() async throws {
        let source = ProfileFixtureSource()
        source.media = [ProfileFixtureSource.item(1, kind: .video)]
        let model = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 416)
        var preview: UIImage?
        var opened = false
        var actions = RoomAttachmentsActions.none
        actions.openVideo = { _, image, _, _ in preview = image; opened = true }
        let controller = RoomProfileViewController(room: nil, title: "Video", subtitle: "", model: model, actions: actions)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let grid = try #require(controller.mediaGrid)
        try await wait { grid.geometry?.count == 1 }
        let tile = try #require(grid.scrollView.layer.sublayers?.compactMap { $0 as? RoomMediaTileLayer }.first)
        try await wait { tile.image != nil }
        let displayed = try #require(tile.image)
        #expect(model.previewImage(for: source.media[0]) == nil)
        grid.activate(0)
        #expect(opened)
        #expect(preview === displayed)
    }

    @Test("Live header actions, menus and height changes preserve the media anchor")
    func liveHeader() async throws {
        let source = ProfileFixtureSource()
        let attachments = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        var snapshot = ProfileTestSource.snapshot()
        let profileSource = ProfileTestSource(snapshot)
        let sdk = ProfileTestNotificationSettings()
        let profile = RoomProfileViewModel(snapshot: snapshot, source: profileSource,
            notifications: RoomNotificationSettingsService(settings: sdk), isCurrentSession: { true })
        let controller = RoomProfileViewController(room: nil, title: snapshot.title, subtitle: "",
            model: attachments, actions: .none, profileModel: profile)
        var tapped: [RoomProfileAction] = []
        controller.onAction = { tapped.append($0) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 690))
        window.rootViewController = controller
        window.isHidden = false
        defer { profile.stop(); attachments.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        try await wait { profile.canChangeNotifications && controller.mediaGrid?.geometry?.count == 120 }
        controller.view.layoutIfNeeded()
        let invite = try #require(find(UIButton.self, in: controller.view, id: "profile.action.invite"))
        let search = try #require(find(UIButton.self, in: controller.view, id: "profile.action.search"))
        let notifications = try #require(find(UIButton.self, in: controller.view, id: "profile.action.notifications"))
        let more = try #require(find(UIButton.self, in: controller.view, id: "profile.action.more"))
        for button in [invite, search, notifications, more] {
            let rect = button.convert(button.bounds, to: controller.view)
            #expect(rect.width > 50 && rect.height >= 44)
            #expect(rect.minX >= 0 && rect.maxX <= controller.view.bounds.width)
        }
        invite.sendActions(for: .touchUpInside)
        search.sendActions(for: .touchUpInside)
        #expect(tapped == [.invite, .search])
        #expect(notifications.showsMenuAsPrimaryAction && more.showsMenuAsPrimaryAction)
        #expect(notifications.menu?.children.compactMap { $0 as? UIAction }.filter { $0.state == .on }.count == 1)
        let header = try #require(controller.node.subnodes?.flatMap { [$0] + ($0.subnodes ?? []) }
            .compactMap { $0 as? RoomProfileHeaderNode }.first)
        #expect(header.hitTest(CGPoint(x: header.bounds.midX, y: 30), with: nil) == nil)

        let grid = try #require(controller.mediaGrid)
        let gestureHost = try #require(grid.scrollView.panGestureRecognizer.view)
        #expect(gestureHost !== grid.scrollView)
        for button in [invite, search, notifications, more] {
            #expect(button.isDescendant(of: gestureHost))
            #expect(grid.scrollView.touchesShouldCancel(in: button))
        }
        #expect(grid.scrollView.isDescendant(of: gestureHost))
        grid.scrollView.contentOffset.y = 1200
        let before = try #require(grid.captureAnchor())
        snapshot.title = "Updated group"
        snapshot.topic = String(repeating: "A long topic about the group and its shared media. ", count: 12)
        snapshot.permissions = .init(invite: false, editName: false, editAvatar: false)
        profileSource.send(snapshot)
        try await wait { profile.snapshot == snapshot }
        controller.view.layoutIfNeeded()
        let after = try #require(grid.captureAnchor())
        #expect(after.id == before.id)
        #expect(abs(after.offset - before.offset) < 1)
        #expect(!invite.isEnabled)
        #expect(more.menu?.children.compactMap { $0 as? UIAction }.contains { $0.title == RoomProfileAction.edit.title } == false)

        // Return to the header: members remain a direct action, not a page.
        grid.scrollView.contentOffset.y = -grid.scrollView.contentInset.top
        controller.view.layoutIfNeeded()
        let members = try #require(find(UIView.self, in: controller.view, id: "profile.members"))
        #expect(members.accessibilityTraits.contains(.button))

        // Menu deduplication must use the incoming @Published snapshot when
        // membership changes, rather than the model's previous stored value.
        snapshot.isJoined = false
        profileSource.send(snapshot)
        try await wait { profile.snapshot == snapshot }
        let choices = try #require(notifications.menu).children.compactMap { $0 as? UIAction }
        #expect(!choices.isEmpty && choices.allSatisfy { $0.attributes.contains(.disabled) })
        #expect(!notifications.isEnabled)
    }

    @Test("The native vertical pan follows the selected page and cancels with paging")
    func sharedHeaderPan() async throws {
        let source = ProfileFixtureSource()
        let model = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        let controller = RoomProfileViewController(room: nil, title: "Group", subtitle: "", model: model, actions: .none)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let media = try #require(controller.mediaGrid?.scrollView)
        let host = try #require(media.panGestureRecognizer.view)
        let button = UIButton(type: .custom)
        button.menu = UIMenu(children: [UIAction(title: "Choice") { _ in }])
        button.showsMenuAsPrimaryAction = true
        #expect(media is RoomProfileMediaScrollView)
        #expect(media.touchesShouldCancel(in: button))
        #expect(!media.touchesShouldCancel(in: UISlider()))
        let pager = try #require(find(RoomProfilePagerScrollView.self, in: controller.view, id: "profile.pager"))
        #expect(media.panGestureRecognizer.isEnabled && host !== media)
        controller.scrollViewWillBeginDragging(pager)
        #expect(!media.panGestureRecognizer.isEnabled)
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        let files = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.files"))
        #expect(files is RoomProfileCollectionView)
        #expect(files.touchesShouldCancel(in: button))
        #expect(!files.touchesShouldCancel(in: UISlider()))
        #expect(media.panGestureRecognizer.view === media)
        #expect(files.panGestureRecognizer.view === host && files.panGestureRecognizer.isEnabled)
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width * 0.8
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        #expect(files.panGestureRecognizer.view === host && files.panGestureRecognizer.isEnabled)
        controller.viewWillDisappear(false)
        #expect(!files.panGestureRecognizer.isEnabled)
        controller.viewWillAppear(false)
        #expect(files.panGestureRecognizer.isEnabled)
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = 0
        controller.scrollViewDidEndDecelerating(pager)
        #expect(media.panGestureRecognizer.view === host && media.panGestureRecognizer.isEnabled)
        #expect(files.panGestureRecognizer.view === files)
    }

    @Test("A failed large avatar retries on expansion, never on repeated layout")
    func avatarRetry() async throws {
        let source = ProfileFixtureSource()
        let model = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        var snapshot = ProfileTestSource.snapshot()
        snapshot.avatarURL = "mxc://profile.invalid/avatar"
        let profile = RoomProfileViewModel(snapshot: snapshot, source: ProfileTestSource(snapshot),
            notifications: nil, isCurrentSession: { true })
        let preview = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        let full = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { $0.fill(CGRect(x: 0, y: 0, width: 16, height: 16)) }
        let attempts = Atomic(0)
        let controller = RoomProfileViewController(room: nil, title: "Group", subtitle: "", model: model,
            actions: .none, profileModel: profile, avatarLoader: { _, pixels in
                if pixels == 240 { return preview }
                let attempt = attempts.withValue { $0 += 1; return $0 }
                return attempt == 1 ? nil : full
            })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller; window.isHidden = false
        defer { profile.stop(); model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let avatar = try #require(find(RoomProfileAvatarView.self, in: controller.view, id: "profile.avatar"))
        try await wait { attempts.wrappedValue == 1 && avatar.isAccessibilityElement }
        for _ in 0..<20 { controller.view.setNeedsLayout(); controller.view.layoutIfNeeded() }
        #expect(attempts.wrappedValue == 1 && avatar.image === preview)
        #expect(avatar.accessibilityActivate())
        try await wait { avatar.image === full }
        #expect(attempts.wrappedValue == 2)
        for _ in 0..<20 { controller.view.setNeedsLayout(); controller.view.layoutIfNeeded() }
        #expect(attempts.wrappedValue == 2)
    }

    @Test("Muted room rows keep the state through profile updates and expose it to VoiceOver")
    func mutedRoomRow() {
        let summary = RoomSummary(id: "!room:example.org", displayName: "Muted group", avatarURL: nil,
            lastMessage: "A message", lastMessageSenderName: nil, lastMessageTimestamp: nil,
            lastOwnMessageStatus: nil, unreadCount: 3, unreadMentionCount: 0, isMarkedUnread: false,
            isEncrypted: true, isSpace: false, isMuted: true, directUserId: nil,
            spaceChildRoomCount: 0, spaceChildSpaceCount: 0, spaceRecentRooms: [], spaceMetadata: nil)
        let model = RoomModel(from: summary)
        #expect(model.isMuted)
        #expect(model.withSyntheticAvatarColor("#123456").isMuted)
        #expect(model.withSpaceProfile(name: "Renamed", avatarURL: nil).isMuted)
        #expect(model.withSpaceMetadata(nil).isMuted)
        let node = RoomsCellNode(chat: model)
        _ = node.view
        node.frame = CGRect(x: 0, y: 0, width: 320, height: 90)
        node.view.layoutIfNeeded()
        #expect(node.accessibilityLabel?.contains(String(localized: "Notifications muted")) == true)
        #expect(node.subnodes?.compactMap { $0 as? ASImageNode }.contains { $0.image?.renderingMode == .alwaysTemplate } == true)
    }

    @Test("Back owns right swipes across the first page, and only the leading edge elsewhere")
    func backSwipePriority() {
        let pager = RoomProfilePagerScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        pager.contentSize = CGSize(width: 1206, height: 874)
        var firstPageSettled = true
        pager.canStartBackFromAnywhere = { firstPageSettled }
        for x: CGFloat in [12, 180, 390] {
            let point = CGPoint(x: x, y: 500)
            #expect(pager.allowsInteractiveBack(at: point))
            #expect(pager.yieldsPanToInteractiveBack(from: point, velocity: CGPoint(x: 200, y: 30)))
            #expect(!pager.yieldsPanToInteractiveBack(from: point, velocity: CGPoint(x: -200, y: 30)))
            #expect(!pager.yieldsPanToInteractiveBack(from: point, velocity: CGPoint(x: 30, y: 200)))
            #expect(!pager.yieldsPanToInteractiveBack(from: point, velocity: CGPoint(x: 30, y: -200)))
        }

        firstPageSettled = false
        for offset: CGFloat in [0, 201, 402, 804] {
            pager.contentOffset.x = offset
            let edge = CGPoint(x: offset + 12, y: 500)
            let center = CGPoint(x: offset + 180, y: 500)
            #expect(pager.allowsInteractiveBack(at: edge))
            #expect(!pager.allowsInteractiveBack(at: center))
            #expect(pager.yieldsPanToInteractiveBack(from: edge, velocity: CGPoint(x: 200, y: 0)))
            #expect(!pager.yieldsPanToInteractiveBack(from: center, velocity: CGPoint(x: 200, y: 0)))
            #expect(!pager.yieldsPanToInteractiveBack(from: edge, velocity: CGPoint(x: -200, y: 0)))
        }

        // A zoom/menu interaction locks both competing horizontal gestures.
        firstPageSettled = true
        pager.isScrollEnabled = false
        #expect(!pager.allowsInteractiveBack(at: CGPoint(x: pager.bounds.minX + 12, y: 500)))
        #expect(!pager.allowsInteractiveBack(at: CGPoint(x: pager.bounds.midX, y: 500)))
    }

    @Test("Short and empty sections preserve media depth through cancellation, eviction and returning")
    func session() async throws {
        let source = ProfileFixtureSource()
        let model = RoomAttachmentsViewModel(roomId: "!profile:example.org", source: source,
            filterMode: .sdkOnlyMessage, tilePixelSize: 128)
        let controller = RoomProfileViewController(room: nil, title: "Design team",
            subtitle: "12 members", model: model, actions: .none)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        defer { model.stop(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let media = try #require(find(UIScrollView.self, in: controller.view, id: "profile.media"))
        let pager = try #require(find(RoomProfilePagerScrollView.self, in: controller.view, id: "profile.pager"))
        let tabs = try #require(find(RoomProfileTabsView.self, in: controller.view, id: "profile.sections"))
        func backFromCenter() -> Bool {
            pager.allowsInteractiveBack(at: CGPoint(x: pager.bounds.midX, y: pager.bounds.midY))
        }
        try await wait { controller.mediaGrid?.geometry?.count == 120 && media.contentSize.height > 2000 }
        media.contentOffset.y = 1200 - 48
        let deepOffset = media.contentOffset.y
        let height = media.contentInset.top - 48
        #expect(abs(tabs.superview!.frame.minY - pager.frame.minY) < 1)
        #expect(backFromCenter())

        controller.scrollViewWillBeginDragging(pager)
        #expect(!backFromCenter())
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        #expect(!backFromCenter())
        let files = try #require(find(ASCollectionView.self, in: controller.view, id: "profile.files"))
        try await wait { itemCount(files) == 3 }
        #expect(abs(files.contentOffset.y + 48) < 1)
        #expect(files.contentSize.height + files.contentInset.bottom >= files.bounds.height - 48)
        files.contentOffset.y = -files.contentInset.top
        #expect(abs(media.contentOffset.y - (deepOffset - height)) < 1)
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width * 0.5
        #expect(abs(tabs.position - 0.5) < 0.001)
        #expect(!backFromCenter())
        #expect(abs(tabs.superview!.frame.minY - pager.frame.minY - height * 0.5) < 1)
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        #expect(tabs.position == 1 && tabs.selectedIndex == 1)
        #expect(!backFromCenter())
        #expect(abs(files.contentOffset.y + files.contentInset.top) < 1)

        controller.didReceiveMemoryWarning()
        #expect(find(UIScrollView.self, in: controller.view, id: "profile.media") == nil)
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = 0
        #expect(!backFromCenter())
        controller.scrollViewDidEndDecelerating(pager)
        #expect(backFromCenter())
        let restored = try #require(find(UIScrollView.self, in: controller.view, id: "profile.media"))
        let grid = try #require(controller.mediaGrid)
        try await wait { grid.geometry?.count == 120 && restored.contentSize.height > 2000 }
        #expect(abs(restored.contentOffset.y - deepOffset) < 1)
        #expect(abs(tabs.superview!.frame.minY - pager.frame.minY) < 1)

        // Inserts before the viewport retain the same visible event and gap.
        let oldPath = try #require(grid.geometry?.index(at: CGPoint(x: 20, y: restored.contentOffset.y + 60)))
        let oldFrame = try #require(grid.frameForItem(at: oldPath))
        let gap = restored.contentOffset.y - oldFrame.minY
        source.media.insert(contentsOf: (200..<203).map { ProfileFixtureSource.item($0) }, at: 0)
        source.publish()
        try await wait { grid.geometry?.count == 123 }
        let shifted = try #require(grid.frameForItem(at: oldPath + 3))
        #expect(abs(restored.contentOffset.y - shifted.minY - gap) < 1)

        let top = try #require(find(UIButton.self, in: controller.view, id: "profile.scrollToTop"))
        let beforeTop = restored.contentOffset.y
        top.sendActions(for: .touchUpInside)
        #expect(restored.contentOffset.y > 0)
        try await wait { restored.contentOffset.y < beforeTop - 1 && restored.contentOffset.y > 0 }
        let interrupted = restored.contentOffset.y
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        try await Task.sleep(for: .milliseconds(400))
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = 0
        controller.scrollViewDidEndDecelerating(pager)
        #expect(abs(restored.contentOffset.y - interrupted) < 1)
        top.sendActions(for: .touchUpInside)
        try await wait { !grid.isScrollingToBeginning && abs(restored.contentOffset.y + restored.contentInset.top) < 1 }
        #expect(abs(tabs.superview!.frame.minY - pager.frame.minY - height) < 1)
        source.files = []
        source.publish()
        controller.scrollViewWillBeginDragging(pager)
        pager.contentOffset.x = pager.bounds.width
        controller.scrollViewDidEndDecelerating(pager)
        // Texture publishes the new item count before its batch completion
        // restores padding and offset. Wait for the completed presentation.
        try await wait(diagnostics: {
            "Empty files: count=\(itemCount(files)), offset=\(files.contentOffset), inset=\(files.contentInset), "
                + "size=\(files.contentSize), tabsY=\(tabs.superview!.frame.minY), pagerY=\(pager.frame.minY)"
        }) { itemCount(files) == 1 && abs(files.contentOffset.y + files.contentInset.top) < 1 }
        #expect(abs(files.contentOffset.y + files.contentInset.top) < 1)
        files.contentOffset.y = -files.contentInset.top
        #expect(abs(tabs.superview!.frame.minY - pager.frame.minY - height) < 1)
    }

    @Test("Parent layout and queued scroll corrections during file deletion cannot reopen the header", arguments: [false, true])
    func layoutDuringFileDeletion(queuedCorrection: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host; window.isHidden = false
        let page = RoomProfileListPage()
        defer { page.onScroll = nil; window.isHidden = true; window.rootViewController = nil }
        host.view.addSubview(page.view)
        page.install()
        page.isActive = true
        var state = RoomProfileScrollState()
        state.scroll(to: state.headerHeight)
        page.headerHeight = state.headerHeight
        page.collapse = state.collapse
        page.onScroll = {
            state.scroll(to: page.normalizedOffset)
            page.collapse = state.collapse
        }
        page.layout(frame: host.view.bounds, depth: 0, bottomInset: 0)
        let footer = RoomProfileRow(id: "footer", title: "No files", detail: nil,
                                    item: nil, isHeader: false, isAction: false)
        page.update(RoomProfileRow.rows(groups: [.init(id: "month", title: "September",
            items: [ProfileFixtureSource.item(1, kind: .file)])]) + [footer])
        try await wait { itemCount(page.node.view) == 3 && !page.isAdjusting }

        var nestedLayouts = 0
        let observation = page.scrollView.observe(\.contentSize, options: [.old, .new]) { _, change in
            MainActor.assumeIsolated {
                guard change.oldValue != change.newValue, page.isAdjusting else { return }
                nestedLayouts += 1
                page.layout(frame: host.view.bounds, depth: state.depth(for: state.selected), bottomInset: 0)
                #expect(page.isAdjusting)
                if queuedCorrection, let oldSize = change.oldValue, let newSize = change.newValue, oldSize.height > newSize.height {
                    // Reproduce UIKit's pending correction before its first
                    // frame, while the model offset is still at the anchor.
                    page.scrollView.setContentOffset(CGPoint(x: 0,
                        y: page.scrollView.contentOffset.y + newSize.height - oldSize.height), animated: true)
                }
            }
        }
        defer { observation.invalidate() }
        page.update([footer])
        try await wait { itemCount(page.node.view) == 1 && !page.isAdjusting }
        // Observe a full scroll animation interval: checking its first frame
        // alone would miss an uncancelled correction that has not moved yet.
        if queuedCorrection { try await Task.sleep(for: .milliseconds(400)) }
        #expect(nestedLayouts > 0)
        #expect(abs(page.scrollView.contentOffset.y + page.tabsHeight) < 1)
        #expect(state.collapse == state.headerHeight)
    }

    @Test("A file menu extracts only its attachment, restores it and keeps the stable event action")
    func itemContextMenu() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        let page = RoomProfileListPage()
        defer { page.dismissContextMenu(); window.isHidden = true; window.rootViewController = nil }
        host.view.addSubview(page.node.view)
        page.install()
        page.isActive = true
        page.collapse = page.headerHeight
        page.layout(frame: host.view.bounds, depth: 0, bottomInset: 0)
        let items = (1...3).map { ProfileFixtureSource.item($0, kind: .file) }
        let rows = RoomProfileRow.rows(groups: [.init(id: "month", title: "September", items: items)])
        page.update(rows)
        try await wait { itemCount(page.node.view) == 4 && !page.isAdjusting }
        page.node.view.layoutIfNeeded()
        let cell = try #require(page.node.nodeForItem(at: IndexPath(item: 1, section: 0)) as? ListContextMenuCellNode)
        let other = try #require(page.node.nodeForItem(at: IndexPath(item: 2, section: 0)) as? ListContextMenuCellNode)
        let source = cell.extractContentForMenu(in: window.coordinateSpace)
        var selectedEvent: String?
        page.onShowInChat = { selectedEvent = $0.id }
        cell.onContextMenuActivated?(.init(x: 20, y: 20))
        let overlay = try #require(source.node.view.window)
        #expect(overlay !== window)
        #expect(page.node.view.window === window)
        #expect(other.view.window === window)
        #expect(source.node.bounds.size == cell.bounds.size)
        #expect(source.node.bounds.height < page.node.bounds.height)
        #expect(!page.scrollView.isScrollEnabled)
        #expect(page.node.view.interactions.allSatisfy { !($0 is UIContextMenuInteraction) })

        // An incoming edit waits for restoration instead of replacing the
        // cell underneath the raised preview or changing the action's ID.
        page.update(Array(rows.dropLast()))
        try await Task.sleep(for: .milliseconds(400))
        #expect(itemCount(page.node.view) == 4)
        func action(in view: UIView) -> UIControl? {
            if let control = view as? UIControl,
               control.accessibilityLabel == String(localized: "Show in Chat", table: "RoomProfile") { return control }
            return view.subviews.lazy.compactMap { action(in: $0) }.first
        }
        let button = try #require(action(in: overlay))
        button.sendActions(for: .touchUpInside)
        try await wait { selectedEvent != nil && itemCount(page.node.view) == 3 }
        #expect(selectedEvent == items[0].id)
        #expect(source.node.view.window === window)
        #expect(page.scrollView.isScrollEnabled)
    }
}
