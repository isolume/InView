import Foundation
import simd

/// What a sign names, normalized for people, search and spoken directions: "RM. 204" reads as
/// "Room 204", "WOMEN" as "Women's restroom". Arrows mean the sign points somewhere else, so a
/// directional reading never labels the door it hangs beside.
public struct SignReading: Codable, Hashable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case room, exit, restroom, elevator, stairs, lobby, office, other

        public var title: String {
            switch self {
            case .room: "Room"
            case .exit: "Exit"
            case .restroom: "Restroom"
            case .elevator: "Elevator"
            case .stairs: "Stairs"
            case .lobby: "Lobby"
            case .office: "Office"
            case .other: "Place"
            }
        }
    }

    public var category: Category
    /// Short spoken name: "Room 204", "Emergency exit", "Main lobby".
    public var title: String
    /// Secondary text on the same plate, like "Chemistry Lab" under a room number.
    public var detail: String?
    public var roomNumber: String?
    /// Arrows or direction words printed on the sign, relative to the sign itself.
    public var directions: [String]

    public init(category: Category, title: String, detail: String? = nil, roomNumber: String? = nil, directions: [String] = []) {
        self.category = category
        self.title = title
        self.detail = detail
        self.roomNumber = roomNumber
        self.directions = directions
    }

    /// A sign with an arrow points along the corridor, not at the door it hangs beside.
    public var isDirectional: Bool { !directions.isEmpty }

    /// "Room 204 · Chemistry Lab", or just the title.
    public var fullTitle: String {
        guard let detail, !detail.isEmpty, detail.caseInsensitiveCompare(title) != .orderedSame else { return title }
        return "\(title) · \(detail)"
    }

    enum CodingKeys: String, CodingKey {
        case category, title, detail, roomNumber = "room_number", directions
    }
}

/// Reads the lines of one sign plate into a `SignReading`. Deterministic and offline, so it works at
/// camera rate; an AI pass may refine the result later but never has to.
public enum SignInterpreter {
    /// Posters and notices are long; signs are a few words.
    static let maximumWords = 9

    public static func interpret(_ lines: [String]) -> SignReading? {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        let joined = cleaned.joined(separator: " ")
        let upper = joined.uppercased()
        let tokens = upper.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }.filter { !$0.isEmpty }
        let words = Set(tokens)
        guard !tokens.isEmpty, tokens.count <= maximumWords else { return nil }
        // Prices, times, percentages and phone numbers aren't room signs.
        guard upper.rangeOfCharacter(from: CharacterSet(charactersIn: "$%@:")) == nil else { return nil }
        let directions = SignMeaning.classify(joined)?.directions ?? []

