import AccessCore
import ARKit
import CoreVideo
import MetalKit
import RoomPlan
import simd

/// Camera feedback has its own small display budget; RoomPlan keeps the complete measurements.
@MainActor
final class ScanPreviewCameraView: MTKView, MTKViewDelegate {
    private weak var session: ARSession?
    private var renderer: ScanPreviewRenderer?
    private var index = ScanPreviewIndex()
    private var visibleLines: [ScanPreviewLine] = []
    private var timer: Timer?
    private var worker: Task<Void, Never>?
    private var selectionWorker: Task<Void, Never>?
    private var pendingRoom: (room: CapturedRoom, observedAt: TimeInterval?)?
    private var generation = 0
    private var indexRevision = 0
    var onMeasurementsReady: ((ScanLiveRoomMeasurements) -> Void)?

    init(session: ARSession) {
        self.session = session
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        backgroundColor = .black
        isUserInteractionEnabled = false
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = false
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        preferredFramesPerSecond = 30
        isPaused = true
        delegate = self
        if let device { renderer = ScanPreviewRenderer(device: device, pixelFormat: colorPixelFormat) }
    }

    required init(coder: NSCoder) { fatalError("Use init(session:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(window?.screen.scale ?? 2, 2)
        drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        isPaused = window == nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleLines() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshVisibleLines()
    }

    func update(room: CapturedRoom, observedAt: TimeInterval?) {
        // Keep only the newest waiting room while one immutable snapshot is indexed off-thread.
        pendingRoom = (room, observedAt)
        buildPendingRoom()
    }

    func clearRoom() {
        generation += 1
        pendingRoom = nil
        worker?.cancel()
        selectionWorker?.cancel()
        index = ScanPreviewIndex()
        visibleLines = []
        renderer?.setLines([])
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isPaused = true
        clearRoom()
        renderer?.clear()
    }

    private func buildPendingRoom() {
        guard worker == nil, let pending = pendingRoom else { return }
        pendingRoom = nil
        let generation = generation
        let previous = index
        worker = Task.detached(priority: .utility) { [weak self] in
            var index = previous
            let measurements = ScanLiveRoomMeasurements(room: pending.room, observedAt: pending.observedAt)
            if !Task.isCancelled { index.replace(with: ScanPreviewMeasurements.components(in: pending.room)) }
            await self?.didBuild(index, measurements: measurements, generation: generation)
        }
    }

    private func didBuild(_ index: ScanPreviewIndex, measurements: ScanLiveRoomMeasurements, generation: Int) {
        worker = nil
        if self.generation == generation {
            self.index = index
            indexRevision += 1
            onMeasurementsReady?(measurements)
            refreshVisibleLines()
        }
        buildPendingRoom()
    }

    private func refreshVisibleLines() {
        guard window != nil, let frame = session?.currentFrame,
              case .normal = frame.camera.trackingState,
              abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 0.25 else {
            visibleLines = []
            renderer?.setLines([])
            return
        }
        guard selectionWorker == nil, let device else { return }
        let pose = frame.camera.transform.columns.3
        let position = SIMD3(pose.x, pose.y, pose.z), timestamp = frame.timestamp
        let index = index, previous = visibleLines, generation = generation, revision = indexRevision
        selectionWorker = Task.detached(priority: .utility) { [weak self] in
            let lines = index.nearbyLines(to: position)
            let prepared = !Task.isCancelled && lines != previous
                ? ScanPreviewPreparedLines.make(from: lines, device: device) : nil
            await self?.didSelect(lines, prepared: prepared, position: position, timestamp: timestamp,
                                  generation: generation, revision: revision)
        }
    }

    private func didSelect(_ lines: [ScanPreviewLine], prepared: ScanPreviewPreparedLines?,
                           position: SIMD3<Float>, timestamp: TimeInterval, generation: Int, revision: Int) {
        selectionWorker = nil
        guard self.generation == generation, indexRevision == revision else {
            refreshVisibleLines()
            return
        }
        // A late worker must not bring back old outlines after tracking loss or a quick move.
        guard window != nil, let frame = session?.currentFrame,
              case .normal = frame.camera.trackingState,
              abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 0.25,
              abs(ProcessInfo.processInfo.systemUptime - timestamp) < 0.5,
              simd_distance(position, frame.camera.transform.translation) <= 0.5 else {
            visibleLines = []
            renderer?.setLines([])
            return
        }
        guard let prepared else { return }
        visibleLines = lines
        renderer?.setPreparedLines(prepared)
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            renderer?.draw(view: self, frame: session?.currentFrame,
                           orientation: window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait)
        }
    }
}

