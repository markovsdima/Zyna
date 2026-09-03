//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import QuickLook
import UIKit

/// Presents a single local file in `QLPreviewController` from any view
/// controller. Keeps itself alive as the data source until dismissal.
@MainActor
final class QuickLookPresenter: NSObject, @preconcurrency QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {

    private static var active: QuickLookPresenter?

    private let url: URL

    private init(url: URL) {
        self.url = url
    }

    static func present(url: URL, from presenter: UIViewController) {
        let dataSource = QuickLookPresenter(url: url)
        active = dataSource
        let controller = QLPreviewController()
        controller.dataSource = dataSource
        controller.delegate = dataSource
        presenter.present(controller, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        url as NSURL
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        if Self.active === self {
            Self.active = nil
        }
    }
}
