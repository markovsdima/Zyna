//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Metal
import MetalKit
import UIKit

final class RoomSpaceLinkHeroView: UIView {

    struct Configuration: Equatable {
        let groupId: String
        let groupName: String
        let groupAvatarMxcURL: String?
        let spaceId: String
        let spaceName: String
        let spaceAvatarMxcURL: String?
        let hasSpaceSideLink: Bool
        let hasRoomSideLink: Bool
        let canEditSpaceSide: Bool
        let canEditRoomSide: Bool
    }

    override class var layerClass: AnyClass { CAMetalLayer.self }

    private struct QuadVertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    private struct Uniforms {
        var resolutionTimeScale: SIMD4<Float>
        var linkState: SIMD4<Float>
        var appearance: SIMD4<Float>
    }

    private struct RenderPayload {
        let metalLayer: CAMetalLayer
        let pipelineState: MTLRenderPipelineState
        let groupTexture: MTLTexture
        let spaceTexture: MTLTexture
        let vertices: [QuadVertex]
        let uniforms: Uniforms
    }

    private static let pipelineState: MTLRenderPipelineState? = {
        let ctx = MetalContext.shared
        guard let vertexFunction = ctx.library.makeFunction(name: "roomSpaceLinkHeroVertex"),
              let fragmentFunction = ctx.library.makeFunction(name: "roomSpaceLinkHeroFragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = false

        return try? ctx.device.makeRenderPipelineState(descriptor: descriptor)
    }()

    private static let vertices = [
        QuadVertex(position: SIMD2<Float>(-1, -1), uv: SIMD2<Float>(0, 1)),
        QuadVertex(position: SIMD2<Float>(1, -1), uv: SIMD2<Float>(1, 1)),
        QuadVertex(position: SIMD2<Float>(-1, 1), uv: SIMD2<Float>(0, 0)),
        QuadVertex(position: SIMD2<Float>(1, 1), uv: SIMD2<Float>(1, 0))
    ]

    private var metalLayer: CAMetalLayer {
        // swiftlint:disable:next force_cast
        layer as! CAMetalLayer
    }

    private let textureLoader = MTKTextureLoader(device: MetalContext.shared.device)
    private let renderQueue = DispatchQueue(label: "room.space.link.hero.render", qos: .userInteractive)
    private var displayLinkToken: DisplayLinkToken?
    private var configuration: Configuration?
    private var groupTexture: MTLTexture?
    private var spaceTexture: MTLTexture?
    private var avatarLoadTask: Task<Void, Never>?
    private var avatarLoadRevision: UInt64 = 0
    private var startTime = CACurrentMediaTime()
    private var frameInFlight = false
    private var needsRender = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        avatarLoadTask?.cancel()
        displayLinkToken?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func apply(_ configuration: Configuration) {
        guard self.configuration != configuration else { return }

        let previousConfiguration = self.configuration
        let shouldReloadAvatars = previousConfiguration.map {
            $0.groupId != configuration.groupId
                || $0.groupName != configuration.groupName
                || $0.groupAvatarMxcURL != configuration.groupAvatarMxcURL
                || $0.spaceId != configuration.spaceId
                || $0.spaceName != configuration.spaceName
                || $0.spaceAvatarMxcURL != configuration.spaceAvatarMxcURL
        } ?? true

        self.configuration = configuration
        if shouldReloadAvatars {
            avatarLoadRevision &+= 1
            let revision = avatarLoadRevision
            installFallbackTextures(for: configuration)
            loadAvatarTextures(for: configuration, revision: revision)
        }
        setNeedsRender()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLinkToken?.invalidate()
            displayLinkToken = nil
        } else {
            startTime = CACurrentMediaTime()
            setNeedsRender()
        }
        updateDisplayLinkSubscription()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        setNeedsRender()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        setNeedsRender()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false

        metalLayer.device = MetalContext.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.maximumDrawableCount = 3
        metalLayer.presentsWithTransaction = false
        if #available(iOS 16, *) {
            metalLayer.allowsNextDrawableTimeout = false
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
    }

    @objc private func reduceMotionChanged() {
        updateDisplayLinkSubscription()
        setNeedsRender()
    }

    private func installFallbackTextures(for configuration: Configuration) {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let avatarSide = max(160, Int(ceil(180 * scale)))

        let groupImage = AvatarViewModel(
            userId: configuration.groupId,
            displayName: configuration.groupName,
            mxcAvatarURL: nil
        ).circleImage(diameter: CGFloat(avatarSide), fontSize: CGFloat(avatarSide) * 0.28)

        let spaceImage = AvatarViewModel(
            userId: configuration.spaceId,
            displayName: configuration.spaceName,
            mxcAvatarURL: nil
        ).roundedRectImage(
            size: CGSize(width: avatarSide, height: avatarSide),
            cornerRadius: CGFloat(avatarSide) * 0.06,
            fontSize: CGFloat(avatarSide) * 0.28
        )

        groupTexture = makeTexture(from: groupImage)
        spaceTexture = makeTexture(from: spaceImage)
    }

