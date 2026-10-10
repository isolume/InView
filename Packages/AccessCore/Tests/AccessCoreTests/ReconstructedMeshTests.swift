import Foundation
import simd
import Testing
@testable import AccessCore

/// A horizontal grid of `cells` × `cells` squares, `spacing` apart, at `y` in anchor coordinates.
/// `facingUp` winds faces and points normals up (a floor); otherwise down (a ceiling).
private func horizontalGrid(cells: Int, spacing: Float, y: Float, label: String, facingUp: Bool,
                            origin: SIMD2<Float> = .zero, transform: simd_float4x4 = matrix_identity_float4x4) -> ReconstructedMeshAnchor {
    var vertices: [SIMD3<Float>] = []
    for row in 0...cells {
        for column in 0...cells {
            vertices.append(SIMD3(origin.x + Float(column) * spacing, y, origin.y + Float(row) * spacing))
        }
    }
    var faces: [SIMD3<UInt32>] = []
    let width = UInt32(cells + 1)
    for row in 0..<UInt32(cells) {
        for column in 0..<UInt32(cells) {
            let a = row * width + column, b = a + 1, c = a + width, d = c + 1
            // Counterclockwise seen from above is a → c → b in this x/z layout.
            faces.append(facingUp ? SIMD3(a, c, b) : SIMD3(a, b, c))
            faces.append(facingUp ? SIMD3(b, c, d) : SIMD3(b, d, c))
        }
    }
    let normal = SIMD3<Float>(0, facingUp ? 1 : -1, 0)
    return ReconstructedMeshAnchor(mapFromAnchor: transform, vertices: vertices,
                                   normals: Array(repeating: normal, count: vertices.count),
                                   faces: faces, labels: Array(repeating: label, count: faces.count))
}

private func faceNormal(_ mesh: CaptureMesh, _ index: Int) -> SIMD3<Float> {
    let p = mesh.triangles[index].map { SIMD3(mesh.vertices[$0][0], mesh.vertices[$0][1], mesh.vertices[$0][2]) }
    return simd_normalize(simd_cross(p[1] - p[0], p[2] - p[0]))
}

@Test func compactionMergesAnchorsIntoMapCoordinatesAndWeldsSharedEdges() throws {
    let shift = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(2, -1.3, 5, 1))
    // Two neighboring 1 m floor patches whose shared edge was reported by both anchors.
    let left = horizontalGrid(cells: 4, spacing: 0.25, y: 0, label: "floor", facingUp: true, transform: shift)
    let right = horizontalGrid(cells: 4, spacing: 0.25, y: 0, label: "floor", facingUp: true,
                               origin: SIMD2(1, 0), transform: shift)
    let compacted = try #require(try ReconstructedMesh.compact([left, right]))
    #expect(compacted.cellSize == 0.02)
    #expect(compacted.sourceTriangleCount == 64)
    #expect(compacted.mesh.triangles.count == 64)
    // 9 × 5 grid points: the shared column of 5 is welded into one.
    #expect(compacted.mesh.vertices.count == 45)
    #expect(compacted.mesh.id == ReconstructedMesh.sourceID)
    #expect(compacted.mesh.mapFromAnchor == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
    let heights = Set(compacted.mesh.vertices.map { $0[1] })
    #expect(heights == [-1.3])
    #expect(compacted.mesh.vertices.map { $0[0] }.min() == 2)
    #expect(compacted.mesh.vertices.map { $0[2] }.max() == 6)
    #expect(compacted.mesh.classifications == Array(repeating: "floor", count: 64))
    try CaptureBundle(id: "scan", mapID: "map", meshes: [compacted.mesh]).validate()
}

@Test func compactionKeepsAFaceSeenByOverlappingAnchorsOnce() throws {
    let patch = horizontalGrid(cells: 2, spacing: 0.5, y: 0, label: "floor", facingUp: true)
    let compacted = try #require(try ReconstructedMesh.compact([patch, patch]))
    #expect(compacted.sourceTriangleCount == 16)
    #expect(compacted.mesh.triangles.count == 8)
}

@Test func compactionWindsFacesTowardsTheObservedSide() throws {
    // ARKit reported these faces wound away from their normals; rendering single-sided would hide them.
    var floor = horizontalGrid(cells: 2, spacing: 0.5, y: 0, label: "floor", facingUp: true)
    floor.faces = floor.faces.map { SIMD3($0.x, $0.z, $0.y) }
    let ceiling = horizontalGrid(cells: 2, spacing: 0.5, y: 2.6, label: "ceiling", facingUp: false)
    let compacted = try #require(try ReconstructedMesh.compact([floor, ceiling]))
    let labels = try #require(compacted.mesh.classifications)
    for index in compacted.mesh.triangles.indices {
        let normal = faceNormal(compacted.mesh, index)
        #expect(labels[index] == "floor" ? normal.y > 0.99 : normal.y < -0.99)
    }
}