        if !words.isDisjoint(with: ["EXIT", "EXITS", "EGRESS", "SALIDA", "SORTIE"]) {
            guard words.isDisjoint(with: ["NO", "NOT"]) else { return nil }
            let title = words.contains("FIRE") ? "Fire exit"
                : words.contains("EMERGENCY") ? "Emergency exit" : "Exit"
            return SignReading(category: .exit, title: title, directions: directions)
        }
        if !words.isDisjoint(with: ["ELEVATOR", "ELEVATORS", "LIFT", "LIFTS"]) {
            return SignReading(category: .elevator, title: "Elevator", directions: directions)
        }
        if !words.isDisjoint(with: ["STAIR", "STAIRS", "STAIRCASE", "STAIRWAY", "STAIRWELL"]) {
            let letter = tokens.first { $0.count == 1 && $0.first?.isLetter == true }
            return SignReading(category: .stairs, title: letter.map { "Stair \($0)" } ?? "Stairs", directions: directions)
        }
        if let restroom = restroomTitle(words) {
            return SignReading(category: .restroom, title: restroom, roomNumber: roomNumber(in: tokens).map(\.number),
                               directions: directions)
        }
        if let found = roomNumber(in: tokens) {
            let detail = detailText(cleaned, excluding: found.consumed)
            let isSuite = words.contains("SUITE") || words.contains("STE")
            return SignReading(category: .room, title: "\(isSuite ? "Suite" : "Room") \(found.number)",
                               detail: detail, roomNumber: found.number, directions: directions)
        }
        if !words.isDisjoint(with: ["LOBBY", "ATRIUM", "FOYER", "RECEPTION"]) {
            let title = words.contains("MAIN") ? "Main lobby" : titleCase(joined)
            return SignReading(category: .lobby, title: title.count <= 40 ? title : "Lobby", directions: directions)
        }
        if !words.isDisjoint(with: ["OFFICE", "OFFICES", "LAB", "LABORATORY", "CLASSROOM", "CONFERENCE", "LOUNGE",
                                    "LIBRARY", "CAFE", "CAFETERIA", "BALLROOM", "THEATER", "THEATRE", "AUDITORIUM"]) {
            return SignReading(category: .office, title: titleCase(joined), directions: directions)
        }
        return nil
    }

    private static func restroomTitle(_ words: Set<String>) -> String? {
        let general: Set<String> = ["RESTROOM", "RESTROOMS", "TOILET", "TOILETS", "WC", "BATHROOM", "BATHROOMS", "LAVATORY"]
        let women: Set<String> = ["WOMEN", "WOMENS", "WOMAN", "LADIES", "FEMALE"]
        let men: Set<String> = ["MEN", "MENS", "GENTLEMEN", "MALE"]
        let isWomen = !words.isDisjoint(with: women), isMen = !words.isDisjoint(with: men)
        let isGeneral = !words.isDisjoint(with: general)
        if words.contains("GENDER") || words.contains("UNISEX") || words.contains("FAMILY") && isGeneral { return "All-gender restroom" }
        if isWomen && !isMen { return "Women's restroom" }
        if isMen && !isWomen { return "Men's restroom" }
        return isGeneral || (isWomen && isMen) ? "Restroom" : nil
    }

    /// "204", "204A", "B-204", "RM 204", "ROOM 2.04" → the number as printed, without the "ROOM" prefix.
    static func roomNumber(in tokens: [String]) -> (number: String, consumed: Set<String>)? {
        let prefixes: Set<String> = ["ROOM", "RM", "SUITE", "STE", "NO"]
        for (index, token) in tokens.enumerated() {
            guard token.range(of: #"^([A-Z]{1,3}-?)?[0-9]{2,4}[A-Z]?$"#, options: .regularExpression) != nil else { continue }
            let digits = token.filter(\.isNumber)
            // A bare four-digit number is usually a year, not a room.
            if token.allSatisfy(\.isNumber), digits.count == 4, digits.hasPrefix("19") || digits.hasPrefix("20") { continue }
            var consumed: Set<String> = [token]
            if index > 0, prefixes.contains(tokens[index - 1]) { consumed.insert(tokens[index - 1]) }
            return (token, consumed)
        }
        return nil
    }

    /// The plate's other words, like "CHEMISTRY LAB", in title case.
    private static func detailText(_ lines: [String], excluding consumed: Set<String>) -> String? {
        let remaining = lines.joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { word in
                let core = word.uppercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                return !core.isEmpty && !consumed.contains(core) && core.contains(where: \.isLetter)
            }
            .joined(separator: " ")
        let text = titleCase(remaining)
        return text.filter(\.isLetter).count >= 3 ? text : nil
    }

    static func titleCase(_ text: String) -> String {
        text.split(separator: " ").map { word in
            let lower = word.lowercased()
            return lower.count <= 2 && ["of", "to", "&", "a", "an"].contains(lower) ? lower : lower.capitalized
        }.joined(separator: " ")
    }
}

/// How a place came from a sign: what was read, and the measured door and room it labels. Stored on
/// the `AccessPoint` so maps can light up the door and fill the room.
public struct SignTag: Codable, Hashable, Sendable {
    public struct Door: Codable, Hashable, Sendable {
        /// Door center on the floor, as (x, z).
        public var center: SIMD2<Float>
        public var width: Float
        /// Same convention as `Footprint.yaw`.
        public var yaw: Float

        public init(center: SIMD2<Float>, width: Float, yaw: Float) {
            self.center = center; self.width = width; self.yaw = yaw
        }
    }

    public var reading: SignReading
    /// The raw text exactly as it was read.
    public var text: String
    /// The sign's measured position, in map meters.
    public var signPosition: SIMD3<Float>
    public var door: Door?
    /// The measured floor of the room behind the door, as (x, z), when the scan covered it.
    public var room: [SIMD2<Float>]?
    /// "on_device" for Vision OCR, "ai" once a vision model confirmed or corrected it.
    public var reader: String

