import CryptoKit
import Foundation
import simd

/// The parts of the worker's navigation analysis (`GET /scans/{id}/analysis`) the app uses.
///
/// The worker adds products and categories over time, so decoding is deliberately forgiving: every
/// product is optional, unknown keys are ignored, unknown categories decode as `.unknown`, and a
/// malformed entry is dropped instead of failing the whole document. Positions use the scan's shared
/// ARKit frame (meters, +Y up), the same space as `VenueMap`.
public struct ScanAnalysis: Decodable, Equatable, Sendable {
    public var schemaVersion: Int?
    public var scanID: String
    public var generatedAt: String?
    public var places: [Place]
    public var doors: [Door]
    public var doorSummary: DoorSummary?
    public var hazards: [Hazard]
    public var routes: [Route]
    public var notices: [String]

    public init(scanID: String, schemaVersion: Int? = 1, generatedAt: String? = nil, places: [Place] = [],
                doors: [Door] = [], doorSummary: DoorSummary? = nil, hazards: [Hazard] = [],
                routes: [Route] = [], notices: [String] = []) {
        self.scanID = scanID; self.schemaVersion = schemaVersion; self.generatedAt = generatedAt
        self.places = places; self.doors = doors; self.doorSummary = doorSummary; self.hazards = hazards
        self.routes = routes; self.notices = notices
    }

    /// Doors the worker flagged (too narrow, low headroom, or any other screening issue).
    public var doorsWithIssues: [Door] {
        doors.filter { !$0.issues.isEmpty || $0.meetsClearWidth == false || $0.meetsHeadroom == false }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", scanID = "scan_id", generatedAt = "generated_at"
        case places, doors, hazards, routes, notices, summary
    }

    private struct Summary: Decodable {
        var doors: DoorSummary?
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            doors = container.lossy(DoorSummary.self, forKey: AnyKey("doors"))
        }
    }

    /// The worker's routes product is `{profiles, routes: [...]}`; older drafts used a bare list.
    private struct RoutesProduct: Decodable {
        var routes: [Route]
        init(from decoder: any Decoder) throws {
            if let list = try? LossyList<Route>(from: decoder) { routes = list.elements; return }
            let container = try decoder.container(keyedBy: AnyKey.self)
            routes = container.lossy(LossyList<Route>.self, forKey: AnyKey("routes"))?.elements ?? []
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scanID = try container.decode(String.self, forKey: .scanID)
        schemaVersion = container.lossy(Int.self, forKey: .schemaVersion)
        generatedAt = container.lossy(String.self, forKey: .generatedAt)
        places = container.lossy(LossyList<Place>.self, forKey: .places)?.elements ?? []
        doors = container.lossy(LossyList<Door>.self, forKey: .doors)?.elements ?? []
        hazards = container.lossy(LossyList<Hazard>.self, forKey: .hazards)?.elements ?? []
        routes = container.lossy(RoutesProduct.self, forKey: .routes)?.routes ?? []
        notices = container.lossy(LossyList<String>.self, forKey: .notices)?.elements ?? []
        doorSummary = container.lossy(Summary.self, forKey: .summary)?.doors
    }
}

extension ScanAnalysis {
    /// A named, located thing worth navigating to or past (entrance, restroom, elevator, room ...).
    public struct Place: Decodable, Equatable, Sendable {
        public enum Category: String, Decodable, Sendable, CaseIterable {
            case entrance, exit, emergencyExit = "emergency_exit", restroom
            case accessibleRestroom = "accessible_restroom", elevator, stairs, escalator, ramp, door, room
            case corridor, information, reception, seating, waterFountain = "water_fountain"
            case fireExtinguisher = "fire_extinguisher", firstAid = "first_aid", landmark, unknown

            public init(from decoder: any Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Category(rawValue: raw) ?? .unknown
            }

            /// Mirrors the worker's `access_point_kind()` for documents that omit it.
            public var accessPointKind: AccessPoint.Kind {
                switch self {
                case .elevator: .elevator
                case .ramp: .ramp
                default: .destination
                }
            }

