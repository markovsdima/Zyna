//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class RoomSecurityPrivacyViewController: ASDKViewController<SettingsScreenNode> {

    var onBack: (() -> Void)?

    private enum Section: Int, CaseIterable {
        case access
        case directory
        case encryption
        case history

        var title: String {
            switch self {
            case .access:
                return String(localized: "Room Access")
            case .directory:
                return String(localized: "Room Directory")
            case .encryption:
                return String(localized: "Encryption")
            case .history:
                return String(localized: "Room History")
            }
        }
    }

    private enum EditableSetting {
        case access
        case directory
        case alias
        case encryption
        case history
    }

    private enum AccessOption: CaseIterable {
        case inviteOnly
        case anyone

        var title: String {
            switch self {
            case .inviteOnly:
                return String(localized: "Invite Only")
            case .anyone:
                return String(localized: "Anyone")
            }
        }

        var detail: String {
            switch self {
            case .inviteOnly:
                return String(localized: "Only invited people can join this room.")
            case .anyone:
                return String(localized: "Anyone can join this room without an invite.")
            }
        }

        var joinRule: JoinRule {
            switch self {
            case .inviteOnly:
                return .invite
            case .anyone:
                return .public
            }
        }
    }

    private enum DirectoryRow: Int, CaseIterable {
        case alias
        case visibility
    }

    private enum HistoryOption: CaseIterable {
        case shared
        case invited
        case joined
        case anyone

        var title: String {
            switch self {
            case .shared:
                return String(localized: "New members can see previous history")
            case .invited:
                return String(localized: "From invite")
            case .joined:
                return String(localized: "From joining")
            case .anyone:
                return String(localized: "Anyone")
            }
        }

        var detail: String? {
            switch self {
            case .shared:
                return String(localized: "New members can see messages sent before they joined.")
            case .invited:
                return String(localized: "Members can see history from the moment they were invited.")
            case .joined:
                return String(localized: "Members can see history from the moment they joined.")
            case .anyone:
                return String(localized: "History can be read without joining the room.")
            }
        }

        var historyVisibility: RoomHistoryVisibility {
            switch self {
            case .shared:
                return .shared
            case .invited:
                return .invited
            case .joined:
                return .joined
            case .anyone:
                return .worldReadable
            }
        }
    }

    private let room: Room
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let glassTopBar = GlassTopBar()
    private var voicePlayerHost: EmbeddedVoiceTopPlayerHost?

    private var roomInfo: RoomInfo?
    private var powerLevels: RoomPowerLevels?
    private var directoryVisibility: RoomVisibility?
    private var roomInfoTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var roomInfoSubscription: TaskHandle?
    private var progressAlert: UIAlertController?
    private var isLoading = false
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
        roomInfoTask?.cancel()
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
            .title(text: String(localized: "Security and Privacy"), subtitle: nil)
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
        roomInfoTask?.cancel()
        isLoading = true
        tableView.reloadData()

        roomInfoTask = Task { [weak self] in
            guard let self else { return }
            let loadedInfo = try? await self.room.roomInfo()
            let loadedPowerLevels: RoomPowerLevels?
            if let infoPowerLevels = loadedInfo?.powerLevels {
                loadedPowerLevels = infoPowerLevels
            } else {
                loadedPowerLevels = try? await self.room.getPowerLevels()
            }
            let loadedVisibility = try? await self.room.getRoomVisibility()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.roomInfo = loadedInfo ?? self.roomInfo
                self.powerLevels = loadedPowerLevels ?? self.powerLevels
                self.directoryVisibility = loadedVisibility ?? self.directoryVisibility ?? .private
                self.isLoading = false
                self.tableView.reloadData()
            }
        }
    }

    private func subscribeToRoomInfoUpdates() {
        let listener = RoomSecurityPrivacyInfoListener { [weak self] info in
            DispatchQueue.main.async { [weak self] in
                self?.applyRoomInfo(info)
            }
        }
        roomInfoSubscription = room.subscribeToRoomInfoUpdates(listener: listener)
    }

    private func applyRoomInfo(_ info: RoomInfo) {
        roomInfo = info
        if let infoPowerLevels = info.powerLevels {
            powerLevels = infoPowerLevels
        }
        tableView.reloadData()
    }

    private var isEncrypted: Bool {
        switch roomInfo?.encryptionState ?? room.encryptionState() {
        case .encrypted:
            return true
        case .notEncrypted, .unknown:
            return false
        }
    }

    private var selectedAccess: AccessOption? {
        switch roomInfo?.joinRule {
        case .public:
            return .anyone
        case .invite, .private:
            return .inviteOnly
        case .none, .knock, .restricted(rules: _), .knockRestricted(rules: _), .custom(repr: _):
            return nil
        }
    }

    private var selectedHistory: HistoryOption? {
        switch roomInfo?.historyVisibility {
        case .shared:
            return .shared
        case .invited:
            return .invited
        case .joined:
            return .joined
        case .worldReadable:
            return .anyone
        case .custom(value: _), .none:
            return nil
        }
    }

    private var availableHistoryOptions: [HistoryOption] {
        var options: [HistoryOption] = [.shared, .invited, .joined]
        if (!isEncrypted && selectedAccess == .anyone) || selectedHistory == .anyone {
            options.append(.anyone)
        }
        return options
    }

    private var serverName: String? {
        guard let userId = try? MatrixClientService.shared.client?.userId() else { return nil }
        guard let colon = userId.firstIndex(of: ":") else { return nil }
        let serverStart = userId.index(after: colon)
        guard serverStart < userId.endIndex else { return nil }
        return String(userId[serverStart...])
    }

    private var aliases: [String] {
        var result: [String] = []
        if let canonicalAlias = roomInfo?.canonicalAlias {
            result.append(canonicalAlias)
        } else if let canonicalAlias = room.canonicalAlias() {
            result.append(canonicalAlias)
        }
        result.append(contentsOf: roomInfo?.alternativeAliases ?? room.alternativeAliases())
        return result.reduce(into: []) { unique, alias in
            guard !unique.contains(alias) else { return }
            unique.append(alias)
        }
    }

    private var displayedAlias: String? {
        guard let serverName else {
            return aliases.first
        }
        return aliasMatching(serverName: serverName, useFallback: true)
    }

    private var editableAlias: String? {
        guard let serverName else { return nil }
        return aliasMatching(serverName: serverName, useFallback: false)
    }

    private func aliasMatching(serverName: String, useFallback: Bool) -> String? {
        let localAlias = aliases.first { $0.hasSuffix(":\(serverName)") }
        return localAlias ?? (useFallback ? aliases.first : nil)
    }

    private func updateAccess(_ option: AccessOption) {
        guard canEdit(.access) else { return }
        guard selectedAccess != option else { return }
        let shouldHideFromDirectory = option == .inviteOnly && canEdit(.directory)
        performSavingOperation { [room] in
            try await room.updateJoinRules(newRule: option.joinRule)
            if shouldHideFromDirectory {
                try await room.updateRoomVisibility(visibility: .private)
            }
        }
    }

    private func updateHistory(_ option: HistoryOption) {
        guard canEdit(.history) else { return }
        guard selectedHistory != option else { return }
        performSavingOperation { [room] in
            try await room.updateHistoryVisibility(visibility: option.historyVisibility)
        }
    }

    private func updateDirectoryVisibility(isVisible: Bool) {
        guard canEdit(.directory) else {
            tableView.reloadData()
            return
        }
        guard displayedAlias != nil else {
            presentError(RoomSecurityPrivacyError.aliasRequiredForDirectory)
            tableView.reloadData()
            return
        }
        let visibility: RoomVisibility = isVisible ? .public : .private
        guard directoryVisibility != visibility else {
            tableView.reloadData()
            return
        }
        performSavingOperation { [room] in
            try await room.updateRoomVisibility(visibility: visibility)
        }
    }

    private func confirmEnableEncryption() {
        guard canEdit(.encryption) else {
            tableView.reloadData()
            return
        }
        guard !isEncrypted else { return }
        let alert = UIAlertController(
            title: String(localized: "Enable End-to-End Encryption?"),
            message: String(localized: "This cannot be turned off later for this room."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
            self?.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: String(localized: "Enable"), style: .default) { [weak self] _ in
            self?.enableEncryption()
        })
        present(alert, animated: true)
    }

    private func enableEncryption() {
        guard canEdit(.encryption) else { return }
        performSavingOperation { [room] in
            try await room.enableEncryption()
        }
    }

    private func performSavingOperation(_ operation: @escaping () async throws -> Void) {
        guard !isSaving else { return }
        isSaving = true
        tableView.reloadData()
        presentProgress()

        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                try? await Task.sleep(for: .milliseconds(250))
                let loadedInfo = try? await self.room.roomInfo()
                let loadedPowerLevels: RoomPowerLevels?
                if let infoPowerLevels = loadedInfo?.powerLevels {
                    loadedPowerLevels = infoPowerLevels
                } else {
                    loadedPowerLevels = try? await self.room.getPowerLevels()
                }
                let loadedVisibility = try? await self.room.getRoomVisibility()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.roomInfo = loadedInfo ?? self.roomInfo
                    self.powerLevels = loadedPowerLevels ?? self.powerLevels
                    self.directoryVisibility = loadedVisibility ?? self.directoryVisibility
                    self.finishSaving()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.finishSaving(error: error)
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

    private func presentAliasEditor() {
        guard canEdit(.alias) else { return }
        guard let serverName else {
            presentError(RoomSecurityPrivacyError.missingServerName)
            return
        }

        let currentLocalPart = editableAlias.flatMap(Self.aliasLocalPart)
        let proposedLocalPart = currentLocalPart
            ?? roomInfo?.displayName.flatMap(Self.defaultAliasLocalPart)
            ?? room.displayName().flatMap(Self.defaultAliasLocalPart)
            ?? ""

        let alert = UIAlertController(
            title: String(localized: "Room Address"),
            message: String(localized: "Use only the local part before the server name."),
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = proposedLocalPart
            textField.placeholder = String(localized: "Room address")
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
            let value = alert?.textFields?.first?.text ?? ""
            self?.saveAlias(localPart: value, serverName: serverName)
        })
        present(alert, animated: true)
    }

    private func saveAlias(localPart: String, serverName: String) {
        guard canEdit(.alias) else { return }
        let normalizedLocalPart = Self.normalizedAliasLocalPart(localPart, serverName: serverName)
        guard !normalizedLocalPart.isEmpty else {
            presentError(RoomSecurityPrivacyError.emptyAlias)
            return
        }

        let desiredAlias = "#\(normalizedLocalPart):\(serverName)"
        guard isRoomAliasFormatValid(alias: desiredAlias) else {
            presentError(RoomSecurityPrivacyError.invalidAlias)
            return
        }

        guard desiredAlias != editableAlias else { return }

        performSavingOperation { [room, weak self] in
            guard let self else { return }
            guard let client = MatrixClientService.shared.client else {
                throw RoomSecurityPrivacyError.clientUnavailable
            }

            let aliasAlreadyBelongsToRoom = await MainActor.run {
                self.aliases.contains(desiredAlias)
            }
            if !aliasAlreadyBelongsToRoom {
                guard try await client.isRoomAliasAvailable(alias: desiredAlias) else {
                    throw RoomSecurityPrivacyError.aliasTaken
                }

                guard try await room.publishRoomAliasInRoomDirectory(alias: desiredAlias) else {
                    throw RoomSecurityPrivacyError.aliasPublishFailed
                }
            }

            let oldEditableAlias = await MainActor.run { self.editableAlias }
            if let oldEditableAlias,
               oldEditableAlias != desiredAlias {
                _ = try await room.removeRoomAliasFromRoomDirectory(alias: oldEditableAlias)
            }

            let savedCanonicalAlias = await MainActor.run {
                self.roomInfo?.canonicalAlias ?? room.canonicalAlias()
            }
            var alternativeAliases = await MainActor.run {
                self.roomInfo?.alternativeAliases ?? room.alternativeAliases()
            }
            alternativeAliases.removeAll { $0 == oldEditableAlias || $0 == desiredAlias }

            if savedCanonicalAlias == nil || savedCanonicalAlias?.hasSuffix(":\(serverName)") == true {
                try await room.updateCanonicalAlias(alias: desiredAlias, altAliases: alternativeAliases)
            } else {
                alternativeAliases.insert(desiredAlias, at: 0)
                try await room.updateCanonicalAlias(alias: savedCanonicalAlias, altAliases: alternativeAliases)
            }
        }
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "Could Not Save Room Settings"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func canEdit(_ setting: EditableSetting) -> Bool {
        guard let powerLevels else { return false }
        switch setting {
        case .access:
            return powerLevels.canOwnUserSendState(stateEvent: .roomJoinRules)
        case .directory, .alias:
            return powerLevels.canOwnUserSendState(stateEvent: .roomCanonicalAlias)
        case .encryption:
            return powerLevels.canOwnUserSendState(stateEvent: .roomEncryption)
        case .history:
            return powerLevels.canOwnUserSendState(stateEvent: .roomHistoryVisibility)
        }
    }

    private func disabledDetail(for setting: EditableSetting) -> String? {
        if powerLevels == nil {
            return String(localized: "Loading permissions")
        }
        if !canEdit(setting) {
            return String(localized: "Not enough permissions")
        }
        return nil
    }

    private static func defaultAliasLocalPart(for roomName: String) -> String? {
        let localPart = roomAliasNameFromRoomDisplayName(roomName: roomName).lowercased()
        return localPart.isEmpty ? nil : localPart
    }

    private static func normalizedAliasLocalPart(_ value: String, serverName: String) -> String {
        var result = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if result.hasPrefix("#") {
            result.removeFirst()
        }

        if result.hasSuffix(":\(serverName)"),
           let colon = result.lastIndex(of: ":") {
            result = String(result[..<colon])
        }

        return result
    }

    private static func aliasLocalPart(_ alias: String) -> String {
        var value = alias
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        return value.split(separator: ":").first.flatMap(String.init) ?? ""
    }
}

extension RoomSecurityPrivacyViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) ?? .access {
        case .access:
            return AccessOption.allCases.count
        case .directory:
            return DirectoryRow.allCases.count
        case .encryption:
            return 1
        case .history:
            return availableHistoryOptions.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        (Section(rawValue: section) ?? .access).title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) ?? .access {
        case .access:
            if selectedAccess == nil, roomInfo?.joinRule != nil {
                return String(localized: "This room currently uses an access rule Zyna cannot edit directly. Choosing an option will replace it.")
            }
            return nil
        case .directory:
            if displayedAlias == nil {
                return String(localized: "A room address is required before the room can be shown in the public room directory.")
            }
            return String(localized: "Directory visibility controls whether this room can be found in public room search.")
        case .encryption:
            return String(localized: "End-to-end encryption cannot be disabled after it is enabled.")
        case .history:
            if isEncrypted || selectedAccess != .anyone {
                return String(localized: "World-readable history is available only for public unencrypted rooms.")
            }
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) ?? .access {
        case .access:
            let option = AccessOption.allCases[indexPath.row]
            let enabled = !isSaving && canEdit(.access)
            return optionCell(
                tableView: tableView,
                title: option.title,
                detail: disabledDetail(for: .access) ?? option.detail,
                isSelected: selectedAccess == option,
                isEnabled: enabled
            )
        case .directory:
            return directoryCell(tableView: tableView, row: DirectoryRow(rawValue: indexPath.row) ?? .alias)
        case .encryption:
            return encryptionCell(tableView: tableView)
        case .history:
            let option = availableHistoryOptions[indexPath.row]
            let enabled = !isSaving && canEdit(.history)
            return optionCell(
                tableView: tableView,
                title: option.title,
                detail: disabledDetail(for: .history) ?? option.detail,
                isSelected: selectedHistory == option,
                isEnabled: enabled
            )
        }
    }

    private func optionCell(
        tableView: UITableView,
        title: String,
        detail: String?,
        isSelected: Bool,
        isEnabled: Bool
    ) -> UITableViewCell {
        let identifier = "optionCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        configureBaseCell(cell)
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = detail
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryView = nil
        cell.accessoryType = isSelected ? .checkmark : .none
        cell.tintColor = AppColor.accent
        applyEnabledState(isEnabled, to: cell, allowsSelection: true)
        return cell
    }

    private func directoryCell(tableView: UITableView, row: DirectoryRow) -> UITableViewCell {
        switch row {
        case .alias:
            let identifier = "valueCell"
            let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
                ?? UITableViewCell(style: .value1, reuseIdentifier: identifier)
            configureBaseCell(cell)
            cell.textLabel?.text = String(localized: "Room Address")
            cell.detailTextLabel?.text = displayedAlias ?? String(localized: "Not Set")
            cell.accessoryType = .disclosureIndicator
            cell.accessoryView = nil
            applyEnabledState(!isSaving && canEdit(.alias), to: cell, allowsSelection: true)
            return cell
        case .visibility:
            let identifier = "switchCell"
            let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
            configureBaseCell(cell)
            cell.textLabel?.text = String(localized: "Visible in Room Directory")
            if let disabled = disabledDetail(for: .directory) {
                cell.detailTextLabel?.text = disabled
            } else if isLoading || directoryVisibility == nil {
                cell.detailTextLabel?.text = String(localized: "Loading")
            } else if displayedAlias == nil {
                cell.detailTextLabel?.text = String(localized: "Room address required")
            } else {
                cell.detailTextLabel?.text = nil
            }
            cell.accessoryType = .none
            let control = UISwitch()
            control.isOn = directoryVisibility == .public
            control.isEnabled = !isSaving
                && !isLoading
                && canEdit(.directory)
                && directoryVisibility != nil
                && displayedAlias != nil
            control.addTarget(self, action: #selector(directorySwitchChanged(_:)), for: .valueChanged)
            cell.accessoryView = control
            applyEnabledState(control.isEnabled, to: cell, allowsSelection: false)
            return cell
        }
    }

    private func encryptionCell(tableView: UITableView) -> UITableViewCell {
        let identifier = "encryptionCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .value1, reuseIdentifier: identifier)
        configureBaseCell(cell)
        cell.textLabel?.text = String(localized: "End-to-End Encryption")
        cell.detailTextLabel?.text = isEncrypted ? nil : disabledDetail(for: .encryption)
        cell.accessoryType = .none
        let control = UISwitch()
        control.isOn = isEncrypted
        control.isEnabled = !isSaving && !isEncrypted && canEdit(.encryption)
        control.addTarget(self, action: #selector(encryptionSwitchChanged(_:)), for: .valueChanged)
        cell.accessoryView = control
        applyEnabledState(control.isEnabled || isEncrypted, to: cell, allowsSelection: false)
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
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 13)
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

        switch Section(rawValue: indexPath.section) ?? .access {
        case .access:
            guard canEdit(.access) else { return }
            updateAccess(AccessOption.allCases[indexPath.row])
        case .directory:
            if DirectoryRow(rawValue: indexPath.row) == .alias,
               canEdit(.alias) {
                presentAliasEditor()
            }
        case .encryption:
            break
        case .history:
            guard canEdit(.history) else { return }
            updateHistory(availableHistoryOptions[indexPath.row])
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }

    @objc private func directorySwitchChanged(_ sender: UISwitch) {
        updateDirectoryVisibility(isVisible: sender.isOn)
    }

    @objc private func encryptionSwitchChanged(_ sender: UISwitch) {
        guard sender.isOn else {
            tableView.reloadData()
            return
        }
        confirmEnableEncryption()
    }
}

private enum RoomSecurityPrivacyError: LocalizedError {
    case clientUnavailable
    case missingServerName
    case emptyAlias
    case invalidAlias
    case aliasTaken
    case aliasRequiredForDirectory
    case aliasPublishFailed

    var errorDescription: String? {
        switch self {
        case .clientUnavailable:
            return String(localized: "Matrix client is not ready.")
        case .missingServerName:
            return String(localized: "Cannot determine the server name for the room address.")
        case .emptyAlias:
            return String(localized: "Room address is required.")
        case .invalidAlias:
            return String(localized: "Room address contains unsupported characters.")
        case .aliasTaken:
            return String(localized: "This room address is already taken.")
        case .aliasRequiredForDirectory:
            return String(localized: "Add a room address before showing the room in the directory.")
        case .aliasPublishFailed:
            return String(localized: "Could not publish this room address.")
        }
    }
}

private final class RoomSecurityPrivacyInfoListener: RoomInfoListener {
    private let callback: @Sendable (RoomInfo) -> Void

    init(callback: @escaping @Sendable (RoomInfo) -> Void) {
        self.callback = callback
    }

    func call(roomInfo: RoomInfo) {
        callback(roomInfo)
    }
}
