import Foundation
import simd
import Testing
@testable import AccessCore

struct SignPlacesTests {
    @Test func readsRoomPlates() throws {
        let plain = try #require(SignInterpreter.interpret(["204"]))
        #expect(plain.category == .room)
        #expect(plain.title == "Room 204")
        #expect(plain.roomNumber == "204")

        let labeled = try #require(SignInterpreter.interpret(["RM. 204A", "CHEMISTRY LAB"]))
        #expect(labeled.title == "Room 204A")
        #expect(labeled.detail == "Chemistry Lab")
        #expect(labeled.fullTitle == "Room 204A · Chemistry Lab")

        #expect(SignInterpreter.interpret(["Suite 300"])?.title == "Suite 300")
        #expect(SignInterpreter.interpret(["B-204"])?.roomNumber == "B-204")
    }

    @Test func readsExitsRestroomsAndLandmarks() {
        #expect(SignInterpreter.interpret(["EXIT"])?.category == .exit)
        #expect(SignInterpreter.interpret(["EMERGENCY EXIT"])?.title == "Emergency exit")
        #expect(SignInterpreter.interpret(["FIRE EXIT"])?.title == "Fire exit")
        #expect(SignInterpreter.interpret(["EXIT →"])?.isDirectional == true)
        #expect(SignInterpreter.interpret(["NOT AN EXIT"]) == nil)
        #expect(SignInterpreter.interpret(["WOMEN"])?.title == "Women's restroom")
        #expect(SignInterpreter.interpret(["Men"])?.category == .restroom)
        #expect(SignInterpreter.interpret(["All Gender Restroom"])?.title == "All-gender restroom")
        #expect(SignInterpreter.interpret(["Elevators"])?.category == .elevator)
        #expect(SignInterpreter.interpret(["Stair B"])?.title == "Stair B")
        #expect(SignInterpreter.interpret(["MAIN LOBBY"])?.title == "Main lobby")
        #expect(SignInterpreter.interpret(["Student Lounge"])?.category == .office)
    }

    @Test func ignoresTextThatIsNotASign() {
        #expect(SignInterpreter.interpret(["Welcome"]) == nil)
        #expect(SignInterpreter.interpret(["2026"]) == nil)
        #expect(SignInterpreter.interpret(["Open 10:30"]) == nil)
        #expect(SignInterpreter.interpret(["$204"]) == nil)
        #expect(SignInterpreter.interpret(["Join us for the club fair this Thursday in room 204 at noon please"]) == nil)
    }

    /// A corridor along x with a door in the wall at z = 0, and a room behind it (z < 0).
    private func corridor() -> VenueMap {
        let door = Footprint(kind: .door, center: SIMD2(2, 0), size: SIMD2(0.9, 0.15), yaw: 0)
        let wall = Footprint(kind: .wall, center: SIMD2(0, 0), size: SIMD2(10, 0.15), yaw: 0)
        let hall = Footprint(floor: [SIMD2(-5, 0), SIMD2(5, 0), SIMD2(5, 3), SIMD2(-5, 3)], bottom: -1.3)
        let room = Footprint(floor: [SIMD2(0, -4), SIMD2(4, -4), SIMD2(4, 0), SIMD2(0, 0)], bottom: -1.3)
        return VenueMap(floorY: -1.3, footprints: [hall, room, wall, door], points: [])
    }

    @Test func bindsAPlaqueToTheDoorBesideItOnTheReadersSide() throws {
        let reading = try #require(SignInterpreter.interpret(["204"]))
        // Plaque 0.3 m right of the frame, at eye height; the reader stands in the corridor.
        let point = SignPlaceBinder.place(for: reading, text: "204", sign: SIMD3(2.75, 0.2, 0.02),
                                          viewer: SIMD3(2.5, 0.2, 1.8), in: corridor())
        #expect(point.title == "Room 204")
        #expect(point.kind == .destination)
        let door = try #require(point.sign?.door)
        #expect(door.center == SIMD2(2, 0))
        #expect(abs(point.position.x - 2) < 1e-4)
        #expect(abs(point.position.z - SignPlaceBinder.standOff) < 1e-4)
        #expect(point.position.y == -1.3)
        // The room behind the door is the measured floor on the far side.
        #expect(point.sign?.room?.count == 4)
    }

