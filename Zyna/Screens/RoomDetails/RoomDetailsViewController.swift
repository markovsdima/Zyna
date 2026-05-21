//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK
import PhotosUI

final class RoomDetailsViewController: ASDKViewController<RoomDetailsNode> {

    private enum PendingAvatarChange {
        case none
        case set(Data)
        case remove
    }

    private struct DirectRoomState {
        var isDirect: Bool
        var userId: String?
        var displayName: String?
        var avatarMxcUrl: String?
        var profileTask: Task<Void, Never>?
        var profileRevision: UInt64 = 0

        init(userId: String?) {
            self.isDirect = userId != nil
            self.userId = userId
        }
    }

    var onBack: (() -> Void)?
    var onSearchTapped: (() -> Void)?
    var onInviteMembersTapped: (() -> Void)?
    var onMembersTapped: (() -> Void)?
    var onProfileTapped: ((String) -> Void)?
    var onPinnedMessagesTapped: (() -> Void)?
    var onSecurityPrivacyTapped: (() -> Void)?
    var onRolesPermissionsTapped: (() -> Void)?

    private let room: Room
    private let memberCount: Int?
    private var directState: DirectRoomState
    private let glassTopBar = GlassTopBar()
    private var voicePlayerHost: EmbeddedVoiceTopPlayerHost?

    private var isEditingDetails = false
    private var isSavingChanges = false
    private var loadedRoomName = "Group"
    private var loadedHasAvatar = false
    private var pendingAvatarChange: PendingAvatarChange = .none
    private var roomInfoTask: Task<Void, Never>?
    private var roomInfoSubscription: TaskHandle?

    init(
        room: Room,
        memberCount: Int?,
        directUserId: String? = nil,
        audioPlayer: AudioPlayerService? = nil
    ) {
        self.room = room
        self.memberCount = memberCount
        self.directState = DirectRoomState(userId: directUserId)
        super.init(node: RoomDetailsNode())
        node.setDirectRoom(directState.isDirect)
        node.setDirectProfileAvailable(directUserId != nil)
        self.voicePlayerHost = audioPlayer.map {
            EmbeddedVoiceTopPlayerHost(viewController: self, audioPlayer: $0)
        }
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupGlassTopBar()
        setupVoicePlayerHost()

        node.onSearchTapped = { [weak self] in
            self?.onSearchTapped?()
        }

        node.onAvatarTapped = { [weak self] in
            guard let self, self.isEditingDetails else { return }
            self.presentAvatarPicker()
        }

        node.onRemoveAvatarTapped = { [weak self] in
            self?.removeAvatarRequested()
        }

        node.onInviteTapped = { [weak self] in
            self?.onInviteMembersTapped?()
        }

        node.onMembersTapped = { [weak self] in
            self?.onMembersTapped?()
        }

        node.onProfileTapped = { [weak self] in
            guard let self, let userId = self.directState.userId else { return }
            self.onProfileTapped?(userId)
        }

        node.onPinnedMessagesTapped = { [weak self] in
            self?.onPinnedMessagesTapped?()
        }

        node.onSecurityPrivacyTapped = { [weak self] in
            self?.onSecurityPrivacyTapped?()
        }

        node.onRolesPermissionsTapped = { [weak self] in
            self?.onRolesPermissionsTapped?()
        }

        node.setEditing(false)
        applyRoomState()
        loadDirectProfileIfNeeded()
        loadRoomInfo()
        subscribeToRoomInfoUpdates()
    }

