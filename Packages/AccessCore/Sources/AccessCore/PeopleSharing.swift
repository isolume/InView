import CryptoKit
import Foundation
import simd

/// Live location sharing between two people who agreed to it. The server only ever returns another
/// person's position while a share they started (or accepted) is active.
public struct PersonShare: Decodable, Equatable, Identifiable, Sendable {
    public enum Direction: String, Decodable, Sendable { case outgoing, incoming }
    public enum State: String, Decodable, Sendable { case requested, active, declined, revoked, expired }

    public var id: String
    /// `outgoing`: you share your position with them. `incoming`: they share theirs with you.
    public var direction: Direction
    public var state: State
    public var person: PersonMatch
    public var expiresAt: Date?
    public var startedByMe: Bool

    private enum CodingKeys: String, CodingKey {
        case id, direction, state, person, expiresAt = "expires_at", startedByMe = "started_by_me"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        direction = try c.decode(Direction.self, forKey: .direction)
        state = try c.decode(State.self, forKey: .state)
        person = try c.decode(PersonMatch.self, forKey: .person)
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt).map { Date(timeIntervalSince1970: $0) }
        startedByMe = try c.decodeIfPresent(Bool.self, forKey: .startedByMe) ?? false
    }

    /// Someone asked you to share and is waiting for your answer.
    public var needsMyAnswer: Bool { direction == .outgoing && state == .requested && !startedByMe }
    /// You can follow this person right now.
    public var canFollow: Bool { direction == .incoming && state == .active }
}

/// A position in the shared map frame of a venue (the published map, never a device-local scan).
public struct SharedPosition: Codable, Equatable, Sendable {
    public var venueID: String
    public var floor: Int
    public var x: Float
    public var z: Float
    public var headingDegrees: Float?
    public var accuracyMeters: Float?

    public static let studentCenterVenueID = "student-center-east"

    public init(venueID: String = SharedPosition.studentCenterVenueID, floor: Int, x: Float, z: Float,
                headingDegrees: Float? = nil, accuracyMeters: Float? = nil) {
        self.venueID = venueID; self.floor = floor; self.x = x; self.z = z
        self.headingDegrees = headingDegrees; self.accuracyMeters = accuracyMeters
    }

    private enum CodingKeys: String, CodingKey {
        case venueID = "venue_id", floor, x, z, headingDegrees = "heading_deg", accuracyMeters = "accuracy_m"
    }
}

/// Where a person who is sharing with you is right now.
public struct PersonLocation: Decodable, Equatable, Sendable {
    public var person: PersonMatch
    public var position: SharedPosition
    public var updatedAt: Date
    public var ageSeconds: Int
    public var shareExpiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case person, updatedAt = "updated_at", ageSeconds = "age_seconds", shareExpiresAt = "share_expires_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        person = try c.decode(PersonMatch.self, forKey: .person)
        position = try SharedPosition(from: decoder)
        updatedAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .updatedAt))
        ageSeconds = try c.decodeIfPresent(Int.self, forKey: .ageSeconds) ?? 0
        shareExpiresAt = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .shareExpiresAt))
    }

    /// Whether this position is in the map frame of `venueID` on `floor`, so a route can reach it.
    public func isOn(venueID: String, floor: Int) -> Bool {
        position.venueID == venueID && position.floor == floor
    }

    /// The same id every time for one person, so a moving destination updates in place.
    public var destinationID: UUID {
        let bytes = Array(SHA256.hash(data: Data("inview-person-pin:\(person.personID)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A destination at their position on the map's floor, so the planner can route to a person the
    /// way it routes to a place.
    public func destination(floorY: Float) -> AccessPoint {
        AccessPoint(id: destinationID, kind: .destination, name: person.name,
                    position: SIMD3(position.x, floorY, position.z), source: .manual, confidence: 1)
    }

    /// Whether the person has moved far enough from `previous` to re-plan the route.
    public func hasMoved(from previous: PersonLocation?, atLeast meters: Float = 2.5) -> Bool {
        guard let previous, previous.position.venueID == position.venueID,
              previous.position.floor == position.floor else { return true }
        return simd_distance(SIMD2(previous.position.x, previous.position.z), SIMD2(position.x, position.z)) >= meters
    }
}
