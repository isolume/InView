import AccessCore
import ARKit
import CryptoKit
import Foundation
import simd

/// The saved camera map and the rigid registration used to build Floor 2's model.
enum StudentCenterLocalization {
    struct Assets {
        let worldMap: ARWorldMap
        let mapFromWorld: simd_float4x4
    }

    enum Failure: Error, LocalizedError {
        case incompatibleMap, missingResource, unreadableArchive, unsupportedDevice

        var errorDescription: String? {
            switch self {
            case .incompatibleMap: "Live location hasn’t been added for this version of the floor."
            case .missingResource: "The saved location data is missing. Reinstall the latest build and try again."
            case .unreadableArchive: "The saved location data couldn’t be opened."
            case .unsupportedDevice: "Live location needs an iPhone or iPad that supports AR."
            }
        }
    }

    private struct Registration: Decodable {
        let archiveSHA256: String
        let archiveBytes: Int
        let mapSHA256: String
        let mapFromWorld: [Float]
    }

    private static let registration: Registration? = {
        guard let url = resourceURL("student-center-east-floor-2-localization", extension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Registration.self, from: data),
              value.mapFromWorld.count == 16, value.mapFromWorld.allSatisfy(\.isFinite),
              let mapURL = resourceURL(StudentCenterCatalog.navigationResourceName, extension: "json"),
              let mapData = try? Data(contentsOf: mapURL), digest(mapData) == value.mapSHA256 else { return nil }
        return value
    }()

    /// Published annotations may change; different geometry must never borrow this registration.
    static func mapFromWorld(for map: VenueMap) -> simd_float4x4? {
        guard map.requiresOptimizedLocalization != true, let bundled = StudentCenterCatalog.map(),
              map.floorY == bundled.floorY,
              map.requiresMeasuredFloorCoverage == bundled.requiresMeasuredFloorCoverage,
              map.footprints.count == bundled.footprints.count,
              Set(map.footprints) == Set(bundled.footprints), let registration else { return nil }
        let m = registration.mapFromWorld
        let transform = simd_float4x4(columns: (
            SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
            SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
        let rotation = simd_float3x3(columns: (
            SIMD3(m[0], m[1], m[2]), SIMD3(m[4], m[5], m[6]), SIMD3(m[8], m[9], m[10])))
        guard abs(simd_determinant(rotation) - 1) < 0.0001,
              simd_length(rotation.columns.0) > 0.9999,
              simd_length(rotation.columns.0) < 1.0001,
              simd_length(rotation.columns.1 - SIMD3(0, 1, 0)) < 0.0001,
              abs(simd_dot(rotation.columns.0, rotation.columns.2)) < 0.0001,
              transform.columns.0.w == 0, transform.columns.1.w == 0,
              transform.columns.2.w == 0, transform.columns.3.w == 1 else { return nil }
        return transform
    }

    /// Called off the main thread; archive verification and decoding can take seconds.
    static func load(for map: VenueMap) -> Result<Assets, Failure> {
        guard let transform = mapFromWorld(for: map) else { return .failure(.incompatibleMap) }
        guard ARWorldTrackingConfiguration.isSupported else { return .failure(.unsupportedDevice) }
        return worldMap.map { Assets(worldMap: $0, mapFromWorld: transform) }
    }

    private static let worldMap: Result<ARWorldMap, Failure> = {
        guard let registration,
              let url = resourceURL("student-center-east-floor-2", extension: "arworldmap"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.missingResource) }
        guard data.count == registration.archiveBytes, digest(data) == registration.archiveSHA256,
              let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            return .failure(.unreadableArchive)
        }
        return .success(map)
    }()

    static func resourceURL(_ name: String, extension ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "StudentCenter")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reject frames from the previous run and let ARKit publish the changed origin before routing.
struct NavigationSessionAlignment {
    enum Action: Equatable { case wait, changeOrigin, ready }
    private var startedAt: TimeInterval = .infinity
    private var changedAt: TimeInterval?
    private var needsOriginChange = false
    private(set) var isReady = false

    mutating func reset(startedAt: TimeInterval, needsOriginChange: Bool) {
        self.startedAt = startedAt
        self.needsOriginChange = needsOriginChange
        changedAt = nil
        isReady = false
    }

    mutating func next(timestamp: TimeInterval, trackingIsNormal: Bool) -> Action {
        guard timestamp > startedAt, trackingIsNormal else { return .wait }
        if needsOriginChange, changedAt == nil {
            changedAt = timestamp
            return .changeOrigin
        }
        guard changedAt.map({ timestamp > $0 }) ?? true else { return .wait }
        isReady = true
        return .ready
    }

    mutating func didChangeOrigin(at timestamp: TimeInterval) {
        if let changedAt { self.changedAt = max(changedAt, timestamp) }
    }
}
