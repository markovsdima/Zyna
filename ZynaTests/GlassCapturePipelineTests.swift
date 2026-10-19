//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Metal
import Testing
import UIKit
@testable import Zyna

@Suite("Glass capture CPU/GPU overlap", .serialized)
@MainActor
struct GlassCapturePipelineTests {
    private func pool() throws -> GlassCaptureBufferPool {
        try #require(GlassCaptureBufferPool(
            width: 32, height: 32, device: MetalContext.shared.device, tick: 0
        ))
    }

    @Test("CPU never reacquires a buffer with GPU readers")
    func busyBuffers() throws {
        let pool = try pool()
        let first = try #require(pool.writableBuffer())
        let firstReader = GlassCaptureReadLease([first])
        let second = try #require(pool.writableBuffer())
        #expect(first !== second)
        let secondReader = GlassCaptureReadLease([second])
        defer { firstReader.release(); secondReader.release() }
        #expect(pool.writableBuffer() == nil)
        firstReader.release()
        #expect(pool.writableBuffer() === first)
        #expect(!second.isWritable)
    }

    @Test("Two hosts may read one buffer; late repeated release cannot unpin its successor")
    func sharedReaders() throws {
        let buffers = try pool()
        let buffer = try #require(buffers.writableBuffer())
        let oldHost = GlassCaptureReadLease([buffer])
        let newHost = GlassCaptureReadLease([buffer])
        oldHost.release()
        #expect(!buffer.isWritable)
        oldHost.release()
        #expect(!buffer.isWritable)
        newHost.release()
        let successor = GlassCaptureReadLease([buffer])
        oldHost.release()
        #expect(!buffer.isWritable)
        successor.release()
        #expect(buffer.isWritable)
    }

    @Test("Equal-sized anchor pools do not share writable memory")
    func separateAnchors() throws {
        let first = try pool()
        let second = try pool()
        let a = try #require(first.writableBuffer())
        let b = try #require(second.writableBuffer())
        #expect(a !== b)
        #expect(a.ctx.data != b.ctx.data)
        let reader = GlassCaptureReadLease([a])
        defer { reader.release() }
        #expect(second.slots.allSatisfy { $0.isWritable })
    }

    @Test("A GPU lease keeps capture memory alive after pool eviction")
    func evictedPool() throws {
        var pool: GlassCaptureBufferPool? = try self.pool()
        weak var buffer = pool?.slots.first
        let reader = GlassCaptureReadLease([try #require(buffer)])
        pool = nil
        #expect(buffer != nil)
        reader.release()
        #expect(buffer == nil)
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let renderer = GlassRenderer()

        init() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.rootViewController = UIViewController()
            window.isHidden = false
            renderer.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            window.rootViewController!.view.addSubview(renderer)
            renderer.layoutIfNeeded()
            renderer.updateDrawableSize(scale: window.screen.scale)
        }

        func close() {
            renderer.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }

        func item(_ source: GlassCaptureBuffer, refresh: Bool = true) -> GlassRenderer.RenderItem {
            var shapes = GlassRenderer.ShapeParams()
            shapes.shape0 = SIMD4<Float>(0, 0, 1, 1)
            return GlassRenderer.RenderItem(
                name: "test", frame: renderer.bounds, captureFrameInWindow: renderer.bounds,
                source: source, shapes: shapes, isHDR: false, liquidZone: nil,
                time: 0, barData: nil, glyphData: nil, previewData: nil,
                voiceData: nil, backdropOverlay: nil, refreshBlur: refresh,
                adaptiveAppearance: 1, adaptiveContrast: 0
            )
        }

        func blockGPU() throws -> MTLSharedEvent {
            let event = try #require(MetalContext.shared.device.makeSharedEvent())
            let command = try #require(MetalContext.shared.commandQueue.makeCommandBuffer())
            command.encodeWaitForEvent(event, value: 1)
            command.commit()
            return event
        }

        func waitForIdle() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while renderer.isFrameInFlight || renderer.hasPendingFrame {
                try #require(ContinuousClock.now < deadline, "GPU did not retire its frames")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

#if DEBUG && GLASS_PROFILING
    @Test("A busy GPU keeps only the latest frame with profiling on or off", arguments: [false, true])
#else
    @Test("A busy GPU keeps only the latest frame without profiling hooks", arguments: [false])
#endif
    func latestPendingFrame(profiling: Bool) async throws {
#if DEBUG && GLASS_PROFILING
        let originalScopes = LogConfig.enabled
        defer { LogConfig.enabled = originalScopes }
        if profiling {
            LogConfig.enabled.insert(.glassPerf)
        } else {
            LogConfig.enabled.remove(.glassPerf)
        }
#endif
        let fixture = try Fixture()
        defer { fixture.close() }
        let pool = try pool()
        let first = pool.slots[0]
        let latest = pool.slots[1]
        let event = try fixture.blockGPU()
        defer { event.signaledValue = 1 }
        do {
#if DEBUG && GLASS_PROFILING
            let profiler = GlassCaptureProfiler.shared
            profiler.noteScroll()
            let now = CACurrentMediaTime()
            profiler.beginTick(DisplayLinkDriver.Frame(
                timestamp: now, targetTimestamp: now + 1.0 / 120,
                deltaTime: 1.0 / 120
            ))
            defer { profiler.endTick() }
#endif

            let initial = try #require(fixture.renderer.render(items: [fixture.item(first)]))
            #expect(!initial.queued)
            #expect(!first.isWritable)
#if DEBUG && GLASS_PROFILING
            #expect((initial.drawableMs > 0) == profiling)
            #expect((fixture.renderer.profileSubmission != nil) == profiling)
#endif
            let pending = try #require(fixture.renderer.render(items: [fixture.item(latest)]))
            #expect(pending.queued)
            #expect(fixture.renderer.hasPendingFrame)
            #expect(latest.isWritable)

            // A fresh tick discards stale geometry before rewriting this buffer.
            fixture.renderer.discardPendingFrame()
            latest.didCapture()
            let replacement = try #require(fixture.renderer.render(items: [fixture.item(latest)]))
            #expect(replacement.queued)
        }
        event.signaledValue = 1
        try await fixture.waitForIdle()
        #expect(first.isWritable && latest.isWritable)
#if DEBUG && GLASS_PROFILING
        #expect((fixture.renderer.profileSubmission != nil) == profiling)
#endif

        // The pending frame actually reached the GPU, including its blur.
        let reused = try #require(fixture.renderer.render(items: [fixture.item(latest, refresh: false)]))
        #expect(reused.blurPassCount == 0)
        try await fixture.waitForIdle()
    }

    @Test("Resizing discards pending geometry without releasing in-flight GPU memory")
    func resizeWithPendingFrame() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let buffers = try pool()
        let first = buffers.slots[0]
        let pending = buffers.slots[1]
        let event = try fixture.blockGPU()
        defer { event.signaledValue = 1 }
        _ = try #require(fixture.renderer.render(items: [fixture.item(first)]))
        let queued = try #require(fixture.renderer.render(items: [fixture.item(pending)]))
        #expect(queued.queued)

        // The per-tick size check must preserve a valid waiting frame.
        fixture.renderer.updateDrawableSize(scale: fixture.window.screen.scale)
        #expect(fixture.renderer.hasPendingFrame)

        fixture.renderer.frame.size = CGSize(width: 48, height: 48)
        fixture.renderer.layoutIfNeeded()
        #expect(!fixture.renderer.hasPendingFrame)
        #expect(fixture.renderer.isFrameInFlight)
        #expect(!first.isWritable)
        #expect(pending.isWritable)

        event.signaledValue = 1
        try await fixture.waitForIdle()
        #expect(buffers.slots.allSatisfy { $0.isWritable })

        // A discarded frame must not warm the blur cache on completion.
        // Submit current geometry and verify that rendering can resume.
        let current = try #require(fixture.renderer.render(items: [fixture.item(pending, refresh: false)]))
        #expect(!current.queued)
        #expect(current.blurPassCount == 1)
        try await fixture.waitForIdle()
    }

    @Test("A new generation refreshes blur even when a render-only frame replaces capture")
    func overwrittenSource() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let buffers = try pool()
        let buffer = try #require(buffers.writableBuffer())
        buffer.didCapture()
        _ = try #require(fixture.renderer.render(items: [fixture.item(buffer)]))
        try await fixture.waitForIdle()
        let reused = try #require(fixture.renderer.render(items: [fixture.item(buffer, refresh: false)]))
        #expect(reused.blurPassCount == 0)
        try await fixture.waitForIdle()
        buffer.didCapture()
        let updated = try #require(fixture.renderer.render(items: [fixture.item(buffer, refresh: false)]))
        #expect(updated.blurPassCount == 1)
        try await fixture.waitForIdle()
    }

    @Test("Detaching a host discards pending work but retains GPU memory until completion")
    func detachedHost() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let pool = try pool()
        let event = try fixture.blockGPU()
        defer { event.signaledValue = 1 }
        _ = try #require(fixture.renderer.render(items: [fixture.item(pool.slots[0])]))
        _ = try #require(fixture.renderer.render(items: [fixture.item(pool.slots[1])]))
        fixture.renderer.removeFromSuperview()
        #expect(!fixture.renderer.hasPendingFrame)
        #expect(!pool.slots[0].isWritable)
        event.signaledValue = 1
        try await fixture.waitForIdle()
        #expect(pool.slots.allSatisfy { $0.isWritable })
    }
}
