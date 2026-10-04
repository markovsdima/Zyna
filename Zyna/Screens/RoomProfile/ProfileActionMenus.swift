// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit

@MainActor
enum ProfileActionMenus {
    static func sharing(isPreparing: Bool, isAvailable: Bool, action: @escaping (Bool) -> Void) -> UIMenu {
        let attributes: UIMenuElement.Attributes = isPreparing || !isAvailable ? .disabled : []
        return UIMenu(options: .displayInline, children: [
            UIAction(title: isPreparing ? String(localized: "Preparing link…", table: "RoomProfile")
                : String(localized: "Share link", table: "RoomProfile"),
                image: AppIcon.share.template(size: 18), attributes: attributes) { _ in action(false) },
            UIAction(title: String(localized: "Copy link"),
                image: AppIcon.copy.template(size: 18), attributes: attributes) { _ in action(true) }
        ])
    }

    static func blocking(_ model: UserBlockingViewModel?, presenter: UIViewController) -> UIAction? {
        guard let model, !model.isSelf else { return nil }
        if model.loadError != nil {
            return UIAction(title: String(localized: "Reload block status", table: "RoomProfile")) { [weak model] _ in model?.refresh() }
        }
        let title: String
        if model.isSaving { title = String(localized: "Saving", table: "RoomProfile") }
        else if model.isBlocked == nil { title = String(localized: "Loading block status", table: "RoomProfile") }
        else { title = model.isBlocked == true ? String(localized: "Unblock", table: "RoomProfile") : String(localized: "Block", table: "RoomProfile") }
        return UIAction(title: title, image: AppIcon.personSlash.template(size: 18),
            attributes: model.canChange ? (model.isBlocked == true ? [] : .destructive) : .disabled) { [weak model, weak presenter] _ in
            guard let model, let presenter, model.canChange, let blocked = model.isBlocked else { return }
            let title = blocked ? String(localized: "Unblock this person?", table: "RoomProfile")
                : String(localized: "Block this person?", table: "RoomProfile")
            let message = blocked ? model.userID
                : String(localized: "Blocking hides this person's past and future messages from you in all chats, including shared groups. You won't receive invitations from them.")
                    + "\n\n" + String(localized: "You can unblock them in Settings.", table: "RoomProfile")
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: blocked ? String(localized: "Unblock", table: "RoomProfile")
                : String(localized: "Block", table: "RoomProfile"), style: blocked ? .default : .destructive) { [weak model] _ in
                model?.setBlocked(!blocked)
            })
            presenter.present(alert, animated: true)
        }
    }

    static func person(_ model: PersonProfileViewModel, presenter: UIViewController, sharing: UIMenu? = nil) -> UIMenu {
        let snapshot = model.snapshot
        var entries: [UIMenuElement] = [UIAction(title: String(localized: "Copy Matrix ID", table: "RoomProfile"),
            image: AppIcon.copy.template(size: 18)) { _ in UIPasteboard.general.string = snapshot.userID }]
        if let sharing { entries.insert(sharing, at: 0) }
        if let action = blocking(model.blocking, presenter: presenter) { entries.append(action) }
        if let group = snapshot.group {
            let roles = group.availableRoles.map { role in
                UIAction(title: role.localizedLabel,
                    attributes: !model.isPerformingAction && role != group.role ? [] : .disabled,
                    state: role == group.role ? .on : .off) { [weak model, weak presenter] _ in
                    guard let model, let presenter else { return }
                    confirm(.role(role), model: model, presenter: presenter)
                }
            }
            if !roles.isEmpty { entries.append(UIMenu(title: String(localized: "Role"), children: roles)) }
            for action: PersonProfileModeration in [.kick, .ban, .unban] where snapshot.allows(action) {
                entries.append(UIAction(title: title(action, invited: group.membership == .invite),
                    attributes: model.isPerformingAction ? .disabled : .destructive) { [weak model, weak presenter] _ in
                    guard let model, let presenter else { return }
                    confirm(action, model: model, presenter: presenter)
                })
            }
        }
        if model.loadError != nil {
            entries.append(UIAction(title: String(localized: "Reload profile", table: "RoomProfile")) { [weak model] _ in model?.refresh() })
        }
        return UIMenu(children: entries)
    }

    private static func title(_ action: PersonProfileModeration, invited: Bool) -> String {
        switch action {
        case .role: String(localized: "Change role?")
        case .kick: invited ? String(localized: "Cancel Invite") : String(localized: "Kick")
        case .ban: String(localized: "Ban")
        case .unban: String(localized: "Unban", table: "RoomProfile")
        }
    }

    private static func confirm(_ action: PersonProfileModeration, model: PersonProfileViewModel, presenter: UIViewController) {
        guard model.snapshot.allows(action), !model.isPerformingAction, let group = model.snapshot.group else { return }
        let actionTitle = title(action, invited: group.membership == .invite)
        let message: String
        if case .role(let role) = action {
            let name = model.snapshot.title, roleLabel = role.localizedLabel
            message = String(localized: "Set \(name) as \(roleLabel)?")
        } else { message = "\(model.snapshot.title)\n\(group.title)" }
        let alert = UIAlertController(title: actionTitle, message: message, preferredStyle: .alert)
        if action == .kick || action == .ban || action == .unban {
            alert.addTextField { $0.placeholder = String(localized: "Reason (optional)") }
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        let confirmationTitle: String
        if case .role = action { confirmationTitle = String(localized: "Change") }
        else { confirmationTitle = actionTitle }
        alert.addAction(UIAlertAction(title: confirmationTitle,
            style: action == .kick || action == .ban ? .destructive : .default) { [weak model, weak alert] _ in
            model?.perform(action, reason: alert?.textFields?.first?.text)
        })
        presenter.present(alert, animated: true)
    }
}
