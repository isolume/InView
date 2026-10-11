import Foundation
import simd

/// Counts distinct observations, not duplicate detections in one image or a stationary retry.
public enum FeatureConfirmation {
    public static func isNewView(position: SIMD3<Float>, direction: SIMD3<Float>, timestamp: Double,
                                 previousPosition: SIMD3<Float>, previousDirection: SIMD3<Float>, previousTimestamp: Double) -> Bool {
        let values = [position, direction, previousPosition, previousDirection]
        guard values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              timestamp.isFinite, previousTimestamp.isFinite, timestamp - previousTimestamp >= 0.8,
              simd_length(direction) > 0.9, simd_length(previousDirection) > 0.9 else { return false }
        return simd_distance(position, previousPosition) >= 0.15
            || simd_dot(simd_normalize(direction), simd_normalize(previousDirection)) < cos(Float.pi / 18)
    }
}

/// A validated immutable depth frame, suitable for delayed visual detections.
public struct FeatureDepthGeometry: Sendable {
    private let frame: CaptureDepthFrame
    private let transform: simd_float4x4

    public init?(_ frame: CaptureDepthFrame) {
        let d = frame.depth, k = frame.camera, m = frame.mapFromCamera
        guard frame.pixelOrientation == "sensor_native", frame.timestampSeconds.isFinite,
              (1...1024).contains(d.width), (1...1024).contains(d.height),
              d.valuesM.count == d.width * d.height, d.confidence?.count == d.valuesM.count,
              k.imageWidth > 0, k.imageHeight > 0, k.fx > 0, k.fy > 0,
              [k.fx, k.fy, k.cx, k.cy].allSatisfy(\.isFinite),
              m.count == 16, m.allSatisfy(\.isFinite) else { return nil }
        self.frame = frame
        transform = simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                            SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
    }

    /// Native sensor UV, not the portrait JPEG coordinates.
    public func point(at uv: SIMD2<Float>) -> SIMD3<Float>? {
        guard uv.x.isFinite, uv.y.isFinite, (0..<1).contains(uv.x), (0..<1).contains(uv.y) else { return nil }
        let d = frame.depth, k = frame.camera
        let column = Int(uv.x * Float(d.width)), row = Int(uv.y * Float(d.height))
        let index = row * d.width + column
        guard let depth = d.valuesM[index], depth.isFinite, (0.15...8).contains(depth),
              let confidence = d.confidence?[index], (1...2).contains(confidence) else { return nil }
        let camera = SIMD4<Float>((uv.x * Float(k.imageWidth) - k.cx) * depth / k.fx,
                                  -(uv.y * Float(k.imageHeight) - k.cy) * depth / k.fy, -depth, 1)
        let world = transform * camera
        return SIMD3(world.x, world.y, world.z)
    }

    /// Exact-frame neighborhood; median world point rejects isolated depth speckles.
    public func target(at uv: SIMD2<Float>) -> SIMD3<Float>? {
        var points: [SIMD3<Float>] = []
        for y in -1...1 { for x in -1...1 {
            let offset = SIMD2(Float(x) / Float(frame.depth.width), Float(y) / Float(frame.depth.height))
            if let p = point(at: uv + offset) { points.append(p) }
        } }
        guard points.count >= 4 else { return nil }
        let center = SIMD3(points.map(\.x).sorted()[points.count / 2],
                           points.map(\.y).sorted()[points.count / 2], points.map(\.z).sorted()[points.count / 2])
        guard points.filter({ simd_distance($0, center) < 0.15 }).count >= 4 else { return nil }
        return center
    }

    /// Bounded grid within a visible feature box [x, y, width, height] in the upright JPEG.
    public func samples(portraitBox box: SIMD4<Float>, columns: Int = 13, rows: Int = 49) -> [SIMD3<Float>] {
        guard (2...25).contains(columns), (2...65).contains(rows),
              [box.x, box.y, box.z, box.w].allSatisfy(\.isFinite),
              box.x >= 0, box.y >= 0, box.z > 0, box.w > 0, box.x + box.z <= 1.001, box.y + box.w <= 1.001 else { return [] }
        var points: [SIMD3<Float>] = []
        var pixels = Set<Int>()
        for row in 0..<rows { for column in 0..<columns {
            let x = box.x + box.z * (Float(column) + 0.5) / Float(columns)
            let y = box.y + box.w * (Float(row) + 0.5) / Float(rows)
            let uv = SIMD2(y, 1 - x)
            guard (0..<1).contains(uv.x), (0..<1).contains(uv.y) else { continue }
            let pixel = Int(uv.y * Float(frame.depth.height)) * frame.depth.width + Int(uv.x * Float(frame.depth.width))
            guard pixels.insert(pixel).inserted, let p = point(at: uv) else { continue }
            points.append(p)
        } }
        return points
    }
}
