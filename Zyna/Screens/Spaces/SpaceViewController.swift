//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceViewController: ASDKViewController<SpaceScreenNode> {

    var onBack: (() -> Void)?
    var onSettings: (() -> Void)?
    var onChatSelected: ((RoomModel) -> Void)?
    var onSpaceSelected: ((RoomModel) -> Void)?
    var onCreateContent: ((RoomModel, SpacePresentationKind) -> Void)?

    private var space: RoomModel
    private let presentation: SpacePresentationKind
    private let roomListService: ZynaRoomListService
    private let glassTopBar = GlassTopBar()
    private var chats: [RoomModel] = []
    private var lines: [RoomModel] = []
    private var loadTask: Task<Void, Never>?

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
        loadTask?.cancel()
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
        loadChildren()
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

        let backIcon = AppIcon.chevronBackward.template(size: 17, weight: .semibold)
        let composeIcon = AppIcon.compose.template(size: 17, weight: .medium)
        glassTopBar.onTitleTapped = { [weak self] in
            self?.onSettings?()
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

    private func loadChildren() {
        let cachedSummaries = roomListService.cachedSpaceChildRooms(for: space.id)
        let cachedSpaceSummaries = roomListService.cachedSpaceChildSpaces(for: space.id)
        if !cachedSummaries.isEmpty || !cachedSpaceSummaries.isEmpty {
            applyChildSummaries(
                rooms: cachedSummaries,
                spaces: cachedSpaceSummaries
            )
        }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let summaries = await roomListService.refreshSpaceChildren(for: space.id)

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                applyChildSummaries(
                    rooms: summaries.rooms,
                    spaces: summaries.spaces
                )
            }
        }
    }

    private func applyChildSummaries(rooms: [RoomSummary], spaces: [RoomSummary]) {
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
    }

    private func updateSpaceCounts() {
        let roomCount = max(space.spaceChildRoomCount, chats.count)
        let lineCount = max(space.spaceChildSpaceCount, lines.count)
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
            spaceRecentRooms: space.spaceRecentRooms
        )
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
            return { SpaceLineCellNode(line: line) }
        }

        if chats.isEmpty {
            let message = space.spaceChildRoomCount > 0
                ? String(localized: "No accessible chats")
                : String(localized: "Add the first chat")
            return { SpaceEmptyChatsCellNode(message: message) }
        }

        let chat = chats[indexPath.row - chatStartRow]
        return { RoomsCellNode(chat: chat) }
    }

    private var lineRowCount: Int {
        max(1, lines.count)
    }

    private var chatStartRow: Int {
        1 + lineRowCount
    }

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)

        if indexPath.row > 0, indexPath.row < chatStartRow, !lines.isEmpty {
            onSpaceSelected?(lines[indexPath.row - 1])
            return
        }

        guard indexPath.row >= chatStartRow, !chats.isEmpty else { return }
        onChatSelected?(chats[indexPath.row - chatStartRow])
    }
}
