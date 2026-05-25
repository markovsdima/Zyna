//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import GRDB
import MatrixRustSDK

final class PinnedMessagesViewController: ASDKViewController<SettingsScreenNode> {

    var onBack: (() -> Void)?
    var onSelectEvent: ((String) -> Void)?

    private struct Item: Sendable {
        let eventId: String
        let title: String
        let subtitle: String?
        let isLoadedLocally: Bool
    }

    private let room: Room
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let glassTopBar = GlassTopBar()
    private var voicePlayerHost: EmbeddedVoiceTopPlayerHost?
    private var loadTask: Task<Void, Never>?
    private var roomInfoSubscription: TaskHandle?
    private var items: [Item] = []
    private var isLoading = true

    init(room: Room, audioPlayer: AudioPlayerService? = nil) {
        self.room = room
        super.init(node: SettingsScreenNode())
        self.voicePlayerHost = audioPlayer.map {
            EmbeddedVoiceTopPlayerHost(viewController: self, audioPlayer: $0)
        }
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
        roomInfoSubscription?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTableView()
        setupGlassTopBar()
        setupVoicePlayerHost()
        subscribeToRoomInfoUpdates()
        loadPinnedMessages()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        voicePlayerHost?.refresh()
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
        voicePlayerHost?.layout()
        glassTopBar.updateLayout(in: view)
        updateTableInsets()
    }

    private func setupTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .appBG
        tableView.separatorStyle = .singleLine
        tableView.contentInsetAdjustmentBehavior = .never
        view.addSubview(tableView)
        node.tableView = tableView
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .appBG
        glassTopBar.sourceView = tableView
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar

        glassTopBar.items = [
            .circleButton(
                icon: AppIcon.chevronBackward.template(size: 17, weight: .semibold),
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ),
            .title(text: String(localized: "Pinned Messages"), subtitle: nil)
        ]
    }

    private func setupVoicePlayerHost() {
        voicePlayerHost?.onVisibilityChanged = { [weak self] in
            self?.view.setNeedsLayout()
            GlassService.shared.setNeedsCapture()
        }
        voicePlayerHost?.install()
        node.voicePlayerView = voicePlayerHost?.accessibilityView
    }

    private func updateTableInsets() {
        let top = glassTopBar.coveredHeight
        if abs(tableView.contentInset.top - top) > 0.5 {
            tableView.contentInset.top = top
            tableView.verticalScrollIndicatorInsets.top = top
        }
        let bottom = max(view.safeAreaInsets.bottom + 16, 16)
        if abs(tableView.contentInset.bottom - bottom) > 0.5 {
            tableView.contentInset.bottom = bottom
            tableView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    private func subscribeToRoomInfoUpdates() {
        let listener = PinnedMessagesInfoListener { [weak self] info in
            DispatchQueue.main.async { [weak self] in
                self?.applyPinnedEventIds(info.pinnedEventIds)
            }
        }
        roomInfoSubscription = room.subscribeToRoomInfoUpdates(listener: listener)
    }

    private func loadPinnedMessages() {
        loadTask?.cancel()
        isLoading = true
        tableView.reloadData()

        let room = room
        loadTask = Task { [weak self, room] in
            let info = try? await room.roomInfo()
            let eventIds = info?.pinnedEventIds ?? []
            let roomId = room.id()
            let loadedItems = await Task.detached {
                Self.buildItems(eventIds: eventIds, roomId: roomId)
            }.value
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.items = loadedItems
                self.isLoading = false
                self.tableView.reloadData()
            }
        }
    }

    private func applyPinnedEventIds(_ eventIds: [String]) {
        loadTask?.cancel()
        let roomId = room.id()
        loadTask = Task { [weak self] in
            let loadedItems = await Task.detached {
                Self.buildItems(eventIds: eventIds, roomId: roomId)
            }.value
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.items = loadedItems
                self.isLoading = false
                self.tableView.reloadData()
            }
        }
    }

    nonisolated private static func buildItems(eventIds: [String], roomId: String) -> [Item] {
        let uniqueEventIds = eventIds.reduce(into: [String]()) { result, eventId in
            guard !eventId.isEmpty, !result.contains(eventId) else { return }
            result.append(eventId)
        }
        guard !uniqueEventIds.isEmpty else { return [] }

        let storedByEventId = loadStoredMessages(eventIds: uniqueEventIds, roomId: roomId)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        return uniqueEventIds.map { eventId in
            guard let stored = storedByEventId[eventId] else {
                return Item(
                    eventId: eventId,
                    title: String(localized: "Pinned message"),
                    subtitle: String(localized: "Message not loaded yet"),
                    isLoadedLocally: false
                )
            }

            let message = stored.toChatMessage()
            let title = message?.content.textPreview
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? String(localized: "Pinned message")
            let sender = stored.senderDisplayName?.nilIfEmpty ?? stored.senderId
            let date = dateFormatter.string(
                from: Date(timeIntervalSince1970: stored.timestamp)
            )
            return Item(
                eventId: eventId,
                title: title,
                subtitle: "\(sender) - \(date)",
                isLoadedLocally: true
            )
        }
    }

    nonisolated private static func loadStoredMessages(
        eventIds: [String],
        roomId: String
    ) -> [String: StoredMessage] {
        (try? DatabaseService.shared.dbQueue.read { db in
            var result: [String: StoredMessage] = [:]
            for eventId in eventIds {
                if let stored = try StoredMessage
                    .filter(Column("roomId") == roomId && Column("eventId") == eventId)
                    .fetchOne(db) {
                    result[eventId] = stored
                }
            }
            return result
        }) ?? [:]
    }
}

