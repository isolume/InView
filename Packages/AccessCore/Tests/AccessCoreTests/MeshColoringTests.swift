import Foundation
import simd
import Testing
@testable import AccessCore

/// A floor of `cells` × `cells` squares centered on the origin at y = 0, wound up (or down).
private func floorMesh(cells: Int = 3, spacing: Float = 0.6, facingUp: Bool = true) -> CaptureMesh {
    let start = -Float(cells) * spacing / 2
    var vertices: [[Float]] = []
    for row in 0...cells {
        for column in 0...cells {
            vertices.append([start + Float(column) * spacing, 0, start + Float(row) * spacing])
        }
    }
    var triangles: [[Int]] = []
    let width = cells + 1
    for row in 0..<cells {
        for column in 0..<cells {
            let a = row * width + column, b = a + 1, c = a + width, d = c + 1
            triangles.append(facingUp ? [a, c, b] : [a, b, c])
            triangles.append(facingUp ? [b, c, d] : [b, d, c])
        }
    }
    return CaptureMesh(id: ReconstructedMesh.sourceID, mapFromAnchor: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                       vertices: vertices, triangles: triangles)
}

/// A camera 2 m above the origin looking straight down, with a 90° view: image x follows map x,
/// image y follows map z. Depth reads `depth` everywhere, or nothing where `missing` says.
private func overheadFrame(depth: Float = 2, missing: (Int, Int) -> Bool = { _, _ in false }) -> CaptureDepthFrame {
    let size = 10
    var values: [Float?] = []
    for row in 0..<size {
        for column in 0..<size { values.append(missing(column, row) ? nil : depth) }
    }
    return CaptureDepthFrame(id: "overhead", timestampSeconds: 1,
                             mapFromCamera: [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 2, 0, 1],
                             camera: CaptureCameraCalibration(imageWidth: 100, imageHeight: 100, fx: 50, fy: 50, cx: 50, cy: 50),
                             depth: CaptureDepthImage(width: size, height: size, valuesM: values,
                                                      confidence: Array(repeating: 2, count: size * size)))
}

/// Red on the image's left half, blue on its right.
private func splitImage() throws -> ColorImage {
    var rgba: [UInt8] = []
    for _ in 0..<100 {
        for column in 0..<100 { rgba.append(contentsOf: column < 50 ? [220, 30, 30, 255] : [30, 30, 220, 255]) }
    }
    return try #require(ColorImage(width: 100, height: 100, rgba: rgba))
}

@Test func verticesTakeTheColorOfThePhotoThatSawThem() throws {
    let mesh = floorMesh()
    var coloring = try #require(MeshColoring(mesh: mesh))
    try coloring.add(frame: overheadFrame(), image: splitImage())
    #expect(coloring.observationsUsed == 1)
    #expect(coloring.coverage == 1)
    let colors = try coloring.colors()
    for (vertex, color) in zip(mesh.vertices, colors) {
        #expect(color == (vertex[0] < 0 ? 0xDC1E1E : 0x1E1EDC))
    }
    // Colors travel with the mesh through validation.
    var colored = mesh
    colored.colors = colors
    try CaptureBundle(id: "scan", mapID: "map", meshes: [colored]).validate()
}

@Test func uprightPhotoSamplingRotatesBackToTheCalibratedSensorFrame() throws {
    // A 3x2 sensor image becomes a 2x3 upright image. Its sensor columns map to portrait rows;
    // the two pixels in each row distinguish the other axis and catch mirrored rotation.
    let portrait = try #require(ColorImage(width: 2, height: 3, rgba: [
        255, 0, 0, 255, 0, 255, 0, 255,
        0, 0, 255, 255, 255, 255, 0, 255,
        255, 0, 255, 255, 0, 255, 255, 255,
    ], orientation: .portraitClockwise))
    #expect(simd_distance(portrait.color(at: SIMD2(1.0 / 6, 0.25)), SIMD3(0, 1, 0)) < 0.00001)
    #expect(simd_distance(portrait.color(at: SIMD2(1.0 / 6, 0.75)), SIMD3(1, 0, 0)) < 0.00001)
    #expect(simd_distance(portrait.color(at: SIMD2(0.5, 0.25)), SIMD3(1, 1, 0)) < 0.00001)
    #expect(simd_distance(portrait.color(at: SIMD2(5.0 / 6, 0.75)), SIMD3(1, 0, 1)) < 0.00001)
}

