//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK
import PhotosUI

final class SpaceSettingsViewController: ASDKViewController<SettingsScreenNode> {

    private enum PendingAvatarChange {
        case none
        case set(image: UIImage, data: Data)
        case remove
    }

    private enum Section: Int, CaseIterable {
        case organization
        case administration

        var title: String {
            switch self {
            case .organization:
                return String(localized: "Organization")
            case .administration:
                return String(localized: "Administration")
            }
        }
    }

    private enum OrganizationRow: Int, CaseIterable {
        case children
        case parentStorylines
    }

    private enum AdministrationRow: Int, CaseIterable {
        case access
        case permissions
        case members
    }

    var onBack: (() -> Void)?
    var onProfileUpdated: ((RoomModel) -> Void)?
    var onAccessTapped: (() -> Void)?
    var onPermissionsTapped: (() -> Void)?
    var onParentStorylinesTapped: (() -> Void)?
    var onMembersTapped: (() -> Void)?

    private var space: RoomModel
    private let room: Room
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let glassTopBar = GlassTopBar()
    private let headerView = SpaceSettingsHeaderView()
    private var voicePlayerHost: EmbeddedVoiceTopPlayerHost?

    private var roomInfo: RoomInfo?
    private var powerLevels: RoomPowerLevels?
    private var roomInfoTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var roomInfoSubscription: TaskHandle?
    private var progressAlert: UIAlertController?

    private var isEditingProfile = false
    private var isSaving = false
    private var loadedName: String
    private var loadedTopic: String
    private var loadedAvatarURL: String?
    private var pendingAvatarChange: PendingAvatarChange = .none

    init(
        space: RoomModel,
        room: Room,
        audioPlayer: AudioPlayerService? = nil
    ) {
        self.space = space
        self.room = room
        self.loadedName = space.name.isEmpty ? String(localized: "Untitled") : space.name
        self.loadedTopic = room.topic() ?? ""
        self.loadedAvatarURL = room.avatarUrl() ?? space.avatar.mxcAvatarURL
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
        setupHeader()
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
        updateHeaderFrame()
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
        rebuildGlassItems()
    }

    private func setupVoicePlayerHost() {
        voicePlayerHost?.onVisibilityChanged = { [weak self] in
            self?.view.setNeedsLayout()
            GlassService.shared.setNeedsCapture()
        }
        voicePlayerHost?.install()
        node.voicePlayerView = voicePlayerHost?.accessibilityView
    }

