//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import PhotosUI

final class ProfileViewController: ASDKViewController<ProfileNode> {

    var onLogout: (() -> Void)?

    private let viewModel: ProfileViewModel
    private var cancellables = Set<AnyCancellable>()

    init(mode: ProfileMode) {
        self.viewModel = ProfileViewModel(mode: mode)
        super.init(node: ProfileNode(mode: mode))
        viewModel.onLogout = { [weak self] in self?.onLogout?() }
        setupCallbacks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupNavigationBar()
        bindViewModel()
        viewModel.load()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        node.topInset = view.safeAreaInsets.top + 24
        node.bottomInset = max(view.safeAreaInsets.bottom + 16, 16)
        node.setNeedsLayout()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            viewModel.cleanup()
        }
    }

    // MARK: - Navigation Bar

    private func setupNavigationBar() {
        if case .own = viewModel.mode {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "pencil"),
                style: .plain,
                target: self,
                action: #selector(editTapped)
            )
        }
    }

    @objc private func editTapped() {
        if viewModel.isEditing {
            // Save
            let newName = node.editingName?.trimmingCharacters(in: .whitespacesAndNewlines)
            viewModel.save(displayName: newName, avatarData: nil)
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "pencil"),
                style: .plain, target: self, action: #selector(editTapped)
            )
        } else {
            // Enter edit mode
            viewModel.toggleEditing()
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Done", style: .done, target: self, action: #selector(editTapped)
            )
        }
    }

    // MARK: - Bindings

    private func bindViewModel() {
        Publishers.CombineLatest3(viewModel.$avatar, viewModel.$displayName, viewModel.$userId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avatar, displayName, userId in
                self?.node.update(avatar: avatar, displayName: displayName, userId: userId)
            }
            .store(in: &cancellables)

        viewModel.$isEditing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] editing in
                self?.node.setEditing(editing)
            }
            .store(in: &cancellables)

        viewModel.$presence
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presence in
                self?.node.updatePresence(presence)
            }
            .store(in: &cancellables)
    }

    // MARK: - Callbacks

    private func setupCallbacks() {
        node.onLogoutTapped = { [weak self] in
            self?.confirmLogout()
        }
        node.onSettingsTapped = {
            print("[profile] Settings tapped")
        }
        node.onAvatarTapped = { [weak self] in
            self?.presentAvatarPicker()
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
        let alert = UIAlertController(title: "Выход", message: "Вы уверены?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Выйти", style: .destructive) { [weak self] _ in
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
                self?.node.updateAvatarLocally(image: image)
                self?.viewModel.save(displayName: nil, avatarData: jpeg)
            }
        }
    }
}
