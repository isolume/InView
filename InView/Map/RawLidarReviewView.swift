import AccessCore
import ImageIO
import SceneKit
import SwiftUI
import simd

/// Inspection of the original stream, independent of the corrected model and navigation map.
struct RawLidarReviewView: View {
    let scanID: String
    @Environment(\.dismiss) private var dismiss
    @State private var colorized = true
    @State private var cloud: LidarPreview?
    @State private var failure: String?
    @State private var exporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportDirectory: URL?
    @State private var exportShare: ScanEvidenceShare?
    @State private var exportFailure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let cloud, !cloud.positions.isEmpty {
                    LidarPreviewCanvas(cloud: cloud, colorized: colorized)
                        .ignoresSafeArea(edges: .bottom)
                        .safeAreaInset(edge: .bottom) {
                            Text("Original scan · \(cloud.sampledFrames) of \(cloud.totalFrames) views")
                                .font(.caption)
                                .padding(12)
                                .background(.thinMaterial, in: Capsule())
                                .padding()
                        }
                } else if let failure {
                    ContentUnavailableView("Scan data unavailable", systemImage: "viewfinder",
                                           description: Text(failure))
                } else if cloud != nil {
                    ContentUnavailableView("No depth points", systemImage: "viewfinder",
                                           description: Text("The saved views contain no usable depth measurements."))
                } else {
                    ProgressView("Loading scan data…")
                }
            }
            .navigationTitle("Scan data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Appearance", selection: $colorized) {
                        Text("Depth").tag(false)
                        Text("Color").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .disabled(cloud == nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if exporting { exportTask?.cancel() }
                        else { exportEvidence() }
                    } label: {
                        if exporting { ProgressView() }
                        else { Image(systemName: "square.and.arrow.up") }
                    }
                    .accessibilityLabel(exporting ? "Cancel export" : "Export scan data")
                    .disabled(cloud == nil || cloud?.totalFrames == 0)
                }
            }
            .task {
                do {
                    let id = scanID
                    cloud = try await ScanWork.run { try LidarPreview.load(scanID: id) }
                } catch is CancellationError {
                    // Closing the view cancels its disk reads and decoding.
                } catch { failure = error.localizedDescription }
            }
            .onDisappear {
                exportTask?.cancel()
                if !exporting, exportShare == nil { discardExport() }
            }
            .sheet(item: $exportShare, onDismiss: discardExport) { share in
                ScanEvidenceShareSheet(url: share.url)
            }
            .alert("Could not export scan data", isPresented: Binding(
                get: { exportFailure != nil }, set: { if !$0 { exportFailure = nil } }
            )) {
                Button("OK", role: .cancel) { exportFailure = nil }
            } message: { Text(exportFailure ?? "Please try again.") }
        }
    }

    private func exportEvidence() {
        guard !exporting else { return }
        discardExport()
        let id = scanID
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "inview-evidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        exportDirectory = directory
        exporting = true
        exportTask = Task {
            do {
                let url = try await ScanWork.run(priority: .utility) {
                    do {
                        try Task.checkCancellation()
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let archive = try StreamEvidenceArchive(root: CaptureStore.streamRoot(for: id), expectedScanID: id)
                        let url = directory.appending(path: "scan-\(id).tar")
                        try StreamEvidenceExport.write(archive: archive, to: url)
                        try Task.checkCancellation()
                        return url
                    } catch {
                        // The detached worker owns cleanup too: caller cancellation can arrive
                        // before ScanWork has begun waiting for that worker to finish.
                        try? FileManager.default.removeItem(at: directory)
                        throw error
                    }
                }
                try Task.checkCancellation()
                exportShare = ScanEvidenceShare(url: url)
            } catch is CancellationError {
                discardExport()
            } catch {
                discardExport()
                exportFailure = error.localizedDescription
            }
            exporting = false
            exportTask = nil
        }
    }

    private func discardExport() {
        guard let directory = exportDirectory else { return }
        try? FileManager.default.removeItem(at: directory)
        exportDirectory = nil
    }
}

