import Foundation
import Testing
@testable import AccessCore

@Test func legacyAccessPointsDecodeWithoutAName() throws {
    let json = Data("""
    {"id":"F424C907-4530-44DD-96D7-60E9EF3E01A3","kind":"ramp","position":[1,0,2],"source":"manual","confidence":1}
    """.utf8)
    let point = try JSONDecoder().decode(AccessPoint.self, from: json)
    #expect(point.kind == .ramp)
    #expect(point.name == nil)
    #expect(point.title == "Ramp")
    #expect(point.position == [1, 0, 2])
}

@Test func namedDestinationsKeepTheirNameWhenSaved() throws {
    let point = AccessPoint(kind: .destination, name: "Kitchen", position: [4, 0, -3], source: .manual, confidence: 1)
    let decoded = try JSONDecoder().decode(AccessPoint.self, from: JSONEncoder().encode(point))
    #expect(decoded == point)
    #expect(decoded.title == "Kitchen")
    var unnamed = decoded
    unnamed.name = "  "
    #expect(unnamed.title == "Destination")
}