            public var title: String {
                rawValue.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        public var id: String
        public var category: Category
        public var name: String?
        /// BCP-47 language tag to name, for signage read in several languages.
        public var names: [String: String]
        /// `[x, y, z]` in meters.
        public var position: SIMD3<Float>?
        public var floorID: String?
        public var confidence: Float?
        public var sources: [String]
        /// The worker's mapping onto `AccessPoint.Kind`; nil when absent or not a known kind.
        public var accessPointKind: AccessPoint.Kind?
        public var sourceAccessPointID: UUID?
        public var source: AccessPoint.Source?
        public var slopeDegrees: Float?
        public var requiresAssistance: Bool?

        public init(id: String, category: Category, name: String? = nil, names: [String: String] = [:],
                    position: SIMD3<Float>?, floorID: String? = nil, confidence: Float? = nil,
                    sources: [String] = [], accessPointKind: AccessPoint.Kind? = nil,
                    sourceAccessPointID: UUID? = nil, source: AccessPoint.Source? = nil,
                    slopeDegrees: Float? = nil, requiresAssistance: Bool? = nil) {
            self.id = id; self.category = category; self.name = name; self.names = names
            self.position = position; self.floorID = floorID; self.confidence = confidence
            self.sources = sources; self.accessPointKind = accessPointKind
            self.sourceAccessPointID = sourceAccessPointID; self.source = source
            self.slopeDegrees = slopeDegrees; self.requiresAssistance = requiresAssistance
        }

        private enum CodingKeys: String, CodingKey {
            case id, category, name, names, positionM = "position_m", floorID = "floor_id"
            case confidence, sources, accessPointKind = "access_point_kind"
            case sourceAccessPointID = "source_access_point_id", source
            case slopeDegrees = "slope_degrees", requiresAssistance = "requires_assistance"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            category = container.lossy(Category.self, forKey: .category) ?? .unknown
            name = container.lossy(String.self, forKey: .name)
            names = container.lossy([String: String].self, forKey: .names) ?? [:]
            position = container.lossy([Float].self, forKey: .positionM).flatMap(vector3)
            floorID = container.lossy(String.self, forKey: .floorID)
            confidence = container.lossy(Float.self, forKey: .confidence).flatMap { $0.isFinite ? $0 : nil }
            sources = container.lossy(LossyList<String>.self, forKey: .sources)?.elements ?? []
            accessPointKind = container.lossy(String.self, forKey: .accessPointKind).flatMap(AccessPoint.Kind.init(rawValue:))
            sourceAccessPointID = container.lossy(UUID.self, forKey: .sourceAccessPointID)
            source = container.lossy(AccessPoint.Source.self, forKey: .source)
            slopeDegrees = container.lossy(Float.self, forKey: .slopeDegrees).flatMap { $0.isFinite ? $0 : nil }
            requiresAssistance = container.lossy(Bool.self, forKey: .requiresAssistance)
        }

        /// The best name for the reader's languages: an exact or base-language match in `names`,
        /// then `name`, then any translation, then the category.
        public func localizedName(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
            let usable = names.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let base = { (tag: String) in tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? tag.lowercased() }
            for language in preferredLanguages {
                if let exact = usable.first(where: { $0.key.caseInsensitiveCompare(language) == .orderedSame }) { return exact.value }
                if let match = usable.sorted(by: { $0.key < $1.key }).first(where: { base($0.key) == base(language) }) { return match.value }
            }
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
            if let any = usable.sorted(by: { $0.key < $1.key }).first { return any.value }
            return category.title
        }
    }

    /// A doorway clearance check (screening evidence, not certification).
    public struct Door: Decodable, Equatable, Sendable {
        public var id: String
        public var kind: String?
        /// `(x, z)` on the floor.
        public var center: SIMD2<Float>?
        public var measuredClearWidthM: Float?
        public var requiredMinClearWidthM: Float?
        public var meetsClearWidth: Bool?
        public var meetsHeadroom: Bool?
        public var issues: [String]

        private enum CodingKeys: String, CodingKey {
            case id, kind, centerXZ = "center_xz_m", measuredClearWidthM = "measured_clear_width_m"
            case requiredMinClearWidthM = "required_min_clear_width_m", meetsClearWidth = "meets_clear_width"
            case meetsHeadroom = "meets_headroom", issues
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            kind = container.lossy(String.self, forKey: .kind)
            center = container.lossy([Float].self, forKey: .centerXZ).flatMap(vector2)
            measuredClearWidthM = container.lossy(Float.self, forKey: .measuredClearWidthM)
            requiredMinClearWidthM = container.lossy(Float.self, forKey: .requiredMinClearWidthM)
            meetsClearWidth = container.lossy(Bool.self, forKey: .meetsClearWidth)
            meetsHeadroom = container.lossy(Bool.self, forKey: .meetsHeadroom)
            issues = container.lossy(LossyList<String>.self, forKey: .issues)?.elements ?? []
        }
    }

    public struct DoorSummary: Decodable, Equatable, Sendable {
        public var checked: Int
        public var belowMinWidth: Int
        public var belowHeadroom: Int

        private enum CodingKeys: String, CodingKey {
            case checked, belowMinWidth = "below_min_width", belowHeadroom = "below_headroom"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            checked = container.lossy(Int.self, forKey: .checked) ?? 0
            belowMinWidth = container.lossy(Int.self, forKey: .belowMinWidth) ?? 0
            belowHeadroom = container.lossy(Int.self, forKey: .belowHeadroom) ?? 0
        }
    }

    /// A step, drop-off, steep ramp, low headroom or protruding object found in the floor evidence.
    public struct Hazard: Decodable, Equatable, Sendable {
        public enum Kind: String, Decodable, Sendable {
            case step, stairs, ramp, levelChange = "level_change", dropOff = "drop_off"
            case lowHeadroom = "low_headroom", protrudingObject = "protruding_object", unknown

