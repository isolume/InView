import Foundation
import Testing
import simd
@testable import AccessCore

/// A real worker analysis (synthetic building, seed 0) trimmed to its five numbered highlights.
private func fixture() throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/highlights-building.analysis.json")
    return try Data(contentsOf: url)
}

struct ScanHighlightsTests {
    @Test func decodesTheWorkersHighlightsProduct() throws {
        let analysis = try JSONDecoder().decode(ScanAnalysis.self, from: fixture())
        let highlights = try #require(analysis.highlights)
        #expect(highlights.floorID == "level-2")
        #expect(highlights.items.map(\.rank) == [1, 2, 3, 4, 5])
        let stairs = try #require(highlights.items.first)
        #expect(stairs.kind == "barrier" && stairs.severity == "barrier" && stairs.title == "Stairs")
        #expect(stairs.number == 1 && stairs.importance > 0.9)
        #expect(highlights.items(severity: "barrier").count == 5)
        let image = try #require(highlights.image)
        #expect((image.width, image.height, image.mapWidth, image.mapHeight) == (1860, 749, 1400, 700))
        #expect(image.pngData?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
    }

    @Test func pixelsAndFloorPositionsAreInverseOfEachOther() throws {
        let image = try #require(JSONDecoder().decode(ScanAnalysis.self, from: fixture()).highlights?.image)
        for point in [SIMD2<Float>(0, 0), SIMD2(3.2, -1.7), SIMD2(10, 4)] {
            let pixel = image.pixel(forX: point.x, z: point.y)
            if let back = image.position(forPixel: pixel) {
                #expect(simd_distance(back, point) < 0.001)
            }
        }
        // The legend panel is not part of the plan.
        #expect(image.position(forPixel: SIMD2(Float(image.mapWidth) + 5, 10)) == nil)
    }

    @Test func eachItemsAnchorPixelMatchesItsFloorPosition() throws {
        let highlights = try #require(JSONDecoder().decode(ScanAnalysis.self, from: fixture()).highlights)
        let image = try #require(highlights.image)
        for item in highlights.items {
            let anchor = try #require(item.anchorPixel)
            let expected = image.pixel(forX: item.position.x, z: item.position.y)
            #expect(simd_distance(anchor, expected) < 2.5, "\(item.title)")
        }
    }

    @Test func tappingABadgeFindsItsItem() throws {
        let highlights = try #require(JSONDecoder().decode(ScanAnalysis.self, from: fixture()).highlights)
        for item in highlights.items {
            let badge = try #require(item.calloutPixel)
            #expect(highlights.item(atPixel: badge)?.id == item.id)
        }
        #expect(highlights.item(atPixel: SIMD2(-500, -500)) == nil)
    }

    @Test func malformedEntriesAndImagesAreDroppedNotFatal() throws {
        let json = Data(#"""
        {"scan_id":"s","highlights":{"floor_id":"g","items":[
          {"id":"a","kind":"door","title":"Door","severity":"barrier","rank":2,"importance":7,"position_xz_m":[1,2]},
          {"id":"b","kind":"door","position_xz_m":[1,2]},
          {"id":"c","kind":"route","title":"No position","rank":1},
          {"id":"d","kind":"barrier","title":"Stairs","rank":1,"position_xz_m":[3,4],"anchor_px":[1]}
        ],"image":{"width":0,"height":5,"resolution_m_per_px":0.1,"origin_xz_m":[0,0]}}}
        """#.utf8)
        let highlights = try #require(JSONDecoder().decode(ScanAnalysis.self, from: json).highlights)
        #expect(highlights.items.map(\.id) == ["a"])
        #expect(highlights.items[0].importance == 1, "clamped")
        #expect(highlights.image == nil, "an unusable image is dropped, the ranked list survives")
    }

    @Test func analysesWithoutHighlightsStillDecode() throws {
        let analysis = try JSONDecoder().decode(ScanAnalysis.self, from: Data(#"{"scan_id":"s"}"#.utf8))
        #expect(analysis.highlights == nil)
        let odd = try JSONDecoder().decode(ScanAnalysis.self, from: Data(#"{"scan_id":"s","highlights":[1,2]}"#.utf8))
        #expect(odd.highlights == nil)
    }
}
