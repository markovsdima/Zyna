//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit

@MainActor
final class DocumentScanFlow {

    private enum DraftRecoveryDecision {
        case resume
        case startNew
        case cancel
    }

    private let draftStorage: ScanDraftStorageService
    private let scannerService: DocumentScannerService
    private let pdfExportService: PDFExportService
    private let attachmentStore: DocumentScanAttachmentStore

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    init(
        draftStorage: ScanDraftStorageService = FileBackedScanDraftStorage(),
        scannerService: DocumentScannerService? = nil,
        pdfExportService: PDFExportService = CoreGraphicsPDFExportService(),
        attachmentStore: DocumentScanAttachmentStore = DocumentScanAttachmentStore()
    ) {
        self.draftStorage = draftStorage
        self.scannerService = scannerService
            ?? CustomDocumentScannerService(draftStorage: draftStorage)
        self.pdfExportService = pdfExportService
        self.attachmentStore = attachmentStore
    }

    func scan(from presenter: UIViewController) async throws -> DocumentScanAttachment {
        let recoveryData = try await recoveryDataIfAvailable(from: presenter)
        let scanResult = try await scannerService.scan(from: presenter, recovering: recoveryData)
        let images = scanResult.images
        guard !images.isEmpty else {
            throw ScannerError.cancelled
        }

        let filename = "Scan \(Self.filenameDateFormatter.string(from: Date())).pdf"
        let exportService = pdfExportService
        let attachmentStore = attachmentStore
        // TODO(scanner-perf): Stream PDF output directly to file and load pages from draft URLs
        // so large scans do not keep every corrected UIImage plus PDF data in memory.
        let exportResult = try await Task.detached(priority: .userInitiated) {
            let pdfData = try exportService.generatePDF(from: images)
            let fileURL = try attachmentStore.writePDFData(pdfData, filename: filename)
            return (pdfData: pdfData, fileURL: fileURL)
        }.value

        if let draftId = scanResult.draftId {
            let draftStorage = draftStorage
            Task.detached(priority: .utility) {
                try? draftStorage.deleteDraft(draftId: draftId)
            }
        }

        return DocumentScanAttachment(
            fileURL: exportResult.fileURL,
            previewImage: images.first.map(attachmentStore.makePreviewImage(from:)),
            filename: filename,
            pageCount: images.count,
            byteCount: UInt64(exportResult.pdfData.count)
        )
    }

    private func recoveryDataIfAvailable(from presenter: UIViewController) async throws -> DraftRecoveryData? {
        let draftStorage = draftStorage
        let activeDraftTask = Task.detached(priority: .utility) {
            try draftStorage.fetchActiveDraft()
        }
        guard let activeDraft = try? await activeDraftTask.value else {
            return nil
        }

        let decision = await presentDraftRecoveryPrompt(for: activeDraft, from: presenter)
        switch decision {
        case .resume:
            let images = try await Task.detached(priority: .userInitiated) {
                try draftStorage.loadCorrectedImages(for: activeDraft.id)
            }.value
            guard !images.isEmpty else {
                Task.detached(priority: .utility) {
                    try? draftStorage.deleteDraft(draftId: activeDraft.id)
                }
                return nil
            }
            return DraftRecoveryData(draftId: activeDraft.id, images: images)
        case .startNew:
            try? await Task.detached(priority: .utility) {
                try draftStorage.deleteDraft(draftId: activeDraft.id)
            }.value
            return nil
        case .cancel:
            throw ScannerError.cancelled
        }
    }

    private func presentDraftRecoveryPrompt(
        for draft: DraftInfo,
        from presenter: UIViewController
    ) async -> DraftRecoveryDecision {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: String(localized: "Continue Previous Scan?"),
                message: String(
                    format: String(localized: "A previous scan was interrupted. Pages: %d."),
                    draft.pageCount
                ),
                preferredStyle: .alert
            )
            let finish: (DraftRecoveryDecision) -> Void = { decision in
                alert.dismiss(animated: true) {
                    continuation.resume(returning: decision)
                }
            }
            alert.addAction(UIAlertAction(title: String(localized: "Continue"), style: .default) { _ in
                finish(.resume)
            })
            alert.addAction(UIAlertAction(title: String(localized: "Start New Scan"), style: .destructive) { _ in
                finish(.startNew)
            })
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
                finish(.cancel)
            })

            presenter.present(alert, animated: true)
        }
    }
}
