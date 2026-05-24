//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class SpaceAccessViewController: ASDKViewController<SettingsScreenNode> {

    var onBack: (() -> Void)?

    private enum Section: Int, CaseIterable {
        case access
        case directory

        var title: String {
            switch self {
            case .access:
                return String(localized: "Who Can Join")
            case .directory:
                return String(localized: "Storyline Directory")
            }
        }
    }

    private enum EditableSetting {
        case access
        case directory
        case alias
    }

    private enum AccessOption: CaseIterable {
        case inviteOnly
        case anyone

        var title: String {
            switch self {
            case .inviteOnly:
                return String(localized: "Private Storyline")
            case .anyone:
                return String(localized: "Public Storyline")
            }
        }

        var detail: String {
            switch self {
            case .inviteOnly:
                return String(localized: "Only invited people can join this Storyline.")
            case .anyone:
                return String(localized: "Anyone can join this Storyline without an invite.")
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
            .title(text: String(localized: "Storyline Access"), subtitle: nil)
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
            let loadedInfo = try? await room.roomInfo()
            let loadedPowerLevels: RoomPowerLevels?
            if let infoPowerLevels = loadedInfo?.powerLevels {
                loadedPowerLevels = infoPowerLevels
            } else {
                loadedPowerLevels = try? await room.getPowerLevels()
            }
            let loadedVisibility = try? await room.getRoomVisibility()

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.roomInfo = loadedInfo ?? self.roomInfo
                self.powerLevels = loadedPowerLevels ?? self.powerLevels
                self.directoryVisibility = loadedVisibility ?? self.directoryVisibility ?? .private
                self.isLoading = false
                self.tableView.reloadData()
                GlassService.shared.setNeedsCapture()
            }
        }
    }

    private func subscribeToRoomInfoUpdates() {
        let listener = SpaceAccessRoomInfoListener { [weak self] info in
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
        GlassService.shared.setNeedsCapture()
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

    private func updateDirectoryVisibility(isVisible: Bool) {
        guard canEdit(.directory) else {
            tableView.reloadData()
            return
        }
        guard displayedAlias != nil else {
            presentError(SpaceAccessError.aliasRequiredForDirectory)
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
                let loadedInfo = try? await room.roomInfo()
                let loadedPowerLevels: RoomPowerLevels?
                if let infoPowerLevels = loadedInfo?.powerLevels {
                    loadedPowerLevels = infoPowerLevels
                } else {
                    loadedPowerLevels = try? await room.getPowerLevels()
                }
                let loadedVisibility = try? await room.getRoomVisibility()

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
            GlassService.shared.setNeedsCapture()
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
            presentError(SpaceAccessError.missingServerName)
            return
        }

        let currentLocalPart = editableAlias.flatMap(Self.aliasLocalPart)
        let proposedLocalPart = currentLocalPart
            ?? roomInfo?.displayName.flatMap(Self.defaultAliasLocalPart)
            ?? room.displayName().flatMap(Self.defaultAliasLocalPart)
            ?? ""

        let alert = UIAlertController(
            title: String(localized: "Storyline Address"),
            message: String(localized: "Use only the local part before the server name."),
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = proposedLocalPart
            textField.placeholder = String(localized: "Storyline address")
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
            presentError(SpaceAccessError.emptyAlias)
            return
        }

        let desiredAlias = "#\(normalizedLocalPart):\(serverName)"
        guard isRoomAliasFormatValid(alias: desiredAlias) else {
            presentError(SpaceAccessError.invalidAlias)
            return
        }

        guard desiredAlias != editableAlias else { return }

        performSavingOperation { [room, weak self] in
            guard let self else { return }
            guard let client = MatrixClientService.shared.client else {
                throw SpaceAccessError.clientUnavailable
            }

            let aliasAlreadyBelongsToRoom = await MainActor.run {
                self.aliases.contains(desiredAlias)
            }
            if !aliasAlreadyBelongsToRoom {
                guard try await client.isRoomAliasAvailable(alias: desiredAlias) else {
                    throw SpaceAccessError.aliasTaken
                }

                guard try await room.publishRoomAliasInRoomDirectory(alias: desiredAlias) else {
                    throw SpaceAccessError.aliasPublishFailed
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
            title: String(localized: "Could Not Save Storyline Access"),
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
        let localPart = MatrixAliasLocalPart.generated(from: roomName)
        return localPart.isEmpty ? nil : localPart
    }

    private static func normalizedAliasLocalPart(_ value: String, serverName: String) -> String {
        MatrixAliasLocalPart.normalizedUserInput(value, serverName: serverName)
    }

    private static func aliasLocalPart(_ alias: String) -> String {
        var value = alias
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        return value.split(separator: ":").first.flatMap(String.init) ?? ""
    }
}

extension SpaceAccessViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) ?? .access {
        case .access:
            return AccessOption.allCases.count
        case .directory:
            return DirectoryRow.allCases.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        (Section(rawValue: section) ?? .access).title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) ?? .access {
        case .access:
            if selectedAccess == nil, roomInfo?.joinRule != nil {
                return String(localized: "This Storyline currently uses an access rule Zyna cannot edit directly. Choosing an option will replace it.")
            }
            return nil
        case .directory:
            if displayedAlias == nil {
                return String(localized: "A Storyline address is required before the Storyline can be shown in public search.")
            }
            return String(localized: "Directory visibility controls whether this Storyline can be found in public search.")
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) ?? .access {
        case .access:
            let option = AccessOption.allCases[indexPath.row]
            let enabled = !isSaving && canEdit(.access)
            return optionCell(
                title: option.title,
                detail: disabledDetail(for: .access) ?? option.detail,
                isSelected: selectedAccess == option,
                isEnabled: enabled
            )
        case .directory:
            return directoryCell(row: DirectoryRow(rawValue: indexPath.row) ?? .alias)
        }
    }

    private func optionCell(
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
        cell.accessoryType = isSelected ? .checkmark : .none
        cell.tintColor = AppColor.accent
        applyEnabledState(isEnabled, to: cell, allowsSelection: true)
        return cell
    }

    private func directoryCell(row: DirectoryRow) -> UITableViewCell {
        switch row {
        case .alias:
            let identifier = "valueCell"
            let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
                ?? UITableViewCell(style: .value1, reuseIdentifier: identifier)
            configureBaseCell(cell)
            cell.textLabel?.text = String(localized: "Storyline Address")
            cell.detailTextLabel?.text = displayedAlias ?? String(localized: "Not Set")
            cell.accessoryType = .disclosureIndicator
            applyEnabledState(!isSaving && canEdit(.alias), to: cell, allowsSelection: true)
            return cell
        case .visibility:
            let identifier = "switchCell"
            let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
            configureBaseCell(cell)
            cell.textLabel?.text = String(localized: "Visible in Storyline Directory")
            if let disabled = disabledDetail(for: .directory) {
                cell.detailTextLabel?.text = disabled
            } else if isLoading || directoryVisibility == nil {
                cell.detailTextLabel?.text = String(localized: "Loading")
            } else if displayedAlias == nil {
                cell.detailTextLabel?.text = String(localized: "Storyline address required")
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

    private func configureBaseCell(_ cell: UITableViewCell) {
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.contentView.alpha = 1
        cell.isUserInteractionEnabled = true
        cell.selectionStyle = .default
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.textLabel?.font = .systemFont(ofSize: 17)
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.font = .systemFont(ofSize: 13)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
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
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }

    @objc private func directorySwitchChanged(_ sender: UISwitch) {
        updateDirectoryVisibility(isVisible: sender.isOn)
    }
}

private enum SpaceAccessError: LocalizedError {
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
            return String(localized: "Cannot determine the server name for the Storyline address.")
        case .emptyAlias:
            return String(localized: "Storyline address is required.")
        case .invalidAlias:
            return String(localized: "Invalid Storyline address.")
        case .aliasTaken:
            return String(localized: "This Storyline address is already taken.")
        case .aliasRequiredForDirectory:
            return String(localized: "A Storyline address is required before the Storyline can be shown in public search.")
        case .aliasPublishFailed:
            return String(localized: "Could not publish the Storyline address.")
        }
    }
}

private final class SpaceAccessRoomInfoListener: RoomInfoListener {
    private let callback: @Sendable (RoomInfo) -> Void

    init(callback: @escaping @Sendable (RoomInfo) -> Void) {
        self.callback = callback
    }

    func call(roomInfo: RoomInfo) {
        callback(roomInfo)
    }
}
