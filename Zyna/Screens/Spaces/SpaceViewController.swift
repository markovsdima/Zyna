//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpaceViewController: ASDKViewController<SpaceScreenNode> {

    var onBack: (() -> Void)?
    var onSettings: (() -> Void)?
    var onChatSelected: ((RoomModel) -> Void)?

    private let space: RoomModel
    private let roomListService: ZynaRoomListService
    private let glassTopBar = GlassTopBar()
    private var chats: [RoomModel] = []
    private var loadTask: Task<Void, Never>?

    init(space: RoomModel, roomListService: ZynaRoomListService) {
        self.space = space
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
        loadChildChats()
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
                subtitle: String(localized: "Storyline")
            ),
            .circleButton(
                icon: composeIcon,
                accessibilityLabel: String(localized: "Add to Storyline"),
                action: { }
            )
        ]
    }

    private func loadChildChats() {
        let cachedSummaries = roomListService.cachedSpaceChildRooms(for: space.id)
        if !cachedSummaries.isEmpty {
            applyChildSummaries(cachedSummaries)
        }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let summaries = await roomListService.refreshSpaceChildRooms(for: space.id)

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                applyChildSummaries(summaries)
            }
        }
    }

    private func applyChildSummaries(_ summaries: [RoomSummary]) {
        var models = summaries.map { RoomModel(from: $0) }
        let statuses = PresenceTracker.shared.statuses
        if !statuses.isEmpty {
            models = models.map { room in
                guard let userId = room.directUserId,
                      let status = statuses[userId] else { return room }
                var updated = room
                updated.isOnline = status.online
                updated.lastSeen = status.lastSeen
                return updated
            }
        }

        guard models != chats else { return }
        chats = models
        node.tableNode.reloadData()
    }
}

extension SpaceViewController: ASTableDataSource, ASTableDelegate {
    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        2 + max(1, chats.count)
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        if indexPath.row == 0 {
            let space = self.space
            return { SpaceHeaderCellNode(space: space) }
        }

        if indexPath.row == 1 {
            return { SpaceLinesPlaceholderCellNode() }
        }

        if chats.isEmpty {
            let message = space.spaceChildRoomCount > 0
                ? String(localized: "No accessible chats")
                : String(localized: "Add the first chat")
            return { SpaceEmptyChatsCellNode(message: message) }
        }

        let chat = chats[indexPath.row - 2]
        return { RoomsCellNode(chat: chat) }
    }

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        guard indexPath.row >= 2, !chats.isEmpty else { return }
        onChatSelected?(chats[indexPath.row - 2])
    }
}
