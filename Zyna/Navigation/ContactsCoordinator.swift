//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import MatrixRustSDK

final class ContactsCoordinator {

    let navigationController = ZynaNavigationController()

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

        navigationController.setStack([vc], animated: false)
    }

    // MARK: - Private

    private func showProfile(for contact: ContactModel) {
        let hasDM = contact.roomId != nil
            || (try? MatrixClientService.shared.client?.getDmRoom(userId: contact.userId)) != nil

        let vc = ProfileViewController(mode: .other(userId: contact.userId))
        vc.onSearchTapped = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onBack = { [weak self] in
            self?.navigationController.pop()
        }
        vc.onMessageTapped = { [weak self] in
            self?.openChat(for: contact)
        }
        vc.messageButtonTitle = hasDM
            ? "Перейти в чат"
            : "Новый чат с \(contact.displayName)"
        navigationController.push(vc)
    }

    private func openChat(for contact: ContactModel) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, let room = await Self.resolveRoom(for: contact) else { return }
            await MainActor.run {
                DispatchQueue.main.async { [weak self] in
                    self?.onOpenChat?(room)
                }
            }
        }
    }

    private func callContact(_ contact: ContactModel) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, let room = await Self.resolveRoom(for: contact) else { return }
            await MainActor.run {
                self.onStartCall?(room)
            }
        }
    }

    private static func resolveRoom(for contact: ContactModel) async -> Room? {
        guard let client = MatrixClientService.shared.client else { return nil }

        if let roomId = contact.roomId,
           let room = try? client.getRoom(roomId: roomId) {
            return room
        }

        if let room = try? client.getDmRoom(userId: contact.userId) {
            return room
        }

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
            return try? client.getRoom(roomId: roomId)
        } catch {
            ScopedLog(.ui)("Failed to create DM: \(error)")
            return nil
        }
    }
}
