import Foundation
import simd

/// The worker's `highlights` product: the key aspects of a scan, ranked, and the annotated plan
/// that shows them. Positions are in the scan's ARKit frame, like the rest of `ScanAnalysis`.
public struct ScanHighlights: Decodable, Equatable, Sendable {
    public struct Item: Decodable, Equatable, Identifiable, Sendable {
        public var id: String
        public var rank: Int
        /// `barrier`, `narrow_passage`, `door`, `access_feature`, `wayfinding` or `route`.
        public var kind: String
        /// `barrier`, `warning`, `asset` or `info`.
        public var severity: String
        /// 0...1.
        public var importance: Float
        public var title: String
        public var reason: String
        /// Floor position as (x, z) in meters.
        public var position: SIMD2<Float>
        /// The badge number drawn on the image, nil for items beyond the numbered callouts.
        public var number: Int?
        /// Where this item sits in `Image` pixels.
        public var anchorPixel: SIMD2<Float>?
        public var calloutPixel: SIMD2<Float>?

        private enum CodingKeys: String, CodingKey {
            case id, rank, kind, severity, importance, title, reason, number
            case position = "position_xz_m", anchorPixel = "anchor_px", calloutPixel = "callout_px"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(String.self, forKey: .kind)
            title = try c.decode(String.self, forKey: .title)
            severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? "info"
            rank = try c.decodeIfPresent(Int.self, forKey: .rank) ?? 0
            reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
            let importance = try c.decodeIfPresent(Float.self, forKey: .importance) ?? 0
            self.importance = importance.isFinite ? min(1, max(0, importance)) : 0
            number = try c.decodeIfPresent(Int.self, forKey: .number)
            position = try Self.point(c, .position) ?? { throw DecodingError.dataCorruptedError(
                forKey: .position, in: c, debugDescription: "Missing position.") }()
            anchorPixel = try Self.point(c, .anchorPixel)
            calloutPixel = try Self.point(c, .calloutPixel)
        }

        private static func point(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> SIMD2<Float>? {
            guard let values = try c.decodeIfPresent([Float].self, forKey: key) else { return nil }
            guard values.count == 2, values.allSatisfy(\.isFinite) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Invalid point.")
            }
            return SIMD2(values[0], values[1])
        }
    }

    public struct Image: Decodable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// The plan occupies the left `mapWidth` pixels; the legend panel sits to its right.
        public var mapWidth: Int
        public var mapHeight: Int
        public var metersPerPixel: Float
        /// World (x, z) of pixel (0, 0).
        public var origin: SIMD2<Float>
        /// Base64 PNG; absent when the server omitted it (use `/scans/{id}/highlights.png`).
        public var pngBase64: String?

        private enum CodingKeys: String, CodingKey {
            case width, height, mapWidth = "map_width_px", mapHeight = "map_height_px"
            case metersPerPixel = "resolution_m_per_px", origin = "origin_xz_m", pngBase64 = "png_base64"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            width = try c.decode(Int.self, forKey: .width)
            height = try c.decode(Int.self, forKey: .height)
            mapWidth = try c.decodeIfPresent(Int.self, forKey: .mapWidth) ?? width
            mapHeight = try c.decodeIfPresent(Int.self, forKey: .mapHeight) ?? height
            let scale = try c.decode(Float.self, forKey: .metersPerPixel)
            let origin = try c.decode([Float].self, forKey: .origin)
            guard width > 0, height > 0, scale.isFinite, scale > 0, origin.count == 2, origin.allSatisfy(\.isFinite) else {
                throw DecodingError.dataCorruptedError(forKey: .metersPerPixel, in: c, debugDescription: "Invalid image geometry.")
            }
            metersPerPixel = scale
            self.origin = SIMD2(origin[0], origin[1])
            pngBase64 = try c.decodeIfPresent(String.self, forKey: .pngBase64)
        }

        /// The decoded PNG bytes, when the image is embedded.
        public var pngData: Data? {
            guard let pngBase64, pngBase64.utf8.count <= 12 * 1024 * 1024 else { return nil }
            return Data(base64Encoded: pngBase64)
        }

        /// Where a floor position falls in the image.
        public func pixel(forX x: Float, z: Float) -> SIMD2<Float> {
            SIMD2((x - origin.x) / metersPerPixel, (z - origin.y) / metersPerPixel)
        }

        /// The floor position under an image pixel; nil over the legend panel.
        public func position(forPixel pixel: SIMD2<Float>) -> SIMD2<Float>? {
            guard pixel.x >= 0, pixel.y >= 0, pixel.x < Float(mapWidth), pixel.y < Float(mapHeight) else { return nil }
            return origin + pixel * metersPerPixel
        }
    }

    public var floorID: String?
    /// Most important first.
    public var items: [Item]
    public var image: Image?

    private enum CodingKeys: String, CodingKey { case floorID = "floor_id", items, image }

    public init(floorID: String? = nil, items: [Item] = [], image: Image? = nil) {
        self.floorID = floorID; self.items = items; self.image = image
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        floorID = Self.optional(c, String.self, .floorID)
        items = (try? c.decode(LossyList<Item>.self, forKey: .items))?.elements ?? []
        items.sort { ($0.rank == 0 ? Int.max : $0.rank) < ($1.rank == 0 ? Int.max : $1.rank) }
        image = Self.optional(c, Image.self, .image)
    }

    private static func optional<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ type: T.Type, _ key: CodingKeys) -> T? {
        try? c.decodeIfPresent(type, forKey: key)
    }

    /// The numbered item whose badge or anchor lies within `radius` pixels of `pixel`: what a tap
    /// on the image means. Badges win over anchors when both are in range.
    public func item(atPixel pixel: SIMD2<Float>, radius: Float = 24) -> Item? {
        var best: (Item, Float)?
        for item in items {
            for point in [item.calloutPixel, item.anchorPixel].compactMap({ $0 }) {
                let distance = simd_distance(point, pixel)
                if distance <= radius, best == nil || distance < best!.1 { best = (item, distance) }
            }
        }
        return best?.0
    }

    /// The items of one severity, most important first.
    public func items(severity: String) -> [Item] { items.filter { $0.severity == severity } }
}
