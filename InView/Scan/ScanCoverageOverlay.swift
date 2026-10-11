import AccessCore
import ARKit
import CoreVideo
import MetalKit
import SwiftUI
import UIKit
import simd

/// Saved coverage stays attached to measured surfaces as the camera moves.
struct ScanCoverageOverlay: UIViewRepresentable {
    let session: ARSession
    let coverage: DepthScanCoverageSnapshot

    func makeUIView(context: Context) -> ScanCoverageCameraView {
        let view = ScanCoverageCameraView()
        view.configure(session: session, coverage: coverage)
        return view
    }

    func updateUIView(_ view: ScanCoverageCameraView, context: Context) {
        view.configure(session: session, coverage: coverage)
    }

    static func dismantleUIView(_ view: ScanCoverageCameraView, coordinator: ()) { view.stop() }
}

@MainActor
final class ScanCoverageCameraView: MTKView, MTKViewDelegate {
    private weak var session: ARSession?
    private var coverage = DepthScanCoverage().snapshot()
    private var renderer: ScanCoverageMetalRenderer?
    private var timer: Timer?
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var generation = 0
    private var lastSampleTimestamp: TimeInterval?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        prepareRenderer()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        if device == nil { device = MTLCreateSystemDefaultDevice() }
        prepareRenderer()
    }

    private func prepareRenderer() {
        isOpaque = false
        layer.isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = false
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        preferredFramesPerSecond = 30
        isPaused = true
        delegate = self
        if let device { renderer = ScanCoverageMetalRenderer(device: device, pixelFormat: colorPixelFormat) }
    }

    func configure(session: ARSession, coverage: DepthScanCoverageSnapshot) {
        if self.session !== session {
            stop()
            self.session = session
            lastSampleTimestamp = nil
        }
        self.coverage = coverage
        if coverage.isEmpty {
            stop()
            return
        }
        if window != nil { start() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A transparent accent does not need three full-resolution camera-sized
        // drawable buffers. Two pixels per point keep its fine details crisp.
        let scale = min(window?.screen.scale ?? 2, 2)
        drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    private func start() {
        guard renderer != nil, !coverage.isEmpty else { return }
        isPaused = false
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        worker?.cancel()
        // Keep the worker slot until its copied sample finishes, including quick reattachments.
        renderer?.clearGeometry()
        draw()
        isPaused = true
    }

    private func sample() {
        guard window != nil, bounds.width > 0, bounds.height > 0, !coverage.isEmpty,
              worker == nil, let frame = session?.currentFrame,
              case .normal = frame.camera.trackingState,
              abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 0.25,
              lastSampleTimestamp != frame.timestamp, let depth = frame.sceneDepth,
              let copied = CopiedCoverageDepth(frame: frame, depth: depth) else { return }
        let coverage = coverage, generation = generation, id = UUID()
        workerID = id
        lastSampleTimestamp = frame.timestamp
        worker = Task.detached(priority: .utility) { [weak self] in
            let geometry = ScanCoverageMetalRenderer.makeGeometry(frame: copied.decodedFrame(), coverage: coverage)
            await self?.didBuild(geometry, generation: generation, id: id)
        }
    }

    private func didBuild(_ geometry: ScanCoverageGeometry, generation: Int, id: UUID) {
        guard workerID == id else { return }
        worker = nil
        workerID = nil
        guard self.generation == generation, window != nil else { return }
        renderer?.setGeometry(geometry)
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            renderer?.draw(view: self, frame: session?.currentFrame,
                           orientation: window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait)
        }
    }
}

/// Copy only depth/confidence bytes. No ARFrame or mutable sensor buffer reaches the mesh worker.
private struct CopiedCoverageDepth: Sendable {
    let timestamp: TimeInterval
    let pose: simd_float4x4
    let camera: CaptureCameraCalibration
    let width: Int, height: Int, depthStride: Int, confidenceStride: Int
    let depth: Data, confidence: Data

    @MainActor
    init?(frame: ARFrame, depth: ARDepthData) {
        let buffer = depth.depthMap
        guard let confidence = depth.confidenceMap else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let depthStride = CVPixelBufferGetBytesPerRow(buffer)
        let confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        guard (3...512).contains(width), (3...512).contains(height),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height,
              depthStride >= width * 4, depthStride <= 4_096,
              confidenceStride >= width, confidenceStride <= 1_024,
              let depthBytes = Self.copyBytes(buffer, count: depthStride * height),
              let confidenceBytes = Self.copyBytes(confidence, count: confidenceStride * height) else { return nil }
        let intrinsics = frame.camera.intrinsics, resolution = frame.camera.imageResolution
        self.timestamp = frame.timestamp
        self.pose = frame.camera.transform
        self.camera = .init(imageWidth: Int(resolution.width), imageHeight: Int(resolution.height),
                            fx: intrinsics[0][0], fy: intrinsics[1][1], cx: intrinsics[2][0], cy: intrinsics[2][1])
        self.width = width; self.height = height
        self.depthStride = depthStride; self.confidenceStride = confidenceStride
        self.depth = depthBytes; self.confidence = confidenceBytes
    }

    private static func copyBytes(_ buffer: CVPixelBuffer, count: Int) -> Data? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let pointer = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return Data(bytes: pointer, count: count)
    }

    func decodedFrame() -> CaptureDepthFrame {
        let values: [Float?] = depth.withUnsafeBytes { bytes in
            (0..<height).flatMap { row in (0..<width).map { column in
                let value = bytes.loadUnaligned(fromByteOffset: row * depthStride + column * 4, as: Float.self)
                return value.isFinite && value > 0 ? value : nil
            } }
        }
        let confidence: [Int] = confidence.withUnsafeBytes { bytes in
            (0..<height).flatMap { row in (0..<width).map { column in
                Int(bytes.load(fromByteOffset: row * confidenceStride + column, as: UInt8.self))
            } }
        }
        let matrix = (0..<4).flatMap { [pose[$0].x, pose[$0].y, pose[$0].z, pose[$0].w] }
        return .init(id: "coverage-preview", timestampSeconds: timestamp, mapFromCamera: matrix,
                     camera: camera, depth: .init(width: width, height: height, valuesM: values, confidence: confidence))
    }
}
