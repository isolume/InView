import AccessCore
import Darwin
import Foundation
import simd

// Run from the repository root after building AccessCore:
//   swift build --package-path Packages/AccessCore
//   swiftc scripts/build-student-center-scene.swift \
//     -I Packages/AccessCore/.build/debug -L Packages/AccessCore/.build/debug \
//     -lAccessCore -module-cache-path /private/tmp/inview-scene-module-cache \
//     -o /private/tmp/build-student-center-scene
//   PACKAGE_RESOURCE_BUNDLE_PATH="$PWD/Packages/AccessCore/.build/debug" \
//     /private/tmp/build-student-center-scene \
//     --map InView/Resources/StudentCenter/student-center-east-floor-2.json \
//     --output /private/tmp/student-center-east-floor-2-scene.json
//
// This prepares the same measured-map display cache as NavigationMapSurface.
// It reads the map without changing its geometry, destinations or coordinate frame.
// Estimated USDZ geometry and raw capture evidence never supply floor coverage.

private enum BuilderError: Error, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

private let usage = """
Usage: build-student-center-scene --map <venue-map.json> --output <scene.json>
Prepares a lightweight display cache from the map's measured floor geometry.
"""

private func arguments() throws -> (map: URL, output: URL)? {
    let values = Array(CommandLine.arguments.dropFirst())
    if values == ["--help"] || values == ["-h"] { print(usage); return nil }
    var paths: [String: String] = [:]
    var index = 0
    while index < values.count {
        let flag = values[index]
        guard ["--map", "--output"].contains(flag), paths[flag] == nil,
              index + 1 < values.count, !values[index + 1].hasPrefix("--") else {
            throw BuilderError.invalid(usage)
        }
        paths[flag] = values[index + 1]
        index += 2
    }
    guard let mapPath = paths["--map"], let outputPath = paths["--output"],
          !mapPath.isEmpty, !outputPath.isEmpty else { throw BuilderError.invalid(usage) }
    let map = URL(fileURLWithPath: mapPath).standardizedFileURL
    let output = URL(fileURLWithPath: outputPath).standardizedFileURL
    guard map.resolvingSymlinksInPath() != output.resolvingSymlinksInPath() else {
        throw BuilderError.invalid("The scene output must be a different file from the source map.")
    }
    return (map, output)
}

/// VenueScene carries map outlines in world XZ coordinates; the preparation pipeline
/// consumes surface-local polygons. Keep the measured outline rather than its box.
private func measuredOutlineScene(_ scene: ProcessedScene) throws -> ProcessedScene {
    var result = scene
    for index in result.surfaces.indices {
        let surface = result.surfaces[index]
        guard surface.kind == "floor", surface.polygonCorners == nil,
              let outline = surface.outline else { continue }
        guard (3...128).contains(outline.count),
              outline.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
            throw BuilderError.invalid("The map contains an invalid floor outline.")
        }
        let pose = surface.mapFromSurface
        let matrix = simd_float4x4(columns: (
            SIMD4(pose[0], pose[1], pose[2], pose[3]), SIMD4(pose[4], pose[5], pose[6], pose[7]),
            SIMD4(pose[8], pose[9], pose[10], pose[11]), SIMD4(pose[12], pose[13], pose[14], pose[15])
        ))
        let inverse = simd_inverse(matrix)
        result.surfaces[index].polygonCorners = outline.map { corner in
            let local = inverse * SIMD4(corner[0], pose[13], corner[1], 1)
            return [local.x, local.y, local.z]
        }
    }
    try result.validate()
    return result
}

private func makeCache(from map: VenueMap) throws -> ProcessedScene {
    let floors = map.footprints.filter { $0.kind == .floor }
    guard map.floorY.isFinite, !floors.isEmpty,
          let scene = VenueScene.make(from: map) else {
        throw BuilderError.invalid("The map needs valid measured floor geometry.")
    }
    // Validate the complete source before selecting a story can hide invalid geometry.
    try FinalMapSceneBuilder.validateInput(scene, floorFootprints: floors, floorY: map.floorY)
    let inputScene = try measuredOutlineScene(scene)
    let floor = IndoorFloorContent(scene: inputScene, map: map, selectedFloorID: nil)
    guard floor.isRouteFloor, let selectedScene = floor.scene, let selectedMap = floor.map,
          floor.floor != nil else {
        throw BuilderError.invalid("The measured map's active floor could not be selected.")
    }
    var result = try FinalMapSceneBuilder.make(
        from: selectedScene,
        floorFootprints: selectedMap.footprints.filter { $0.kind == .floor },
        floorY: floor.floor?.elevation ?? selectedMap.floorY
    )
    // The scan layer uses one measured box per object. Detailed furniture belongs to
    // the separate visual model; captured IDs, poses and bounds remain unchanged.
    for index in result.objects.indices {
        result.objects[index].modelKey = "bounds_v1"
        result.objects[index].modelMeshes = []
        result.objects[index].parts = [SceneModelPart(
            center: [0, 0, 0], dimensionsM: result.objects[index].measuredDimensionsM,
            color: "#CBD1CC"
        )]
    }
    guard result.sourceScanID == "venue-map", result.mapID == "venue-map",
          result.floorID == floor.floor?.id, result.meshes.isEmpty, result.pointCloud.isEmpty,
          result.surfaces.count <= 4_000, result.objects.count <= 1_000 else {
        throw BuilderError.invalid("The prepared scene does not match the bundled map cache format.")
    }
    try result.validate()
    return result
}

private func run() throws {
    guard let paths = try arguments() else { return }
    let attributes = try FileManager.default.attributesOfItem(atPath: paths.map.path)
    guard let size = attributes[.size] as? NSNumber, size.intValue <= 10_000_000 else {
        throw BuilderError.invalid("The map exceeds the bundled map size limit.")
    }
    let data = try Data(contentsOf: paths.map)
    guard data.count <= 10_000_000 else {
        throw BuilderError.invalid("The map exceeds the bundled map size limit.")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let map = try decoder.decode(VenueMap.self, from: data)
    let scene = try makeCache(from: map)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let output = try encoder.encode(scene)
    guard output.count <= 20_000_000 else {
        throw BuilderError.invalid("The prepared scene exceeds the bundled cache size limit.")
    }
    try output.write(to: paths.output, options: .atomic)
    print("Prepared \(scene.surfaces.count) surfaces and \(scene.objects.count) measured objects.")
    print(paths.output.path)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
