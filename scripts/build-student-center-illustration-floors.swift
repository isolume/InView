import AccessCore
import Darwin
import Foundation
import simd

// Run from the repository root after building AccessCore. Compile the absolute
// source path so the resulting executable finds its defaults from any directory:
//   swift build --package-path Packages/AccessCore
//   swiftc "$PWD/scripts/build-student-center-illustration-floors.swift" \
//     -I Packages/AccessCore/.build/debug -L Packages/AccessCore/.build/debug \
//     -lAccessCore -module-cache-path /private/tmp/inview-scene-module-cache \
//     -o /private/tmp/build-student-center-illustration-floors
//   PACKAGE_RESOURCE_BUNDLE_PATH="$PWD/Packages/AccessCore/.build/debug" \
//     /private/tmp/build-student-center-illustration-floors
//
// Display illustration evidence only. This never writes a VenueMap or supplies
// routing coverage. Original floor polygons remain unchanged; the new native
// RoomPlan envelope is unreviewed for routing. Observed AR floors are excluded.

private enum BuilderError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw BuilderError.invalid(message) }
}

private struct Registration: Decodable {
    let source_capture_id: String
    let horizontal_rotation_radians: Double
    let translation_xz_m: [Double]
    let uniform_scale: Double
    let vertical_translation_m: Double?
}

private struct Paths {
    let map: URL
    let capture: URL
    let registration: URL
    let output: URL
}

private let usage = """
Usage: build-student-center-illustration-floors [--root <repository>] [--map <original-map.json>]
       [--capture <source-capture.json>] [--registration <registration.json>] [--output <floors.json>]
Defaults use the archived Floor 2 evidence and write floors-2-3/illustration-floors.json.
Relative file paths resolve from the repository root. Output is for illustration only.
"""