/// Display-only rectangles and boxes. These never feed map construction or routing.
enum ScanPreviewMeasurements {
    nonisolated static func components(in room: CapturedRoom) -> [ScanPreviewComponent] {
        var result: [ScanPreviewComponent] = []
        for surface in room.walls + room.doors + room.openings + room.windows + room.floors {
            if Task.isCancelled { return [] }
            let corners = surface.polygonCorners
            guard corners.count <= 512 else { continue }
            let local: [SIMD3<Float>] = corners.count >= 3 ? corners : [
                SIMD3(-surface.dimensions.x / 2, -surface.dimensions.y / 2, 0),
                SIMD3(surface.dimensions.x / 2, -surface.dimensions.y / 2, 0),
                SIMD3(surface.dimensions.x / 2, surface.dimensions.y / 2, 0),
                SIMD3(-surface.dimensions.x / 2, surface.dimensions.y / 2, 0)
            ]
            let points = local.map { world($0, transform: surface.transform) }
            let lines = points.indices.map { ScanPreviewLine(start: points[$0], end: points[($0 + 1) % points.count]) }
            result.append(.init(id: surface.identifier, lines: lines))
        }
        let edges = [(0, 1), (1, 3), (3, 2), (2, 0), (4, 5), (5, 7), (7, 6), (6, 4),
                     (0, 4), (1, 5), (2, 6), (3, 7)]
        for object in room.objects {
            if Task.isCancelled { return [] }
            let half = object.dimensions / 2
            let points = (0..<8).map { i in
                world(SIMD3(i & 1 == 0 ? -half.x : half.x,
                            i & 2 == 0 ? -half.y : half.y,
                            i & 4 == 0 ? -half.z : half.z), transform: object.transform)
            }
            result.append(.init(id: object.identifier, lines: edges.map { .init(start: points[$0.0], end: points[$0.1]) }))
        }
        return result
    }

    private nonisolated static func world(_ point: SIMD3<Float>, transform: simd_float4x4) -> SIMD3<Float> {
        let p = transform * SIMD4(point, 1)
        return SIMD3(p.x, p.y, p.z)
    }
}

private struct ScanPreviewGPUline {
    var start: SIMD4<Float>
    var end: SIMD4<Float>
}

/// A worker creates this buffer once; the main actor only publishes its immutable handle.
struct ScanPreviewPreparedLines: @unchecked Sendable {
    let buffer: MTLBuffer?
    let count: Int

    nonisolated static func make(from lines: [ScanPreviewLine], device: MTLDevice) -> Self {
        guard !lines.isEmpty else { return .init(buffer: nil, count: 0) }
        let values = lines.prefix(ScanPreviewIndex.maximumVisibleLines).map {
            ScanPreviewGPUline(start: SIMD4($0.start, 1), end: SIMD4($0.end, 1))
        }
        let buffer = values.withUnsafeBytes { bytes -> MTLBuffer? in
            guard let address = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
        }
        return .init(buffer: buffer, count: buffer == nil ? 0 : values.count)
    }
}

private struct ScanPreviewUniforms {
    var viewProjection: simd_float4x4
    var inverseDisplay: simd_float3x3
    var sizes: SIMD4<Float>
    var cameraConversion: SIMD4<Float>
}

