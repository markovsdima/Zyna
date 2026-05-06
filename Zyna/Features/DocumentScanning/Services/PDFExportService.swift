//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

// MARK: - PDFExportService Protocol

protocol PDFExportService {
    func generatePDF(from imageURLs: [URL]) throws -> Data
    func generatePDF(from images: [UIImage]) throws -> Data
}

// MARK: - ExportError

enum ExportError: LocalizedError {
    case imageLoadFailed(URL)
    case pdfGenerationFailed

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let url):
            return "Failed to load image: \(url.lastPathComponent)"
        case .pdfGenerationFailed:
            return "Failed to generate PDF"
        }
    }
}

// MARK: - CoreGraphicsPDFExportService

final class CoreGraphicsPDFExportService: PDFExportService {

    func generatePDF(from imageURLs: [URL]) throws -> Data {
        let images = try imageURLs.map { url in
            guard let image = UIImage(contentsOfFile: url.path) else {
                throw ExportError.imageLoadFailed(url)
            }
            return image
        }
        return try generatePDF(from: images)
    }

    func generatePDF(from images: [UIImage]) throws -> Data {
        let pdfData = NSMutableData()

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            throw ExportError.pdfGenerationFailed
        }

        var mediaBox = CGRect.zero

        guard let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.pdfGenerationFailed
        }

        for image in images {
            let pageRect = CGRect(
                origin: .zero,
                size: CGSize(width: image.size.width, height: image.size.height)
            )

            var pageBox = pageRect
            pdfContext.beginPage(mediaBox: &pageBox)

            pdfContext.saveGState()
            pdfContext.translateBy(x: 0, y: pageRect.height)
            pdfContext.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(pdfContext)
            image.draw(in: pageRect)
            UIGraphicsPopContext()
            pdfContext.restoreGState()

            pdfContext.endPage()
        }

        pdfContext.closePDF()

        return pdfData as Data
    }
}