@Test func compactionCoarsensUntilTheMeshFitsItsTarget() throws {
    // 3 cm triangles over 3 m: too many at 2 cm welding, fewer once 8 cm cells merge them.
    let dense = horizontalGrid(cells: 100, spacing: 0.03, y: 0, label: "floor", facingUp: true)
    let compacted = try #require(try ReconstructedMesh.compact([dense], triangleTarget: 5_000))
    #expect(compacted.sourceTriangleCount == 20_000)
    #expect(compacted.cellSize > 0.02)
    #expect(compacted.mesh.triangles.count <= 5_000)
    #expect(compacted.mesh.triangles.count > 500)
    try CaptureBundle(id: "scan", mapID: "map", meshes: [compacted.mesh]).validate()
}

@Test func compactionDropsUnplaceableVerticesAndKeepsUnlabeledMeshesUnlabeled() throws {
    var patch = horizontalGrid(cells: 1, spacing: 1, y: 0, label: "floor", facingUp: true)
    patch.labels = nil
    patch.vertices[3] = SIMD3(.nan, 0, 0)
    let compacted = try #require(try ReconstructedMesh.compact([patch]))
    #expect(compacted.mesh.triangles.count == 1)
    #expect(compacted.mesh.classifications == nil)
    #expect(try ReconstructedMesh.compact([]) == nil)
}

@Test func ceilingIsMeasuredAboveTheFloorItCovers() throws {
    // A 4 × 4 m floor with ceiling captured over one 2 × 2 m corner.
    let floor = horizontalGrid(cells: 8, spacing: 0.5, y: -1.3, label: "floor", facingUp: true)
    let ceiling = horizontalGrid(cells: 4, spacing: 0.5, y: 1.4, label: "ceiling", facingUp: false)
    let compacted = try #require(try ReconstructedMesh.compact([floor, ceiling]))
    let measured = try #require(CeilingMeasurement.measure(compacted.mesh, floorY: -1.3))
    #expect(abs(measured.heightM - 2.7) < 0.01)
    #expect(abs(measured.elevation - 1.4) < 0.01)
    #expect(abs((measured.floorCoverage ?? 0) - 0.25) < 0.02)
    #expect(abs(measured.areaM2 - 4) < 0.3)
}

@Test func ceilingIgnoresMislabeledWallsAndImplausibleHeights() throws {
    let floor = horizontalGrid(cells: 4, spacing: 0.5, y: 0, label: "floor", facingUp: true)
    // A shelf top labeled as ceiling is far too low for a room.
    let shelf = horizontalGrid(cells: 2, spacing: 0.5, y: 1.2, label: "ceiling", facingUp: false)
    // The top of a wall, vertical, labeled as ceiling.
    let wall = CaptureMesh(id: "wall", mapFromAnchor: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                           vertices: [[0, 2.4, 0], [1, 2.4, 0], [0, 2.8, 0]], triangles: [[0, 1, 2]],
                           classifications: ["ceiling"])
    let compacted = try #require(try ReconstructedMesh.compact([floor, shelf]))
    #expect(CeilingMeasurement.measure(compacted.mesh, floorY: 0) == nil)
    #expect(CeilingMeasurement.measure(wall, floorY: 0) == nil)
}

@Test func ceilingFallsBackToTheMapFloorWhenNoFloorWasLabeled() throws {
    let ceiling = horizontalGrid(cells: 2, spacing: 0.5, y: 1.5, label: "ceiling", facingUp: false)
    let compacted = try #require(try ReconstructedMesh.compact([ceiling]))
    let measured = try #require(CeilingMeasurement.measure(compacted.mesh, floorY: -1.2))
    #expect(abs(measured.heightM - 2.7) < 0.01)
    #expect(measured.floorCoverage == nil)
    #expect(CeilingMeasurement.measure(compacted.mesh, floorY: nil) == nil)
}

/// Runs the hint through (time, x, looking up, ceiling nearby) steps and returns when it showed.
private func hintShown(_ hint: CeilingCaptureHint, _ steps: [(TimeInterval, Float, Bool, Bool)]) -> [Bool] {
    var hint = hint
    return steps.map { hint.update(time: $0.0, position: SIMD3($0.1, 0, 0), lookingUp: $0.2, ceilingNearby: $0.3) }
}

@Test func ceilingHintWaitsThenClearsOnceTheCeilingIsCaptured() {
    let shown = hintShown(CeilingCaptureHint(delay: 6), [
        (0, 0, false, false), (5, 0, false, false), (6.5, 0, false, false),
        (7, 0, true, true),
        // Walking on to an area without ceiling asks again after the delay.
        (10, 4, false, false), (13.5, 4, false, false),
    ])
    #expect(shown == [false, false, true, false, false, true])
}

@Test func ceilingHintStopsAskingWhereTheCeilingIsOutOfReach() {
    let shown = hintShown(CeilingCaptureHint(delay: 6, outOfRangeTravel: 3, lookUpDuration: 2), [
        (0, 0, false, false), (7, 0, true, false),
        // Looked up for two seconds and LiDAR found nothing: an atrium, not a scanning mistake.
        (9, 0, true, false), (20, 2, false, false),
        // Three meters on, it's a new area: wait the full delay before asking again.
        (21, 3.5, false, false), (27.5, 3.5, false, false),
    ])
    #expect(shown == [false, true, false, false, false, true])
}
