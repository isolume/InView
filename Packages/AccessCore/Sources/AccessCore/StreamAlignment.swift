import Foundation
import simd

/// Original and optimized poses for one retained reconstruction keyframe.
public struct StreamPoseCorrection: Codable, Equatable, Sendable {
    public var frameID: String
    public var timestampSeconds: Double
    public var originalMapFromCamera: [Float]
    public var optimizedMapFromCamera: [Float]

    public init(frameID: String, timestampSeconds: Double, originalMapFromCamera: [Float],
                optimizedMapFromCamera: [Float]) {
        self.frameID = frameID; self.timestampSeconds = timestampSeconds
        self.originalMapFromCamera = originalMapFromCamera
        self.optimizedMapFromCamera = optimizedMapFromCamera
    }

    enum CodingKeys: String, CodingKey {
        case frameID = "frame_id", timestampSeconds = "timestamp_seconds"
        case originalMapFromCamera = "original_map_from_camera", optimizedMapFromCamera = "optimized_map_from_camera"
    }

    public func validate() throws {
        guard !frameID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, frameID.utf8.count <= 128,
              timestampSeconds.isFinite, timestampSeconds >= 0,
              validRigidTransform(originalMapFromCamera), validRigidTransform(optimizedMapFromCamera) else {
            throw StreamAlignment.invalidResponse
        }
    }

    /// Apply this transform to observations made in the original ARKit coordinate frame.
    public var transform: simd_float4x4 {
        guard validRigidTransform(originalMapFromCamera), validRigidTransform(optimizedMapFromCamera) else {
            return matrix_identity_float4x4
        }
        return streamMatrix(optimizedMapFromCamera) * simd_inverse(streamMatrix(originalMapFromCamera))
    }
}

/// Corrections are interpolated by capture time, preserving the backend's reconstruction frame.
/// This does not provide a relocalization transform for an independently loaded ARWorldMap.
public struct StreamAlignment: Codable, Equatable, Sendable {
    public var referenceFrame: String
    public var optimized: Bool
    public var frames: [StreamPoseCorrection]
    public var constraints: [JSONValue]
    public var initialCost: Double
    public var finalCost: Double

    public init(referenceFrame: String = "original_arkit_session", optimized: Bool,
                frames: [StreamPoseCorrection], constraints: [JSONValue] = [],
                initialCost: Double = 0, finalCost: Double = 0) {
        self.referenceFrame = referenceFrame; self.optimized = optimized; self.frames = frames
        self.constraints = constraints; self.initialCost = initialCost; self.finalCost = finalCost
    }

    enum CodingKeys: String, CodingKey {
        case referenceFrame = "reference_frame", optimized, frames, constraints
        case initialCost = "initial_cost", finalCost = "final_cost"
    }

    public func validate() throws {
        guard referenceFrame == "original_arkit_session", frames.count <= 64,
              !optimized || !frames.isEmpty,
              initialCost.isFinite, initialCost >= 0, finalCost.isFinite, finalCost >= 0,
              Set(frames.map(\.frameID)).count == frames.count else { throw Self.invalidResponse }
        for frame in frames { try frame.validate() }
        for (previous, next) in zip(frames, frames.dropFirst()) {
            guard previous.timestampSeconds < next.timestampSeconds else { throw Self.invalidResponse }
        }
        if let first = frames.first {
            guard zip(first.originalMapFromCamera, first.optimizedMapFromCamera).allSatisfy({ abs($0 - $1) <= 0.0001 }) else {
                throw Self.invalidResponse
            }
        }
        if !optimized {
            guard frames.allSatisfy({ frame in
                zip(frame.originalMapFromCamera, frame.optimizedMapFromCamera).allSatisfy { abs($0 - $1) <= 0.0001 }
            }) else { throw Self.invalidResponse }
        }
    }

    /// Small numerical changes do not invalidate an otherwise matching localization frame.
    /// Call validate() before using a decoded alignment; malformed matrices are conservative here.
    public var materiallyChanged: Bool {
        for frame in frames {
            guard validRigidTransform(frame.originalMapFromCamera), validRigidTransform(frame.optimizedMapFromCamera) else {
                return true
            }
            let transform = frame.transform
            if simd_length(transform.translation) > 0.005 || streamRotationAngle(transform) > 0.005 { return true }
        }
        return false
    }

    /// Interpolates rigid corrections using translation lerp and shortest-path quaternion slerp.
    /// Times outside retained keyframes use the nearest endpoint. Validate decoded data first.
    public func correction(at timestamp: Double) -> simd_float4x4 {
        guard let first = frames.first else { return matrix_identity_float4x4 }
        guard timestamp > first.timestampSeconds else { return first.transform }
        guard let last = frames.last, timestamp < last.timestampSeconds else { return frames.last!.transform }
        var lower = 0
        var upper = frames.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if frames[middle].timestampSeconds <= timestamp { lower = middle }
            else { upper = middle }
        }
        let before = frames[lower]
        let after = frames[upper]
        let interval = after.timestampSeconds - before.timestampSeconds
        guard interval > 0 else { return before.transform }
        let fraction = Float((timestamp - before.timestampSeconds) / interval)
        let a = before.transform
        let b = after.transform
        let position = a.translation + fraction * (b.translation - a.translation)
        let rotationA = streamQuaternion(a)
        var rotationB = streamQuaternion(b)
        if simd_dot(rotationA.vector, rotationB.vector) < 0 { rotationB = simd_quatf(vector: -rotationB.vector) }
        let rotation = simd_normalize(simd_slerp(rotationA, rotationB, fraction))
        var result = simd_float4x4(rotation)
        result.columns.3 = SIMD4<Float>(position, 1)
        return result
    }

    static var invalidResponse: BackendClientError {
        .invalidResponse("The scan server returned invalid alignment data.")
    }
}

private func streamMatrix(_ values: [Float]) -> simd_float4x4 {
    simd_float4x4(columns: (SIMD4(values[0], values[1], values[2], values[3]),
                           SIMD4(values[4], values[5], values[6], values[7]),
                           SIMD4(values[8], values[9], values[10], values[11]),
                           SIMD4(values[12], values[13], values[14], values[15])))
}

private func streamQuaternion(_ matrix: simd_float4x4) -> simd_quatf {
    simd_normalize(simd_quatf(simd_float3x3(columns: (SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                                                    SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                                                    SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)))))
}

private func streamRotationAngle(_ matrix: simd_float4x4) -> Float {
    let quaternion = streamQuaternion(matrix)
    return 2 * atan2(simd_length(quaternion.imag), abs(quaternion.real))
}
