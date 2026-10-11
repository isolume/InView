import Foundation
import Testing
@testable import AccessCore

private func location(x: Float = 4.5, z: Float = -12.25, floor: Int = 2, id: String = "p1") throws -> PersonLocation {
    let json = #"{"person":{"person_id":"\#(id)","name":"Ada","handle":"ada_l"},"venue_id":"student-center-east","floor":\#(floor),"x":\#(x),"z":\#(z),"updated_at":1760000000.0,"age_seconds":3,"share_expires_at":1760003600.0}"#
    return try JSONDecoder().decode(PersonLocation.self, from: Data(json.utf8))
}

@Test func personLocationDecodesTheServersFlatShape() throws {
    let here = try location()
    #expect(here.person.name == "Ada" && here.position.floor == 2)
    #expect(here.position.x == 4.5 && here.position.z == -12.25)
    #expect(here.ageSeconds == 3)
    #expect(here.shareExpiresAt.timeIntervalSince1970 == 1_760_003_600)
}

@Test func aPersonBecomesARoutableDestinationOnTheMapsFloor() throws {
    let point = try location().destination(floorY: -1.4)
    #expect(point.kind == .destination && point.title == "Ada")
    #expect(point.position == SIMD3<Float>(4.5, -1.4, -12.25))
    #expect(point.floorPoint == SIMD2<Float>(4.5, -12.25))
}

@Test func theDestinationKeepsOneIdentityWhileThePersonMoves() throws {
    let a = try location(x: 1, z: 1).destinationID
    let b = try location(x: 9, z: 9).destinationID
    let other = try location(id: "p2").destinationID
    #expect(a == b)
    #expect(a != other)
}

@Test func onlyARealMoveReplansTheRoute() throws {
    let before = try location(x: 0, z: 0)
    #expect(try location(x: 1, z: 1).hasMoved(from: before) == false)
    #expect(try location(x: 3, z: 0).hasMoved(from: before))
    #expect(try location(x: 0, z: 0, floor: 3).hasMoved(from: before))
    #expect(before.hasMoved(from: nil))
}

@Test func theVenueAndFloorMustMatchBeforeRouting() throws {
    let here = try location(floor: 2)
    #expect(here.isOn(venueID: "student-center-east", floor: 2))
    #expect(!here.isOn(venueID: "student-center-east", floor: 3))
    #expect(!here.isOn(venueID: "somewhere-else", floor: 2))
}

@Test func sharesDecodeWithDirectionAndConsentState() throws {
    let json = #"{"id":"s1","direction":"outgoing","state":"requested","person":{"person_id":"p1","name":"Ben","handle":null},"expires_at":null,"started_by_me":false}"#
    let share = try JSONDecoder().decode(PersonShare.self, from: Data(json.utf8))
    #expect(share.needsMyAnswer)
    #expect(!share.canFollow)
    let live = #"{"id":"s2","direction":"incoming","state":"active","person":{"person_id":"p2","name":"Ada"},"expires_at":1760003600.0,"started_by_me":true}"#
    let active = try JSONDecoder().decode(PersonShare.self, from: Data(live.utf8))
    #expect(active.canFollow && !active.needsMyAnswer)
    #expect(active.expiresAt?.timeIntervalSince1970 == 1_760_003_600)
}

@Test func sharedPositionEncodesTheServersFieldNames() throws {
    let data = try JSONEncoder().encode(SharedPosition(floor: 2, x: 1, z: 2, headingDegrees: 90, accuracyMeters: 1.5))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["venue_id"] as? String == "student-center-east")
    #expect(object["heading_deg"] as? Double == 90 && object["accuracy_m"] as? Double == 1.5)
    #expect(object.keys.sorted() == ["accuracy_m", "floor", "heading_deg", "venue_id", "x", "z"])
}
