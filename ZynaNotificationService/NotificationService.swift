//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var processingTask: Task<Void, Never>?
    private let didFinish = Atomic(false)

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttemptContent else {
            finish(with: request.content)
            return
        }

        let payload = NSEPushPayload(userInfo: request.content.userInfo)
        processingTask = Task { [weak self] in
            let prepared = await NSEMatrixBootstrap().run(payload: payload)
            if let prepared {
                Self.apply(prepared, to: bestAttemptContent)
            }
            self?.finish(with: bestAttemptContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        processingTask?.cancel()
        finish(with: bestAttemptContent)
    }

    private static func apply(_ prepared: NSEPreparedNotification, to content: UNMutableNotificationContent) {
        content.title = prepared.title
        if let subtitle = prepared.subtitle {
            content.subtitle = subtitle
        }
        content.body = prepared.body
        content.sound = prepared.isNoisy ? .default : nil
    }

    private func finish(with content: UNNotificationContent?) {
        guard didFinish.tryToSetFlag() else { return }

        let handler = contentHandler
        contentHandler = nil
        processingTask = nil

        if let content {
            handler?(content)
        }
    }

}