/// Two camera submissions at most, plus a fixed-capacity buffer of nearby lines.
@MainActor
final class ScanPreviewRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let cameraPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let inFlight = DispatchSemaphore(value: 2)
    private var lines: MTLBuffer?
    private(set) var lineCount = 0

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return nil }
        func pipeline(vertex: String, fragment: String, blending: Bool) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = pixelFormat
            color.isBlendingEnabled = blending
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let camera = pipeline(vertex: "cameraVertex", fragment: "cameraFragment", blending: false),
              let line = pipeline(vertex: "lineVertex", fragment: "lineFragment", blending: true) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device; self.queue = queue; cameraPipeline = camera; linePipeline = line
        textureCache = cache
    }

    func setLines(_ values: [ScanPreviewLine]) {
        setPreparedLines(ScanPreviewPreparedLines.make(from: values, device: device))
    }

    func setPreparedLines(_ prepared: ScanPreviewPreparedLines) {
        lines = prepared.buffer
        lineCount = prepared.count
    }

    func clear() {
        setLines([])
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    func draw(view: MTKView, frame: ARFrame?, orientation: UIInterfaceOrientation) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        guard let frame, view.bounds.width > 0, view.bounds.height > 0,
              let textures = textures(for: frame.capturedImage, depth: frame.sceneDepth),
              let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let inverse = frame.displayTransform(for: orientation, viewportSize: view.bounds.size).inverted()
        var uniforms = ScanPreviewUniforms(
            viewProjection: frame.camera.projectionMatrix(for: orientation, viewportSize: view.bounds.size,
                                                          zNear: 0.05, zFar: 8) * frame.camera.viewMatrix(for: orientation),
            inverseDisplay: simd_float3x3(columns: (SIMD3(Float(inverse.a), Float(inverse.b), 0),
                                                   SIMD3(Float(inverse.c), Float(inverse.d), 0),
                                                   SIMD3(Float(inverse.tx), Float(inverse.ty), 1))),
            sizes: SIMD4(Float(view.drawableSize.width), Float(view.drawableSize.height),
                         textures.videoRange ? 1 : 0, textures.depth == nil || textures.confidence == nil ? 0 : 1),
            cameraConversion: textures.bt709 ? SIMD4(1.5748, -0.187324, -0.468124, 1.8556)
                                            : SIMD4(1.402, -0.344136, -0.714136, 1.772))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ScanPreviewUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ScanPreviewUniforms>.stride, index: 1)
        encoder.setRenderPipelineState(cameraPipeline)
        encoder.setFragmentTexture(textures.y, index: 0)
        encoder.setFragmentTexture(textures.cbcr, index: 1)
        encoder.setFragmentTexture(textures.depth ?? textures.y, index: 2)
        encoder.setFragmentTexture(textures.confidence ?? textures.y, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        if case .normal = frame.camera.trackingState,
           abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 0.25,
           let lines, lineCount > 0 {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(lines, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: lineCount * 6)
        }
        encoder.endEncoding()
        command.present(drawable)
        let pacing = inFlight
        command.addCompletedHandler { [textures, pacing] _ in
            withExtendedLifetime(textures) {}
            pacing.signal()
        }
        submitted = true
        command.commit()
    }

    // Immutable ownership bundle; the completion handler only extends its lifetime.
    private struct CameraTextures: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let yWrapper: CVMetalTexture, cbcrWrapper: CVMetalTexture
        let y: MTLTexture, cbcr: MTLTexture
        let videoRange: Bool, bt709: Bool
        let depthBuffer: CVPixelBuffer?
        let depthWrapper: CVMetalTexture?
        let depth: MTLTexture?
        let confidenceBuffer: CVPixelBuffer?
        let confidenceWrapper: CVMetalTexture?
        let confidence: MTLTexture?
    }

    private func textures(for buffer: CVPixelBuffer, depth: ARDepthData?) -> CameraTextures? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        var y: CVMetalTexture?, cbcr: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil, .r8Unorm,
                    CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0), 0, &y) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil, .rg8Unorm,
                    CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), 1, &cbcr) == kCVReturnSuccess,
              let y, let cbcr, let yTexture = CVMetalTextureGetTexture(y), let cbcrTexture = CVMetalTextureGetTexture(cbcr) else { return nil }
        let depthBuffer = depth?.depthMap, confidence = depth?.confidenceMap
        var depthWrapper: CVMetalTexture?, confidenceWrapper: CVMetalTexture?
        if let depthBuffer, let confidence,
           CVPixelBufferGetPixelFormatType(depthBuffer) == kCVPixelFormatType_DepthFloat32,
           CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(depthBuffer) == CVPixelBufferGetWidth(confidence),
           CVPixelBufferGetHeight(depthBuffer) == CVPixelBufferGetHeight(confidence) {
            _ = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, depthBuffer, nil, .r32Float,
                    CVPixelBufferGetWidth(depthBuffer), CVPixelBufferGetHeight(depthBuffer), 0, &depthWrapper)
            _ = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, confidence, nil, .r8Unorm,
                    CVPixelBufferGetWidth(confidence), CVPixelBufferGetHeight(confidence), 0, &confidenceWrapper)
        }
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        return .init(buffer: buffer, yWrapper: y, cbcrWrapper: cbcr, y: yTexture, cbcr: cbcrTexture,
                     videoRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                     bt709: matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
                     depthBuffer: depthBuffer, depthWrapper: depthWrapper,
                     depth: depthWrapper.flatMap { CVMetalTextureGetTexture($0) },
                     confidenceBuffer: confidence, confidenceWrapper: confidenceWrapper,
                     confidence: confidenceWrapper.flatMap { CVMetalTextureGetTexture($0) })
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4x4 viewProjection; float3x3 inverseDisplay; float4 sizes; float4 cameraConversion; };
    struct Line { float4 start; float4 end; };
    struct CameraVertex { float4 position [[position]]; float2 uv; };
    struct LineVertex { float4 position [[position]]; float depth; };
    constant float2 corners[6] = {float2(-1,-1), float2(1,-1), float2(-1,1),
                                  float2(-1,1), float2(1,-1), float2(1,1)};
    vertex CameraVertex cameraVertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(1)]]) {
        float2 p = corners[id];
        float2 screen = float2((p.x + 1) * 0.5, (1 - p.y) * 0.5);
        return {float4(p, 0, 1), (u.inverseDisplay * float3(screen, 1)).xy};
    }
    fragment float4 cameraFragment(CameraVertex v [[stage_in]], constant Uniforms &u [[buffer(1)]],
                                    texture2d<float> y [[texture(0)]], texture2d<float> cbcr [[texture(1)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float luma = y.sample(s, v.uv).r;
        float2 chroma = cbcr.sample(s, v.uv).rg - 0.5;
        if (u.sizes.z > 0) { luma = (luma - 16.0/255.0) * (255.0/219.0); chroma *= 255.0/224.0; }
        float3 rgb = float3(luma + u.cameraConversion.x * chroma.y,
                            luma + u.cameraConversion.y * chroma.x + u.cameraConversion.z * chroma.y,
                            luma + u.cameraConversion.w * chroma.x);
        return float4(saturate(rgb), 1);
    }
    vertex LineVertex lineVertex(uint id [[vertex_id]], const device Line *lines [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]]) {
        Line line = lines[id / 6];
        float4 a = u.viewProjection * line.start, b = u.viewProjection * line.end;
        if (a.w <= 0.05 && b.w <= 0.05) return {float4(2, 2, 2, 1), 0};
        if (a.w < 0.05) a = mix(a, b, (0.05 - a.w) / (b.w - a.w));
        if (b.w < 0.05) b = mix(b, a, (0.05 - b.w) / (a.w - b.w));
        float2 direction = (b.xy/b.w - a.xy/a.w) * u.sizes.xy;
        float length = metal::length(direction);
        if (length < 0.01) return {float4(2, 2, 2, 1), 0};
        float2 offset = float2(-direction.y, direction.x) / length * 2.0 / u.sizes.xy;
        float2 corner = corners[id % 6];
        float4 p = corner.x < 0 ? a : b;
        p.xy += offset * corner.y * p.w;
        return {p, p.w};
    }
    fragment float4 lineFragment(LineVertex v [[stage_in]], constant Uniforms &u [[buffer(1)]],
                                 texture2d<float> depth [[texture(2)]], texture2d<float> confidence [[texture(3)]]) {
        if (u.sizes.w > 0) {
            constexpr sampler s(address::clamp_to_edge, filter::nearest);
            float2 uv = (u.inverseDisplay * float3(v.position.xy / u.sizes.xy, 1)).xy;
            float measured = depth.sample(s, uv).r;
            // Measured outlines tolerate small fitting differences but disappear behind nearer surfaces.
            if (confidence.sample(s, uv).r > 1.5/255.0 && isfinite(measured) && measured > 0
                && v.depth > measured + 0.2) discard_fragment();
        }
        return float4(1, 1, 1, 0.85);
    }
    """
}
