import AccessCore
import ARKit
import CoreVideo
import MetalKit
import simd

struct ScanCoverageVertex: Sendable {
    var position: SIMD4<Float>
    var alpha: SIMD4<Float>
}

private struct ScanCoverageUniforms {
    var viewProjection: simd_float4x4
    var sensorView: simd_float4x4
    var inverseDisplay: simd_float3x3
    var sizes: SIMD4<Float>
}

/// A small measured mesh reprojects every draw; live depth removes occluded or changed surfaces.
@MainActor
final class ScanCoverageMetalRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let inFlight = DispatchSemaphore(value: 2)
    private var vertices: MTLBuffer?
    private var vertexCount = 0

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        let options = MTLCompileOptions()
        options.mathMode = .safe
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: options),
              let vertex = library.makeFunction(name: "coverageVertex"),
              let fragment = library.makeFunction(name: "coverageFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = pixelFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device; self.queue = queue; self.pipeline = pipeline; self.textureCache = cache
    }

    func clearGeometry() {
        vertices = nil
        vertexCount = 0
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    func setGeometry(_ geometry: [ScanCoverageVertex]) {
        guard !geometry.isEmpty, geometry.count <= 75_000 else { clearGeometry(); return }
        vertices = geometry.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
        }
        vertexCount = vertices == nil ? 0 : geometry.count
    }

    func draw(view: MTKView, frame: ARFrame?, orientation: UIInterfaceOrientation) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var retainedDepth: CoverageDepthTextures?
        if let frame, case .normal = frame.camera.trackingState,
           abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 0.25,
           let vertices, vertexCount > 0, view.bounds.width > 0, view.bounds.height > 0,
           let depth = frame.sceneDepth, let textures = makeTextures(depth) {
            retainedDepth = textures
            let inverse = frame.displayTransform(for: orientation, viewportSize: view.bounds.size).inverted()
            var uniforms = ScanCoverageUniforms(
                viewProjection: frame.camera.projectionMatrix(for: orientation, viewportSize: view.bounds.size,
                                                              zNear: 0.05, zFar: 8)
                    * frame.camera.viewMatrix(for: orientation),
                sensorView: frame.camera.transform.inverse,
                inverseDisplay: simd_float3x3(columns: (SIMD3(Float(inverse.a), Float(inverse.b), 0),
                                                        SIMD3(Float(inverse.c), Float(inverse.d), 0),
                                                        SIMD3(Float(inverse.tx), Float(inverse.ty), 1))),
                sizes: SIMD4(Float(view.drawableSize.width), Float(view.drawableSize.height),
                             Float(textures.depthTexture.width), Float(textures.depthTexture.height)))
            encoder.setRenderPipelineState(pipeline)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ScanCoverageUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ScanCoverageUniforms>.stride, index: 1)
            encoder.setFragmentTexture(textures.depthTexture, index: 0)
            encoder.setFragmentTexture(textures.confidenceTexture, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
        encoder.endEncoding()
        command.present(drawable)
        let pacing = inFlight
        // CV wrappers and their pixel buffers live for exactly this GPU submission; no camera image is retained.
        command.addCompletedHandler { [retainedDepth, pacing, weak view] completed in
            withExtendedLifetime(retainedDepth) {}
            if completed.status == .error {
                // Hide any last presented mask if the GPU cannot present a clear frame.
                Task { @MainActor in view?.isHidden = true }
            }
            pacing.signal()
        }
        submitted = true
        command.commit()
    }

    private func makeTextures(_ depth: ARDepthData) -> CoverageDepthTextures? {
        let buffer = depth.depthMap
        guard let confidence = depth.confidenceMap else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard (3...512).contains(width), (3...512).contains(height),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height else { return nil }
        var depthWrapper: CVMetalTexture?, confidenceWrapper: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil,
                                                       .r32Float, width, height, 0, &depthWrapper) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, confidence, nil,
                                                       .r8Unorm, width, height, 0, &confidenceWrapper) == kCVReturnSuccess,
              let depthWrapper, let confidenceWrapper,
              let depthTexture = CVMetalTextureGetTexture(depthWrapper),
              let confidenceTexture = CVMetalTextureGetTexture(confidenceWrapper) else { return nil }
        return .init(depth: buffer, confidence: confidence, depthWrapper: depthWrapper,
                     confidenceWrapper: confidenceWrapper, depthTexture: depthTexture, confidenceTexture: confidenceTexture)
    }

    nonisolated static func makeGeometry(frame: CaptureDepthFrame, coverage: DepthScanCoverageSnapshot) -> [ScanCoverageVertex] {
        guard !Task.isCancelled, let mask = coverage.mask(for: frame), !Task.isCancelled else { return [] }
        let image = frame.depth, camera = frame.camera, pose = frame.mapFromCamera
        let transform = simd_float4x4(columns: (SIMD4(pose[0], pose[1], pose[2], pose[3]),
                                               SIMD4(pose[4], pose[5], pose[6], pose[7]),
                                               SIMD4(pose[8], pose[9], pose[10], pose[11]),
                                               SIMD4(pose[12], pose[13], pose[14], pose[15])))
        let scaleX = Float(image.width) / Float(camera.imageWidth), scaleY = Float(image.height) / Float(camera.imageHeight)
        let fx = camera.fx * scaleX, fy = camera.fy * scaleY, cx = camera.cx * scaleX, cy = camera.cy * scaleY
        let step = max(2, Int(ceil(sqrt(Double(image.width * image.height) / 12_500))))
        var result: [ScanCoverageVertex] = []
        result.reserveCapacity(75_000)
        func vertex(_ x: Int, _ y: Int) -> ScanCoverageVertex {
            let index = y * image.width + x, z = image.valuesM[index]!
            let point = transform * SIMD4((Float(x) - cx) * z / fx, -(Float(y) - cy) * z / fy, -z, 1)
            return .init(position: point, alpha: SIMD4(Float(mask.alpha[index]) / 255, 0, 0, 0))
        }
        for row in stride(from: 1, to: image.height - 1 - step, by: step) {
            if Task.isCancelled { return [] }
            for column in stride(from: 1, to: image.width - 1 - step, by: step) {
                var low = Float.greatestFiniteMagnitude, high: Float = 0, supported = true
                // Checking the entire small cell prevents coarse triangles spanning holes or thin objects.
                for y in row...(row + step) {
                    for x in column...(column + step) {
                        let index = y * image.width + x
                        guard mask.alpha[index] > 0, let value = image.valuesM[index], value.isFinite else {
                            supported = false; continue
                        }
                        low = min(low, value); high = max(high, value)
                    }
                }
                guard supported, high - low <= 0.025 + low * 0.01, result.count <= 75_000 - 6 else { continue }
                let a = vertex(column, row), b = vertex(column + step, row)
                let c = vertex(column, row + step), d = vertex(column + step, row + step)
                result.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        return result
    }

    nonisolated static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct CoverageVertex { float4 position; float4 alpha; };
    struct CoverageUniforms {
        float4x4 viewProjection;
        float4x4 sensorView;
        float3x3 inverseDisplay;
        float4 sizes;
    };
    struct CoverageRaster {
        float4 position [[position]];
        float expectedDepth;
        float alpha;
    };
    vertex CoverageRaster coverageVertex(uint id [[vertex_id]],
        const device CoverageVertex *vertices [[buffer(0)]], constant CoverageUniforms &u [[buffer(1)]]) {
        CoverageRaster out;
        out.position = u.viewProjection * vertices[id].position;
        out.expectedDepth = -(u.sensorView * vertices[id].position).z;
        out.alpha = vertices[id].alpha.x;
        return out;
    }
    fragment float4 coverageFragment(CoverageRaster in [[stage_in]],
        constant CoverageUniforms &u [[buffer(1)]], texture2d<float, access::read> depth [[texture(0)]],
        texture2d<float, access::read> confidence [[texture(1)]]) {
        float2 uv = (u.inverseDisplay * float3(in.position.xy / u.sizes.xy, 1)).xy;
        if (any(uv <= 0) || any(uv >= 1)) discard_fragment();
        uint2 pixel = uint2(uv * u.sizes.zw);
        if (pixel.x < 1 || pixel.y < 1 || pixel.x + 1 >= depth.get_width() || pixel.y + 1 >= depth.get_height()) discard_fragment();
        float live = depth.read(pixel).r;
        float level = confidence.read(pixel).r * 255;
        if (!isfinite(live) || live < 0.2 || live > 5 || level < 1.5 || level > 2.5
            || !isfinite(in.expectedDepth) || abs(live - in.expectedDepth) > 0.03 + live * 0.005) discard_fragment();
        const int2 offsets[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
        for (int i = 0; i < 4; ++i) {
            uint2 neighbor = uint2(int2(pixel) + offsets[i]);
            float neighborDepth = depth.read(neighbor).r;
            float neighborLevel = confidence.read(neighbor).r * 255;
            if (!isfinite(neighborDepth) || neighborDepth < 0.2 || neighborDepth > 5
                || neighborLevel < 1.5 || neighborLevel > 2.5 || abs(neighborDepth - live) > 0.015 + live * 0.01) discard_fragment();
        }
        float alpha = clamp(in.alpha, 0.0f, 55.0f / 255.0f);
        return float4(float3(35, 215, 105) / 255 * alpha, alpha);
    }
    """
}

// Immutable resource handles cross to the completion queue only to retain/release them.
// That callback never reads or mutates their sensor bytes.
private struct CoverageDepthTextures: @unchecked Sendable {
    let depth: CVPixelBuffer
    let confidence: CVPixelBuffer
    let depthWrapper: CVMetalTexture
    let confidenceWrapper: CVMetalTexture
    let depthTexture: MTLTexture
    let confidenceTexture: MTLTexture
}