    private func setupHeader() {
        headerView.onAvatarTapped = { [weak self] in
            self?.presentAvatarPicker()
        }
        headerView.onRemoveAvatarTapped = { [weak self] in
            self?.removeAvatarRequested()
        }
        tableView.tableHeaderView = headerView
        applyHeaderState()
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

    private func updateHeaderFrame() {
        let height = headerView.preferredHeight(isEditing: isEditingProfile)
        let targetFrame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        guard headerView.frame != targetFrame else { return }
        headerView.frame = targetFrame
        tableView.tableHeaderView = headerView
    }

    private func rebuildGlassItems() {
        let backIcon = AppIcon.chevronBackward.template(size: 17, weight: .semibold)
        var items: [GlassTopBar.Item] = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.handleBackTapped() }
            ),
            .title(text: String(localized: "Storyline Settings"), subtitle: nil)
        ]

        if isEditingProfile {
            items.append(.circleButton(
                icon: AppIcon.checkmark.template(size: 17, weight: .semibold),
                accessibilityLabel: String(localized: "Done"),
                action: { [weak self] in self?.saveProfile() }
            ))
        } else if canEditProfile {
            items.append(.circleButton(
                icon: AppIcon.pencil.template(size: 17, weight: .medium),
                accessibilityLabel: String(localized: "Edit"),
                action: { [weak self] in self?.enterProfileEditing() }
            ))
        }

        glassTopBar.items = items
    }

    private func loadState() {
        roomInfoTask?.cancel()
        roomInfoTask = Task { [weak self] in
            guard let self else { return }
            let loadedInfo = try? await room.roomInfo()
            let loadedPowerLevels: RoomPowerLevels?
            if let infoPowerLevels = loadedInfo?.powerLevels {
                loadedPowerLevels = infoPowerLevels
            } else {
                loadedPowerLevels = try? await room.getPowerLevels()
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let loadedInfo {
                    self.applyRoomInfo(loadedInfo)
                }
                self.powerLevels = loadedPowerLevels ?? self.powerLevels
                self.rebuildGlassItems()
                self.applyHeaderState()
                self.tableView.reloadData()
            }
        }
    }

    private func subscribeToRoomInfoUpdates() {
        let listener = SpaceSettingsRoomInfoListener { [weak self] info in
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

        guard !isEditingProfile, !isSaving else {
            tableView.reloadData()
            return
        }

        loadedName = info.displayName?.nilIfEmpty
            ?? room.displayName()?.nilIfEmpty
            ?? space.name.nilIfEmpty
            ?? String(localized: "Untitled")
        loadedTopic = info.topic ?? room.topic() ?? ""
        loadedAvatarURL = info.avatarUrl ?? room.avatarUrl()
        space = space.withSpaceProfile(name: loadedName, avatarURL: loadedAvatarURL)
        onProfileUpdated?(space)
        rebuildGlassItems()
        applyHeaderState()
        tableView.reloadData()
        GlassService.shared.setNeedsCapture()
    }

    private func applyHeaderState(localAvatarImage: UIImage? = nil) {
        var displayedAvatarURL = loadedAvatarURL
        var displayedLocalAvatarImage = localAvatarImage
        switch pendingAvatarChange {
        case .none:
            break
        case .set(let image, _):
            displayedAvatarURL = nil
            displayedLocalAvatarImage = displayedLocalAvatarImage ?? image
        case .remove:
            displayedAvatarURL = nil
        }

        headerView.configure(
            name: loadedName,
            topic: loadedTopic,
            metaText: space.spaceMetaText,
            avatar: AvatarViewModel(
                userId: space.id,
                displayName: loadedName,
                mxcAvatarURL: displayedAvatarURL
            ),
            localAvatarImage: displayedLocalAvatarImage,
            hasAvatar: displayedAvatarURL != nil || displayedLocalAvatarImage != nil,
            isEditing: isEditingProfile,
            canEditName: canEditName,
            canEditTopic: canEditTopic,
            canEditAvatar: canEditAvatar
        )
    }

    private var canEditProfile: Bool {
        canEditName || canEditTopic || canEditAvatar
    }

    private var canEditName: Bool {
        powerLevels?.canOwnUserSendState(stateEvent: .roomName) == true
    }

    private var canEditTopic: Bool {
        powerLevels?.canOwnUserSendState(stateEvent: .roomTopic) == true
    }

    private var canEditAvatar: Bool {
        powerLevels?.canOwnUserSendState(stateEvent: .roomAvatar) == true
    }

    private var accessText: String {
        switch roomInfo?.joinRule {
        case .public:
            return String(localized: "Public")
        case .invite, .private:
            return String(localized: "Private")
        case .knock, .knockRestricted(rules: _):
            return String(localized: "Ask to join")
        case .restricted(rules: _):
            return String(localized: "Restricted access")
        case .custom(repr: _):
            return String(localized: "Custom access")
        case .none:
            return String(localized: "Loading")
        }
    }

    private func handleBackTapped() {
        guard !isSaving else { return }
        if isEditingProfile {
            cancelProfileEditing()
        } else {
            onBack?()
        }
    }

    private func enterProfileEditing() {
        guard !isSaving else { return }
        guard canEditProfile else {
            showErrorAlert(
                title: String(localized: "Storyline Profile"),
                message: String(localized: "You do not have permission to edit this Storyline profile.")
            )
            return
        }
        pendingAvatarChange = .none
        isEditingProfile = true
        rebuildGlassItems()
        applyHeaderState()
        updateHeaderFrame()
    }

    private func cancelProfileEditing() {
        pendingAvatarChange = .none
        isEditingProfile = false
        rebuildGlassItems()
        applyHeaderState()
        updateHeaderFrame()
    }

    private func saveProfile() {
        guard !isSaving else { return }
        let newName = canEditName
            ? headerView.nameText.trimmingCharacters(in: .whitespacesAndNewlines)
            : loadedName
        let newTopic = canEditTopic
            ? headerView.topicText.trimmingCharacters(in: .whitespacesAndNewlines)
            : loadedTopic

        if canEditName, newName.isEmpty {
            showErrorAlert(
                title: String(localized: "Storyline name is required"),
                message: String(localized: "Choose a name before saving changes.")
            )
            return
        }

        let nameChanged = canEditName && newName != loadedName
        let topicChanged = canEditTopic && newTopic != loadedTopic
        let avatarChanged: Bool = {
            guard canEditAvatar else { return false }
            switch pendingAvatarChange {
            case .none: return false
            case .set, .remove: return true
            }
        }()

        guard nameChanged || topicChanged || avatarChanged else {
            cancelProfileEditing()
            return
        }

        isSaving = true
        presentProgress()

        let avatarChange = pendingAvatarChange
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if nameChanged {
                    try await room.setName(name: newName)
                }
                if topicChanged {
                    try await room.setTopic(topic: newTopic)
                }
                switch avatarChange {
                case .none:
                    break
                case .set(_, let data):
                    try await room.uploadAvatar(
                        mimeType: "image/jpeg",
                        data: data,
                        mediaInfo: nil
                    )
                case .remove:
                    try await room.removeAvatar()
                }

                try? await Task.sleep(for: .milliseconds(350))
                let loadedInfo = try? await room.roomInfo()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let loadedInfo {
                        self.roomInfo = loadedInfo
                        self.powerLevels = loadedInfo.powerLevels ?? self.powerLevels
                    }
                    self.loadedName = loadedInfo?.displayName?.nilIfEmpty
                        ?? self.room.displayName()?.nilIfEmpty
                        ?? newName
                    self.loadedTopic = loadedInfo?.topic ?? self.room.topic() ?? newTopic
                    self.loadedAvatarURL = loadedInfo?.avatarUrl ?? self.room.avatarUrl()
                    if case .remove = avatarChange {
                        self.loadedAvatarURL = nil
                    }
                    self.space = self.space.withSpaceProfile(
                        name: self.loadedName,
                        avatarURL: self.loadedAvatarURL
                    )
                    self.onProfileUpdated?(self.space)
                    self.pendingAvatarChange = .none
                    self.isEditingProfile = false
                    self.finishSaving()
                    self.rebuildGlassItems()
                    self.applyHeaderState()
                    self.updateHeaderFrame()
                    self.tableView.reloadData()
                    GlassService.shared.setNeedsCapture()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.pendingAvatarChange = .none
                    self.finishSaving(error: error)
                    self.applyHeaderState()
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
            if let error {
                self.showErrorAlert(
                    title: String(localized: "Failed to save Storyline"),
                    message: error.localizedDescription
                )
            }
        }

        if let progressAlert {
            progressAlert.dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }

    private func presentAvatarPicker() {
        guard isEditingProfile, !isSaving, canEditAvatar else { return }
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func removeAvatarRequested() {
        guard isEditingProfile, !isSaving, canEditAvatar else { return }
        switch pendingAvatarChange {
        case .remove:
            break
        case .set:
            pendingAvatarChange = loadedAvatarURL == nil ? .none : .remove
        case .none:
            guard loadedAvatarURL != nil else { return }
            pendingAvatarChange = .remove
        }
        applyHeaderState()
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = UIAlertController(
            title: title,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

extension SpaceSettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) ?? .organization {
        case .organization:
            return OrganizationRow.allCases.count
        case .administration:
            return AdministrationRow.allCases.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        (Section(rawValue: section) ?? .organization).title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) ?? .organization {
        case .organization:
            return organizationCell(row: OrganizationRow(rawValue: indexPath.row) ?? .children)
        case .administration:
            return administrationCell(row: AdministrationRow(rawValue: indexPath.row) ?? .access)
        }
    }

    private func organizationCell(row: OrganizationRow) -> UITableViewCell {
        switch row {
        case .children:
            let cell = valueCell(identifier: "children")
            cell.textLabel?.text = String(localized: "Chats and Lines")
            cell.detailTextLabel?.text = space.spaceMetaText
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        case .parentStorylines:
            let cell = subtitleCell(identifier: "parentStorylines")
            cell.textLabel?.text = String(localized: "Parent Storylines")
            cell.detailTextLabel?.text = String(localized: "View and repair parent Storyline links")
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    private func administrationCell(row: AdministrationRow) -> UITableViewCell {
        switch row {
        case .access:
            let cell = subtitleCell(identifier: "access")
            cell.textLabel?.text = String(localized: "Access and Visibility")
            cell.detailTextLabel?.text = accessText
            cell.accessoryType = .disclosureIndicator
            return cell
        case .permissions:
            let cell = subtitleCell(identifier: "permissions")
            cell.textLabel?.text = String(localized: "Roles and Permissions")
            cell.detailTextLabel?.text = String(localized: "Edit who can change this Storyline")
            cell.accessoryType = .disclosureIndicator
            return cell
        case .members:
            let cell = valueCell(identifier: "members")
            cell.textLabel?.text = String(localized: "Members")
            if let count = roomInfo?.joinedMembersCount {
                cell.detailTextLabel?.text = "\(count)"
            } else {
                cell.detailTextLabel?.text = String(localized: "Loading")
            }
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    private func subtitleCell(identifier: String) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        configureBaseCell(cell)
        return cell
    }

    private func valueCell(identifier: String) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .value1, reuseIdentifier: identifier)
        configureBaseCell(cell)
        return cell
    }

    private func configureBaseCell(_ cell: UITableViewCell) {
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.selectionStyle = .default
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.textLabel?.font = .systemFont(ofSize: 17)
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.font = .systemFont(ofSize: 13)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isSaving, !isEditingProfile else { return }

        switch Section(rawValue: indexPath.section) ?? .organization {
        case .organization:
            switch OrganizationRow(rawValue: indexPath.row) ?? .children {
            case .children:
                break
            case .parentStorylines:
                onParentStorylinesTapped?()
            }
        case .administration:
            switch AdministrationRow(rawValue: indexPath.row) ?? .access {
            case .access:
                onAccessTapped?()
            case .permissions:
                onPermissionsTapped?()
            case .members:
                onMembersTapped?()
            }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }
}

extension SpaceSettingsViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = results.first else { return }

        result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            if let error {
                ScopedLog(.rooms)("Space settings avatar picker failed: \(error)")
                return
            }
            guard let image = object as? UIImage,
                  let jpeg = image.jpegData(compressionQuality: 0.85)
            else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingAvatarChange = .set(image: image, data: jpeg)
                self.applyHeaderState(localAvatarImage: image)
            }
        }
    }
}

