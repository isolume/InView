import Foundation
import simd

/// Reusable on-device sign semantics. This classifies text, never certifies a destination.
public struct SignMeaning: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case room, direction, exit, elevator, stairs, restroom }
    public var kind: Kind
    /// Arrows/words are relative to the printed sign, not a world-space navigation vector.
    public var directions: [String]

    public static func classify(_ text: String) -> SignMeaning? {
        let upper = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Set(upper.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let rules: [(String, [String])] = [
            ("left", ["←", "⬅", "LEFT"]), ("right", ["→", "➡", "RIGHT"]),
            ("ahead", ["↑", "⬆", "AHEAD", "STRAIGHT"]), ("back", ["↓", "⬇"]),
            ("upstairs", ["UPSTAIRS"]), ("downstairs", ["DOWNSTAIRS"]),
            ("upper_left", ["↖"]), ("upper_right", ["↗"]),
            ("lower_left", ["↙"]), ("lower_right", ["↘"])
        ]
        let directions = rules.compactMap { name, tokens in
            tokens.contains { token in token.first?.isLetter == true ? words.contains(token) : upper.contains(token) } ? name : nil
        }
        let kind: Kind?
        if !words.isDisjoint(with: ["EXIT", "EXITS", "EGRESS"]) { kind = .exit }
        else if !words.isDisjoint(with: ["ELEVATOR", "ELEVATORS", "LIFT", "LIFTS"]) { kind = .elevator }
        else if !words.isDisjoint(with: ["STAIR", "STAIRS", "STAIRCASE", "STAIRWAY", "STAIRWELL"]) { kind = .stairs }
        else if !words.isDisjoint(with: ["RESTROOM", "RESTROOMS", "TOILET", "TOILETS", "WC"]) { kind = .restroom }
        else if !words.isDisjoint(with: ["ROOM", "ROOMS", "RM", "OFFICE", "LAB", "SUITE"])
                    || upper.range(of: "^[A-Z]?[0-9]{2,4}[A-Z]?$", options: .regularExpression) != nil { kind = .room }
        else if !directions.isEmpty { kind = .direction }
        else { kind = nil }
        return kind.map { SignMeaning(kind: $0, directions: directions) }
    }
}

/// Explicit metric position of the *sign*, in this capture's unchanged AR map frame.
/// Never confuse local y, height above a measured floor, barometric camera displacement,
/// and GPS altitude above mean sea level: they are different datums.
public struct SpatialSign: Codable, Equatable, Sendable {
    public var meaning: SignMeaning
    public var x: Float
    public var y: Float
    public var z: Float
    public var floorID: String?
    public var floorElevationM: Float?
    public var heightAboveFloorM: Float?
    public var latitude: Double?
    public var longitude: Double?
    public var altitudeMSLM: Double?
    public var horizontalAccuracyM: Double?
    public var verticalAccuracyM: Double?
    public var environment: CaptureEnvironmentSample?
    public var timestampSeconds: Double
    public var depthM: Float
    public var depthSampleCount: Int
    public var depthSpreadM: Float
    public var positionSource = "lidar_depth_median"
    public var coordinateFrame = "capture_map_meters_y_up"
    public var destinationVerified = false
    public var position: SIMD3<Float> { SIMD3(x, y, z) }

    enum CodingKeys: String, CodingKey {
        case meaning, x, y, z, environment
        case floorID = "floor_id", floorElevationM = "floor_elevation_m", heightAboveFloorM = "height_above_floor_m"
        case latitude, longitude, altitudeMSLM = "altitude_msl_m"
        case horizontalAccuracyM = "horizontal_accuracy_m", verticalAccuracyM = "vertical_accuracy_m"
        case timestampSeconds = "timestamp_seconds", depthM = "depth_m", depthSampleCount = "depth_sample_count"
        case depthSpreadM = "depth_spread_m", positionSource = "position_source", coordinateFrame = "coordinate_frame"
        case destinationVerified = "destination_verified"
    }

    public mutating func apply(reference: BuildingMapReference?) {
        // Replacing/removing a map reference must never leave stale coordinates behind.
        latitude = nil; longitude = nil; horizontalAccuracyM = nil
        guard let reference, let coordinate = try? reference.coordinate(for: SIMD2(x, z)) else { return }
        latitude = coordinate.latitude; longitude = coordinate.longitude
        horizontalAccuracyM = reference.horizontalAccuracyM
    }
}