    public init(reading: SignReading, text: String, signPosition: SIMD3<Float>, door: Door? = nil,
                room: [SIMD2<Float>]? = nil, reader: String = "on_device") {
        self.reading = reading; self.text = text; self.signPosition = signPosition
        self.door = door; self.room = room; self.reader = reader
    }

    enum CodingKeys: String, CodingKey {
        case reading, text, signPosition = "sign_position", door, room, reader
    }
}

/// Turns a localized sign into a place on the map: the nearest measured door on the sign's wall
/// becomes "Room 204" or "Exit", and the place sits in front of that door, on the reader's side, so
/// routes end where a person actually waits.
public enum SignPlaceBinder {
    /// Room plaques hang beside the frame and exit signs above it; neither is far from the door.
    public static let doorSearchRadius: Float = 2.2
    /// Where the place sits, measured out from the door.
    public static let standOff: Float = 0.6

    public struct DoorMatch: Equatable, Sendable {
        public var footprint: Footprint
        /// Lower is better: distance past the door's edge plus how far the sign is off its wall.
        public var score: Float
    }

    /// The door or opening a sign belongs to: on the same wall, and beside or above the frame.
    public static func door(for sign: SIMD3<Float>, in map: VenueMap) -> DoorMatch? {
        let point = SIMD2(sign.x, sign.z)
        return map.footprints.filter { $0.kind == .door || $0.kind == .opening }.compactMap { door -> DoorMatch? in
            let local = door.local(point)
            let pastEdge = max(0, abs(local.x) - door.size.x / 2)
            let offWall = abs(local.y)
            guard pastEdge <= doorSearchRadius, offWall <= 0.9 else { return nil }
            return DoorMatch(footprint: door, score: pastEdge + offWall * 2)
        }.min { $0.score < $1.score }
    }

    /// Builds the place a sign names. `viewer` is where the reader stood (the camera), which tells
    /// the corridor side of the door from the room side; `id` keeps an existing place's identity.
    public static func place(for reading: SignReading, text: String, sign: SIMD3<Float>, viewer: SIMD3<Float>?,
                             in map: VenueMap, id: UUID = UUID(), confidence: Float = 0.9) -> AccessPoint {
        let signFloor = SIMD2(sign.x, sign.z)
        let viewerFloor = viewer.map { SIMD2($0.x, $0.z) }
        var tag = SignTag(reading: reading, text: text, signPosition: sign)
        var spot: SIMD2<Float>
        if !reading.isDirectional, let door = door(for: sign, in: map)?.footprint
            ?? estimatedDoor(for: sign, reading: reading, viewer: viewer, in: map) {
            let normal = SIMD2(-sin(door.yaw), cos(door.yaw))
            // Stand on the viewer's side; without a viewer, on the side the sign is on.
            let reference = viewerFloor ?? signFloor
            let offset = simd_dot(reference - door.center, normal)
            let side: Float = offset >= 0 ? 1 : -1
            spot = door.center + normal * side * standOff
            tag.door = SignTag.Door(center: door.center, width: door.size.x, yaw: door.yaw)
            tag.room = room(behind: door, side: -side, in: map)
        } else if let viewerFloor, simd_distance(viewerFloor, signFloor) > 0.05 {
            // No door: the floor in front of the sign, toward where the reader stood.
            let toward = simd_normalize(viewerFloor - signFloor)
            spot = signFloor + toward * min(standOff, simd_distance(viewerFloor, signFloor))
        } else {
            spot = signFloor
        }
        let kind: AccessPoint.Kind = reading.category == .elevator ? .elevator : .destination
        var point = AccessPoint(id: id, kind: kind, name: reading.fullTitle,
                                position: SIMD3(spot.x, map.floorY, spot.y), source: .detected, confidence: confidence)
        point.sign = tag
        return point
    }

