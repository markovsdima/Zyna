//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import UIKit

final class SpaceViewController: ASDKViewController<SpaceScreenNode> {

    var onBack: (() -> Void)?
    var onSettings: ((RoomModel) -> Void)?
    var onChatSelected: ((RoomModel) -> Void)?
    var onSpaceSelected: ((RoomModel) -> Void)?
    var onCreateContent: ((RoomModel, SpacePresentationKind) -> Void)?

    private var space: RoomModel
    private let presentation: SpacePresentationKind
    private let roomListService: ZynaRoomListService
    private let glassTopBar = GlassTopBar()
    private var chats: [RoomModel] = []
    private var lines: [RoomModel] = []
    private var spaceChildrenObservation: SpaceChildrenObservation?
    private var removeTasks: [String: Task<Void, Never>] = [:]
    private var removingChildIds = Set<String>()
    private var activeChildContextMenu: ListContextMenuController?
    private weak var childContextLockedScrollView: UIScrollView?
    private var childContextScrollWasEnabled = true

    init(
        space: RoomModel,
        presentation: SpacePresentationKind,
        roomListService: ZynaRoomListService
    ) {
        self.space = space
        self.presentation = presentation
        self.roomListService = roomListService
        super.init(node: SpaceScreenNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        spaceChildrenObservation?.cancel()
        activeChildContextMenu?.dismiss(animated: false)
        removeTasks.values.forEach { $0.cancel() }
        setChildContextInteractionLocked(false)
    }

    func reloadChildren() {
        restartChildrenObservation()
    }

    func updateSpace(_ updatedSpace: RoomModel) {
        guard updatedSpace.id == space.id else { return }
        space = updatedSpace
        rebuildGlassTopBarItems()
        node.tableNode.reloadData()
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTable()
        setupGlassTopBar()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glassTopBar.updateLayout(in: view)

        let topInset = glassTopBar.coveredHeight + 8
        if node.tableNode.contentInset.top != topInset {
            var contentInset = node.tableNode.contentInset
            contentInset.top = topInset
            node.tableNode.contentInset = contentInset
        }
        if node.tableNode.view.verticalScrollIndicatorInsets.top != topInset {
            var indicatorInsets = node.tableNode.view.verticalScrollIndicatorInsets
            indicatorInsets.top = topInset
            node.tableNode.view.verticalScrollIndicatorInsets = indicatorInsets
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GlassService.shared.captureFor(duration: 0.5)
        GlassService.shared.setNeedsCapture()
        startChildrenObservation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        spaceChildrenObservation?.cancel()
        spaceChildrenObservation = nil
        activeChildContextMenu?.dismiss(animated: false)
        setChildContextInteractionLocked(false)
    }

    private func setupTable() {
        node.tableNode.dataSource = self
        node.tableNode.delegate = self
        node.tableNode.view.separatorStyle = .none
        node.tableNode.view.backgroundColor = .systemBackground
        node.tableNode.view.contentInsetAdjustmentBehavior = .never
        node.tableNode.view.alwaysBounceVertical = true
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .systemBackground
        glassTopBar.sourceView = node.tableNode.view
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar
        rebuildGlassTopBarItems()
    }

    private func rebuildGlassTopBarItems() {
        let backIcon = AppIcon.chevronBackward.template(size: 17, weight: .semibold)
        let composeIcon = AppIcon.compose.template(size: 17, weight: .medium)
        glassTopBar.onTitleTapped = { [weak self] in
            guard let self else { return }
            self.onSettings?(self.space)
        }
        glassTopBar.items = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ),
            .title(
                text: space.name.isEmpty ? String(localized: "Untitled") : space.name,
                subtitle: presentation.title
            ),
            .circleButton(
                icon: composeIcon,
                accessibilityLabel: String(localized: "Add to \(presentation.title)"),
                action: { [weak self] in
                    guard let self else { return }
                    self.onCreateContent?(self.space, self.presentation)
                }
            )
        ]
    }

    private func startChildrenObservation(applyCache: Bool = true) {
        guard spaceChildrenObservation == nil else { return }

        let cachedSummaries = roomListService.cachedSpaceChildRooms(for: space.id)
        let cachedSpaceSummaries = roomListService.cachedSpaceChildSpaces(for: space.id)
        if applyCache, !cachedSummaries.isEmpty || !cachedSpaceSummaries.isEmpty {
            applyChildSummaries(
                rooms: cachedSummaries,
                spaces: cachedSpaceSummaries
            )
        }

        spaceChildrenObservation = roomListService.observeSpaceChildren(for: space.id) { [weak self] summaries in
            guard let self else { return }
            applyChildSummaries(
                rooms: summaries.rooms,
                spaces: summaries.spaces
            )
        }
    }