public enum SignLocalizer {
    /// Matched sensor-native depth/calibration only; never guesses a depth from a bounding box.
    public static func locate(_ observation: CaptureTextObservation, frame: CaptureDepthFrame,
                              floorID: String? = nil, floorY: Float? = nil,
                              environment: CaptureEnvironmentSample? = nil,
                              reference: BuildingMapReference? = nil) -> SpatialSign? {
        guard observation.frameID == frame.id, observation.confidence >= 0.65,
              let meaning = SignMeaning.classify(observation.text), frame.pixelOrientation == "sensor_native",
              frame.timestampSeconds.isFinite,
              frame.mapFromCamera.count == 16, frame.mapFromCamera.allSatisfy(\.isFinite),
              observation.bboxSensorNorm.count == 4, observation.bboxSensorNorm.allSatisfy(\.isFinite) else { return nil }
        guard let measured = measure(boxSensorNorm: observation.bboxSensorNorm, in: frame) else { return nil }
        let world = measured.position, meters = measured.depthM, spread = measured.spreadM, samples = measured.sampleCount
        let m = frame.mapFromCamera
        let floor = floorY.flatMap { $0.isFinite ? $0 : nil }
        let context = environment.flatMap { $0.isFinite ? $0 : nil }
        let verticalAccuracy = context?.verticalAccuracyM.flatMap { $0 >= 0 ? $0 : nil }
        let altitude = verticalAccuracy == nil ? nil : context?.altitudeM.map { $0 + Double(world.y - m[13]) }
        var result = SpatialSign(meaning: meaning, x: world.x, y: world.y, z: world.z, floorID: floorID,
                                 floorElevationM: floor, heightAboveFloorM: floor.map { world.y - $0 },
                                 altitudeMSLM: altitude, verticalAccuracyM: verticalAccuracy, environment: context,
                                 timestampSeconds: frame.timestampSeconds, depthM: meters,
                                 depthSampleCount: samples, depthSpreadM: spread)
        result.apply(reference: reference)
        return result
    }

    /// The metric map point at the center of a sensor-native text box, from the median of the matched
    /// LiDAR depth inside it. Nil when depth is missing, low-confidence or spans a discontinuity.
    public static func measure(boxSensorNorm: [Double], in frame: CaptureDepthFrame)
        -> (position: SIMD3<Float>, depthM: Float, spreadM: Float, sampleCount: Int)? {
        let box = boxSensorNorm
        guard box.count == 4, box.allSatisfy(\.isFinite), frame.mapFromCamera.count == 16 else { return nil }
        let u = box[0] + box[2] / 2, v = box[1] + box[3] / 2
        let depth = frame.depth, camera = frame.camera
        guard box[2] > 0, box[3] > 0, (0..<1).contains(u), (0..<1).contains(v),
              depth.width > 0, depth.height > 0, depth.width <= 4096, depth.height <= 4096,
              depth.valuesM.count == depth.width * depth.height,
              depth.confidence == nil || depth.confidence?.count == depth.valuesM.count,
              camera.imageWidth > 0, camera.imageHeight > 0,
              camera.fx.isFinite, camera.fy.isFinite, camera.cx.isFinite, camera.cy.isFinite,
              camera.fx > 0, camera.fy > 0 else { return nil }
        let cx = Int(u * Double(depth.width)), cy = Int(v * Double(depth.height))
        var samples: [Float] = []
        for row in max(0, cy - 1)...min(depth.height - 1, cy + 1) {
            for column in max(0, cx - 1)...min(depth.width - 1, cx + 1) {
                // Do not borrow background pixels outside a small text box.
                let su = (Double(column) + 0.5) / Double(depth.width)
                let sv = (Double(row) + 0.5) / Double(depth.height)
                guard su >= box[0], su <= box[0] + box[2], sv >= box[1], sv <= box[1] + box[3] else { continue }
                let index = row * depth.width + column
                guard let d = depth.valuesM[index], d.isFinite, d >= 0.15, d <= 8,
                      let confidence = depth.confidence?[index], confidence >= 1 else { continue }
                samples.append(d)
            }
        }
        guard samples.count >= 3 else { return nil }
        samples.sort()
        let meters = samples[samples.count / 2]
        let spread = samples.last! - samples.first!
        guard spread <= max(0.12, meters * 0.05) else { return nil }
        let point = SIMD4<Float>((Float(u) * Float(camera.imageWidth) - camera.cx) * meters / camera.fx,
                                 -(Float(v) * Float(camera.imageHeight) - camera.cy) * meters / camera.fy, -meters, 1)
        let m = frame.mapFromCamera
        let world = SIMD3<Float>(m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12],
                                 m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13],
                                 m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14])
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { return nil }
        return (world, meters, spread, samples.count)
    }
}
