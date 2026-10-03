// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import MatrixRustSDK
import UIKit

@MainActor
enum ContentReportFlow {
    private struct Key: Hashable {
        let sessionID: String
        let roomID: String
        let target: ContentReportTarget
    }

    /// Owns an in-flight operation independently of its screen. Finished
    /// detached entries are released; the result banner can reopen a receipt.
    private final class Entry {
        let id = UUID().uuidString
        let key: Key
        let model: ContentReportViewModel
        let isCurrentSession: () -> Bool
        weak var navigation: ZynaNavigationController?
        weak var controller: UIViewController?
        weak var audioPlayer: AudioPlayerService?
        var isPresented = false

        init(key: Key, model: ContentReportViewModel, isCurrentSession: @escaping () -> Bool) {
            self.key = key; self.model = model; self.isCurrentSession = isCurrentSession
        }
    }

    private static var entries: [String: Entry] = [:]
    private static var accountObservation: AnyCancellable?

    static func open(from presenter: UIViewController, room: Room, target: ContentReportTarget,
                     audioPlayer: AudioPlayerService? = nil) {
        guard let navigation = presenter.zynaNavigationController,
              let client = MatrixClientService.shared.client,
              let session = MatrixClientService.shared.currentLocalSessionId else { return }
        let isCurrentSession = {
            MatrixClientService.shared.currentLocalSessionId == session && MatrixClientService.shared.client === client
        }
        let model = ContentReportViewModel(target: target,
            source: SDKContentReportSource(client: client, room: room, target: target,
                                          database: DatabaseService.shared.dbQueue),
            isCurrentSession: isCurrentSession)
        present(model: model, roomID: room.id(), sessionID: session, in: navigation,
                audioPlayer: audioPlayer, isCurrentSession: isCurrentSession)
    }

    static func present(model: ContentReportViewModel, roomID: String, sessionID: String,
                        in navigation: ZynaNavigationController, audioPlayer: AudioPlayerService? = nil,
                        isCurrentSession: @escaping () -> Bool) {
        observeAccounts()
        discardInactiveSessions()
        guard isCurrentSession() else { return }
        let key = Key(sessionID: sessionID, roomID: roomID, target: model.target)
        // Reopening a pending report returns to that operation, so it cannot
        // submit a second report while the first request is still in flight.
        let entry = entries.values.first { $0.key == key } ?? Entry(key: key, model: model, isCurrentSession: isCurrentSession)
        entry.audioPlayer = audioPlayer
        show(entry, in: navigation)
    }

    private static func show(_ entry: Entry, in navigation: ZynaNavigationController) {
        guard entry.isCurrentSession() else { return }
        AppBannerCenter.shared.dismiss(id: entry.id)
        if let controller = entry.controller, let existingNavigation = entry.navigation,
           existingNavigation.stack.contains(where: { $0 === controller }) {
            existingNavigation.pop(to: controller)
            return
        }
        entries[entry.id] = entry
        entry.navigation = navigation
        entry.isPresented = true
        let model = entry.model
        let title = model.target.isInvitation ? String(localized: "Invitation", table: "Reports")
            : String(localized: "Report", table: "Reports")
        let controller = GlassHostingController(title: title, rootView: ContentReportView(model: model),
            audioPlayer: entry.audioPlayer, onBack: { [weak model] in model?.close() })
        entry.controller = controller
        let roomID = entry.key.roomID
        model.onClose = { [weak navigation, weak controller] left in
            guard let navigation, let controller, navigation.topViewController === controller else { return }
            if left, let index = navigation.stack.lastIndex(where: { $0.chatRoomIdentifier != nil }),
               index > 0, navigation.stack[index].chatRoomIdentifier == roomID {
                navigation.pop(to: navigation.stack[index - 1])
            } else { navigation.pop() }
        }
        model.onSubmissionFinished = { [weak entry] in
            guard let entry, entry.isCurrentSession() else { return }
            let leaving = entry.controller?.parent != nil
                && !(entry.navigation?.stack.contains(where: { $0 === entry.controller }) ?? false)
            guard !entry.isPresented || leaving else { return }
            entry.isPresented = false
            finishDetached(entry)
        }
        controller.onRemovedFromParent = { [weak entry, weak controller] in
            guard let entry, entry.controller === controller else { return }
            entry.controller = nil
            entry.model.onClose = nil
            // A request can finish during the pop animation, after the
            // controller has left the stack but before this callback.
            guard entry.isPresented else { return }
            entry.isPresented = false
            guard entry.isCurrentSession() else {
                entry.model.stop(); entries[entry.id] = nil
                return
            }
            removeLeftRoomBranch(entry)
            if entry.model.isSubmitting {
                showBanner(entry, pending: true)
            } else {
                entry.model.stop()
                entries[entry.id] = nil
            }
        }
        navigation.push(controller)
        if model.context == nil && !model.isLoading { model.load() }
    }