private func arguments() throws -> Paths? {
    let values = Array(CommandLine.arguments.dropFirst())
    if values == ["--help"] || values == ["-h"] { print(usage); return nil }
    var options: [String: String] = [:]
    var index = 0
    while index < values.count {
        let flag = values[index]
        try require(["--root", "--map", "--capture", "--registration", "--output"].contains(flag)
                    && options[flag] == nil && index + 1 < values.count
                    && !values[index + 1].hasPrefix("--") && !values[index + 1].isEmpty, usage)
        options[flag] = values[index + 1]
        index += 2
    }
    let root = options["--root"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        ?? URL(fileURLWithPath: #filePath).standardizedFileURL
            .deletingLastPathComponent().deletingLastPathComponent()
    try require(FileManager.default.fileExists(atPath: root.appending(path: "Packages/AccessCore/Package.swift").path),
                "The repository root could not be found. Pass --root or compile the absolute source path.")
    func path(_ value: String) -> URL {
        URL(fileURLWithPath: value, relativeTo: root.appending(path: "", directoryHint: .isDirectory)).standardizedFileURL
    }
    let evidence = "models/walkthrough-building/floor-2-evidence"
    let paths = Paths(
        map: path(options["--map"] ?? "\(evidence)/original-floor-2.json"),
        capture: path(options["--capture"] ?? "\(evidence)/E3CF408C-680C-4ECF-B9EB-F09117308BD3/capture.json"),
        registration: path(options["--registration"] ?? "\(evidence)/registration.json"),
        output: path(options["--output"] ?? "models/walkthrough-building/floors-2-3/illustration-floors.json")
    )
    try require([paths.map, paths.capture, paths.registration].allSatisfy {
        $0.resolvingSymlinksInPath() != paths.output.resolvingSymlinksInPath()
    }, "The illustration output must be a different file from each source input.")
    return paths
}

private func area(_ corners: [SIMD2<Float>]) -> Double { Double(abs(Polygon.signedArea(corners))) }
private func regionArea(_ region: BuildingFootprintCutaway.Region) -> Double {
    area(region.exterior) - region.holes.reduce(0) { $0 + area($1) }
}

private func run() throws {
    guard let paths = try arguments() else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let oldMap = try decoder.decode(VenueMap.self, from: Data(contentsOf: paths.map))
    let capture = try decoder.decode(CaptureBundle.self, from: Data(contentsOf: paths.capture))
    try capture.validate()
    let registration = try decoder.decode(Registration.self, from: Data(contentsOf: paths.registration))
    try require(registration.source_capture_id == capture.id, "The registration belongs to a different source capture.")
    try require(registration.translation_xz_m.count == 2 && registration.translation_xz_m.allSatisfy(\.isFinite)
                && registration.horizontal_rotation_radians.isFinite && registration.uniform_scale == 1,
                "The registration must preserve scale and use finite rotation and translation.")
    if case .object(let metadata) = capture.metadata {
        try require(metadata["coordinate_space"] == .string("shared_arkit_session"),
                    "Use the original archived capture; a registered copy would apply the transform twice.")
    } else {
        throw BuilderError.invalid("The source capture needs its original session coordinate metadata.")
    }
    // UUID source IDs distinguish native RoomPlan floors from observed-N additions.
    let native = capture.surfaces.filter { $0.kind == "floor" && UUID(uuidString: $0.id) != nil }
    try require(native.count == 1, "This Floor 2 capture should contain exactly one native RoomPlan floor.")
    let source = native[0]
    let pose = source.mapFromSurface
    let matrix = simd_float4x4(columns: (
        SIMD4(pose[0], pose[1], pose[2], pose[3]), SIMD4(pose[4], pose[5], pose[6], pose[7]),
        SIMD4(pose[8], pose[9], pose[10], pose[11]), SIMD4(pose[12], pose[13], pose[14], pose[15])
    ))
    guard let corners = source.polygonCorners, corners.count >= 3 else {
        throw BuilderError.invalid("The native floor needs its measured polygon outline.")
    }
    let sourceWorld = corners.map { matrix * SIMD4($0[0], $0[1], $0[2], 1) }
    let sourceFloorY = sourceWorld.reduce(Float.zero) { $0 + $1.y } / Float(sourceWorld.count)
    // Explicit illustration-plane choice. Horizontal wall fitting did not measure
    // vertical registration; align this envelope to the old map's active floor.
    let verticalShift = oldMap.floorY - sourceFloorY
    try require(oldMap.floorY.isFinite && verticalShift.isFinite, "The illustration floor height must be finite.")
    if let recordedShift = registration.vertical_translation_m {
        try require(recordedShift.isFinite && abs(recordedShift - Double(verticalShift)) < 0.00001,
                    "The recorded vertical placement does not match the original map's floor.")
    }
    let c = cos(registration.horizontal_rotation_radians), s = sin(registration.horizontal_rotation_radians)
    let tx = registration.translation_xz_m[0], tz = registration.translation_xz_m[1]
    let outline: [SIMD2<Float>] = sourceWorld.map { point in
        SIMD2(Float(c * Double(point.x) - s * Double(point.z) + tx),
              Float(s * Double(point.x) + c * Double(point.z) + tz))
    }
    let oldFloors = oldMap.footprints.filter { $0.kind == .floor }
    try require(oldFloors.count == 12, "Retain the original twelve Floor 2 floor polygons.")
    let uncovered = try BuildingFootprintCutaway.subtractRegions(mapped: oldFloors.map(\.corners), from: outline)
    var additions: [Footprint] = []
    for region in uncovered {
        let exactPieces: [[SIMD2<Float>]]
        if region.holes.isEmpty {
            exactPieces = [region.exterior]
        } else {
            // Footprint has one exterior ring. Exact pieces preserve every cutout.
            exactPieces = try BuildingFootprintCutaway.subtract(mapped: [], from: region.exterior, holes: region.holes)
        }
        for piece in exactPieces {
            try require((3...128).contains(piece.count) && piece.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                        && area(piece) > 0.000001, "Subtraction produced an invalid floor piece.")
            additions.append(Footprint(floor: piece, bottom: sourceFloorY + verticalShift))
        }
    }
    let result = oldFloors + additions
    for floor in result {
        try require(floor.kind == .floor && floor.bottom?.isFinite == true
                    && (3...128).contains(floor.corners.count)
                    && floor.corners.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                    && floor.center.x.isFinite && floor.center.y.isFinite
                    && floor.size.x > 0 && floor.size.y > 0 && area(floor.corners) > 0.000001,
                    "The output contains an invalid floor polygon.")
    }
    let remainingArea = uncovered.reduce(0) { $0 + regionArea($1) }
    let addedArea = additions.reduce(0) { $0 + area($1.corners) }
    try require(abs(remainingArea - addedArea) < 0.005, "Piece splitting changed the measured area or filled a hole.")
    // Re-subtract old masks to verify that no covered area was accidentally added back.
    // Original polygons can overlap one another and are retained without rewriting.
    for addition in additions {
        let verification = try BuildingFootprintCutaway.subtractRegions(mapped: oldFloors.map(\.corners), from: addition.corners)
        let verifiedArea = verification.reduce(0) { $0 + regionArea($1) }
        try require(abs(verifiedArea - area(addition.corners)) < 0.005, "An added piece overlaps the old floor coverage.")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try FileManager.default.createDirectory(at: paths.output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(result).write(to: paths.output, options: .atomic)
    let excluded = capture.surfaces.filter { $0.kind == "floor" && UUID(uuidString: $0.id) == nil }.count
    print("Display-only floors: \(oldFloors.count) original + \(additions.count) uncovered native pieces; excluded \(excluded) observed floors.")
    print("Native envelope \(area(outline)) m²; exact uncovered addition \(addedArea) m².")
    print("Illustration floor Y \(oldMap.floorY); explicitly selected vertical shift \(verticalShift).")
    print(paths.output.path)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
