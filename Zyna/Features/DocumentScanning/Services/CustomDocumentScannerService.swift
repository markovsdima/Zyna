//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

// MARK: - CustomDocumentScannerService

final class CustomDocumentScannerService: DocumentScannerService {

    private let draftStorage: ScanDraftStorageService

    init(draftStorage: ScanDraftStorageService = FileBackedScanDraftStorage()) {
        self.draftStorage = draftStorage
    }

    @MainActor
    func scan(from viewController: UIViewController, recovering: DraftRecoveryData? = nil) async throws -> ScanResult {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = ScanFlowCoordinator(
                draftStorage: draftStorage,
                continuation: continuation,
                recovering: recovering
            )
            let cameraVC = CameraPreviewViewController()
            cameraVC.delegate = coordinator

            let navController = UINavigationController(rootViewController: cameraVC)
            navController.modalPresentationStyle = .fullScreen
            if let recovering {
                cameraVC.updatePageCount(recovering.images.count, lastImage: recovering.images.last)
                if let reviewVC = coordinator.makeRecoveryReviewController() {
                    navController.setViewControllers([cameraVC, reviewVC], animated: false)
                }
            }

            // Retain coordinator for the lifetime of the modal
            objc_setAssociatedObject(navController, &AssociatedKeys.coordinator, coordinator, .OBJC_ASSOCIATION_RETAIN)

            coordinator.navigationController = navController
            viewController.present(navController, animated: true)
        }
    }
}

// MARK: - AssociatedKeys

private enum AssociatedKeys {
    nonisolated(unsafe) static var coordinator = 0
}

// MARK: - ScanFlowCoordinator

private final class ScanFlowCoordinator: NSObject {

    // MARK: - Properties

    private var continuation: CheckedContinuation<ScanResult, Error>?
    private var scannedPages: [UIImage] = []
    weak var navigationController: UINavigationController?

    private let draftStorage: ScanDraftStorageService
    private let perspectiveService = PerspectiveCorrectionService()
    private let draftId: UUID
    private var pageInfos: [DraftPageInfo] = []
    private var editingPageIndex: Int?
    private var retakingPageIndex: Int?

    // MARK: - Init

    init(draftStorage: ScanDraftStorageService, continuation: CheckedContinuation<ScanResult, Error>, recovering: DraftRecoveryData? = nil) {
        self.draftStorage = draftStorage
        self.continuation = continuation
        if let recovering {
            self.draftId = recovering.draftId
            self.scannedPages = recovering.images
        } else {
            self.draftId = (try? draftStorage.createDraft()) ?? UUID()
        }
    }

    // MARK: - Helpers

