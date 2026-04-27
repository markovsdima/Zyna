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

    var onBack: (() -> Void)?
    var onSearchTapped: (() -> Void)?
    var onInviteMembersTapped: (() -> Void)?
    var onMembersTapped: (() -> Void)?

    private let room: Room
    private let memberCount: Int?
    private let glassTopBar = GlassTopBar()

    private var isEditingDetails = false
    private var isSavingChanges = false
    private var loadedRoomName = "Group"
    private var loadedHasAvatar = false
    private var pendingAvatarChange: PendingAvatarChange = .none

    init(room: Room, memberCount: Int?) {
        self.room = room
        self.memberCount = memberCount
        super.init(node: RoomDetailsNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupGlassTopBar()

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

        node.setEditing(false)
        applyRoomState()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glassTopBar.updateLayout(in: view)
        let target = glassTopBar.coveredHeight + 24
        if abs(target - node.topInset) > 0.5 {
            node.topInset = target
            node.setNeedsLayout()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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

    private func rebuildGlassItems(editing: Bool) {
        let backIcon = AppIcon.chevronBackward.rendered(size: 17, weight: .semibold, color: AppColor.accent)
        let trailingIcon: UIImage
        let trailingLabel: String

        if editing {
            trailingIcon = AppIcon.checkmark.rendered(size: 17, weight: .semibold, color: AppColor.accent)
            trailingLabel = String(localized: "Done")
        } else {
            trailingIcon = AppIcon.pencil.rendered(size: 17, weight: .medium, color: AppColor.accent)
            trailingLabel = String(localized: "Edit")
        }

        glassTopBar.items = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.handleBackTapped() }
            ),
            .flexibleSpace,
            .circleButton(
                icon: trailingIcon,
                accessibilityLabel: trailingLabel,
                action: { [weak self] in self?.editTapped() }
            )
        ]
    }

    private func applyRoomState() {
        let name = room.displayName() ?? "Group"
        let avatarUrl = room.avatarUrl()
        loadedRoomName = name
        loadedHasAvatar = avatarUrl != nil
        node.update(name: name, memberCount: memberCount, avatarMxcUrl: avatarUrl)
    }

    private func setEditing(_ editing: Bool) {
        isEditingDetails = editing
        node.setEditing(editing)
        rebuildGlassItems(editing: editing)
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
        guard !isSavingChanges else { return }
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