    @Test func exitAboveADoorAndDirectionalSignsStayUnbound() throws {
        let exit = try #require(SignInterpreter.interpret(["EXIT"]))
        let above = SignPlaceBinder.place(for: exit, text: "EXIT", sign: SIMD3(2.1, 0.9, 0.05),
                                          viewer: SIMD3(2, 0.2, 2), in: corridor())
        #expect(above.sign?.door != nil)
        let arrow = try #require(SignInterpreter.interpret(["EXIT →"]))
        let pointing = SignPlaceBinder.place(for: arrow, text: "EXIT →", sign: SIMD3(2.1, 0.9, 0.05),
                                             viewer: SIMD3(2, 0.2, 2), in: corridor())
        #expect(pointing.sign?.door == nil)
    }

    @Test func farFromAnyDoorThePlaceSitsInFrontOfTheSign() throws {
        let reading = try #require(SignInterpreter.interpret(["MAIN LOBBY"]))
        let point = SignPlaceBinder.place(for: reading, text: "MAIN LOBBY", sign: SIMD3(-4, 0.5, 0.05),
                                          viewer: SIMD3(-4, 0.2, 2), in: corridor())
        #expect(point.sign?.door == nil)
        #expect(abs(point.position.z - 0.65) < 1e-3)
    }

    @Test func readingTheSameSignTwiceUpdatesOnePlace() throws {
        var map = corridor()
        let reading = try #require(SignInterpreter.interpret(["204"]))
        let first = SignPlaceBinder.place(for: reading, text: "204", sign: SIMD3(2.75, 0.2, 0.02), viewer: SIMD3(2.5, 0.2, 1.8), in: map)
        #expect(map.applySign(first).isNew)
        let better = try #require(SignInterpreter.interpret(["204", "Chemistry Lab"]))
        let second = SignPlaceBinder.place(for: better, text: "204 Chemistry Lab", sign: SIMD3(2.7, 0.2, 0.03), viewer: SIMD3(2, 0.2, 1.5), in: map)
        let result = map.applySign(second)
        #expect(!result.isNew)
        #expect(map.points.count == 1)
        #expect(map.points[0].id == first.id)
        #expect(map.points[0].title == "Room 204 · Chemistry Lab")
    }

    @Test func searchFindsSignPlacesByCategoryAndNumber() throws {
        let reading = try #require(SignInterpreter.interpret(["EXIT"]))
        let exit = SignPlaceBinder.place(for: reading, text: "EXIT", sign: SIMD3(2, 0.9, 0.05), viewer: nil, in: corridor())
        #expect(exit.matches(query: "exits"))
        let room = SignPlaceBinder.place(for: try #require(SignInterpreter.interpret(["204"])), text: "204",
                                         sign: SIMD3(2.75, 0.2, 0.02), viewer: nil, in: corridor())
        #expect(room.matches(query: "204"))
        #expect(room.matches(query: "rooms"))
        #expect(!room.matches(query: "exit"))
    }

    @Test func signTagsRoundTripAndOldPlacesStillDecode() throws {
        let reading = try #require(SignInterpreter.interpret(["204"]))
        let point = SignPlaceBinder.place(for: reading, text: "204", sign: SIMD3(2.75, 0.2, 0.02), viewer: SIMD3(2.5, 0.2, 1.8), in: corridor())
        let decoded = try JSONDecoder().decode(AccessPoint.self, from: JSONEncoder().encode(point))
        #expect(decoded == point)

        let legacy = #"{"id":"\#(UUID().uuidString)","kind":"destination","name":"Desk","position":[0,0,0],"source":"manual","confidence":1}"#
        #expect(try JSONDecoder().decode(AccessPoint.self, from: Data(legacy.utf8)).sign == nil)
        let broken = #"{"id":"\#(UUID().uuidString)","kind":"destination","name":"Desk","position":[0,0,0],"source":"manual","confidence":1,"sign":{"bad":true}}"#
        #expect(try JSONDecoder().decode(AccessPoint.self, from: Data(broken.utf8)).title == "Desk")
    }
}
