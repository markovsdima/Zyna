//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Metal

final class GlassPipeline {
    static let shared = GlassPipeline()

    let pipelineState: MTLRenderPipelineState

    private init() {
        let ctx = MetalContext.shared

        let vertexFunction = ctx.library.makeFunction(name: "glassVertex")!
        let fragmentFunction = ctx.library.makeFunction(name: "glassFragment")!

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction

        let ca = descriptor.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .sourceAlpha
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.pipelineState = try! ctx.device.makeRenderPipelineState(descriptor: descriptor)
    }
}
