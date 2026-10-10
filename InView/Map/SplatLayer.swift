import Metal
import MetalKit
import MetalSplatter
import os
import simd
import SplatIO
import UIKit

/// Draws a trained Gaussian splat of the scanned space, the photoreal layer under the 3D map's route and pins.
///
/// The splat is trained on the scan's ARKit camera poses, so it's already in map coordinates: it's drawn with
/// exactly the map camera's view and a matching perspective projection. Anything above `ceiling` is left out
/// when loading, so ceilings and the tops of walls don't hide the floor from above, like the cutaway model.
@MainActor
final class SplatLayer: NSObject, MTKViewDelegate {
    enum State: Equatable {
        case loading
        case ready
        case failed
    }

    /// The camera each frame is drawn from, as a world-to-camera view matrix and a projection.
    struct Camera {
        var view: simd_float4x4
        var projection: simd_float4x4
    }

    let view: MTKView
    var camera: (() -> Camera?)?
    var onStateChange: ((State) -> Void)?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let clearColor: MTLClearColor
    private var renderer: SplatRenderer?
    private var loaded: (url: URL, ceiling: Float)?
    private var loadTask: Task<Void, Never>?
    private let inFlight = DispatchSemaphore(value: maxSimultaneousRenders)

    // Loading runs off the main actor, so these stay unisolated.
    nonisolated private static let maxSimultaneousRenders = 3
    nonisolated private static let colorFormat = MTLPixelFormat.bgra8Unorm_srgb
    nonisolated private static let depthFormat = MTLPixelFormat.depth32Float
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "InView", category: "splat")

    /// Nil when the device has no Metal GPU.
    init?(background: UIColor) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        clearColor = Self.linearClearColor(background)
        view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = Self.colorFormat
        view.depthStencilPixelFormat = Self.depthFormat
        view.sampleCount = 1
        view.backgroundColor = background
        view.preferredFramesPerSecond = 30
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        super.init()
        view.delegate = self
    }

    var isReady: Bool { renderer != nil }

    /// Loads the splat off the main thread, keeping only what's below `ceiling` (map y, in meters).
    func load(_ url: URL, below ceiling: Float) {
        guard loaded?.url != url || loaded?.ceiling != ceiling else { return }
        loaded = (url, ceiling)
        renderer = nil
        loadTask?.cancel()
        onStateChange?(.loading)
        let device = self.device
        let clearColor = self.clearColor
        loadTask = Task { [weak self] in
            do {
                let renderer = try await Task.detached(priority: .userInitiated) {
                    let started = Date.now
                    let points = try await AutodetectSceneReader(url).readAll()
                    let kept = points.filter { $0.position.y < ceiling }
                    guard !kept.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    let renderer = try SplatRenderer(device: device, colorFormat: Self.colorFormat, depthFormat: Self.depthFormat,
                                                     sampleCount: 1, maxViewCount: 1,
                                                     maxSimultaneousRenders: Self.maxSimultaneousRenders, clearColor: clearColor)
                    let chunk = try SplatChunk(device: device, from: kept)
                    await renderer.addChunk(chunk)
                    Self.log.info("splat: \(kept.count) of \(points.count) splats below \(ceiling) m, loaded in \(String(format: "%.2f", Date.now.timeIntervalSince(started)), privacy: .public) s")
                    return renderer
                }.value
                guard let self, !Task.isCancelled, self.loaded?.url == url else { return }
                self.renderer = renderer
                self.onStateChange?(.ready)
            } catch {
                guard let self, !Task.isCancelled else { return }
                Self.log.error("splat: couldn't load \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.onStateChange?(.failed)
            }
        }
    }

    func unload() {
        loadTask?.cancel()
        loadTask = nil
        loaded = nil
        renderer = nil
    }

    // MARK: MTKViewDelegate

    func draw(in view: MTKView) {
        guard let renderer, renderer.isReadyToRender, let camera = camera?(),
              let drawable = view.currentDrawable else { return }
        _ = inFlight.wait(timeout: .distantFuture)
        guard let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        let size = view.drawableSize
        let viewport = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(originX: 0, originY: 0, width: size.width, height: size.height, znear: 0, zfar: 1),
            projectionMatrix: camera.projection, viewMatrix: camera.view,
            screenSize: SIMD2(Int(size.width), Int(size.height)))
        let rendered = (try? renderer.render(viewports: [viewport], colorTexture: drawable.texture, colorStoreAction: .store,
                                             depthTexture: view.depthStencilTexture, rasterizationRateMap: nil,
                                             renderTargetArrayLength: 0, to: commands)) ?? false
        // A frame skipped while splats are being sorted keeps the last one on screen instead of a blank.
        if rendered { commands.present(drawable) }
        commands.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: Math

    /// Metal's right-handed perspective projection, depth 0...1: the same as the map camera's, for any field of view.
    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovy / 2)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    /// The sRGB target expects its clear color in linear light.
    private static func linearClearColor(_ color: UIColor) -> MTLClearColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ value: CGFloat) -> Double {
            Double(value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
        }
        return MTLClearColor(red: linear(red), green: linear(green), blue: linear(blue), alpha: Double(alpha))
    }
}