    deinit {
        roomInfoTask?.cancel()
        directState.profileTask?.cancel()
        roomInfoSubscription?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        voicePlayerHost?.layout()
        glassTopBar.updateLayout(in: view)
        let target = glassTopBar.coveredHeight + 24
        if abs(target - node.topInset) > 0.5 {
            node.topInset = target
            node.setNeedsLayout()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        voicePlayerHost?.refresh()
        GlassService.shared.setNeedsCapture()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        node.bottomInset = max(view.safeAreaInsets.bottom + 16, 16)
        node.setNeedsLayout()
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .appBG
        glassTopBar.sourceView = node.contentNode.view
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar
        rebuildGlassItems(editing: false)
    }

    private func setupVoicePlayerHost() {
        voicePlayerHost?.onVisibilityChanged = { [weak self] in
            self?.view.setNeedsLayout()
            GlassService.shared.setNeedsCapture()
        }
        voicePlayerHost?.install()
        node.voicePlayerView = voicePlayerHost?.accessibilityView
    }

    private func rebuildGlassItems(editing: Bool) {
        let backIcon = AppIcon.chevronBackward.template(size: 17, weight: .semibold)

        var items: [GlassTopBar.Item] = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.handleBackTapped() }
            ),
            .flexibleSpace
        ]

        if !directState.isDirect {
            let trailingIcon: UIImage
            let trailingLabel: String

            if editing {
                trailingIcon = AppIcon.checkmark.template(size: 17, weight: .semibold)
                trailingLabel = String(localized: "Done")
            } else {
                trailingIcon = AppIcon.pencil.template(size: 17, weight: .medium)
                trailingLabel = String(localized: "Edit")
            }

            items.append(.circleButton(
                icon: trailingIcon,
                accessibilityLabel: trailingLabel,
                action: { [weak self] in self?.editTapped() }
            ))
        }

        glassTopBar.items = items
    }

    private func applyRoomState() {
        let name: String
        let avatarUrl: String?
        let fallbackUserId: String?

        if directState.isDirect {
            name = room.displayName()?.nilIfEmpty
                ?? directState.displayName?.nilIfEmpty
                ?? directState.userId
                ?? "Chat"
            avatarUrl = room.avatarUrl() ?? directState.avatarMxcUrl
            fallbackUserId = directState.userId
        } else {
            name = room.displayName() ?? "Group"
            avatarUrl = room.avatarUrl()
            fallbackUserId = nil
        }

        loadedRoomName = name
        loadedHasAvatar = avatarUrl != nil
        node.update(
            name: name,
            memberCount: directState.isDirect ? nil : memberCount,
            avatarMxcUrl: avatarUrl,
            fallbackUserId: fallbackUserId
        )
    }

    private func loadRoomInfo() {
        node.updateTags(Self.tags(encryptionState: room.encryptionState()))
        roomInfoTask?.cancel()
        roomInfoTask = Task { [weak self] in
            guard let self else { return }
            guard let info = try? await self.room.roomInfo() else { return }
            await MainActor.run { [weak self] in
                self?.applyRoomInfo(info)
            }
        }
    }

    private func subscribeToRoomInfoUpdates() {
        let listener = RoomDetailsInfoListener { [weak self] info in
            DispatchQueue.main.async { [weak self] in
                self?.applyRoomInfo(info)
            }
        }
        roomInfoSubscription = room.subscribeToRoomInfoUpdates(listener: listener)
    }

    private func applyRoomInfo(_ info: RoomInfo) {
        setDirectRoom(info.isDirect)
        updateDirectUserId(info.isDirect ? info.heroes.first?.userId : nil)
        node.updateTags(info.isDirect ? Self.directTags(from: info) : Self.tags(from: info))
        node.updatePinnedMessagesCount(info.pinnedEventIds.count)
    }

    private func setDirectRoom(_ isDirectRoom: Bool) {
        guard directState.isDirect != isDirectRoom else { return }

        directState.isDirect = isDirectRoom
        if isDirectRoom {
            pendingAvatarChange = .none
            isEditingDetails = false
            node.setEditing(false)
        }
        node.setDirectRoom(isDirectRoom)
        rebuildGlassItems(editing: isEditingDetails)
        applyRoomState()
    }

    private func updateDirectUserId(_ userId: String?) {
        guard directState.userId != userId else { return }

        directState.userId = userId
        directState.displayName = nil
        directState.avatarMxcUrl = nil
        node.setDirectProfileAvailable(userId != nil)
        applyRoomState()
        loadDirectProfileIfNeeded()
    }

    private func loadDirectProfileIfNeeded() {
        directState.profileTask?.cancel()
        directState.profileRevision &+= 1
        let revision = directState.profileRevision

        guard directState.isDirect,
              let userId = directState.userId,
              let client = MatrixClientService.shared.client
        else { return }

        directState.profileTask = Task { [weak self] in
            let profile = try? await client.getProfile(userId: userId)
            await MainActor.run { [weak self] in
                guard let self,
                      self.directState.profileRevision == revision,
                      self.directState.userId == userId else { return }
                self.directState.displayName = profile?.displayName
                self.directState.avatarMxcUrl = profile?.avatarUrl
                self.applyRoomState()
            }
        }
    }

    private static func tags(from info: RoomInfo) -> [RoomDetailsTag] {
        tags(
            encryptionState: info.encryptionState,
            joinRule: info.joinRule,
            historyVisibility: info.historyVisibility
        )
    }

    private static func directTags(from info: RoomInfo) -> [RoomDetailsTag] {
        [encryptionTag(info.encryptionState)]
    }

    private static func tags(
        encryptionState: EncryptionState,
        joinRule: JoinRule? = nil,
        historyVisibility: RoomHistoryVisibility? = nil
    ) -> [RoomDetailsTag] {
        var tags: [RoomDetailsTag] = [encryptionTag(encryptionState)]
        if let accessTag = accessTag(joinRule: joinRule) {
            tags.append(accessTag)
        }
        if let historyVisibility {
            tags.append(historyTag(historyVisibility))
        }
        return tags
    }

    private static func encryptionTag(_ state: EncryptionState) -> RoomDetailsTag {
        switch state {
        case .encrypted:
            return RoomDetailsTag(title: String(localized: "Encrypted"), style: .positive)
        case .notEncrypted:
            return RoomDetailsTag(title: String(localized: "Not encrypted"), style: .warning)
        case .unknown:
            return RoomDetailsTag(title: String(localized: "Encryption unknown"), style: .neutral)
        }
    }

    private static func accessTag(joinRule: JoinRule?) -> RoomDetailsTag? {
        guard let joinRule else { return nil }
        switch joinRule {
        case .public:
            return RoomDetailsTag(title: String(localized: "Public"), style: .positive)
        case .invite, .private:
            return RoomDetailsTag(title: String(localized: "Private"), style: .neutral)
        case .knock, .knockRestricted(rules: _):
            return RoomDetailsTag(title: String(localized: "Ask to join"), style: .neutral)
        case .restricted(rules: _):
            return RoomDetailsTag(title: String(localized: "Restricted access"), style: .neutral)
        case .custom(repr: _):
            return RoomDetailsTag(title: String(localized: "Custom access"), style: .neutral)
        }
    }

    private static func historyTag(_ visibility: RoomHistoryVisibility) -> RoomDetailsTag {
        switch visibility {
        case .shared:
            return RoomDetailsTag(title: String(localized: "New members can see history"), style: .neutral)
        case .invited:
            return RoomDetailsTag(title: String(localized: "History from invite"), style: .neutral)
        case .joined:
            return RoomDetailsTag(title: String(localized: "History from joining"), style: .neutral)
        case .worldReadable:
            return RoomDetailsTag(title: String(localized: "History visible to anyone"), style: .warning)
        case .custom(value: _):
            return RoomDetailsTag(title: String(localized: "Custom history"), style: .neutral)
        }
    }

    private func setEditing(_ editing: Bool) {
        let effectiveEditing = editing && !directState.isDirect
        isEditingDetails = effectiveEditing
        node.setEditing(effectiveEditing)
        rebuildGlassItems(editing: effectiveEditing)
    }

    private func handleBackTapped() {
        guard !isSavingChanges else { return }
        if isEditingDetails {
            cancelEditing()
        } else {
            onBack?()
        }
    }

    private func editTapped() {
        guard !directState.isDirect, !isSavingChanges else { return }
        if isEditingDetails {
            saveEdits()
        } else {
            pendingAvatarChange = .none
            setEditing(true)
        }
    }

    private func cancelEditing() {
        pendingAvatarChange = .none
        setEditing(false)
        applyRoomState()
    }

    private func presentAvatarPicker() {
        guard isEditingDetails, !isSavingChanges else { return }

        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func removeAvatarRequested() {
        guard isEditingDetails, !isSavingChanges else { return }

        switch pendingAvatarChange {
        case .remove:
            break
        case .set:
            pendingAvatarChange = loadedHasAvatar ? .remove : .none
        case .none:
            guard loadedHasAvatar else { return }
            pendingAvatarChange = .remove
        }

        node.removeAvatarLocally()
    }

    private func saveEdits() {
        let newName = node.editingName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? loadedRoomName

        guard !newName.isEmpty else {
            showErrorAlert(
                title: "Group name is required",
                message: "Choose a name before saving changes."
            )
            return
        }

        let nameChanged = newName != loadedRoomName
        let avatarChanged: Bool = {
            switch pendingAvatarChange {
            case .none: return false
            case .set, .remove: return true
            }
        }()

        guard nameChanged || avatarChanged else {
            cancelEditing()
            return
        }

        isSavingChanges = true

        Task { [weak self] in
            guard let self else { return }
            do {
                if nameChanged {
                    try await self.room.setName(name: newName)
                }

                switch self.pendingAvatarChange {
                case .none:
                    break
                case .set(let jpegData):
                    try await self.room.uploadAvatar(
                        mimeType: "image/jpeg",
                        data: jpegData,
                        mediaInfo: nil
                    )
                case .remove:
                    try await self.room.removeAvatar()
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let resultingHasAvatar = self.nodeHasAvatarAfterPendingSave()
                    self.node.updateNameLocally(newName)
                    self.pendingAvatarChange = .none
                    self.loadedRoomName = newName
                    self.loadedHasAvatar = resultingHasAvatar
                    self.setEditing(false)
                    self.isSavingChanges = false
                    self.scheduleRoomRefresh()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.pendingAvatarChange = .none
                    self.isSavingChanges = false
                    self.applyRoomState()
                    self.showErrorAlert(
                        title: "Failed to save group changes",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func nodeHasAvatarAfterPendingSave() -> Bool {
        switch pendingAvatarChange {
        case .none:
            return loadedHasAvatar
        case .set:
            return true
        case .remove:
            return false
        }
    }

    private func scheduleRoomRefresh() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run { [weak self] in
                guard let self, !self.isEditingDetails else { return }
                self.applyRoomState()
            }
        }
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = UIAlertController(
            title: title,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Accessibility

extension RoomDetailsViewController: AccessibilityFocusProviding {
    /// First element VO focuses on after push: the back button.
    var initialAccessibilityFocus: UIView? {
        glassTopBar.accessibilityElementsInOrder.first
    }
}

extension RoomDetailsViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = results.first else { return }

        result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            if let error {
                print("[room-details] picker load error: \(error)")
                return
            }
            guard let image = object as? UIImage,
                  let jpeg = image.jpegData(compressionQuality: 0.85)
            else { return }

            DispatchQueue.main.async {
                self?.pendingAvatarChange = .set(jpeg)
                self?.node.updateAvatarLocally(image: image)
            }
        }
    }
}

private final class RoomDetailsInfoListener: RoomInfoListener {
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