    private static func finishDetached(_ entry: Entry) {
        removeLeftRoomBranch(entry)
        showBanner(entry, pending: false)
        entries[entry.id] = nil
    }

    private static func showBanner(_ entry: Entry, pending: Bool, routeObstructed: Bool = false) {
        let model = entry.model
        let title: String
        var subtitle: String?
        if pending {
            title = String(localized: "Actions are continuing", table: "Reports")
            subtitle = String(localized: "You can return to the receipt to check the result.", table: "Reports")
        } else if !model.isComplete {
            title = String(localized: "Some actions couldn't be completed", table: "Reports")
            subtitle = model.completed.contains(.report)
                ? String(localized: "Your report was sent. Open the receipt to review the remaining actions.", table: "Reports")
                : String(localized: "Open the receipt to see the result and retry.", table: "Reports")
        } else {
            title = model.completed.contains(.report) ? String(localized: "Report sent", table: "Reports")
                : model.target.isInvitation ? String(localized: "Invitation declined", table: "Reports")
                : String(localized: "Actions completed", table: "Reports")
            subtitle = nil
        }
        if routeObstructed {
            subtitle = String(localized: "Close the current screen, then tap again.", table: "Reports")
        }
        AppBannerCenter.shared.show(AppBannerItem(id: entry.id, title: title, subtitle: subtitle,
            icon: pending ? .send : model.isComplete ? .checkmarkCircleFill : .xmarkCircleFill,
            tintColor: pending || model.isComplete ? AppColor.accent : AppColor.destructive,
            primaryActionTitle: String(localized: "View receipt", table: "Reports"),
            duration: routeObstructed ? 15 : pending ? 5 : 8,
            onPrimaryAction: { [entry] in
                guard entry.isCurrentSession(), let navigation = entry.navigation else { return .dismiss }
                guard navigation.revealForRouting() else {
                    showBanner(entry, pending: entry.model.isSubmitting, routeObstructed: true)
                    return .keepVisible
                }
                show(entry, in: navigation)
                return .dismiss
            }))
    }

    /// A delayed leave must remove only its room's branch, preserving any
    /// other chat the user opened while the request was in flight.
    private static func removeLeftRoomBranch(_ entry: Entry) {
        guard entry.isCurrentSession(), !entry.isPresented,
              entry.model.completed.contains(.leave), let navigation = entry.navigation else { return }
        // Read the stack only after pending pushes/pops have completed.
        // In particular, never enqueue a stale setStack behind a new push.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak navigation] in
            guard let navigation, entry.isCurrentSession(), !entry.isPresented else { return }
            if navigation.isTransitionInFlight { removeLeftRoomBranch(entry); return }
            let next = stackRemovingRoom(entry.key.roomID, from: navigation.stack)
            if next.count != navigation.stack.count { navigation.setStack(next) }
        }
    }

    static func stackRemovingRoom(_ roomID: String, from stack: [UIViewController]) -> [UIViewController] {
        var removing = false
        return stack.enumerated().compactMap { index, controller in
            guard index > 0 else { return controller }
            if let id = controller.chatRoomIdentifier { removing = id == roomID }
            return removing ? nil : controller
        }
    }

    static func discardInactiveSessions() {
        let inactive = entries.values.filter { !$0.isCurrentSession() }
        for entry in inactive {
            entry.model.stop()
            AppBannerCenter.shared.dismiss(id: entry.id)
            entries[entry.id] = nil
        }
    }

    private static func observeAccounts() {
        guard accountObservation == nil else { return }
        accountObservation = MatrixClientService.shared.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { _ in Task { @MainActor in discardInactiveSessions() } }
    }
}
