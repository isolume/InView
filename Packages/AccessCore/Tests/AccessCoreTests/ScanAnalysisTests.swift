import Foundation
import Testing
@testable import AccessCore

/// A worker analysis shaped like PIPELINE.md's contract, with the oddities a newer or older worker
/// may produce: unknown categories and kinds, extra keys, malformed entries, and wrong-shaped products.
let realisticAnalysisJSON = Data("""
{
  "schema_version": 1, "scan_id": "scan-1", "frame": "shared_arkit_session",
  "generated_at": "2026-10-10T20:38:37+00:00",
  "worker": {"name": "inview-worker", "version": "0.2.0"},
  "future_product": {"anything": [1, 2, 3]},
  "floor_map": {"grid": {"cell_m": 0.05}, "png_base64": "AAAA"},
  "places": [
    {"id": "place-elevator-1", "category": "elevator", "name": "Elevator A",
     "names": {"en": "Elevator A", "es": "Ascensor A", "zh-Hans": "电梯 A"},
     "position_m": [4.0, 0.0, -2.0], "floor_id": "ground", "confidence": 0.92,
     "sources": ["sign:s1", "roomplan:object:o3"], "access_point_kind": "elevator", "extra": true},
    {"id": "place-ramp", "category": "ramp", "position_m": [1, 0, 1], "confidence": 0.6},
    {"id": "place-restroom", "category": "accessible_restroom", "name": "Restroom",
     "position_m": [8.5, 1.2, 3.0], "access_point_kind": "destination", "confidence": 1.7},
    {"id": "place-vending", "category": "vending_machine", "name": "Snacks",
     "position_m": [2, 0, 7], "access_point_kind": "teleporter"},
    {"id": "place-no-position", "category": "room", "name": "Room 204"},
    {"id": "place-bad-position", "category": "room", "position_m": [1, 2]},
    {"category": "exit", "name": "Missing id"},
    "not-an-object",
    {"id": "place-null-fields", "category": null, "name": null, "names": null, "position_m": [0, 0, 0],
     "confidence": "high", "sources": null}
  ],
  "doors": [
    {"center_xz_m": [1.2, 2.0], "height_m": 2.0, "id": "door", "issues": ["headroom_below_2.03_m"],
     "kind": "door", "measured_clear_width_m": 0.85, "meets_clear_width": true, "meets_headroom": false,
     "method": "obstacle_raster_span", "nominal_width_m": 0.76, "required_min_clear_width_m": 0.815,
     "span_xz_m": [[0.82, 2.0], [1.58, 2.0]]},
    {"id": "entry", "kind": "opening", "issues": [], "meets_clear_width": true, "meets_headroom": true}
  ],
  "hazards": [
    {"id": "h1", "kind": "step", "severity": "barrier", "position_m": [3, 0.1, 3], "measure": {"rise_m": 0.15}},
    {"id": "h2", "kind": "wet_floor", "severity": "critical"}
  ],
  "routes": {"profiles": ["wheelchair"], "routes": [
    {"from_place": "place-ramp", "to_place": "place-restroom", "profile": "wheelchair",
     "node_ids": ["n1", "n2"], "length_m": 12.5, "estimated_seconds": 14,
     "instructions": {"en": [{"text": "Go straight", "distance_m": 12.5, "maneuver": "straight"}],
                      "es": [{"text": "Siga recto"}]}},
    {"profile": 7}
  ]},
  "summary": {"doors": {"checked": 2, "below_min_width": 0, "below_headroom": 1}, "floor_map": {}},
  "notices": ["Screening only.", 42]
}
""".utf8)

private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("Fixtures/\(name)"))
}

