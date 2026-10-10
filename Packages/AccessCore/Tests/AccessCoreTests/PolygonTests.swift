import Foundation
import simd
import Testing
@testable import AccessCore

private func area(of triangles: [Int], in corners: [SIMD2<Float>]) -> Float {
    stride(from: 0, to: triangles.count, by: 3).reduce(Float(0)) { total, i in
        total + abs(Polygon.signedArea([corners[triangles[i]], corners[triangles[i + 1]], corners[triangles[i + 2]]]))
    }
}

@Test func triangulatesARectangleIntoTwoTriangles() {
    let rectangle: [SIMD2<Float>] = [[0, 0], [4, 0], [4, 3], [0, 3]]
    let triangles = Polygon.triangulate(rectangle)
    #expect(triangles.count == 6)
    #expect(abs(area(of: triangles, in: rectangle) - 12) < 1e-4)
}

@Test func triangulatesAnLShapedRoom() {
    // Concave: a 6 x 6 room with a 3 x 3 corner missing.
    let room: [SIMD2<Float>] = [[0, 0], [6, 0], [6, 3], [3, 3], [3, 6], [0, 6]]
    let triangles = Polygon.triangulate(room)
    #expect(triangles.count == 12)
    #expect(abs(area(of: triangles, in: room) - 27) < 1e-4)
}

@Test func triangulatesClockwiseInputToo() {
    let clockwise: [SIMD2<Float>] = [[0, 0], [0, 3], [4, 3], [4, 0]]
    #expect(Polygon.signedArea(clockwise) < 0)
    #expect(abs(area(of: Polygon.triangulate(clockwise), in: clockwise) - 12) < 1e-4)
}

@Test func refusesDegeneratePolygons() {
    #expect(Polygon.triangulate([[0, 0], [1, 1]]).isEmpty)
    #expect(Polygon.triangulate([[0, 0], [1, 0], [2, 0]]).isEmpty)
}

@Test func floorFootprintUsesItsOutlineAsCorners() {
    let floor = Footprint(floor: [[0, 0], [6, 0], [6, 3], [3, 3], [3, 6], [0, 6]], bottom: -1.3)
    #expect(floor.kind == .floor)
    #expect(floor.corners.count == 6)
    #expect(floor.center == SIMD2<Float>(3, 3))
    #expect(floor.size == SIMD2<Float>(6, 6))
    #expect(!floor.kind.blocksWheelchairs)
}
