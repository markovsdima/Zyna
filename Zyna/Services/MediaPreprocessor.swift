//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

@preconcurrency import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

private let logVideoPreprocess = ScopedLog(.video, prefix: "[VideoPreprocess]")

// MARK: - Processed Image

struct ProcessedImage {
    let imageData: Data
    let width: UInt64
    let height: UInt64
    // TODO: Thumbnail ready for when sendImage SDK bug is fixed
    // let thumbnailData: Data
    // let thumbnailWidth: UInt64
    // let thumbnailHeight: UInt64
}

struct ProcessedVideo {
    let videoURL: URL
    let thumbnailURL: URL
    let thumbnailData: Data
    let blurhash: String?
    let filename: String
    let width: UInt64
    let height: UInt64
    let duration: TimeInterval
    let mimetype: String
    let size: UInt64
    let thumbnailWidth: UInt64
    let thumbnailHeight: UInt64
    let thumbnailSize: UInt64
}

// MARK: - Media Preprocessor

enum MediaPreprocessor {

    static let maxDimension: CGFloat = 2048
    static let jpegQuality: CGFloat = 0.78
    // static let thumbMaxDimension: CGFloat = 800  // TODO: for sendImage thumbnail
    private static let videoMaxLongSide: CGFloat = 1280
    private static let videoThumbnailMaxSize = CGSize(width: 800, height: 600)
    // TODO(video): Replace this soft budget with the homeserver max upload size
    // and an explicit product policy for max duration/size. Element uses the
    // server max and targets roughly 90% of it during export.
    private static let videoSoftMaxBytes: UInt64 = 48 * 1024 * 1024
    private static let videoAudioBitrate = 128_000
    private static let videoMinimumBitrate = 650_000
    private static let videoMaximumBitrate = 4_200_000

    // MARK: - Public

    static func processImage(from data: Data) async throws -> ProcessedImage {
        try await Task.detached {
            let strippedData = stripGPSMetadata(from: data)

            // UIImage handles all formats (JPEG, PNG, HEIC, WebP) and normalizes pixel format
            guard let original = UIImage(data: strippedData) else {
                throw PreprocessorError.invalidImageData
            }

            return try processDecodedImage(original)
        }.value
    }

    static func processImage(from image: UIImage) async throws -> ProcessedImage {
        try await Task.detached {
            try processDecodedImage(image)
        }.value
    }

    static func processVideo(from url: URL) async throws -> ProcessedVideo {
        logVideoPreprocess(
            "start input=\(url.lastPathComponent) ext=\(url.pathExtension) bytes=\(fileSize(at: url))"
        )
        do {
            let processed = try await Task.detached(priority: .userInitiated) {
                try await processVideoFile(from: url)
            }.value
            logVideoPreprocess(
                "done output=\(processed.filename) bytes=\(processed.size) size=\(processed.width)x\(processed.height) duration=\(formatSeconds(processed.duration)) thumbBytes=\(processed.thumbnailSize) thumb=\(processed.thumbnailWidth)x\(processed.thumbnailHeight)"
            )
            return processed
        } catch {
            logVideoPreprocess(
                "failed input=\(url.lastPathComponent) errorType=\(String(describing: type(of: error))) error=\(error)"
            )
            throw error
        }
    }

    // MARK: - GPS Stripping