struct ScanAnalysisTests {
    @Test func decodesRealisticAnalysisTolerantly() throws {
        let analysis = try JSONDecoder().decode(ScanAnalysis.self, from: realisticAnalysisJSON)
        #expect(analysis.scanID == "scan-1")
        #expect(analysis.schemaVersion == 1)
        #expect(analysis.places.map(\.id) == ["place-elevator-1", "place-ramp", "place-restroom", "place-vending",
                                              "place-no-position", "place-bad-position", "place-null-fields"])
        let elevator = analysis.places[0]
        #expect(elevator.category == .elevator)
        #expect(elevator.position == SIMD3(4, 0, -2))
        #expect(elevator.names["es"] == "Ascensor A")
        #expect(elevator.sources.count == 2)
        #expect(elevator.accessPointKind == .elevator)
        #expect(elevator.floorID == "ground")
        let vending = analysis.places[3]
        #expect(vending.category == .unknown)
        #expect(vending.accessPointKind == nil)
        #expect(analysis.places[4].position == nil)
        #expect(analysis.places[5].position == nil)
        let nulls = analysis.places[6]
        #expect(nulls.category == .unknown && nulls.name == nil && nulls.names.isEmpty && nulls.confidence == nil)

        #expect(analysis.doors.count == 2)
        #expect(analysis.doors[0].center == SIMD2(1.2, 2.0))
        #expect(analysis.doorsWithIssues.map(\.id) == ["door"])
        #expect(analysis.doorSummary?.checked == 2)
        #expect(analysis.doorSummary?.belowHeadroom == 1)

        #expect(analysis.hazards.map(\.kind) == [.step, .unknown])
        #expect(analysis.hazards.map(\.severity) == [.barrier, .unknown])
        #expect(analysis.hazards[0].position == SIMD3(3, 0.1, 3))

        #expect(analysis.routes.count == 2)
        #expect(analysis.routes[0].lengthM == 12.5)
        #expect(analysis.routes[0].nodeIDs == ["n1", "n2"])
        #expect(analysis.routes[0].instructionLanguages == ["en", "es"])
        #expect(analysis.routes[1].profile == nil)
        #expect(analysis.notices == ["Screening only."])
    }

    @Test func missingProductsAndWrongShapesDecodeAsEmpty() throws {
        let minimal = try JSONDecoder().decode(ScanAnalysis.self, from: Data(#"{"scan_id":"s"}"#.utf8))
        #expect(minimal.places.isEmpty && minimal.doors.isEmpty && minimal.hazards.isEmpty && minimal.routes.isEmpty)
        #expect(minimal.doorSummary == nil && minimal.schemaVersion == nil)
        let odd = try JSONDecoder().decode(ScanAnalysis.self, from: Data(
            #"{"scan_id":"s","places":{"a":1},"doors":"none","hazards":null,"routes":[{"length_m":3}],"summary":[]}"#.utf8))
        #expect(odd.places.isEmpty && odd.doors.isEmpty && odd.hazards.isEmpty)
        #expect(odd.routes.first?.lengthM == 3)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ScanAnalysis.self, from: Data("{}".utf8)) }
    }

    @Test func decodesRealWorkerOutputFromEndToEndRun() throws {
        for (name, scanID, doorCount) in [("synthetic-walk.analysis.json", "synthetic-walk", 1),
                                          ("demo-room.analysis.json", "demo-room", 2)] {
            let analysis = try JSONDecoder().decode(ScanAnalysis.self, from: fixture(name))
            #expect(analysis.scanID == scanID)
            #expect(analysis.doors.count == doorCount)
            #expect(analysis.doorSummary?.checked == doorCount)
            #expect(!analysis.notices.isEmpty)
        }
        let synthetic = try JSONDecoder().decode(ScanAnalysis.self, from: fixture("synthetic-walk.analysis.json"))
        #expect(synthetic.doors[0].meetsHeadroom == false)
        #expect(synthetic.doorsWithIssues.count == 1)
    }

    @Test func localizedNamePrefersReaderLanguages() throws {
        let place = try JSONDecoder().decode(ScanAnalysis.self, from: realisticAnalysisJSON).places[0]
        #expect(place.localizedName(preferredLanguages: ["es-MX", "en"]) == "Ascensor A")
        #expect(place.localizedName(preferredLanguages: ["zh-Hans-CN"]) == "电梯 A")
        #expect(place.localizedName(preferredLanguages: ["fr"]) == "Elevator A")
        let unnamed = ScanAnalysis.Place(id: "x", category: .waterFountain, position: nil)
        #expect(unnamed.localizedName(preferredLanguages: ["en"]) == "Water Fountain")
    }

    @Test func placesMapOntoAccessPointsWithStableIDs() throws {
        let analysis = try JSONDecoder().decode(ScanAnalysis.self, from: realisticAnalysisJSON)
        let points = analysis.places.compactMap { $0.accessPoint(scanID: "scan-1", preferredLanguages: ["en"]) }
        #expect(points.count == 5) // places without a usable position are skipped
        #expect(points.map(\.kind) == [.elevator, .ramp, .destination, .destination, .destination])
        #expect(points.allSatisfy { $0.source == .detected })
        #expect(points[0].name == "Elevator A" && points[0].confidence == Float(0.92))
        #expect(points[1].name == "Ramp" && points[1].confidence == 0.6)
        #expect(points[2].confidence == 1) // clamped
        #expect(points[2].position == SIMD3(8.5, 1.2, 3))

        let again = analysis.places[0].accessPoint(scanID: "scan-1")
        #expect(again?.id == points[0].id)
        #expect(analysis.places[0].accessPoint(scanID: "scan-2")?.id != points[0].id)
        #expect(Set(points.map(\.id)).count == points.count)
        let onFloor = analysis.places[2].accessPoint(scanID: "scan-1", floorY: -1.3)
        #expect(onFloor?.position == SIMD3(8.5, -1.3, 3))
        // Version 5, RFC 4122 variant.
        let uuid = points[0].id.uuidString
        #expect(Array(uuid)[14] == "5")
        #expect("89AB".contains(Array(uuid)[19]))
        #expect(AccessPoint.detectedID(scanID: "a", placeID: "b") == AccessPoint.detectedID(scanID: "a", placeID: "b"))
    }

    @Test func mergeSkipsKnownIDsNearbySameKindAndNeverTouchesManualPoints() {
        let manual = AccessPoint(kind: .elevator, name: "My elevator", position: SIMD3(0, 0, 0), source: .manual, confidence: 1)
        let detectedElevator = AccessPoint(id: AccessPoint.detectedID(scanID: "s", placeID: "e"), kind: .elevator,
                                           name: "Elevator", position: SIMD3(0.6, 0, 0.3), source: .detected, confidence: 0.9)
        let nearbyRamp = AccessPoint(id: AccessPoint.detectedID(scanID: "s", placeID: "r"), kind: .ramp,
                                     position: SIMD3(0.5, 0, 0), source: .detected, confidence: 0.8)
        let farElevator = AccessPoint(id: AccessPoint.detectedID(scanID: "s", placeID: "e2"), kind: .elevator,
                                      position: SIMD3(5, 0, 0), source: .detected, confidence: 0.8)
        let duplicateOfFar = AccessPoint(id: AccessPoint.detectedID(scanID: "s", placeID: "e3"), kind: .elevator,
                                         position: SIMD3(5.4, 2, 0), source: .detected, confidence: 0.7)
        let existing = [manual]
        let added = AccessPoint.newDetections([detectedElevator, nearbyRamp, farElevator, duplicateOfFar], existing: existing)
        #expect(added.map(\.id) == [nearbyRamp.id, farElevator.id])

        let merged = existing + added
        // Merging the same analysis again adds nothing, even if positions moved slightly.
        var moved = farElevator
        moved.position.x += 3
        #expect(AccessPoint.newDetections([nearbyRamp, moved], existing: merged).isEmpty)
        #expect(merged[0] == manual)
    }
}
