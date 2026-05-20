//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class RoomRolesPermissionsViewController: ASDKViewController<SettingsScreenNode> {

    var onBack: (() -> Void)?

    private struct RoleCounts {
        let administrators: Int
        let moderators: Int
    }

    private enum Section: Int, CaseIterable {
        case roles
        case roomDetails
        case messagesAndContent
        case memberModeration
        case reset

        var title: String? {
            switch self {
            case .roles:
                return String(localized: "Roles")
            case .roomDetails:
                return String(localized: "Room Details")
            case .messagesAndContent:
                return String(localized: "Messages and Content")
            case .memberModeration:
                return String(localized: "Member Moderation")
            case .reset:
                return nil
            }
        }
    }

    private enum RoleSummaryRow: Int, CaseIterable {
        case administrators
        case moderators

        var title: String {
            switch self {
            case .administrators:
                return String(localized: "Administrators")
            case .moderators:
                return String(localized: "Moderators")
            }
        }
    }

    private enum PermissionRole: CaseIterable {
        case administrators
        case moderators
        case everyone

        init(powerLevel: Int64) {
            switch powerLevel {
            case 100...:
                self = .administrators
            case 1..<100:
                self = .moderators
            default:
                self = .everyone
            }
        }

        var title: String {
            switch self {
            case .administrators:
                return String(localized: "Administrators")
            case .moderators:
                return String(localized: "Moderators")
            case .everyone:
                return String(localized: "Everyone")
            }
        }

        var powerLevel: Int64 {
            switch self {
            case .administrators:
                return 100
            case .moderators:
                return 50
            case .everyone:
                return 0
            }
        }
    }

    private enum PermissionKey {
        case roomName
        case roomAvatar
        case roomTopic
        case sendMessages
        case deleteMessages
        case invitePeople
        case removePeople
        case banPeople

        var title: String {
            switch self {
            case .roomName:
                return String(localized: "Room Name")
            case .roomAvatar:
                return String(localized: "Room Avatar")
            case .roomTopic:
                return String(localized: "Room Topic")
            case .sendMessages:
                return String(localized: "Send Messages")
            case .deleteMessages:
                return String(localized: "Delete Messages")
            case .invitePeople:
                return String(localized: "Invite People")
            case .removePeople:
                return String(localized: "Remove People")
            case .banPeople:
                return String(localized: "Ban People")
            }
        }

        func powerLevel(from values: RoomPowerLevelsValues) -> Int64 {
            switch self {
            case .roomName:
                return values.roomName
            case .roomAvatar:
                return values.roomAvatar
            case .roomTopic:
                return values.roomTopic
            case .sendMessages:
                return values.eventsDefault
            case .deleteMessages:
                return values.redact
            case .invitePeople:
                return values.invite
            case .removePeople:
                return values.kick
            case .banPeople:
                return values.ban
            }
        }

        func apply(powerLevel: Int64, to changes: inout RoomPowerLevelChanges) {
            switch self {
            case .roomName:
                changes.roomName = powerLevel
            case .roomAvatar:
                changes.roomAvatar = powerLevel
            case .roomTopic:
                changes.roomTopic = powerLevel
            case .sendMessages:
                changes.eventsDefault = powerLevel
            case .deleteMessages:
                changes.redact = powerLevel
            case .invitePeople:
                changes.invite = powerLevel
            case .removePeople:
                changes.kick = powerLevel
            case .banPeople:
                changes.ban = powerLevel
            }
        }
    }

    private static let roomDetailsRows: [PermissionKey] = [
        .roomName,
        .roomAvatar,
        .roomTopic
    ]
    private static let messagesAndContentRows: [PermissionKey] = [
        .sendMessages,
        .deleteMessages
    ]
    private static let memberModerationRows: [PermissionKey] = [
        .invitePeople,
        .removePeople,
        .banPeople
    ]

    private let room: Room
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let glassTopBar = GlassTopBar()
    private var voicePlayerHost: EmbeddedVoiceTopPlayerHost?

    private var powerLevels: RoomPowerLevels?
    private var powerLevelValues: RoomPowerLevelsValues?
    private var roleCounts: RoleCounts?
    private var stateTask: Task<Void, Never>?
    private var roleCountsTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var roomInfoSubscription: TaskHandle?
    private var progressAlert: UIAlertController?
    private var isLoadingPermissions = false
    private var isSaving = false

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
        stateTask?.cancel()
        roleCountsTask?.cancel()
        operationTask?.cancel()
        roomInfoSubscription?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTableView()
        setupGlassTopBar()
        setupVoicePlayerHost()
        subscribeToRoomInfoUpdates()
        loadState()
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
            .title(text: String(localized: "Roles and Permissions"), subtitle: nil)
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

    private func loadState() {
        stateTask?.cancel()
        roleCountsTask?.cancel()
        isLoadingPermissions = true
        tableView.reloadData()

        let room = room
        stateTask = Task { [weak self, room] in
            let loadedInfo = try? await room.roomInfo()
            let loadedPowerLevels: RoomPowerLevels?
            if let infoPowerLevels = loadedInfo?.powerLevels {
                loadedPowerLevels = infoPowerLevels
            } else {
                loadedPowerLevels = try? await room.getPowerLevels()
            }
            let cachedCounts = await Self.loadRoleCounts(room: room, noSync: true)

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.apply(powerLevels: loadedPowerLevels)
                self.roleCounts = cachedCounts ?? self.roleCounts
                self.isLoadingPermissions = false
                self.tableView.reloadData()
            }

            let syncedCounts = await Self.loadRoleCounts(room: room, noSync: false)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.roleCounts = syncedCounts ?? self.roleCounts
                self.reloadSection(.roles)
            }
        }
    }

    private func subscribeToRoomInfoUpdates() {
        let listener = RoomRolesPermissionsInfoListener { [weak self] info in
            DispatchQueue.main.async { [weak self] in
                self?.applyRoomInfo(info)
            }
        }
        roomInfoSubscription = room.subscribeToRoomInfoUpdates(listener: listener)
    }

    private func applyRoomInfo(_ info: RoomInfo) {
        guard let infoPowerLevels = info.powerLevels else { return }
        apply(powerLevels: infoPowerLevels)
        tableView.reloadData()
        refreshRoleCountsFromCache()
    }

    private func apply(powerLevels: RoomPowerLevels?) {
        self.powerLevels = powerLevels
        self.powerLevelValues = powerLevels?.values()
    }

    private func refreshRoleCountsFromCache() {
        roleCountsTask?.cancel()
        let room = room
        roleCountsTask = Task { [weak self, room] in
            guard let counts = await Self.loadRoleCounts(room: room, noSync: true) else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.roleCounts = counts
                self.reloadSection(.roles)
            }
        }
    }

    private static func loadRoleCounts(room: Room, noSync: Bool) async -> RoleCounts? {
        do {
            let iterator = try await (noSync ? room.membersNoSync() : room.members())
            var administrators = 0
            var moderators = 0
            var didReadMembers = false

            while let chunk = iterator.nextChunk(chunkSize: 512), !chunk.isEmpty {
                didReadMembers = true
                for member in chunk where member.membership == .join {
                    switch MemberCellNode.Role.from(powerLevel: member.powerLevel) {
                    case .owner, .admin:
                        administrators += 1
                    case .moderator:
                        moderators += 1
                    case .member:
                        break
                    }
                }
            }

            if noSync && !didReadMembers {
                return nil
            }
            return RoleCounts(administrators: administrators, moderators: moderators)
        } catch {
            ScopedLog(.rooms)("Failed to load role counts (noSync=\(noSync)): \(error)")
            return nil
        }
    }

    private var canEditPermissions: Bool {
        guard let powerLevels else { return false }
        return powerLevels.canOwnUserSendState(stateEvent: .roomPowerLevels)
    }

    private var disabledDetail: String? {
        if powerLevels == nil || isLoadingPermissions {
            return String(localized: "Loading permissions")
        }
        if !canEditPermissions {
            return String(localized: "Not enough permissions")
        }
        return nil
    }

    private func permissionRows(for section: Section) -> [PermissionKey] {
        switch section {
        case .roomDetails:
            return Self.roomDetailsRows
        case .messagesAndContent:
            return Self.messagesAndContentRows
        case .memberModeration:
            return Self.memberModerationRows
        case .roles, .reset:
            return []
        }
    }

    private func permissionKey(at indexPath: IndexPath) -> PermissionKey? {
        let section = Section(rawValue: indexPath.section) ?? .roles
        let rows = permissionRows(for: section)
        guard rows.indices.contains(indexPath.row) else { return nil }
        return rows[indexPath.row]
    }

    private func currentRole(for key: PermissionKey) -> PermissionRole? {
        guard let powerLevelValues else { return nil }
        return PermissionRole(powerLevel: key.powerLevel(from: powerLevelValues))
    }

    private func presentRolePicker(for key: PermissionKey, from indexPath: IndexPath) {
        guard !isSaving, canEditPermissions else { return }
        guard let currentRole = currentRole(for: key) else { return }

        let alert = UIAlertController(title: key.title, message: nil, preferredStyle: .actionSheet)
        for role in PermissionRole.allCases {
            let title = role == currentRole
                ? String(format: String(localized: "%@ (Current)"), role.title)
                : role.title
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.updatePermission(key, to: role)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))

        if let popover = alert.popoverPresentationController {
            let cell = tableView.cellForRow(at: indexPath)
            popover.sourceView = cell ?? tableView
            popover.sourceRect = cell?.bounds ?? tableView.bounds
        }

        present(alert, animated: true)
    }

    private func updatePermission(_ key: PermissionKey, to role: PermissionRole) {
        guard canEditPermissions else { return }
        guard currentRole(for: key) != role else { return }

        performSavingOperation { [room] in
            var changes = RoomPowerLevelChanges()
            key.apply(powerLevel: role.powerLevel, to: &changes)
            try await room.applyPowerLevelChanges(changes: changes)
        }
    }

    private func confirmResetPermissions() {
        guard !isSaving, canEditPermissions else { return }
        let alert = UIAlertController(
            title: String(localized: "Reset Permissions?"),
            message: String(localized: "Room permissions will be returned to the Matrix defaults."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Reset"), style: .destructive) { [weak self] _ in
            self?.resetPermissions()
        })
        present(alert, animated: true)
    }

    private func resetPermissions() {
        guard canEditPermissions else { return }
        performSavingOperation { [room] in
            _ = try await room.resetPowerLevels()
        }
    }

    private func performSavingOperation(_ operation: @escaping () async throws -> Void) {
        guard !isSaving else { return }
        isSaving = true
        tableView.reloadData()
        presentProgress()

        operationTask?.cancel()
        let room = room
        operationTask = Task { [weak self, room] in
            do {
                try await operation()
                try? await Task.sleep(for: .milliseconds(250))
                let loadedInfo = try? await room.roomInfo()
                let loadedPowerLevels: RoomPowerLevels?
                if let infoPowerLevels = loadedInfo?.powerLevels {
                    loadedPowerLevels = infoPowerLevels
                } else {
                    loadedPowerLevels = try? await room.getPowerLevels()
                }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.apply(powerLevels: loadedPowerLevels ?? self.powerLevels)
                    self.finishSaving()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.finishSaving(error: error)
                }
            }
        }
    }

    private func presentProgress() {
        guard progressAlert == nil else { return }
        let alert = UIAlertController(
            title: String(localized: "Saving"),
            message: nil,
            preferredStyle: .alert
        )
        progressAlert = alert
        present(alert, animated: true)
    }

    private func finishSaving(error: Error? = nil) {
        let completion = { [weak self] in
            guard let self else { return }
            self.isSaving = false
            self.progressAlert = nil
            self.tableView.reloadData()
            if let error {
                self.presentError(error)
            }
        }

        if let progressAlert {
            progressAlert.dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "Could Not Save Room Permissions"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func reloadSection(_ section: Section) {
        let indexSet = IndexSet(integer: section.rawValue)
        tableView.reloadSections(indexSet, with: .automatic)
    }
}

extension RoomRolesPermissionsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) ?? .roles {
        case .roles:
            return RoleSummaryRow.allCases.count
        case .roomDetails:
            return Self.roomDetailsRows.count
        case .messagesAndContent:
            return Self.messagesAndContentRows.count
        case .memberModeration:
            return Self.memberModerationRows.count
        case .reset:
            return 1
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        (Section(rawValue: section) ?? .roles).title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) ?? .roles {
        case .roles:
            return String(localized: "Member roles are changed from each member profile.")
        case .roomDetails, .messagesAndContent, .memberModeration:
            if disabledDetail != nil {
                return String(localized: "Only users who can edit room power levels can change these settings.")
            }
            return nil
        case .reset:
            return String(localized: "Reset returns permissions to the default Matrix power levels.")
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) ?? .roles {
        case .roles:
            let row = RoleSummaryRow(rawValue: indexPath.row) ?? .administrators
            return roleSummaryCell(tableView: tableView, row: row)
        case .roomDetails, .messagesAndContent, .memberModeration:
            guard let key = permissionKey(at: indexPath) else {
                return UITableViewCell(style: .default, reuseIdentifier: nil)
            }
            return permissionCell(tableView: tableView, key: key)
        case .reset:
            return resetCell(tableView: tableView)
        }
    }

    private func roleSummaryCell(tableView: UITableView, row: RoleSummaryRow) -> UITableViewCell {
        let identifier = "roleSummaryCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .value1, reuseIdentifier: identifier)
        configureBaseCell(cell)
        cell.textLabel?.text = row.title
        switch row {
        case .administrators:
            cell.detailTextLabel?.text = roleCounts.map { "\($0.administrators)" }
                ?? String(localized: "Loading")
        case .moderators:
            cell.detailTextLabel?.text = roleCounts.map { "\($0.moderators)" }
                ?? String(localized: "Loading")
        }
        applyEnabledState(true, to: cell, allowsSelection: false)
        return cell
    }

    private func permissionCell(tableView: UITableView, key: PermissionKey) -> UITableViewCell {
        let identifier = "permissionCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .value1, reuseIdentifier: identifier)
        configureBaseCell(cell)
        cell.textLabel?.text = key.title
        if let role = currentRole(for: key) {
            cell.detailTextLabel?.text = role.title
        } else {
            cell.detailTextLabel?.text = disabledDetail ?? String(localized: "Loading")
        }
        cell.accessoryType = canEditPermissions && !isSaving ? .disclosureIndicator : .none
        applyEnabledState(canEditPermissions && !isSaving, to: cell, allowsSelection: true)
        return cell
    }

    private func resetCell(tableView: UITableView) -> UITableViewCell {
        let identifier = "resetCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
        configureBaseCell(cell)
        cell.textLabel?.text = String(localized: "Reset Permissions")
        cell.textLabel?.textColor = .systemRed
        cell.detailTextLabel?.text = nil
        cell.accessoryType = .none
        applyEnabledState(canEditPermissions && !isSaving, to: cell, allowsSelection: true)
        return cell
    }

    private func configureBaseCell(_ cell: UITableViewCell) {
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.contentView.alpha = 1
        cell.isUserInteractionEnabled = true
        cell.selectionStyle = .default
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.textLabel?.font = UIFont.systemFont(ofSize: 17)
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 15)
        cell.detailTextLabel?.textColor = .secondaryLabel
    }

    private func applyEnabledState(
        _ isEnabled: Bool,
        to cell: UITableViewCell,
        allowsSelection: Bool
    ) {
        cell.contentView.alpha = isEnabled ? 1 : 0.45
        cell.isUserInteractionEnabled = true
        cell.selectionStyle = isEnabled && allowsSelection ? .default : .none
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isSaving else { return }

        switch Section(rawValue: indexPath.section) ?? .roles {
        case .roles:
            return
        case .roomDetails, .messagesAndContent, .memberModeration:
            guard let key = permissionKey(at: indexPath) else { return }
            presentRolePicker(for: key, from: indexPath)
        case .reset:
            confirmResetPermissions()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }
}

private final class RoomRolesPermissionsInfoListener: RoomInfoListener {
    private let callback: @Sendable (RoomInfo) -> Void

    init(callback: @escaping @Sendable (RoomInfo) -> Void) {
        self.callback = callback
    }

    func call(roomInfo: RoomInfo) {
        callback(roomInfo)
    }
}