private final class SpaceSettingsHeaderView: UIView {

    var onAvatarTapped: (() -> Void)?
    var onRemoveAvatarTapped: (() -> Void)?

    private enum Metrics {
        static let avatarSize = CGSize(width: 74, height: 74)
        static let avatarCornerRadius: CGFloat = 18
        static let avatarThumbSize = Int(avatarSize.width * ScreenConstants.scale)
    }

    private let containerView = UIView()
    private let avatarButton = UIButton(type: .custom)
    private let avatarImageView = UIImageView()
    private let editBadge = UIImageView()
    private let nameLabel = UILabel()
    private let topicLabel = UILabel()
    private let metaLabel = UILabel()
    private let nameField = UITextField()
    private let topicTextView = UITextView()
    private let removeAvatarButton = UIButton(type: .system)

    private var avatarRevision: UInt64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .appBG
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var nameText: String {
        nameField.text ?? ""
    }

    var topicText: String {
        topicTextView.text ?? ""
    }

    func preferredHeight(isEditing: Bool) -> CGFloat {
        isEditing ? 258 : 146
    }

    func configure(
        name: String,
        topic: String,
        metaText: String,
        avatar: AvatarViewModel,
        localAvatarImage: UIImage?,
        hasAvatar: Bool,
        isEditing: Bool,
        canEditName: Bool,
        canEditTopic: Bool,
        canEditAvatar: Bool
    ) {
        nameLabel.text = name
        topicLabel.text = topic.isEmpty ? String(localized: "No description") : topic
        topicLabel.textColor = topic.isEmpty ? .tertiaryLabel : .secondaryLabel
        metaLabel.text = metaText

        nameField.text = name
        nameField.isEnabled = canEditName
        nameField.alpha = canEditName ? 1 : 0.45

        topicTextView.text = topic
        topicTextView.isEditable = canEditTopic
        topicTextView.alpha = canEditTopic ? 1 : 0.45

        nameLabel.isHidden = isEditing
        topicLabel.isHidden = isEditing
        nameField.isHidden = !isEditing
        topicTextView.isHidden = !isEditing
        removeAvatarButton.isHidden = !isEditing || !canEditAvatar || !hasAvatar
        editBadge.isHidden = !isEditing || !canEditAvatar
        avatarButton.isEnabled = isEditing && canEditAvatar
        avatarButton.accessibilityLabel = String(localized: "Edit")

        configureAvatar(avatar, localAvatarImage: localAvatarImage)
        setNeedsLayout()
    }

