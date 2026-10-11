import AccessCore
import CryptoKit
import Foundation

/// Measured routing coverage is constrained to the reconstructed floor's visible outline.
enum StudentCenterCatalog {
    static let buildingName = "Student Center East"
    static let universityName = "Georgia State University"
    static let buildingID = UUID(uuidString: "D9D59C6A-ED0C-484D-A32C-40E23D2F810B")!
    static let floorLevel = 2
    static let floorLevels = [1, 2, 3]
    static let mapTitle = "Floor 2"
    static let coverageDescription = "Scanned area"
    static let illustrationTitle = "Floor 2"
    static let navigationResourceName = "student-center-east-floor-2-navigation"

    enum Coverage: Equatable {
        case scannedArea
        case noMap
    }

    enum CatalogError: Error, LocalizedError {
        case missingResource
        case unreadableResource
        case invalidGeometry

        var errorDescription: String? {
            switch self {
            case .missingResource: "The Floor 2 map is unavailable."
            case .unreadableResource: "The Floor 2 map could not be opened."
            case .invalidGeometry: "The Floor 2 map could not be displayed."
            }
        }
    }

    static func coverage(for level: Int) -> Coverage {
        level == floorLevel && map() != nil ? .scannedArea : .noMap
    }

    static func map() -> VenueMap? {
        try? mapResult().get()
    }

    static func mapResult() -> Result<VenueMap, CatalogError> {
        bundledMap
    }

    /// Prepared display geometry for this exact bundled scan, avoiding reconstruction on first launch.
    static func scene() -> ProcessedScene? {
        bundledScene
    }

    static var illustrationURL: URL? {
        illustrationURL(for: floorLevel)
    }

    static var illustrationPreviewURL: URL? {
        illustrationPreviewURL(for: floorLevel)
    }

    static func illustrationURL(for floor: Int) -> URL? {
        guard floor == 2 || floor == 3 else { return nil }
        return resourceURL("student-center-east-floor-\(floor)-model", extension: "usdz")
    }

    static func illustrationPreviewURL(for floor: Int) -> URL? {
        guard floor == 2 || floor == 3 else { return nil }
        return resourceURL("student-center-east-floor-\(floor)-model", extension: "png")
    }

    static func hasEstimatedModel(on floor: Int) -> Bool {
        illustrationURL(for: floor) != nil && modelFloorY(for: floor) != nil
    }

    /// These elevations belong to the estimated asset, not an observed floor connection.
    static func modelFloorY(for floor: Int) -> Float? {
        modelLayout?.elevations[String(floor)]
    }

    struct ModelLandmark: Identifiable {
        let id: UUID
        let title: String
        let position: SIMD3<Float>
        let floor: Int
    }

    /// Video-model labels use their own stable IDs and never become routing access points.
    static func modelLandmarks(for floor: Int) -> [ModelLandmark] {
        guard hasEstimatedModel(on: floor), let modelLayout else { return [] }
        return modelLayout.labels.filter { $0.floor == floor }.map { label in
            ModelLandmark(id: landmarkID(floor: floor, title: label.title), title: label.title,
                          position: SIMD3(label.position[0], label.position[1], label.position[2]), floor: floor)
        }
    }

    /// A canvas host for an estimated model, deliberately containing no measured or routable geometry.
    static func estimatedScene(for floor: Int) -> ProcessedScene? {
        guard hasEstimatedModel(on: floor) else { return nil }
        return ProcessedScene(sourceScanID: "estimated-model-floor-\(floor)",
                              mapID: "student-center-east-illustration", floorID: "student-center-east-floor-\(floor)",
                              objects: [], surfaces: [], warnings: ["Estimated visual model; this display source contains no measured floor coverage."])
    }

    private struct ModelLayout: Decodable {
        struct Label: Decodable {
            let floor: Int
            let title: String
            let position: [Float]
        }
        let elevations: [String: Float]
        let labels: [Label]
        enum CodingKeys: String, CodingKey { case elevations = "floor_elevations_m", labels }
    }