    private func finish(with result: Result<ScanResult, Error>) {
        navigationController?.dismiss(animated: true) { [weak self] in
            guard let self, let continuation = self.continuation else { return }
            self.continuation = nil
            switch result {
            case .success(let scanResult):
                continuation.resume(returning: scanResult)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func deleteDraftInBackground() {
        let storage = draftStorage
        let id = draftId
        Task.detached(priority: .utility) {
            try? storage.deleteDraft(draftId: id)
        }
    }

    func makeRecoveryReviewController() -> UIViewController? {
        guard !scannedPages.isEmpty else { return nil }
        pageInfos = (try? draftStorage.fetchDraftPageInfos(for: draftId)) ?? []

        let reviewVC = ScanReviewViewController(pages: scannedPages)
        reviewVC.delegate = self
        return reviewVC
    }
}

// MARK: - CameraPreviewViewControllerDelegate

extension ScanFlowCoordinator: CameraPreviewViewControllerDelegate {

    func cameraPreviewDidCapture(_ controller: CameraPreviewViewController, image: UIImage, quad: Quad<VisionSpace>?, debugCropRect: CGRect?) {
        // Apply perspective correction using the hi-res quad
        let correctedImage: UIImage
        if let quad {
            let imageQuad = quad.toImage(size: image.size)
            correctedImage = perspectiveService.correct(image: image, quad: imageQuad) ?? image
        } else {
            correctedImage = image
        }

        // Retake: replace existing page and return to review
        if let retakeIndex = retakingPageIndex {
            retakingPageIndex = nil
            scannedPages[retakeIndex] = correctedImage

            // Delete old page, write new one
            let storage = draftStorage
            let draftId = draftId
            let oldPageId = retakeIndex < pageInfos.count ? pageInfos[retakeIndex].pageId : nil
            let writeTask = Task.detached(priority: .userInitiated) { () throws -> DraftPageInfo in
                if let oldPageId { try? storage.deletePage(pageId: oldPageId) }
                let pageId = try storage.writeOriginalPage(
                    draftId: draftId, pageIndex: retakeIndex, image: image, quad: quad
                )
                try storage.writeCorrectedImage(pageId: pageId, image: correctedImage)
                return DraftPageInfo(pageId: pageId, pageIndex: retakeIndex, quad: quad)
            }
            Task { [weak self] in
                do {
                    let newInfo = try await writeTask.value
                    guard let self else { return }
                    if retakeIndex < self.pageInfos.count {
                        self.pageInfos[retakeIndex] = newInfo
                    }
                } catch {
                    print("[ScanDraft] Failed to write retake page: \(error)")
                }
            }

            controller.animateCapturedPage(
                correctedImage: correctedImage, quad: quad, pageCount: scannedPages.count
            ) { [weak self] in
                guard let self else { return }
                let reviewVC = ScanReviewViewController(pages: self.scannedPages)
                reviewVC.delegate = self
                self.navigationController?.pushViewController(reviewVC, animated: true)
            }
            return
        }

        // Normal capture: append new page
        let pageIndex = scannedPages.count
        scannedPages.append(correctedImage)
        let newCount = scannedPages.count

        // Write original + corrected to disk in background
        let storage = draftStorage
        let draftId = draftId
        Task.detached(priority: .userInitiated) {
            do {
                let pageId = try storage.writeOriginalPage(
                    draftId: draftId,
                    pageIndex: pageIndex,
                    image: image,
                    quad: quad
                )
                try storage.writeCorrectedImage(pageId: pageId, image: correctedImage)
            } catch {
                print("[ScanDraft] Failed to write page: \(error)")
            }
        }

        // Animate the corrected page on camera VC
        controller.animateCapturedPage(
            correctedImage: correctedImage,
            quad: quad,
            pageCount: newCount
        )
    }

    func cameraPreviewDidFinish(_ controller: CameraPreviewViewController) {
        if scannedPages.isEmpty {
            deleteDraftInBackground()
            finish(with: .failure(ScannerError.cancelled))
        } else {
            pageInfos = (try? draftStorage.fetchDraftPageInfos(for: draftId)) ?? []
            let reviewVC = ScanReviewViewController(pages: scannedPages)
            reviewVC.delegate = self
            navigationController?.pushViewController(reviewVC, animated: true)
        }
    }

    func cameraPreviewDidCancel(_ controller: CameraPreviewViewController) {
        deleteDraftInBackground()
        finish(with: .failure(ScannerError.cancelled))
    }
}

// MARK: - CornerCorrectionViewControllerDelegate

extension ScanFlowCoordinator: CornerCorrectionViewControllerDelegate {

    func cornerCorrectionDidConfirm(_ controller: CornerCorrectionViewController, correctedImage: UIImage) {
        if let editIndex = editingPageIndex {
            // Editing from review screen
            scannedPages[editIndex] = correctedImage
            if editIndex < pageInfos.count {
                let pageId = pageInfos[editIndex].pageId
                let storage = draftStorage
                Task.detached(priority: .userInitiated) {
                    try? storage.writeCorrectedImage(pageId: pageId, image: correctedImage)
                }
            }
            editingPageIndex = nil
            navigationController?.popViewController(animated: true)
            if let reviewVC = navigationController?.topViewController as? ScanReviewViewController {
                reviewVC.updatePage(at: editIndex, image: correctedImage)
            }
        } else {
            // Fallback (unused in current flow)
            scannedPages.append(correctedImage)
            navigationController?.popViewController(animated: true)
        }
    }

    func cornerCorrectionDidRetake(_ controller: CornerCorrectionViewController) {
        editingPageIndex = nil
        navigationController?.popViewController(animated: true)
    }
}

// MARK: - ScanReviewViewControllerDelegate

extension ScanFlowCoordinator: ScanReviewViewControllerDelegate {

    func scanReviewDidSave(_ controller: ScanReviewViewController) {
        finish(with: .success(ScanResult(images: scannedPages, draftId: draftId)))
    }

    func scanReviewDidRequestAddPages(_ controller: ScanReviewViewController) {
        navigationController?.popViewController(animated: true)
        if let cameraVC = navigationController?.topViewController as? CameraPreviewViewController {
            cameraVC.resumeDetection()
        }
    }

    func scanReviewDidRequestEditCorners(_ controller: ScanReviewViewController, at index: Int) {
        guard index < pageInfos.count else { return }
        let info = pageInfos[index]
        guard let originalImage = try? draftStorage.loadOriginalImage(pageId: info.pageId) else { return }

        editingPageIndex = index
        let correctionVC = CornerCorrectionViewController(image: originalImage, quad: info.quad)
        correctionVC.delegate = self
        navigationController?.pushViewController(correctionVC, animated: true)
    }

    func scanReviewDidRequestRetake(_ controller: ScanReviewViewController, at index: Int) {
        retakingPageIndex = index
        navigationController?.popViewController(animated: true)
        if let cameraVC = navigationController?.topViewController as? CameraPreviewViewController {
            cameraVC.resumeDetection()
        }
    }

    func scanReviewDidDeletePage(_ controller: ScanReviewViewController, at index: Int) {
        guard index < scannedPages.count else { return }
        scannedPages.remove(at: index)

        if index < pageInfos.count {
            let pageId = pageInfos[index].pageId
            pageInfos.remove(at: index)
            let storage = draftStorage
            Task.detached(priority: .utility) {
                try? storage.deletePage(pageId: pageId)
            }
        }

        if scannedPages.isEmpty {
            navigationController?.popViewController(animated: true)
            if let cameraVC = navigationController?.topViewController as? CameraPreviewViewController {
                cameraVC.updatePageCount(0)
                cameraVC.resumeDetection()
            }
        }
    }
}
