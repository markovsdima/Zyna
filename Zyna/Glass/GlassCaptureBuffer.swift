//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreGraphics
import Metal

/// Main-thread ownership of CPU capture memory shared with the GPU.
/// A texture reference alone does not prevent CGContext from overwriting it.
final class GlassCaptureBuffer {
    let ctx: CGContext
    let buffer: MTLBuffer?
    let texture: MTLTexture
    let bytesPerRow: Int
    var zeroCopy: Bool { buffer != nil }
    private(set) var generation: UInt64 = 0
    fileprivate var readers = 0
    var isWritable: Bool { readers == 0 }

    init?(width: Int, height: Int, device: MTLDevice) {
        guard width > 0, height > 0 else { return nil }
#if targetEnvironment(simulator) && arch(x86_64)
        let useBuffer = false
#else
        let useBuffer = true
#endif
        bytesPerRow = useBuffer ? (width * 4 + 255) & ~255 : width * 4
        if useBuffer {
            guard let buffer = device.makeBuffer(
                length: bytesPerRow * height, options: .storageModeShared
            ) else { return nil }
            self.buffer = buffer
        } else {
            buffer = nil
        }
        guard let ctx = CGContext(
            data: buffer?.contents(), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        self.ctx = ctx
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared
        let texture: MTLTexture?
        if let buffer {
            texture = buffer.makeTexture(
                descriptor: desc, offset: 0, bytesPerRow: bytesPerRow
            )
        } else {
            texture = device.makeTexture(descriptor: desc)
        }
        guard let texture else { return nil }
        self.texture = texture
    }

    func didCapture() {
        precondition(isWritable)
        if !zeroCopy, let data = ctx.data {
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow
            )
        }
        generation &+= 1
    }
}

/// One pair per anchor and capture size. Pending frames are discarded before
/// writing again; only submitted GPU commands hold read leases.
final class GlassCaptureBufferPool {
    let slots: [GlassCaptureBuffer]
    let byteCost: Int
    var lastUsedTick: Int
    private var nextIndex = 0

    init?(width: Int, height: Int, device: MTLDevice, tick: Int) {
        guard let first = GlassCaptureBuffer(width: width, height: height, device: device),
              let second = GlassCaptureBuffer(width: width, height: height, device: device)
        else { return nil }
        slots = [first, second]
        byteCost = slots.reduce(0) { $0 + $1.bytesPerRow * height }
        lastUsedTick = tick
    }

    func writableBuffer() -> GlassCaptureBuffer? {
        for offset in 0..<slots.count {
            let index = (nextIndex + offset) % slots.count
            guard slots[index].isWritable else { continue }
            nextIndex = (index + 1) % slots.count
            return slots[index]
        }
        return nil
    }
}

/// Retained by the command's completion handler, even after host teardown
/// or pool eviction. Acquire and release exclusively on the main thread.
final class GlassCaptureReadLease {
    private var buffers: [GlassCaptureBuffer]

    init(_ buffers: [GlassCaptureBuffer]) {
        self.buffers = buffers
        for buffer in buffers { buffer.readers += 1 }
    }

    func release() {
        for buffer in buffers { buffer.readers -= 1 }
        buffers.removeAll()
    }
}
