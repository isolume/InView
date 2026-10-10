import Foundation
import Testing
@testable import AccessCore

@Test func photoFurnitureSelectsDistinctSilhouettesFromSuppliedTypesAndSizes() {
    let examples: [(String, [Float], String)] = [
        (" chair ", [0.9, 0.9, 0.87], "lounge_chair_v1"),
        ("ARMCHAIR", [0.9, 0.9, 0.87], "lounge_chair_v1"),
        ("lounge_chair_v1", [0.9, 0.9, 0.87], "lounge_chair_v1"),
        ("sofa", [2.2, 0.8, 0.83], "modular_sofa_v1"),
        ("sofa", [2.05, 0.48, 0.53], "bench_v1"),
        ("sofa", [2.05, 0.61, 0.53], "modular_sofa_v1"),
        ("table", [1.05, 0.43, 1.05], "drum_table_v1"),
        ("table", [1.22, 0.74, 0.61], "folding_table_v1"),
        ("table", [1.22, 0.43, 0.61], "folding_table_v1"),
        ("round_table", [0.54, 0.46, 0.54], "drum_table_v1"),
        ("charging_stand", [0.39, 0.77, 0.36], "charging_stand_v1"),
        ("podium", [0.60, 1.25, 0.48], "lectern_v1"),
        ("sign_stand", [0.38, 1.55, 0.34], "sign_stand_v1"),
        ("trash_bin", [0.43, 0.95, 0.43], "waste_bin_v1"),
        ("open_bin", [0.28, 0.38, 0.23], "open_bin_v1"),
        ("bench", [2.05, 0.48, 0.53], "bench_v1"),
        ("square_planter", [0.72, 1.25, 0.72], "square_planter_v1"),
        ("railing", [2.4, 1.05, 0.11], "railing_v1"),
        ("caution_sign", [0.30, 0.63, 0.42], "floor_sign_v1")
    ]
    for (category, dimensions, key) in examples {
        #expect(FurnitureModelCatalog.modelKey(category: category, dimensions: dimensions) == key)
    }
    #expect(FurnitureModelCatalog.modelKey(category: "unrecognized_fixture", dimensions: [1, 1, 1]) == nil)
    #expect(FurnitureModelCatalog.modelKey(category: "chair", dimensions: [1, 0, 1]) == nil)
    #expect(FurnitureModelCatalog.modelKey(category: "chair", dimensions: [.nan, 1, 1]) == nil)
}

@Test func bundledPhotoMeshesHaveOutwardFacesAndUnitNormalsAfterNonuniformResize() throws {
    let categories = ["lounge_chair", "modular_sofa", "drum_table", "charging_stand", "lectern",
                      "folding_table", "sign_stand", "waste_bin", "open_bin", "bench", "square_planter", "railing", "floor_sign"]
    let sizes: [[Float]] = [[1, 1, 1], [0.27, 1.9, 0.48], [3.1, 0.35, 0.8]]
    for category in categories {
        for size in sizes {
            let key = try #require(FurnitureModelCatalog.modelKey(category: category, dimensions: size))
            let meshes = try FurnitureModelCatalog.meshes(for: key, dimensions: size)
            #expect(!meshes.isEmpty)
            for mesh in meshes {
                try #require(mesh.vertices.count == mesh.normals.count,
                             "\(category), size \(size), mesh \(mesh.name)")
                let validCoordinates = mesh.vertices.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) }
                let validNormals = mesh.normals.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) }
                try #require(validCoordinates && validNormals,
                             "\(category), size \(size), mesh \(mesh.name)")
                #expect(mesh.normals.allSatisfy { abs($0.reduce(0) { $0 + $1 * $1 } - 1) < 0.00001 },
                        "\(category), size \(size), mesh \(mesh.name): unit normals")
                #expect(mesh.vertices.allSatisfy { vertex in
                    (0..<3).allSatisfy { abs(vertex[$0]) <= size[$0] / 2 + 0.00001 }
                }, "\(category), size \(size), mesh \(mesh.name): measured bounds")
                try #require(mesh.triangles.allSatisfy { triangle in
                    triangle.count == 3 && triangle.allSatisfy { $0 >= 0 && $0 < mesh.vertices.count }
                }, "\(category), size \(size), mesh \(mesh.name): triangle indices")
                #expect(mesh.triangles.allSatisfy { triangle in
                    let a = mesh.vertices[triangle[0]].map(Double.init)
                    let b = mesh.vertices[triangle[1]].map(Double.init)
                    let c = mesh.vertices[triangle[2]].map(Double.init)
                    let u = zip(b, a).map(-), v = zip(c, a).map(-)
                    let face = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
                    let normal = (0..<3).map { axis in triangle.reduce(0.0) { $0 + Double(mesh.normals[$1][axis]) } }
                    return zip(face, normal).map(*).reduce(0, +) > 0
                }, "\(category), size \(size), mesh \(mesh.name): outward faces")
            }
        }
    }
}

@Test func localPhotoModelsKeepTheOriginalCaptureAndLowConfidenceBounds() throws {
    let pose: [Float] = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 4, 0.45, 2, 1]
    let chair = CaptureObject(id: "chair", category: "chair", confidence: .high,
                              mapFromObject: pose, dimensionsM: [0.9, 0.9, 0.87])
    var uncertain = chair
    uncertain.id = "uncertain"
    uncertain.confidence = .low
    let capture = CaptureBundle(id: "photos", mapID: "test-space", floorID: "ground", objects: [chair, uncertain])
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let encoded = try encoder.encode(capture)
    let scene = try LocalSceneBuilder.make(from: capture, includeDepthPoints: false)
    #expect(scene.objects[0].modelKey == "lounge_chair_v1")
    #expect(!scene.objects[0].modelMeshes.isEmpty)
    #expect(scene.objects[1].modelKey == "bounds_v1")
    #expect(scene.objects[1].modelMeshes.isEmpty)
    #expect(scene.objects.map(\.mapFromObject) == [pose, pose])
    #expect(scene.objects.map(\.measuredDimensionsM) == [chair.dimensionsM, chair.dimensionsM])
    #expect(scene.objects[0].obstacleCorners == scene.objects[1].obstacleCorners)
    #expect(try encoder.encode(capture) == encoded)
    try scene.validate(source: capture)
}