            public init(from decoder: any Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        public enum Severity: String, Decodable, Sendable {
            case barrier, warning, unknown

            public init(from decoder: any Decoder) throws {
                self = Severity(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        public var id: String
        public var kind: Kind
        public var severity: Severity
        public var position: SIMD3<Float>?

        private enum CodingKeys: String, CodingKey { case id, kind, severity, positionM = "position_m" }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            kind = container.lossy(Kind.self, forKey: .kind) ?? .unknown
            severity = container.lossy(Severity.self, forKey: .severity) ?? .unknown
            position = container.lossy([Float].self, forKey: .positionM).flatMap(vector3)
        }
    }

    /// Summary of a precomputed route between two places (turn-by-turn text stays on the server).
    public struct Route: Decodable, Equatable, Sendable {
        public var fromPlace: String?
        public var toPlace: String?
        public var profile: String?
        public var lengthM: Float?
        public var estimatedSeconds: Float?
        public var nodeIDs: [String]
        /// Languages with turn-by-turn instructions.
        public var instructionLanguages: [String]

        private enum CodingKeys: String, CodingKey {
            case fromPlace = "from_place", toPlace = "to_place", profile, lengthM = "length_m"
            case estimatedSeconds = "estimated_seconds", nodeIDs = "node_ids", instructions
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fromPlace = container.lossy(String.self, forKey: .fromPlace)
            toPlace = container.lossy(String.self, forKey: .toPlace)
            profile = container.lossy(String.self, forKey: .profile)
            lengthM = container.lossy(Float.self, forKey: .lengthM)
            estimatedSeconds = container.lossy(Float.self, forKey: .estimatedSeconds)
            nodeIDs = container.lossy(LossyList<String>.self, forKey: .nodeIDs)?.elements ?? []
            instructionLanguages = (container.lossy([String: JSONValue].self, forKey: .instructions)?.keys).map { $0.sorted() } ?? []
        }
    }
}

// MARK: - Places on the venue map

extension ScanAnalysis.Place {
    /// The map point for this place, or nil when it has no usable position.
    /// - Parameters:
    ///   - scanID: Namespaces the deterministic point ID, so equal place IDs from different scans differ.
    ///   - floorY: When set, rejects positions clearly outside this floor; never changes their elevation.
    public func accessPoint(scanID: String, floorY: Float? = nil,
                            expectedFloorID: String? = nil,
                            preferredLanguages: [String] = Locale.preferredLanguages) -> AccessPoint? {
        guard let position, position.x.isFinite, position.y.isFinite, position.z.isFinite else { return nil }
        if let expectedFloorID, let floorID, floorID != expectedFloorID { return nil }
        // Signage may be above the floor. Keep its measured height without admitting another story.
        if let floorY, (!floorY.isFinite || position.y < floorY - 0.75 || position.y > floorY + 2.5) { return nil }
        return AccessPoint(
            id: sourceAccessPointID ?? AccessPoint.detectedID(scanID: scanID, placeID: id),
            kind: accessPointKind ?? category.accessPointKind,
            name: localizedName(preferredLanguages: preferredLanguages),
            position: position,
            source: source ?? .detected,
            confidence: min(max(confidence ?? 0.5, 0), 1),
            slopeDegrees: slopeDegrees,
            requiresAssistance: requiresAssistance ?? false
        )
    }
}

extension AccessPoint {
    /// Fixed namespace for detected-place IDs (an RFC 4122 name-based UUID, version 5 / SHA-1).
    private static let detectedNamespace = UUID(uuidString: "6F1E3C1A-8B9D-4E52-9C0B-2A7D5F4E8B11")!

    /// A stable UUID for a worker place, so merging the same analysis again never duplicates it.
    public static func detectedID(scanID: String, placeID: String) -> UUID {
        let namespace = withUnsafeBytes(of: detectedNamespace.uuid) { Data($0) }
        var digest = Array(Insecure.SHA1.hash(data: namespace + Data("\(scanID)\u{0}\(placeID)".utf8)).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    /// The detected points worth adding to `existing`: skips any whose ID is already present, and any
    /// within `radius` meters (on the floor) of an existing point of the same kind, including points
    /// accepted earlier in `detected`. Existing points, manual ones especially, are never changed.
    public static func newDetections(_ detected: [AccessPoint], existing: [AccessPoint],
                                     radius: Float = 1) -> [AccessPoint] {
        var kept = existing
        var added: [AccessPoint] = []
        for point in detected {
            guard !kept.contains(where: { $0.id == point.id }),
                  !kept.contains(where: { $0.kind == point.kind && simd_distance($0.floorPoint, point.floorPoint) < radius })
            else { continue }
            kept.append(point)
            added.append(point)
        }
        return added
    }
}

// MARK: - Lenient decoding helpers

private func vector3(_ values: [Float]) -> SIMD3<Float>? {
    guard values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
    return SIMD3(values[0], values[1], values[2])
}

private func vector2(_ values: [Float]) -> SIMD2<Float>? {
    guard values.count == 2, values.allSatisfy(\.isFinite) else { return nil }
    return SIMD2(values[0], values[1])
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Decodes the elements that parse and drops the rest.
struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // A failed decode does not advance the container; consume the value as any JSON.
                _ = try container.decode(JSONValue.self)
            }
        }
        self.elements = elements
    }
}

private extension KeyedDecodingContainer {
    /// The value at `key`, or nil when it is missing, null, or the wrong shape.
    func lossy<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