    private func restartChildrenObservation(applyCache: Bool = true) {
        spaceChildrenObservation?.cancel()
        spaceChildrenObservation = nil
        startChildrenObservation(applyCache: applyCache)
    }

    private func applyChildSummaries(rooms: [RoomSummary], spaces: [RoomSummary]) {
        activeChildContextMenu?.dismiss(animated: false)

        var chatModels = rooms.map { RoomModel(from: $0) }
        let statuses = PresenceTracker.shared.statuses
        if !statuses.isEmpty {
            chatModels = chatModels.map { room in
                guard let userId = room.directUserId,
                      let status = statuses[userId] else { return room }
                var updated = room
                updated.isOnline = status.online
                updated.lastSeen = status.lastSeen
                return updated
            }
        }

        let lineModels = spaces.map { RoomModel(from: $0) }
        guard chatModels != chats || lineModels != lines else { return }
        chats = chatModels
        lines = lineModels
        updateSpaceCounts()
        node.tableNode.reloadData()
        GlassService.shared.setNeedsCapture()
    }

    private func updateSpaceCounts(roomCount requestedRoomCount: Int? = nil, lineCount requestedLineCount: Int? = nil) {
        let roomCount = requestedRoomCount ?? max(space.spaceChildRoomCount, chats.count)
        let lineCount = requestedLineCount ?? max(space.spaceChildSpaceCount, lines.count)
        guard roomCount != space.spaceChildRoomCount || lineCount != space.spaceChildSpaceCount else { return }

        space = RoomModel(
            id: space.id,
            name: space.name,
            lastMessage: space.lastMessage,
            lastMessageSenderName: space.lastMessageSenderName,
            timestamp: space.timestamp,
            avatar: space.avatar,
            isOnline: space.isOnline,
            lastSeen: space.lastSeen,
            unreadCount: space.unreadCount,
            unreadMentionCount: space.unreadMentionCount,
            isMarkedUnread: space.isMarkedUnread,
            isEncrypted: space.isEncrypted,
            isSpace: space.isSpace,
            directUserId: space.directUserId,
            spaceChildRoomCount: roomCount,
            spaceChildSpaceCount: lineCount,
            spaceRecentRooms: space.spaceRecentRooms,
            spaceMetadata: space.spaceMetadata
        )
    }

    private func child(at indexPath: IndexPath) -> RoomModel? {
        if indexPath.row > 0, indexPath.row < chatStartRow, !lines.isEmpty {
            return lines[indexPath.row - 1]
        }

        guard indexPath.row >= chatStartRow, !chats.isEmpty else { return nil }
        let chatIndex = indexPath.row - chatStartRow
        guard chats.indices.contains(chatIndex) else { return nil }
        return chats[chatIndex]
    }

