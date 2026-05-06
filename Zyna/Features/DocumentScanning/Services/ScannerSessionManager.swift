//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import UIKit

// MARK: - ScannerSessionManagerDelegate

protocol ScannerSessionManagerDelegate: AnyObject {
    func sessionManager(_ manager: ScannerSessionManager, didOutput sampleBuffer: CMSampleBuffer)
    func sessionManager(_ manager: ScannerSessionManager, didCapturePhoto image: UIImage)
}

// MARK: - ScannerSessionManager

final class ScannerSessionManager: NSObject {

    // MARK: - Properties

    weak var delegate: ScannerSessionManagerDelegate?

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.docscanner.captureSession")
    private let photoOutput = AVCapturePhotoOutput()

    private(set) lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    // MARK: - Configuration

    func configure() {
        sessionQueue.async { [weak self] in
            self?.setupSession()
        }
    }

    func startRunning() {
        sessionQueue.async { [weak self] in
            guard let self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    func stopRunning() {
        sessionQueue.async { [weak self] in
            guard let self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
        }
    }

    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Private

    private func setupSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo

        // Camera input
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)

        // Video data output (for live rectangle detection)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // Photo output (for high-res still capture)
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }

        // Enable best available video stabilization on all connections
        for output in captureSession.outputs {
            if let connection = output.connection(with: .video),
               connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        captureSession.commitConfiguration()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension ScannerSessionManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        delegate?.sessionManager(self, didOutput: sampleBuffer)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension ScannerSessionManager: AVCapturePhotoCaptureDelegate {

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        delegate?.sessionManager(self, didCapturePhoto: image)
    }
}