    private func setupViews() {
        containerView.backgroundColor = .secondarySystemGroupedBackground
        containerView.layer.cornerRadius = 14
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = Metrics.avatarCornerRadius
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        editBadge.image = AppIcon.pencil.rendered(size: 13, weight: .semibold, color: .white)
        editBadge.backgroundColor = AppColor.accent
        editBadge.contentMode = .center
        editBadge.layer.cornerRadius = 12
        editBadge.clipsToBounds = true
        editBadge.translatesAutoresizingMaskIntoConstraints = false

        avatarButton.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.addTarget(self, action: #selector(avatarTapped), for: .touchUpInside)

        nameLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        topicLabel.font = .systemFont(ofSize: 14)
        topicLabel.numberOfLines = 2
        topicLabel.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = .systemFont(ofSize: 13, weight: .medium)
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 1
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        nameField.font = .systemFont(ofSize: 20, weight: .semibold)
        nameField.textColor = .label
        nameField.backgroundColor = .tertiarySystemGroupedBackground
        nameField.layer.cornerRadius = 10
        nameField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        nameField.leftViewMode = .always
        nameField.returnKeyType = .done
        nameField.translatesAutoresizingMaskIntoConstraints = false

        topicTextView.font = .systemFont(ofSize: 15)
        topicTextView.textColor = .label
        topicTextView.backgroundColor = .tertiarySystemGroupedBackground
        topicTextView.layer.cornerRadius = 10
        topicTextView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        topicTextView.translatesAutoresizingMaskIntoConstraints = false

        removeAvatarButton.setTitle(String(localized: "Remove Photo"), for: .normal)
        removeAvatarButton.setTitleColor(.systemRed, for: .normal)
        removeAvatarButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        removeAvatarButton.addTarget(self, action: #selector(removeAvatarTapped), for: .touchUpInside)
        removeAvatarButton.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(avatarImageView)
        containerView.addSubview(editBadge)
        containerView.addSubview(avatarButton)
        containerView.addSubview(nameLabel)
        containerView.addSubview(topicLabel)
        containerView.addSubview(metaLabel)
        containerView.addSubview(nameField)
        containerView.addSubview(topicTextView)
        containerView.addSubview(removeAvatarButton)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            avatarImageView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 18),
            avatarImageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            avatarImageView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize.width),
            avatarImageView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize.height),