private struct ScanEvidenceShare: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ScanEvidenceShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct LidarPreview: Sendable {
    var positions: [SIMD3<Float>]
    var colors: [SIMD4<Float>]
    var sampledFrames: Int
    var totalFrames: Int

    static func load(scanID: String) throws -> Self {
        let archive = try StreamEvidenceArchive(root: CaptureStore.streamRoot(for: scanID), expectedScanID: scanID)
        let sequences = archive.sampledSequences()
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        // Read and release one validated chunk at a time. The preview retains at most 90k
        // points; a long walk never loads its entire depth or image history into memory.
        for sequence in sequences {
            try Task.checkCancellation()
            let chunk = try archive.readChunk(sequence: sequence)
            let sampler = try LidarColorSampler(jpeg: chunk.colorJPEG)
            let points = try StreamEvidenceArchive.points(in: chunk.frame)
            for point in points {
                positions.append(point.position)
                colors.append(sampler.color(at: point.imageCoordinate))
            }
        }
        return Self(positions: positions, colors: colors, sampledFrames: sequences.count,
                    totalFrames: archive.frameCount)
    }
}

private struct LidarColorSampler {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(jpeg: Data) throws {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: false,
              ] as CFDictionary) else { throw StreamingCaptureError.invalidChunk }
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            // Bitmap rows already match CGImage's top-to-bottom sensor pixel order.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw StreamingCaptureError.invalidChunk }
        rgba = pixels
    }

    func color(at coordinate: SIMD2<Float>) -> SIMD4<Float> {
        let x = min(max(Int(coordinate.x * Float(width)), 0), width - 1)
        let y = min(max(Int(coordinate.y * Float(height)), 0), height - 1)
        let offset = (y * width + x) * 4
        return SIMD4(Float(rgba[offset]) / 255, Float(rgba[offset + 1]) / 255,
                     Float(rgba[offset + 2]) / 255, 1)
    }
}

private struct LidarPreviewCanvas: UIViewRepresentable {
    let cloud: LidarPreview
    let colorized: Bool

    final class Coordinator {
        var colorized: Bool?
        var node: SCNNode?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        let scene = SCNScene()
        scene.background.contents = UIColor.black
        view.scene = scene
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.preferredFramesPerSecond = 30
        view.accessibilityLabel = "Original scan points. Drag to rotate and pinch to zoom."
        let node = SCNNode()
        scene.rootNode.addChildNode(node)
        context.coordinator.node = node
        let low = cloud.positions.reduce(cloud.positions[0]) { simd_min($0, $1) }
        let high = cloud.positions.reduce(cloud.positions[0]) { simd_max($0, $1) }
        let center = (low + high) / 2
        let span = max(1, simd_length(high - low))
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = Double(span * 10)
        camera.simdPosition = center + SIMD3(0, span * 0.4, span)
        camera.look(at: SCNVector3(center.x, center.y, center.z))
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        view.defaultCameraController.target = SCNVector3(center.x, center.y, center.z)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard context.coordinator.colorized != colorized else { return }
        var sources = [SCNGeometrySource(vertices: cloud.positions.map { SCNVector3($0.x, $0.y, $0.z) })]
        if colorized {
            let colorData = cloud.colors.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: colorData, semantic: .color, vectorCount: cloud.colors.count,
                                             usesFloatComponents: true, componentsPerVector: 4,
                                             bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                             dataStride: MemoryLayout<SIMD4<Float>>.stride))
        }
        let element = SCNGeometryElement(indices: Array(Int32(0)..<Int32(cloud.positions.count)), primitiveType: .point)
        element.pointSize = 3
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 4
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = colorized ? UIColor.white : UIColor.systemOrange
        geometry.materials = [material]
        context.coordinator.node?.geometry = geometry
        context.coordinator.colorized = colorized
    }
}