    private static func stripGPSMetadata(from data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return data
        }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, type, 1, nil) else {
            return data
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return data
        }

        var cleaned = properties
        cleaned.removeValue(forKey: kCGImagePropertyGPSDictionary)

        CGImageDestinationAddImageFromSource(dest, source, 0, cleaned as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            return data
        }

        return mutableData as Data
    }

    // MARK: - Resize

    /// Resizes and normalizes an image: forces scale 1.0 and standard dynamic range (strips HDR).
    /// Always redraws through the renderer even if dimensions fit, to normalize pixel format.
    private static func resizeUIImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let w = image.size.width * image.scale   // pixel dimensions
        let h = image.size.height * image.scale
        let scale = min(maxDimension / w, maxDimension / h, 1.0)

        let newSize = CGSize(width: w * scale, height: h * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.preferredRange = .standard   // Force SDR, strip HDR gain map
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func processDecodedImage(_ original: UIImage) throws -> ProcessedImage {
        let resized = resizeUIImage(original, maxDimension: maxDimension)

        guard let imageData = resized.jpegData(compressionQuality: jpegQuality) else {
            throw PreprocessorError.encodingFailed
        }

        return ProcessedImage(
            imageData: imageData,
            width: UInt64(resized.size.width * resized.scale),
            height: UInt64(resized.size.height * resized.scale)
        )
    }

    // MARK: - Video

    private static func processVideoFile(from sourceURL: URL) async throws -> ProcessedVideo {
        let workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zyna-video-\(UUID().uuidString)", isDirectory: true)
        // TODO(video): Add a startup janitor for stale zyna-video-* folders left
        // by failed sends or app termination between preprocessing and cleanup.
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        do {
            let sourceExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
            let inputURL = workingDir.appendingPathComponent("source.\(sourceExtension)")
            try? FileManager.default.removeItem(at: inputURL)
            try FileManager.default.copyItem(at: sourceURL, to: inputURL)

            let asset = AVURLAsset(url: inputURL)
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw PreprocessorError.invalidVideoData
            }

            let durationTime = try await asset.load(.duration)
            let duration = durationTime.seconds
            guard duration.isFinite, duration > 0 else {
                throw PreprocessorError.invalidVideoData
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            let displaySize = displaySize(naturalSize: naturalSize, preferredTransform: preferredTransform)
            let targetDisplaySize = evenSize(scaledSize(displaySize, maxLongSide: videoMaxLongSide))
            let fps = normalizedFrameRate(nominalFrameRate)
            let bitrate = targetVideoBitrate(
                targetSize: targetDisplaySize,
                frameRate: fps,
                duration: duration
            )
            logVideoPreprocess(
                "asset input=\(sourceURL.lastPathComponent) natural=\(formatSize(naturalSize)) display=\(formatSize(displaySize)) target=\(formatSize(targetDisplaySize)) duration=\(formatSeconds(duration)) fps=\(String(format: "%.2f", fps)) bitrate=\(bitrate)"
            )

            let outputURL = workingDir.appendingPathComponent(outputFilename(for: sourceURL))
            try? FileManager.default.removeItem(at: outputURL)

            logVideoPreprocess(
                "transcode start output=\(outputURL.lastPathComponent) workdir=\(workingDir.lastPathComponent)"
            )
            try await transcodeVideo(
                asset: asset,
                videoTrack: videoTrack,
                outputURL: outputURL,
                targetSize: targetDisplaySize,
                frameRate: fps,
                videoBitrate: bitrate,
                preferredTransform: preferredTransform,
                sourceDisplaySize: displaySize,
                duration: durationTime
            )
            logVideoPreprocess("transcode done outputBytes=\(fileSize(at: outputURL))")

            let thumbnail = try await generateVideoThumbnail(
                for: outputURL,
                duration: duration,
                workingDir: workingDir
            )
            let outputSize = fileSize(at: outputURL)
            logVideoPreprocess(
                "thumbnail done bytes=\(thumbnail.data.count) size=\(thumbnail.width)x\(thumbnail.height) blurhash=\(thumbnail.blurhash != nil ? "true" : "false")"
            )

            return ProcessedVideo(
                videoURL: outputURL,
                thumbnailURL: thumbnail.url,
                thumbnailData: thumbnail.data,
                blurhash: thumbnail.blurhash,
                filename: outputURL.lastPathComponent,
                width: UInt64(targetDisplaySize.width),
                height: UInt64(targetDisplaySize.height),
                duration: duration,
                mimetype: "video/mp4",
                size: outputSize,
                thumbnailWidth: UInt64(thumbnail.width),
                thumbnailHeight: UInt64(thumbnail.height),
                thumbnailSize: UInt64(thumbnail.data.count)
            )
        } catch {
            logVideoPreprocess(
                "cleanup after failure workdir=\(workingDir.lastPathComponent) error=\(error)"
            )
            try? FileManager.default.removeItem(at: workingDir)
            throw error
        }
    }

    private struct VideoThumbnail {
        let url: URL
        let data: Data
        let width: Int
        let height: Int
        let blurhash: String?
    }

    private static func transcodeVideo(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        outputURL: URL,
        targetSize: CGSize,
        frameRate: Double,
        videoBitrate: Int,
        preferredTransform: CGAffineTransform,
        sourceDisplaySize: CGSize,
        duration: CMTime
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = targetSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, min(60, Int(frameRate.rounded())))))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(
            uprightTransform(
                preferredTransform: preferredTransform,
                naturalSize: try await videoTrack.load(.naturalSize),
                sourceDisplaySize: sourceDisplaySize,
                targetSize: targetSize
            ),
            at: .zero
        )
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw PreprocessorError.videoEncodingFailed }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(targetSize.width),
                AVVideoHeightKey: Int(targetSize.height),
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoBitrate,
                    AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw PreprocessorError.videoEncodingFailed }
        writer.add(videoInput)

        let audioPair = try await makeAudioReaderWriterPair(asset: asset, reader: reader, writer: writer)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.zyna.video-preprocessor.writer", qos: .userInitiated)
            let group = DispatchGroup()
            let failure = TranscodeFailure()
            let readerBox = UnsafeSendableBox(reader)
            let writerBox = UnsafeSendableBox(writer)
            let videoOutputBox = UnsafeSendableBox(videoOutput)
            let videoInputBox = UnsafeSendableBox(videoInput)
            let audioPairBox = audioPair.map(UnsafeSendableBox.init)

            guard writer.startWriting() else {
                continuation.resume(throwing: writer.error ?? PreprocessorError.videoEncodingFailed)
                return
            }
            guard reader.startReading() else {
                writer.cancelWriting()
                continuation.resume(throwing: reader.error ?? PreprocessorError.videoEncodingFailed)
                return
            }
            writer.startSession(atSourceTime: .zero)

            group.enter()
            videoInput.requestMediaDataWhenReady(on: queue) {
                appendSamples(
                    from: videoOutputBox.value,
                    to: videoInputBox.value,
                    reader: readerBox.value,
                    failure: failure,
                    onFinished: group.leave
                )
            }

            if let audioPairBox {
                group.enter()
                audioPairBox.value.input.requestMediaDataWhenReady(on: queue) {
                    appendSamples(
                        from: audioPairBox.value.output,
                        to: audioPairBox.value.input,
                        reader: readerBox.value,
                        failure: failure,
                        onFinished: group.leave
                    )
                }
            }

            group.notify(queue: queue) {
                if let error = failure.error {
                    readerBox.value.cancelReading()
                    writerBox.value.cancelWriting()
                    continuation.resume(throwing: error)
                    return
                }

                writerBox.value.finishWriting {
                    if writerBox.value.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: writerBox.value.error ?? PreprocessorError.videoEncodingFailed)
                    }
                }
            }
        }
    }

    private struct AudioReaderWriterPair {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
    }

    private static func makeAudioReaderWriterPair(
        asset: AVURLAsset,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> AudioReaderWriterPair? {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        let audioOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM
            ]
        )
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(audioOutput) else { return nil }

        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: videoAudioBitrate
            ]
        )
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else { return nil }

        reader.add(audioOutput)
        writer.add(audioInput)
        return AudioReaderWriterPair(output: audioOutput, input: audioInput)
    }

    private final class TranscodeFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: Error?

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }

        func set(_ error: Error) {
            lock.lock()
            if storedError == nil {
                storedError = error
            }
            lock.unlock()
        }
    }

    private final class UnsafeSendableBox<Value>: @unchecked Sendable {
        let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private static func appendSamples(
        from output: AVAssetReaderOutput,
        to input: AVAssetWriterInput,
        reader: AVAssetReader,
        failure: TranscodeFailure,
        onFinished: @escaping () -> Void
    ) {
        while input.isReadyForMoreMediaData {
            if failure.error != nil {
                input.markAsFinished()
                onFinished()
                return
            }

            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                onFinished()
                return
            }

            if !input.append(sampleBuffer) {
                failure.set(reader.error ?? PreprocessorError.videoEncodingFailed)
                input.markAsFinished()
                onFinished()
                return
            }
        }
    }

    private static func generateVideoThumbnail(
        for videoURL: URL,
        duration: TimeInterval,
        workingDir: URL
    ) async throws -> VideoThumbnail {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = videoThumbnailMaxSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let seconds = min(5, max(0.1, duration * 0.25))
        let cgImage = try await generator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600)
        ).image
        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: jpegQuality) else {
            throw PreprocessorError.encodingFailed
        }
        let blurhash = image.zynaBlurHash(numberOfComponents: (3, 3))

        let thumbnailURL = workingDir.appendingPathComponent("thumbnail.jpg")
        try data.write(to: thumbnailURL, options: .atomic)
        return VideoThumbnail(
            url: thumbnailURL,
            data: data,
            width: Int(image.size.width * image.scale),
            height: Int(image.size.height * image.scale),
            blurhash: blurhash
        )
    }

    private static func displaySize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize {
        let transformed = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private static func scaledSize(_ size: CGSize, maxLongSide: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1280, height: 720) }
        let longSide = max(size.width, size.height)
        let scale = min(1, maxLongSide / longSide)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static func evenSize(_ size: CGSize) -> CGSize {
        let width = max(2, Int(size.width.rounded(.down)) / 2 * 2)
        let height = max(2, Int(size.height.rounded(.down)) / 2 * 2)
        return CGSize(width: width, height: height)
    }

    private static func normalizedFrameRate(_ frameRate: Float) -> Double {
        guard frameRate.isFinite, frameRate > 0 else { return 30 }
        return min(60, max(24, Double(frameRate)))
    }

    private static func targetVideoBitrate(
        targetSize: CGSize,
        frameRate: Double,
        duration: TimeInterval
    ) -> Int {
        let qualityBitrate = Int(targetSize.width * targetSize.height * frameRate * 0.075)
        let availableBitrate: Int
        if duration > 0 {
            let reservedBytes: UInt64 = 512 * 1024
            let mediaBudget = Double(videoSoftMaxBytes > reservedBytes ? videoSoftMaxBytes - reservedBytes : videoSoftMaxBytes)
            availableBitrate = max(videoMinimumBitrate, Int(mediaBudget * 8 / duration) - videoAudioBitrate)
        } else {
            availableBitrate = videoMaximumBitrate
        }
        return min(videoMaximumBitrate, max(videoMinimumBitrate, min(qualityBitrate, availableBitrate)))
    }

    private static func uprightTransform(
        preferredTransform: CGAffineTransform,
        naturalSize: CGSize,
        sourceDisplaySize: CGSize,
        targetSize: CGSize
    ) -> CGAffineTransform {
        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let scale = min(
            targetSize.width / max(1, sourceDisplaySize.width),
            targetSize.height / max(1, sourceDisplaySize.height)
        )
        return preferredTransform
            .concatenating(CGAffineTransform(
                translationX: -transformedRect.minX,
                y: -transformedRect.minY
            ))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func outputFilename(for sourceURL: URL) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\((base.isEmpty ? "video" : base)).mp4"
    }

    private static func fileSize(at url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private static func formatSize(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private static func formatSeconds(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "nan" }
        return String(format: "%.3fs", duration)
    }

    // MARK: - Errors

    enum PreprocessorError: Error {
        case invalidImageData
        case encodingFailed
        case invalidVideoData
        case videoEncodingFailed
    }
}

