//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//
// Zero-copy CPU↔GPU bridge via IOSurface-backed CVPixelBuffer.
// CVPixelBuffer → CVMetalTexture → MTLTexture — shared memory, no memcpy.
//
// Use cases: camera preview, video playback, video calls, AR filters —
// anywhere CVPixelBuffer needs to reach Metal without copying.
//

import CoreVideo
import Metal

final class ZeroCopyBridge {

    let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var pixelBuffer: CVPixelBuffer?
    private var cvTexture: CVMetalTexture?

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Allocate IOSurface-backed pixel buffer + Metal texture view.
    /// Call once per size, reuse across frames.
    func setupBuffer(width: Int, height: Int) {
        let attrs = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]  // IOSurface → zero-copy
        ] as CFDictionary

        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)

        guard let buffer = pixelBuffer, let cache = textureCache else { return }

        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil,
            .bgra8Unorm, width, height, 0, &tex
        )
        cvTexture = tex
    }

    /// Lock buffer for CPU writing, execute actions, unlock + flush for GPU.
    /// Returns the MTLTexture backed by the same memory — no copy.
    func render(actions: (CGContext) -> Void) -> MTLTexture? {
        guard let buffer = pixelBuffer, let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            CVMetalTextureCacheFlush(cache, 0)
        }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        actions(context)

        return cvTexture.flatMap { CVMetalTextureGetTexture($0) }
    }
}