            avatarButton.topAnchor.constraint(equalTo: avatarImageView.topAnchor),
            avatarButton.leadingAnchor.constraint(equalTo: avatarImageView.leadingAnchor),
            avatarButton.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor),
            avatarButton.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor),

            editBadge.widthAnchor.constraint(equalToConstant: 24),
            editBadge.heightAnchor.constraint(equalToConstant: 24),
            editBadge.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 4),
            editBadge.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 4),

            nameLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 19),
            nameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 14),
            nameLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            topicLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5),
            topicLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            topicLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),

            metaLabel.topAnchor.constraint(equalTo: topicLabel.bottomAnchor, constant: 7),
            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),

            nameField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            nameField.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 14),
            nameField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            nameField.heightAnchor.constraint(equalToConstant: 40),

            topicTextView.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10),
            topicTextView.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            topicTextView.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            topicTextView.heightAnchor.constraint(equalToConstant: 82),

            removeAvatarButton.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 8),
            removeAvatarButton.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),

            metaLabel.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -16),
            topicTextView.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -16)
        ])

        isAccessibilityElement = false
        accessibilityElements = [
            avatarButton,
            nameLabel,
            topicLabel,
            metaLabel,
            nameField,
            topicTextView,
            removeAvatarButton
        ]
    }

    private func configureAvatar(_ avatar: AvatarViewModel, localAvatarImage: UIImage?) {
        avatarRevision &+= 1
        let revision = avatarRevision

        if let localAvatarImage {
            avatarImageView.image = Self.roundedAvatarImage(localAvatarImage, cacheKey: "local-\(revision)")
            return
        }

        avatarImageView.image = avatar.roundedRectImage(
            size: Metrics.avatarSize,
            cornerRadius: Metrics.avatarCornerRadius,
            fontSize: 24
        )

        guard let mxc = avatar.mxcAvatarURL else { return }
        if let cached = MediaCache.shared.cachedImage(forUrl: mxc, size: Metrics.avatarThumbSize) {
            avatarImageView.image = Self.roundedAvatarImage(cached, cacheKey: mxc)
            return
        }

        Task { [weak self] in
            guard let image = await MediaCache.shared.loadThumbnail(
                mxcUrl: mxc,
                size: Metrics.avatarThumbSize
            ) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.avatarRevision == revision else { return }
                self.avatarImageView.image = Self.roundedAvatarImage(image, cacheKey: mxc)
            }
        }
    }

    private static func roundedAvatarImage(_ image: UIImage, cacheKey: String) -> UIImage {
        RoundedImageCache.roundedImage(
            source: image,
            size: Metrics.avatarSize,
            cornerRadius: Metrics.avatarCornerRadius,
            cacheKey: cacheKey
        )
    }

    @objc private func avatarTapped() {
        onAvatarTapped?()
    }

    @objc private func removeAvatarTapped() {
        onRemoveAvatarTapped?()
    }
}

private final class SpaceSettingsRoomInfoListener: RoomInfoListener {
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