private extension UIImage {
    // BlurHash uses this fixed Base83 alphabet.
    private static let blurHashBase83Characters = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
    )

    func zynaBlurHash(
        numberOfComponents components: (x: Int, y: Int),
        maxPixelSize: CGFloat = 32
    ) -> String? {
        guard (1...9).contains(components.x),
              (1...9).contains(components.y),
              let cgImage else {
            return nil
        }

        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let scale = min(1, maxPixelSize / max(sourceSize.width, sourceSize.height))
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ),
              let pixelData = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var factors: [(Float, Float, Float)] = []
        factors.reserveCapacity(components.x * components.y)
        for yComponent in 0..<components.y {
            for xComponent in 0..<components.x {
                let normalisation: Float = (xComponent == 0 && yComponent == 0) ? 1 : 2
                factors.append(
                    Self.multiplyBasisFunction(
                        pixels: pixelData,
                        width: width,
                        height: height,
                        bytesPerRow: bytesPerRow,
                        bytesPerPixel: bytesPerPixel
                    ) { x, y in
                        normalisation
                            * cos(Float.pi * Float(xComponent) * x / Float(width))
                            * cos(Float.pi * Float(yComponent) * y / Float(height))
                    }
                )
            }
        }

        guard let dc = factors.first else { return nil }
        let ac = factors.dropFirst()
        var hash = ""
        hash += Self.encodeBase83((components.x - 1) + (components.y - 1) * 9, length: 1)

        let maximumValue: Float
        if ac.isEmpty {
            maximumValue = 1
            hash += Self.encodeBase83(0, length: 1)
        } else {
            let actualMaximumValue = ac.map { max(abs($0.0), abs($0.1), abs($0.2)) }.max() ?? 0
            let quantisedMaximumValue = Int(max(0, min(82, floor(actualMaximumValue * 166 - 0.5))))
            maximumValue = Float(quantisedMaximumValue + 1) / 166
            hash += Self.encodeBase83(quantisedMaximumValue, length: 1)
        }

        hash += Self.encodeBase83(Self.encodeDC(dc), length: 4)
        for factor in ac {
            hash += Self.encodeBase83(Self.encodeAC(factor, maximumValue: maximumValue), length: 2)
        }
        return hash
    }

    private static func multiplyBasisFunction(
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        basisFunction: (Float, Float) -> Float
    ) -> (Float, Float, Float) {
        var red: Float = 0
        var green: Float = 0
        var blue: Float = 0

        for y in 0..<height {
            for x in 0..<width {
                let basis = basisFunction(Float(x), Float(y))
                let offset = y * bytesPerRow + x * bytesPerPixel
                red += basis * sRGBToLinear(pixels[offset])
                green += basis * sRGBToLinear(pixels[offset + 1])
                blue += basis * sRGBToLinear(pixels[offset + 2])
            }
        }

        let scale = 1 / Float(width * height)
        return (red * scale, green * scale, blue * scale)
    }

    private static func encodeDC(_ value: (Float, Float, Float)) -> Int {
        let red = linearToSRGB(value.0)
        let green = linearToSRGB(value.1)
        let blue = linearToSRGB(value.2)
        return (red << 16) + (green << 8) + blue
    }

    private static func encodeAC(_ value: (Float, Float, Float), maximumValue: Float) -> Int {
        let red = Int(max(0, min(18, floor(signPow(value.0 / maximumValue, 0.5) * 9 + 9.5))))
        let green = Int(max(0, min(18, floor(signPow(value.1 / maximumValue, 0.5) * 9 + 9.5))))
        let blue = Int(max(0, min(18, floor(signPow(value.2 / maximumValue, 0.5) * 9 + 9.5))))
        return red * 19 * 19 + green * 19 + blue
    }

    private static func signPow(_ value: Float, _ exponent: Float) -> Float {
        copysign(pow(abs(value), exponent), value)
    }

    private static func linearToSRGB(_ value: Float) -> Int {
        let bounded = max(0, min(1, value))
        if bounded <= 0.0031308 {
            return Int(bounded * 12.92 * 255 + 0.5)
        }
        return Int((1.055 * pow(bounded, 1 / 2.4) - 0.055) * 255 + 0.5)
    }

    private static func sRGBToLinear(_ value: UInt8) -> Float {
        let bounded = Float(value) / 255
        if bounded <= 0.04045 {
            return bounded / 12.92
        }
        return pow((bounded + 0.055) / 1.055, 2.4)
    }

    private static func encodeBase83(_ value: Int, length: Int) -> String {
        var result = ""
        for index in 1...length {
            let divisor = intPow(83, length - index)
            let digit = (value / divisor) % 83
            result.append(blurHashBase83Characters[digit])
        }
        return result
    }

    private static func intPow(_ base: Int, _ exponent: Int) -> Int {
        (0..<exponent).reduce(1) { value, _ in value * base }
    }
}
