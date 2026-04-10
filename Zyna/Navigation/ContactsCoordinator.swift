//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class ContactsCoordinator {

    let navigationController = ASDKNavigationController()

    /// Opens a chat with the selected contact.
    var onOpenChat: ((Room) -> Void)?

    /// Starts a call with the selected contact.
    var onStartCall: ((Room) -> Void)?

    func start() {
        let vc = ContactsViewController()

        vc.onContactSelected = { [weak self] contact in
            self?.showProfile(for: contact)
        }

        vc.onCallTapped = { [weak self] contact in
            self?.callContact(contact)
        }

        navigationController.setViewControllers([vc], animated: false)
    }

    // MARK: - Private

    private func showProfile(for contact: ContactModel) {
        let hasDM = contact.roomId != nil
            || (try? MatrixClientService.shared.client?.getDmRoom(userId: contact.userId)) != nil

        let vc = ProfileViewController(mode: .other(userId: contact.userId))
        vc.onSearchTapped = { [weak self] in
            self?.navigationController.popViewController(animated: true)
        }
        vc.onMessageTapped = { [weak self] in
            self?.openChat(for: contact)
        }
        vc.messageButtonTitle = hasDM
            ? "Перейти в чат"
            : "Новый чат с \(contact.displayName)"
        navigationController.pushViewController(vc, animated: true)
    }

    private func openChat(for contact: ContactModel) {
        resolveRoom(for: contact) { [weak self] room in
            self?.navigationController.popViewController(animated: false)
            self?.onOpenChat?(room)
        }
    }

    private func callContact(_ contact: ContactModel) {
        resolveRoom(for: contact) { [weak self] room in
            self?.onStartCall?(room)
        }
    }

    private func resolveRoom(for contact: ContactModel, completion: @escaping (Room) -> Void) {
        if let roomId = contact.roomId,
           let client = MatrixClientService.shared.client,
           let room = try? client.getRoom(roomId: roomId) {
            completion(room)
            return
        }

        if let client = MatrixClientService.shared.client,
           let room = try? client.getDmRoom(userId: contact.userId) {
            completion(room)
            return
        }

        // Create DM only when explicitly calling
        Task {
            guard let client = MatrixClientService.shared.client else { return }
            do {
                let params = CreateRoomParameters(
                    name: nil, topic: nil,
                    isEncrypted: true, isDirect: true,
                    visibility: .private, preset: .trustedPrivateChat,
                    invite: [contact.userId], avatar: nil,
                    powerLevelContentOverride: nil, joinRuleOverride: nil,
                    historyVisibilityOverride: nil, canonicalAlias: nil
                )
                let roomId = try await client.createRoom(request: params)
                if let room = try? client.getRoom(roomId: roomId) {
                    await MainActor.run { completion(room) }
                }
            } catch {
                ScopedLog(.ui)("Failed to create DM: \(error)")
            }
        }
    }
}
