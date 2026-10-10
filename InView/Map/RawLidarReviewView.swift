import ARKit
import SceneKit
import SwiftUI
import UIKit
import simd

/// Inspection-only rendering of the native LiDAR evidence captured alongside RoomPlan.
/// RoomPlan/ProcessedScene remains the default map and navigation representation.
struct RawLidarReviewView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case raw = "Raw Depth"
        case smoothed = "Smoothed"
        case color = "Color Points"
        case mesh = "AR Mesh"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .raw: "point.3.connected.trianglepath.dotted"
            case .smoothed: "sparkles"
            case .color: "camera.filters"
            case .mesh: "triangle"
            }
        }
    }

    let snapshot: RawScanSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .raw
    @State private var scene: SCNScene?
    @State private var sceneCache: [Mode: SCNScene] = [:]
    @State private var loadingMode: Mode?

    var body: some View {
        ZStack(alignment: .top) {
            if let scene {
                RawLidarSceneView(scene: scene)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            if loadingMode == mode || scene == nil {
                ProgressView("Preparing LiDAR evidence…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .allowsHitTesting(false)
            }

            HStack(spacing: 12) {
                Menu {
                    Picker("LiDAR view", selection: $mode) {
                        ForEach(Mode.allCases) { candidate in
                            Label(candidate.rawValue, systemImage: candidate.symbol)
                                .tag(candidate)
                                .disabled(!isAvailable(candidate))
                        }
                    }
                } label: {
                    Label(mode.rawValue, systemImage: mode.symbol)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.thinMaterial, in: Capsule())
                }
                .accessibilityHint("Choose raw depth, smoothed depth, color points, or AR mesh")
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 10)
            .background(.ultraThinMaterial)
        }
        .safeAreaInset(edge: .bottom) {
            evidenceSummary
        }
        .task(id: mode) {
            if let cached = sceneCache[mode] {
                scene = cached
                loadingMode = nil
                return
            }
            let requestedMode = mode
            loadingMode = requestedMode
            defer {
                if loadingMode == requestedMode { loadingMode = nil }
            }
            let built = await Task.detached(priority: .userInitiated) {
                RawLidarSceneBuilder.makeScene(snapshot: snapshot, mode: requestedMode)
            }.value
            guard !Task.isCancelled, mode == requestedMode else { return }
            sceneCache[requestedMode] = built
            scene = built
        }
    }

    private var evidenceSummary: some View {
        HStack(spacing: 14) {
            Label("\(snapshot.frames.count) depth views", systemImage: "viewfinder")
            Label("\(snapshot.colorKeyframes.count) color", systemImage: "camera.fill")
            Label("\(snapshot.meshes.count) mesh", systemImage: "triangle")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("LiDAR evidence: \(snapshot.frames.count) depth views, \(snapshot.colorKeyframes.count) color keyframes, \(snapshot.meshes.count) mesh anchors")
    }

    private func isAvailable(_ mode: Mode) -> Bool {
        switch mode {
        case .raw: !snapshot.depthBuffers.isEmpty
        case .smoothed: snapshot.depthBuffers.contains { $0.smoothedDepth != nil }
        case .color: !snapshot.colorKeyframes.isEmpty
        case .mesh: !snapshot.meshes.isEmpty
        }
    }
}

private struct RawLidarSceneView: UIViewRepresentable {
    let scene: SCNScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = scene
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if view.scene !== scene { view.scene = scene }
    }
}

private struct ColorSampler {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init?(_ keyframe: RawColorKeyframe) {
        guard let image = UIImage(data: keyframe.jpeg)?.cgImage else { return nil }
        width = image.width
        height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        rgba = pixels
    }

    func color(x: Float, y: Float) -> SIMD4<Float> {
        let px = min(max(Int(x * Float(width - 1)), 0), width - 1)
        let py = min(max(Int(y * Float(height - 1)), 0), height - 1)
        let offset = (py * width + px) * 4
        return SIMD4(
            Float(rgba[offset]) / 255, Float(rgba[offset + 1]) / 255,
            Float(rgba[offset + 2]) / 255, 1
        )
    }
}

private enum RawLidarSceneBuilder {
    static func makeScene(snapshot: RawScanSnapshot, mode: RawLidarReviewView.Mode) -> SCNScene {
        let scene = SCNScene()
        switch mode {
        case .raw:
            scene.rootNode.addChildNode(pointNode(snapshot: snapshot, smoothed: false, fallbackColor: .systemOrange))
        case .smoothed:
            scene.rootNode.addChildNode(pointNode(snapshot: snapshot, smoothed: true, fallbackColor: .systemCyan))
        case .color:
            scene.rootNode.addChildNode(pointNode(snapshot: snapshot, smoothed: true, fallbackColor: .systemCyan, colorized: true))
        case .mesh:
            scene.rootNode.addChildNode(meshNode(snapshot: snapshot))
        }
        addCameraAndAxes(to: scene)
        return scene
    }

