import AccessCore
import CryptoKit
import Foundation

/// Floor 1 includes the raised auditorium area. Its measured zones retain their heights
/// and route only through explicit stairs or elevator connections.
enum StudentCenterFloor1Catalog {
    static let floorLevel = 1
    static let navigationResourceName = "student-center-east-floor-1-navigation"
    private static let modelResourceName = "student-center-east-floor-1-model"
    private static let maximumNavigationBytes = 10_000_000

    enum CatalogError: Error, LocalizedError {
        case missingResource, unreadableResource, invalidGeometry
        var errorDescription: String? {
            switch self {
            case .missingResource: "The Floor 1 map is unavailable."
            case .unreadableResource: "The Floor 1 map could not be opened."
            case .invalidGeometry: "The Floor 1 map could not be displayed."
            }
        }
    }

    static func mapResult() -> Result<ElevatedFloorMap, CatalogError> { bundledMap }
    static func elevatedMap() -> ElevatedFloorMap? { try? bundledMap.get() }

    /// For drawing and searching only. Routing must use `ElevatedFloorRoutePlanner`;
    /// combining these footprints in an ordinary planner would join overlapping levels.
    static func displayMap() -> VenueMap? { bundledDisplayMap }

    static func makeDisplayMap(from map: ElevatedFloorMap) -> VenueMap? {
        guard isDisplayable(map), let base = map.zones.map(\.map.floorY).min() else { return nil }
        return VenueMap(createdAt: map.zones.map(\.map.createdAt).min() ?? .distantPast,
                        floorY: base, footprints: map.zones.flatMap { $0.map.footprints },
                        points: map.zones.flatMap { $0.map.points }, requiresMeasuredFloorCoverage: true)
    }

    static func modelURL() -> URL? { resourceURL(modelResourceName, extension: "usdz") }
    static func previewURL() -> URL? { resourceURL(modelResourceName, extension: "png") }
    static func modelFloorY() -> Float? { modelLayout?.elevations["1"] }

    /// The registered visual model is separate from the measured routing coverage.
    static func scene() -> ProcessedScene? {
        guard modelURL() != nil, modelLayout != nil else { return nil }
        return ProcessedScene(sourceScanID: "student-center-east-floor-1-model",
                              mapID: "student-center-east-floor-1", floorID: "student-center-east-floor-1",
                              objects: [], surfaces: [],
                              warnings: ["The visual model includes filled gaps outside measured navigation coverage."])
    }

    static func modelLandmarks() -> [StudentCenterCatalog.ModelLandmark] {
        landmarks(map: elevatedMap(), layout: modelLayout)
    }

    /// Measured destinations keep their IDs and positions even when the visual layout repeats a label.
    static func landmarks(map: ElevatedFloorMap?, layout: ModelLayout?) -> [StudentCenterCatalog.ModelLandmark] {
        let points = map?.zones.flatMap { $0.map.points } ?? []
        var result = points.map {
            StudentCenterCatalog.ModelLandmark(id: $0.id, title: $0.title, position: $0.position, floor: floorLevel)
        }
        let measuredNames = Set(points.map { normalizedTitle($0.title) })
        for label in layout?.labels ?? [] where !measuredNames.contains(normalizedTitle(label.title)) {
            result.append(StudentCenterCatalog.ModelLandmark(id: landmarkID(title: label.title), title: label.title,
                position: SIMD3(label.position[0], label.position[1], label.position[2]), floor: floorLevel))
        }
        return result
    }

    struct ModelLayout: Decodable {
        struct Label: Decodable {
            let floor: Int
            let title: String
            let position: [Float]
        }
        let elevations: [String: Float]
        let labels: [Label]
        enum CodingKeys: String, CodingKey { case elevations = "floor_elevations_m", labels }
    }

    static func decodeNavigation(_ data: Data) throws -> ElevatedFloorMap {
        guard data.count <= maximumNavigationBytes else { throw CatalogError.unreadableResource }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let map: ElevatedFloorMap
        do { map = try decoder.decode(ElevatedFloorMap.self, from: data) }
        catch { throw CatalogError.unreadableResource }
        guard isDisplayable(map) else { throw CatalogError.invalidGeometry }
        return map
    }

    static func decodeLayout(_ data: Data) -> ModelLayout? {
        guard data.count <= 1_000_000, let layout = try? JSONDecoder().decode(ModelLayout.self, from: data),
              layout.elevations.count == 1, let elevation = layout.elevations["1"], elevation.isFinite,
              abs(elevation) <= 1_000, layout.labels.count <= 200,
              layout.labels.allSatisfy({ label in
                  label.floor == floorLevel && !normalizedTitle(label.title).isEmpty && label.title.count <= 80
                      && label.position.count == 3 && label.position.allSatisfy({ $0.isFinite && abs($0) <= 10_000 })
                      && abs(label.position[1]) <= 1_000
              }), Set(layout.labels.map { normalizedTitle($0.title) }).count == layout.labels.count else { return nil }
        return layout
    }

    private static func isDisplayable(_ map: ElevatedFloorMap) -> Bool {
        guard map.displayFloor == floorLevel, (try? map.validate()) != nil,
              map.zones.allSatisfy({ StudentCenterCatalog.isDisplayable($0.map) }) else { return false }
        return true
    }

    private static let bundledMap: Result<ElevatedFloorMap, CatalogError> = {
        guard let url = resourceURL(navigationResourceName, extension: "json") else { return .failure(.missingResource) }
        guard let data = boundedData(at: url, maximumBytes: maximumNavigationBytes) else { return .failure(.unreadableResource) }
        do { return .success(try decodeNavigation(data)) }
        catch let error as CatalogError { return .failure(error) }
        catch { return .failure(.unreadableResource) }
    }()

    private static let bundledDisplayMap = elevatedMap().flatMap(makeDisplayMap)

    private static let modelLayout: ModelLayout? = {
        guard let url = resourceURL("student-center-east-floor-1-model-layout", extension: "json"),
              let data = boundedData(at: url, maximumBytes: 1_000_000) else { return nil }
        return decodeLayout(data)
    }()

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func landmarkID(title: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("gsu-student-center-east:floor-1-visual-landmark:\(title)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func boundedData(at url: URL, maximumBytes: Int) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumBytes, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maximumBytes else { return nil }
        return data
    }

    private static func resourceURL(_ name: String, extension fileExtension: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "StudentCenter")
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension)
    }
}