    /// Scans often miss doors (RoomPlan reads a closed one as wall), so a sign that names a doorway
    /// gets one where it hangs: on the nearest wall, else facing the reader. Lobby and "other" signs
    /// name an area, not a door, and get none.
    static func estimatedDoor(for sign: SIMD3<Float>, reading: SignReading, viewer: SIMD3<Float>?,
                              in map: VenueMap) -> Footprint? {
        guard reading.category != .lobby, reading.category != .other else { return nil }
        let point = SIMD2(sign.x, sign.z)
        let width: Float = 0.9
        let wall = map.footprints.filter { $0.kind == .wall }.compactMap { wall -> (Footprint, SIMD2<Float>, Float)? in
            let local = wall.local(point)
            let pastEnd = max(0, abs(local.x) - wall.size.x / 2)
            guard pastEnd <= 0.3, abs(local.y) <= 0.9 else { return nil }
            return (wall, local, abs(local.y) + pastEnd)
        }.min { $0.2 < $1.2 }
        if let (wall, local, _) = wall {
            // Keep the doorway on the wall even when the sign hangs near its end.
            let room = max(0, wall.size.x / 2 - width / 2)
            let along = min(max(local.x, -room), room)
            return Footprint(kind: .door, center: wall.floorPoint(local: SIMD2(along, 0)),
                             size: SIMD2(width, 0.15), yaw: wall.yaw)
        }
        guard let viewer else { return nil }
        let facing = SIMD2(viewer.x, viewer.z) - point
        guard simd_length(facing) > 0.2 else { return nil }
        // The wall runs across the reader's line of sight.
        return Footprint(kind: .door, center: point, size: SIMD2(width, 0.15), yaw: atan2(facing.y, facing.x) + .pi / 2)
    }

    /// The measured floor on the far side of a door, when it is a different floor patch from the near side.
    static func room(behind door: Footprint, side: Float, in map: VenueMap) -> [SIMD2<Float>]? {
        let normal = SIMD2(-sin(door.yaw), cos(door.yaw))
        let inside = door.center + normal * side * 1.2
        let outside = door.center - normal * side * 1.2
        let floors = map.footprints.filter { $0.kind == .floor }.map(\.corners).filter { $0.count >= 3 }
        return floors.first { Polygon.contains(inside, in: $0) && !Polygon.contains(outside, in: $0) }
    }
}

extension VenueMap {
    /// Adds a place read from a sign, or updates the one already labeling the same door or carrying
    /// the same name nearby, so pointing at a sign twice never makes two pins.
    /// - Returns: The stored place and whether it is new.
    @discardableResult
    public mutating func applySign(_ point: AccessPoint) -> (point: AccessPoint, isNew: Bool) {
        func matches(_ existing: AccessPoint) -> Bool {
            guard let tag = point.sign else { return false }
            if let door = tag.door, let other = existing.sign?.door, simd_distance(door.center, other.center) < 0.35 { return true }
            let sameName = existing.title.caseInsensitiveCompare(point.title) == .orderedSame
                || existing.sign.map { $0.reading.title.caseInsensitiveCompare(tag.reading.title) == .orderedSame } == true
            return sameName && simd_distance(existing.floorPoint, point.floorPoint) < 4
        }
        guard let index = points.firstIndex(where: matches) else {
            points.append(point)
            return (point, true)
        }
        var updated = point
        updated.id = points[index].id
        updated.requiresAssistance = points[index].requiresAssistance
        // A name someone typed wins over a later reading of the same door.
        if points[index].source == .manual { updated.name = points[index].name; updated.source = .manual }
        points[index] = updated
        return (updated, false)
    }

    /// Places that came from signs, for maps and quick filters.
    public var signPlaces: [AccessPoint] { points.filter { $0.sign != nil } }
}

extension AccessPoint {
    /// The sign category when the place was read from a sign.
    public var signCategory: SignReading.Category? { sign?.reading.category }

    /// Whether search text names this place: its title, kind, sign category or room number.
    public func matches(query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(text) || kind.title.localizedCaseInsensitiveContains(text) { return true }
        guard let sign else { return false }
        let singular = text.hasSuffix("s") ? String(text.dropLast()) : text
        return sign.reading.category.title.localizedCaseInsensitiveContains(singular)
            || sign.reading.roomNumber?.localizedCaseInsensitiveContains(text) == true
            || sign.text.localizedCaseInsensitiveContains(text)
    }
}