@Test func somethingInFrontOfAVertexKeepsThatPhotoOffIt() throws {
    var coloring = try #require(MeshColoring(mesh: floorMesh()))
    // Depth says a surface 0.8 m from the camera hides the floor 2 m away.
    try coloring.add(frame: overheadFrame(depth: 0.8), image: splitImage())
    #expect(coloring.observationsUsed == 0)
    #expect(coloring.coverage == 0)
    #expect(Set(try coloring.colors()) == [MeshColoring.fallback])
}

@Test func aPhotoOfAFacesBackColorsNothing() throws {
    var coloring = try #require(MeshColoring(mesh: floorMesh(facingUp: false)))
    try coloring.add(frame: overheadFrame(), image: splitImage())
    #expect(coloring.coverage == 0)
}

@Test func unseenVerticesBorrowFromSeenNeighbors() throws {
    // No depth on the image's right half: the photo only colors the floor's left (red) side.
    let frame = overheadFrame(missing: { column, _ in column >= 5 })
    var coloring = try #require(MeshColoring(mesh: floorMesh()))
    try coloring.add(frame: frame, image: splitImage())
    #expect(coloring.coverage == 0.5)
    #expect(Set(try coloring.colors()) == [0xDC1E1E])
    #expect(Set(try coloring.colors(fillingRings: 0)) == [0xDC1E1E, MeshColoring.fallback])
}

@Test func coloredMeshesRejectMismatchedColorCounts() {
    var mesh = floorMesh()
    mesh.colors = [0xFFFFFF]
    #expect(throws: CaptureValidationError.self) { try CaptureBundle(id: "scan", mapID: "map", meshes: [mesh]).validate() }
    mesh.colors = Array(repeating: 0x100_0000, count: mesh.vertices.count)
    #expect(throws: CaptureValidationError.self) { try CaptureBundle(id: "scan", mapID: "map", meshes: [mesh]).validate() }
}

@Test func photoColoringBoundsAllProjectionWorkIncludingOccludedPhotos() throws {
    let mesh = floorMesh()
    var coloring = try #require(MeshColoring(mesh: mesh, maximumVertexVisits: mesh.vertices.count))
    try coloring.add(frame: overheadFrame(depth: 0.8), image: splitImage())
    #expect(coloring.observationsUsed == 0)
    #expect(throws: CaptureValidationError.self) {
        try coloring.add(frame: overheadFrame(), image: splitImage())
    }
    #expect(coloring.coverage == 0)
    #expect(MeshColoring.photoLimit(vertexCount: ReconstructedMesh.maximumVertices)
        * ReconstructedMesh.maximumVertices <= MeshColoring.maximumVertexVisits)
    #expect(MeshColoring.photoLimit(vertexCount: ReconstructedMesh.maximumVertices + 1) == 0)
}

@Test func photoColoringRejectsMalformedGeometryAndImageDimensions() {
    var mesh = floorMesh()
    mesh.vertices[0][0] = .nan
    #expect(MeshColoring(mesh: mesh) == nil)
    #expect(ColorImage(width: Int.max, height: Int.max, rgba: []) == nil)
}

@Test func photoColorFillingHonorsCancellation() async throws {
    let coloring = try #require(MeshColoring(mesh: floorMesh()))
    let cancelled = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do { _ = try coloring.colors(); return false }
        catch is CancellationError { return true }
        catch { return false }
    }.value
    #expect(cancelled)
}