    private static func pointNode(snapshot: RawScanSnapshot, smoothed: Bool, fallbackColor: UIColor, colorized: Bool = false) -> SCNNode {
        let buffers = Dictionary(uniqueKeysWithValues: snapshot.depthBuffers.map { ($0.id, $0) })
        let colorKeyframes = Dictionary(uniqueKeysWithValues: snapshot.colorKeyframes.map { ($0.frameID, $0) })
        var points: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []
        let budget = 90_000
        let perFrame = max(1_500, budget / max(snapshot.frames.count, 1))

        for frame in snapshot.frames {
            let sampler = colorized ? colorKeyframes[frame.id].flatMap(ColorSampler.init) : nil
            let source: (width: Int, height: Int, bytesPerRow: Int, data: Data)?
            if smoothed, let native = buffers[frame.id],
               let width = native.smoothedWidth, let height = native.smoothedHeight,
               let bytesPerRow = native.smoothedBytesPerRow, let data = native.smoothedDepth {
                source = (width, height, bytesPerRow, data)
            } else if !smoothed, let native = buffers[frame.id] {
                source = (native.width, native.height, native.bytesPerRow, native.depth)
            } else {
                source = nil
            }
            guard let source else { continue }
            let pixelCount = source.width * source.height
            let step = max(1, Int(sqrt(Double(pixelCount / perFrame))))
            let scaleX = Float(source.width) / Float(frame.camera.imageWidth)
            let scaleY = Float(source.height) / Float(frame.camera.imageHeight)
            let fx = frame.camera.fx * scaleX
            let fy = frame.camera.fy * scaleY
            let cx = frame.camera.cx * scaleX
            let cy = frame.camera.cy * scaleY
            guard fx > 0, fy > 0 else { continue }
            let transform = matrix(frame.mapFromCamera)

            for y in stride(from: 0, to: source.height, by: step) {
                for x in stride(from: 0, to: source.width, by: step) {
                    let offset = y * source.bytesPerRow + x * MemoryLayout<Float>.size
                    guard let depth = float32(source.data, at: offset), depth.isFinite, depth > 0.10, depth < 8 else { continue }
                    if source.width == frame.depth.width, source.height == frame.depth.height,
                       let confidence = frame.depth.confidence {
                        let confidenceIndex = y * source.width + x
                        if confidenceIndex < confidence.count, confidence[confidenceIndex] == 0 { continue }
                    }
                    let local = SIMD4<Float>((Float(x) - cx) * depth / fx, -(Float(y) - cy) * depth / fy, -depth, 1)
                    let world = transform * local
                    points.append(SCNVector3(world.x, world.y, world.z))
                    if colorized {
                        colors.append(sampler?.color(x: Float(x) / Float(source.width), y: Float(y) / Float(source.height)) ?? SIMD4<Float>(0, 0.8, 1, 1))
                    }
                }
            }
        }

        guard !points.isEmpty else { return SCNNode() }
        let vertexSource = SCNGeometrySource(vertices: points)
        var sources = [vertexSource]
        if colorized, colors.count == points.count {
            let flattened = colors.flatMap { [$0.x, $0.y, $0.z, $0.w] }
            let colorData = flattened.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(
                data: colorData, semantic: .color, vectorCount: colors.count,
                usesFloatComponents: true, componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 4
            ))
        }
        let geometry = SCNGeometry(
            sources: sources,
            elements: [SCNGeometryElement(indices: Array(Int32(0)..<Int32(points.count)), primitiveType: .point)]
        )
        geometry.elements.first?.pointSize = 3
        geometry.elements.first?.minimumPointScreenSpaceRadius = 1
        geometry.elements.first?.maximumPointScreenSpaceRadius = 4
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = colorized ? UIColor.white : fallbackColor
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func meshNode(snapshot: RawScanSnapshot) -> SCNNode {
        let root = SCNNode()
        for mesh in snapshot.meshes {
            guard !mesh.vertices.isEmpty, !mesh.triangles.isEmpty else { continue }
            let vertices = mesh.vertices.map { SCNVector3($0[0], $0[1], $0[2]) }
            let indices = mesh.triangles.flatMap { $0.map(Int32.init) }
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: vertices)],
                elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
            )
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.32)
            material.isDoubleSided = true
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.simdTransform = matrix(mesh.mapFromAnchor)
            root.addChildNode(node)
        }
        return root
    }

    private static func addCameraAndAxes(to scene: SCNScene) {
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.position = SCNVector3(0, 1, 2.5)
        camera.eulerAngles = SCNVector3(-0.3, 0, 0)
        scene.rootNode.addChildNode(camera)
        scene.rootNode.addChildNode(axis(color: .systemRed, position: SCNVector3(0.3, 0, 0), rotation: SCNVector3(0, 0, .pi / 2)))
        scene.rootNode.addChildNode(axis(color: .systemGreen, position: SCNVector3(0, 0.3, 0), rotation: SCNVector3(0, 0, 0)))
        scene.rootNode.addChildNode(axis(color: .systemBlue, position: SCNVector3(0, 0, 0.3), rotation: SCNVector3(.pi / 2, 0, 0)))
        scene.background.contents = UIColor.black
    }

    private static func axis(color: UIColor, position: SCNVector3, rotation: SCNVector3) -> SCNNode {
        let node = SCNNode(geometry: SCNCylinder(radius: 0.008, height: 0.6))
        node.geometry?.firstMaterial?.diffuse.contents = color
        node.position = position
        node.eulerAngles = rotation
        return node
    }

    private static func float32(_ data: Data, at offset: Int) -> Float? {
        guard offset >= 0, offset + MemoryLayout<Float>.size <= data.count else { return nil }
        let bits = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        return Float(bitPattern: bits)
    }

    private static func matrix(_ values: [Float]) -> simd_float4x4 {
        guard values.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        )
    }
}