    private func removeChild(_ child: RoomModel) {
        guard !removingChildIds.contains(child.id) else { return }

        removingChildIds.insert(child.id)
        removeChildLocally(child)

        removeTasks[child.id]?.cancel()
        removeTasks[child.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await roomListService.removeChild(
                    child.id,
                    fromSpace: space.id,
                    context: child.isSpace ? "line" : "chat"
                )
                let summaries = await roomListService.refreshSpaceChildren(for: space.id)

                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.removingChildIds.remove(child.id)
                    self.removeTasks[child.id] = nil
                    self.applyChildSummaries(
                        rooms: summaries.rooms,
                        spaces: summaries.spaces
                    )
                    self.restartChildrenObservation(applyCache: false)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.removingChildIds.remove(child.id)
                    self.removeTasks[child.id] = nil
                    self.showRemoveError(error)
                    self.restartChildrenObservation()
                }
            }
        }
    }

    private func removeChildLocally(_ child: RoomModel) {
        let removedChat = chats.contains { $0.id == child.id }
        let removedLine = lines.contains { $0.id == child.id }
        guard removedChat || removedLine else { return }

        chats.removeAll { $0.id == child.id }
        lines.removeAll { $0.id == child.id }

        let roomCount = removedChat
            ? max(chats.count, space.spaceChildRoomCount - 1)
            : space.spaceChildRoomCount
        let lineCount = removedLine
            ? max(lines.count, space.spaceChildSpaceCount - 1)
            : space.spaceChildSpaceCount
        updateSpaceCounts(roomCount: roomCount, lineCount: lineCount)
        node.tableNode.reloadData()
        GlassService.shared.setNeedsCapture()
    }

    private func showRemoveError(_ error: Error) {
        let alert = UIAlertController(
            title: presentation.removeErrorTitle,
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func presentContextMenu(
        for child: RoomModel,
        sourceCell: ListContextMenuCellNode,
        activationPoint: CGPoint
    ) {
        activeChildContextMenu?.dismiss(animated: false)

        guard !removingChildIds.contains(child.id),
              let window = view.window,
              window.windowScene != nil else {
            sourceCell.cancelContextMenuActivation()
            return
        }

        let action = ContextMenuAction(
            title: presentation.removeActionTitle,
            image: UIImage(systemName: "minus.circle"),
            isDestructive: true
        ) { [weak self] in
            self?.removeChild(child)
        }
        let anchorPoint = sourceCell.view.convert(activationPoint, to: window)
        let source = sourceCell.extractContentForMenu(in: window.coordinateSpace)

        let menu = ListContextMenuController(
            contentNode: source.node,
            sourceFrame: source.frame,
            anchorPoint: anchorPoint,
            actions: [action]
        )
        menu.onDismissComplete = { [weak self, weak menu, weak sourceCell] in
            sourceCell?.restoreContentFromMenu()
            self?.setChildContextInteractionLocked(false)
            guard self?.activeChildContextMenu === menu else { return }
            self?.activeChildContextMenu = nil
        }
        activeChildContextMenu = menu
        menu.show(in: window)
    }

    private func openChild(_ child: RoomModel) {
        guard activeChildContextMenu == nil else { return }
        if child.isSpace {
            onSpaceSelected?(child)
        } else {
            onChatSelected?(child)
        }
    }

    private func makeContextMenuCell(
        for child: RoomModel,
        contentNode: ASDisplayNode
    ) -> ListContextMenuCellNode {
        let cell = ListContextMenuCellNode(contentNode: contentNode)
        cell.onQuickTap = { [weak self] in
            self?.openChild(child)
        }
        cell.onContextMenuActivated = { [weak self, weak cell] point in
            guard let cell else { return }
            self?.presentContextMenu(
                for: child,
                sourceCell: cell,
                activationPoint: point
            )
        }
        cell.onDragChanged = { [weak self] point in
            self?.activeChildContextMenu?.trackFinger(at: point)
        }
        cell.onDragEnded = { [weak self] point in
            self?.activeChildContextMenu?.releaseFinger(at: point)
        }
        cell.onInteractionLockChanged = { [weak self] locked in
            self?.setChildContextInteractionLocked(locked)
        }
        cell.setContextAccessibilityActions([
            UIAccessibilityCustomAction(name: presentation.removeActionTitle) { [weak self] _ in
                guard let self, !self.removingChildIds.contains(child.id) else { return false }
                self.removeChild(child)
                return true
            }
        ])
        return cell
    }

    private func setChildContextInteractionLocked(_ locked: Bool) {
        if locked {
            guard childContextLockedScrollView == nil else { return }
            let scrollView = node.tableNode.view
            childContextLockedScrollView = scrollView
            childContextScrollWasEnabled = scrollView.isScrollEnabled
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.panGestureRecognizer.isEnabled = true
            scrollView.isScrollEnabled = false
            return
        }

        guard let scrollView = childContextLockedScrollView else { return }
        scrollView.isScrollEnabled = childContextScrollWasEnabled
        childContextLockedScrollView = nil
        childContextScrollWasEnabled = true
    }
}

extension SpaceViewController: ASTableDataSource, ASTableDelegate {
    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        1 + lineRowCount + max(1, chats.count)
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        if indexPath.row == 0 {
            let space = self.space
            return { SpaceHeaderCellNode(space: space) }
        }

        if indexPath.row < chatStartRow {
            if lines.isEmpty {
                let presentation = self.presentation
                return { SpaceLinesPlaceholderCellNode(presentation: presentation) }
            }
            let line = lines[indexPath.row - 1]
            return { [weak self] in
                self?.makeContextMenuCell(
                    for: line,
                    contentNode: SpaceLineCellNode(line: line)
                ) ?? ListContextMenuCellNode(contentNode: SpaceLineCellNode(line: line))
            }
        }

        if chats.isEmpty {
            let message = space.spaceChildRoomCount > 0
                ? String(localized: "No accessible chats")
                : String(localized: "Add the first chat")
            return { SpaceEmptyChatsCellNode(message: message) }
        }

        let chat = chats[indexPath.row - chatStartRow]
        return { [weak self] in
            self?.makeContextMenuCell(
                for: chat,
                contentNode: RoomsCellNode(chat: chat)
            ) ?? ListContextMenuCellNode(contentNode: RoomsCellNode(chat: chat))
        }
    }

    private var lineRowCount: Int {
        max(1, lines.count)
    }

    private var chatStartRow: Int {
        1 + lineRowCount
    }

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        guard let child = child(at: indexPath) else { return }
        openChild(child)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === node.tableNode.view else { return }
        GlassService.shared.setNeedsCapture()
    }
}