    private func loadAvatarTextures(for configuration: Configuration, revision: UInt64) {
        avatarLoadTask?.cancel()
        avatarLoadTask = Task { [weak self] in
            guard let self else { return }

            let size = 360
            var loadedGroupImage: UIImage?
            var loadedSpaceImage: UIImage?

            if let mxc = configuration.groupAvatarMxcURL {
                loadedGroupImage = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size)
            }

            if Task.isCancelled { return }

            if let mxc = configuration.spaceAvatarMxcURL {
                loadedSpaceImage = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size)
            }

            if Task.isCancelled { return }

            await MainActor.run { [weak self] in
                guard let self,
                      self.avatarLoadRevision == revision
                else { return }

                if let loadedGroupImage {
                    self.groupTexture = self.makeTexture(from: loadedGroupImage)
                }
                if let loadedSpaceImage {
                    self.spaceTexture = self.makeTexture(from: loadedSpaceImage)
                }
                self.setNeedsRender()
            }
        }
    }

    private func makeTexture(from image: UIImage) -> MTLTexture? {
        guard let cgImage = image.cgImage else { return nil }
        return try? textureLoader.newTexture(
            cgImage: cgImage,
            options: [
                .SRGB: false as NSNumber,
                .origin: MTKTextureLoader.Origin.topLeft.rawValue as NSString
            ]
        )
    }

    private func setNeedsRender() {
        needsRender = true
        updateDisplayLinkSubscription()
        if displayLinkToken == nil {
            renderIfNeeded()
        }
    }

    private func updateDisplayLinkSubscription() {
        let shouldRun = window != nil
            && !UIAccessibility.isReduceMotionEnabled
            && !isHidden
            && alpha > 0.01
            && configuration != nil

        guard shouldRun else {
            displayLinkToken?.invalidate()
            displayLinkToken = nil
            return
        }

        guard displayLinkToken == nil else { return }
        displayLinkToken = DisplayLinkDriver.shared.subscribe(rate: .fps(60)) { [weak self] _ in
            self?.renderIfNeeded(force: true)
        }
    }

    private func renderIfNeeded(force: Bool = false) {
        guard force || needsRender else { return }
        needsRender = false
        render()
    }

    private func render() {
        guard bounds.width > 1,
              bounds.height > 1,
              let pipelineState = Self.pipelineState,
              let groupTexture,
              let spaceTexture
        else { return }

        guard !frameInFlight else {
            needsRender = true
            return
        }

        frameInFlight = true
        let payload = RenderPayload(
            metalLayer: metalLayer,
            pipelineState: pipelineState,
            groupTexture: groupTexture,
            spaceTexture: spaceTexture,
            vertices: Self.vertices,
            uniforms: makeUniforms()
        )

        renderQueue.async { [weak self] in
            guard let commandBuffer = MetalContext.shared.commandQueue.makeCommandBuffer(),
                  let drawable = payload.metalLayer.nextDrawable()
            else {
                DispatchQueue.main.async {
                    self?.frameInFlight = false
                    self?.needsRender = true
                }
                return
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = drawable.texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                commandBuffer.commit()
                DispatchQueue.main.async {
                    self?.frameInFlight = false
                    self?.needsRender = true
                }
                return
            }

            var vertices = payload.vertices
            var uniforms = payload.uniforms
            encoder.setRenderPipelineState(payload.pipelineState)
            encoder.setVertexBytes(
                &vertices,
                length: MemoryLayout<QuadVertex>.stride * vertices.count,
                index: 0
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(payload.groupTexture, index: 0)
            encoder.setFragmentTexture(payload.spaceTexture, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()

            commandBuffer.addCompletedHandler { _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.frameInFlight = false
                    if self.needsRender, self.displayLinkToken == nil {
                        self.renderIfNeeded()
                    }
                }
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    private func makeUniforms() -> Uniforms {
        let drawableSize = metalLayer.drawableSize
        let darkMode: Float = traitCollection.userInterfaceStyle == .dark ? 1 : 0
        let reduceMotion: Float = UIAccessibility.isReduceMotionEnabled ? 1 : 0
        let linkState: SIMD4<Float>

        if let configuration {
            linkState = SIMD4<Float>(
                configuration.hasSpaceSideLink ? 1 : 0,
                configuration.hasRoomSideLink ? 1 : 0,
                configuration.canEditSpaceSide ? 1 : 0,
                configuration.canEditRoomSide ? 1 : 0
            )
        } else {
            linkState = SIMD4<Float>(0, 0, 0, 0)
        }

        return Uniforms(
            resolutionTimeScale: SIMD4<Float>(
                Float(max(drawableSize.width, 1)),
                Float(max(drawableSize.height, 1)),
                Float(CACurrentMediaTime() - startTime),
                Float(window?.screen.scale ?? UIScreen.main.scale)
            ),
            linkState: linkState,
            appearance: SIMD4<Float>(darkMode, reduceMotion, 0, 0)
        )
    }
}