extension PinnedMessagesViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isLoading || items.isEmpty {
            return 1
        }
        return items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if isLoading {
            return statusCell(tableView: tableView, text: String(localized: "Loading"))
        }
        guard !items.isEmpty else {
            return statusCell(tableView: tableView, text: String(localized: "No pinned messages"))
        }

        let item = items[indexPath.row]
        let identifier = "pinnedMessageCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        configureBaseCell(cell)
        cell.textLabel?.text = item.title
        cell.detailTextLabel?.text = item.subtitle
        cell.detailTextLabel?.numberOfLines = 1
        cell.imageView?.image = AppIcon.pin.template(size: 16, weight: .medium)
        cell.imageView?.tintColor = item.isLoadedLocally ? AppColor.accent : .tertiaryLabel
        cell.accessoryType = item.isLoadedLocally ? .disclosureIndicator : .none
        cell.selectionStyle = item.isLoadedLocally ? .default : .none
        return cell
    }

    private func statusCell(tableView: UITableView, text: String) -> UITableViewCell {
        let identifier = "statusCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
        configureBaseCell(cell)
        cell.textLabel?.text = text
        cell.textLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.text = nil
        cell.imageView?.image = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        return cell
    }

    private func configureBaseCell(_ cell: UITableViewCell) {
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.textLabel?.font = UIFont.systemFont(ofSize: 17)
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 13)
        cell.detailTextLabel?.textColor = .secondaryLabel
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isLoading, items.indices.contains(indexPath.row) else { return }
        let item = items[indexPath.row]
        guard item.isLoadedLocally else { return }
        onSelectEvent?(item.eventId)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }
}

extension PinnedMessagesViewController: AccessibilityFocusProviding {
    var initialAccessibilityFocus: UIView? {
        AccessibilityElementOrder.firstVisibleView(in: glassTopBar)
    }
}

private final class PinnedMessagesInfoListener: RoomInfoListener {
    private let callback: @Sendable (RoomInfo) -> Void

    init(callback: @escaping @Sendable (RoomInfo) -> Void) {
        self.callback = callback
    }

    func call(roomInfo: RoomInfo) {
        callback(roomInfo)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