    private static let modelLayout: ModelLayout? = {
        guard let url = resourceURL("student-center-east-model-layout", extension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 1_000_000,
              let layout = try? JSONDecoder().decode(ModelLayout.self, from: data),
              layout.elevations["2"] == 0, layout.elevations["3"] == 4,
              layout.labels.count <= 100,
              layout.labels.allSatisfy({ label in
                  [2, 3].contains(label.floor) && !label.title.isEmpty && label.title.count <= 80
                      && label.position.count == 3 && label.position.allSatisfy({ $0.isFinite && abs($0) <= 10_000 })
              }),
              Set(layout.labels.map { "\($0.floor):\($0.title)" }).count == layout.labels.count else { return nil }
        return layout
    }()

    private static func landmarkID(floor: Int, title: String) -> UUID {
        let name = "gsu-student-center-east:estimated-landmark:\(floor):\(title)"
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        // Stable custom UUIDs remain independent of label order and subsequent placement edits.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static let bundledMap: Result<VenueMap, CatalogError> = {
        guard let url = resourceURL(navigationResourceName, extension: "json") else {
            return .failure(.missingResource)
        }
        guard let data = try? Data(contentsOf: url), data.count <= 10_000_000 else {
            return .failure(.unreadableResource)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let map = try? decoder.decode(VenueMap.self, from: data) else {
            return .failure(.unreadableResource)
        }
        guard isDisplayable(map) else { return .failure(.invalidGeometry) }
        return .success(map)
    }()

    private static let bundledScene: ProcessedScene? = {
        guard map() != nil,
              let url = resourceURL("student-center-east-floor-2-scene", extension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 20_000_000 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let scene = try? decoder.decode(ProcessedScene.self, from: data),
              scene.sourceScanID == "venue-map", scene.mapID == "venue-map",
              scene.meshes.isEmpty, scene.pointCloud.isEmpty,
              scene.surfaces.count <= 4_000, scene.objects.count <= 1_000 else { return nil }
        do { try scene.validate() } catch { return nil }
        return scene
    }()

    /// Keep imported geometry within the building-scale limits supported by rendering and routing.
    static func isDisplayable(_ map: VenueMap) -> Bool {
        func bounded(_ value: Float, by limit: Float) -> Bool {
            value.isFinite && abs(value) <= limit
        }

        guard bounded(map.floorY, by: 1_000),
              !map.footprints.isEmpty,
              map.footprints.count <= 10_000,
              map.points.count <= 1_000,
              Set(map.points.map(\.id)).count == map.points.count else { return false }

        let identifiedFootprints = map.footprints.compactMap(\.id)
        let allIdentifiedFeatures = identifiedFootprints + map.points.map(\.id)
        guard Set(allIdentifiedFeatures).count == allIdentifiedFeatures.count else { return false }

        if let reference = map.geographicReference {
            do { try reference.validate() } catch { return false }
        }

        var lower = SIMD2<Float>(repeating: .infinity)
        var upper = SIMD2<Float>(repeating: -.infinity)
        func include(_ point: SIMD2<Float>) -> Bool {
            guard bounded(point.x, by: 10_000), bounded(point.y, by: 10_000) else { return false }
            lower.x = min(lower.x, point.x)
            lower.y = min(lower.y, point.y)
            upper.x = max(upper.x, point.x)
            upper.y = max(upper.y, point.y)
            return upper.x - lower.x <= 500 && upper.y - lower.y <= 500
        }

        for footprint in map.footprints {
            guard bounded(footprint.center.x, by: 10_000), bounded(footprint.center.y, by: 10_000),
                  bounded(footprint.size.x, by: 500), bounded(footprint.size.y, by: 500),
                  footprint.size.x > 0, footprint.size.y > 0,
                  footprint.yaw.isFinite,
                  footprint.bottom.map({ bounded($0, by: 1_000) }) != false,
                  footprint.height.map({ bounded($0, by: 1_000) && $0 >= 0 }) != false else { return false }
            if let polygon = footprint.polygon {
                guard polygon.count >= 3,
                      polygon.count <= 128,
                      polygon.allSatisfy({ bounded($0.x, by: 10_000) && bounded($0.y, by: 10_000) }) else { return false }

                // Subtract the first vertex before accumulating to retain precision far from the origin.
                let origin = polygon[0]
                var doubledArea: Double = 0
                for index in polygon.indices {
                    let a = polygon[index] - origin
                    let b = polygon[(index + 1) % polygon.count] - origin
                    doubledArea += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
                }
                guard abs(doubledArea) > 0.000001 else { return false }
            }
            guard footprint.corners.allSatisfy(include) else { return false }
        }

        for point in map.points {
            guard bounded(point.position.y, by: 1_000), include(point.floorPoint),
                  point.confidence.isFinite, (0...1).contains(point.confidence),
                  point.slopeDegrees?.isFinite != false else { return false }
        }

        return map.requiresMeasuredFloorCoverage != true || map.footprints.contains { $0.kind == .floor }
    }

    private static func resourceURL(_ name: String, extension fileExtension: String) -> URL? {
        // XcodeGen may flatten a group or preserve the resource folder; support either bundle layout.
        Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "StudentCenter")
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension)
    }
}
