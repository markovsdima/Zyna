//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import PhotosUI

final class ProfileViewController: ASDKViewController<ProfileScreenNode> {

    var onLogout: (() -> Void)?
    var onBack: (() -> Void)?
    var onSearchTapped: (() -> Void)?
    var onMessageTapped: (() -> Void)? {
        didSet { node.content.onMessageTapped = onMessageTapped }
    }

    var messageButtonTitle: String? {
        didSet { node.content.messageButtonTitle = messageButtonTitle }
    }

    private let viewModel: ProfileViewModel
    private let glassTopBar = GlassTopBar()
    private var cancellables = Set<AnyCancellable>()

    init(mode: ProfileMode) {
        self.viewModel = ProfileViewModel(mode: mode)
        super.init(node: ProfileScreenNode(mode: mode))
        // .other = pushed sub-screen (from Contacts or Chat title) →
        // hide tab bar. .own = the Profile tab root → keep tab bar.
        if case .other = mode {
            hidesBottomBarWhenPushed = true
        }
        viewModel.onLogout = { [weak self] in self?.onLogout?() }
        setupCallbacks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupGlassTopBar()
        bindViewModel()
        viewModel.load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Force glass recapture after navigation push completes.
        GlassService.shared.setNeedsCapture()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        node.content.topInset = view.safeAreaInsets.top + barContentGap
        node.content.bottomInset = max(view.safeAreaInsets.bottom + 16, 16)
        node.content.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glassTopBar.updateLayout(in: view)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            viewModel.cleanup()
        }
    }

    // MARK: - Glass Top Bar

    /// Bar height (44) + margin between bar and first content element.
    private var barContentGap: CGFloat { 44 + 24 }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .appBG
        glassTopBar.sourceView = node.content.view
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar
        rebuildGlassItems(editing: false)
    }

    private func rebuildGlassItems(editing: Bool) {
        var items: [GlassTopBar.Item] = []

        switch viewModel.mode {
        case .other:
            let backIcon = AppIcon.chevronBackward.rendered(size: 17, weight: .semibold, color: AppColor.accent)
            items.append(.circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ))
            items.append(.flexibleSpace)

        case .own:
            items.append(.flexibleSpace)
            let icon: UIImage
            let label: String
            if editing {
                icon = AppIcon.checkmark.rendered(size: 17, weight: .semibold, color: AppColor.accent)
                label = String(localized: "Done")
            } else {
                icon = AppIcon.pencil.rendered(size: 17, weight: .medium, color: AppColor.accent)
                label = String(localized: "Edit")
            }
            items.append(.circleButton(
                icon: icon,
                accessibilityLabel: label,
                action: { [weak self] in self?.editTapped() }
            ))
        }

        glassTopBar.items = items
    }

    private func editTapped() {
        if viewModel.isEditing {
            let newName = node.content.editingName?.trimmingCharacters(in: .whitespacesAndNewlines)
            viewModel.save(displayName: newName, avatarData: nil)
        } else {
            viewModel.toggleEditing()
        }
    }

    // MARK: - Bindings

    private func bindViewModel() {
        Publishers.CombineLatest3(viewModel.$avatar, viewModel.$displayName, viewModel.$userId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avatar, displayName, userId in
                self?.node.content.update(avatar: avatar, displayName: displayName, userId: userId)
            }
            .store(in: &cancellables)

        viewModel.$isEditing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] editing in
                self?.node.content.setEditing(editing)
                self?.rebuildGlassItems(editing: editing)
            }
            .store(in: &cancellables)

        viewModel.$presence
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presence in
                self?.node.content.updatePresence(presence)
            }
            .store(in: &cancellables)
    }

    // MARK: - Callbacks

    private func setupCallbacks() {
        node.content.onLogoutTapped = { [weak self] in
            self?.confirmLogout()
        }
        node.content.onSettingsTapped = {
            print("[profile] Settings tapped")
        }
        node.content.onAvatarTapped = { [weak self] in
            self?.presentAvatarPicker()
        }
        node.content.onSearchTapped = { [weak self] in
            self?.onSearchTapped?()
        }
    }

    // MARK: - Avatar Picker

    private func presentAvatarPicker() {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: - Logout

    private func confirmLogout() {
        let alert = UIAlertController(title: String(localized: "Sign Out"), message: String(localized: "Are you sure?"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Sign Out"), style: .destructive) { [weak self] _ in
            self?.viewModel.logout()
        })
        present(alert, animated: true)
    }
}

// MARK: - PHPickerViewControllerDelegate

extension ProfileViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = results.first else { return }

        result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            if let error { print("[profile] picker load error: \(error)"); return }
            guard let image = object as? UIImage,
                  let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
            DispatchQueue.main.async {
                self?.node.content.updateAvatarLocally(image: image)
                self?.viewModel.save(displayName: nil, avatarData: jpeg)
            }
        }
    }
}
