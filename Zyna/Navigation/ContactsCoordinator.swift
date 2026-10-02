//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import MatrixRustSDK

final class ContactsCoordinator {

    let navigationController = ZynaNavigationController()
    private let audioPlayer: AudioPlayerService

    /// Opens a chat with the selected contact.
    var onOpenChat: ((Room) -> Void)?

    /// Starts a call with the selected contact.
    var onStartCall: ((Room) -> Void)?

    init(audioPlayer: AudioPlayerService) {
        self.audioPlayer = audioPlayer
    }

    func start() {
        let vc = ContactsViewController(audioPlayer: audioPlayer)

        vc.onContactSelected = { [weak self] contact in
            Task { @MainActor in self?.showProfile(for: contact) }
        }

        vc.onCallTapped = { [weak self] contact in
            self?.callContact(contact)
        }

        navigationController.setStack([vc], animated: false)
    }

    // MARK: - Private

    @MainActor private func showProfile(for contact: ContactModel) {
        guard let model = PersonProfileViewModel.make(userID: contact.userId,
            title: contact.displayName, avatarURL: contact.avatar.mxcAvatarURL,
            preferredRoomID: contact.roomId) else { return }
        let vc = RoomProfileViewController(personModel: model, audioPlayer: audioPlayer)
        vc.onBack = { [weak self] in self?.navigationController.pop() }
        model.onOpenChat = { [weak self, weak vc] room in
            guard let self, let vc, self.navigationController.topViewController === vc else { return }
            self.onOpenChat?(room)
        }
        navigationController.push(vc)
    }

    private func callContact(_ contact: ContactModel) {
        guard let client = MatrixClientService.shared.client,
              let sessionID = MatrixClientService.shared.currentLocalSessionId else { return }
        Task { @MainActor [weak self] in
            do {
                let room = try await DirectConversationService.shared.open(userID: contact.userId,
                    client: client, sessionID: sessionID, preferredRoomID: contact.roomId)
                guard MatrixClientService.shared.currentLocalSessionId == sessionID else { return }
                self?.onStartCall?(room)
            } catch {
                guard let self, MatrixClientService.shared.currentLocalSessionId == sessionID,
                      let presenter = self.navigationController.topViewController,
                      presenter.presentedViewController == nil else { return }
                let alert = UIAlertController(title: String(localized: "Something went wrong"),
                    message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                presenter.present(alert, animated: true)
            }
        }
    }
}
