import simd
import Testing
@testable import AccessCore

@Test func smoothingKeepsTheMeetingRoomChairClearance() throws {
    // Measured geometry and the segment that previously slipped through the demo's
    // inflated chair corner between the half-cell visibility samples.
    let map = VenueMap(floorY: 0, footprints: [
        Footprint(kind: .wall, center: [-3, -11], size: [5, 0.15], yaw: .pi / 2),
        Footprint(kind: .wall, center: [0, -13.5], size: [6, 0.15], yaw: 0),
        Footprint(kind: .obstacle, center: [0.34, -10.82], size: [0.52, 0.54], yaw: 0),
    ], points: [])
    let grid = OccupancyGrid(map: map, clearance: 0.45)
    let a = SIMD2<Float>(1.3750005, -9.125)
    let b = SIMD2<Float>(-1.0249999, -10.625)
    #expect(!grid.isBlocked(try #require(grid.index(containing: a))))
    #expect(!grid.isBlocked(try #require(grid.index(containing: b))))
    #expect(grid.isBlocked(try #require(grid.index(containing: [-0.14880931, -10.077381]))))
    #expect(!grid.lineOfSight(a, b))
    #expect(!grid.lineOfSight(b, a))

    let start = try #require(grid.index(containing: a))
    let goal = try #require(grid.index(containing: b))
    let search = grid.search(from: start, to: goal)
    #expect(search.cost[goal].isFinite)
    let smoothed = grid.smooth(grid.path(to: goal, parents: search.parent).map(grid.center(of:)))
    #expect(smoothed.count >= 3)
    for (from, to) in zip(smoothed, smoothed.dropFirst()) {
        let steps = max(1, Int(ceil(simd_distance(from, to) / (grid.cellSize / 20))))
        for step in 0...steps {
            let position = from + (to - from) * (Float(step) / Float(steps))
            #expect(!grid.isBlocked(try #require(grid.index(containing: position))))
        }
    }
}

@Test func visibilityRejectsTouchingABlockedCornerAndInvalidEndpoints() {
    let obstacle = Footprint(kind: .obstacle, center: [0.5, 0.5], size: [0.01, 0.01], yaw: 0)
    let bounds = AccessPoint(kind: .elevator, position: [3, 0, 3], source: .manual, confidence: 1)
    let grid = OccupancyGrid(map: VenueMap(floorY: 0, footprints: [obstacle], points: [bounds]),
                             clearance: 0, cellSize: 1, padding: 0)
    // Both endpoints are free, but their diagonal touches blocked cell (0, 0).
    #expect(!grid.lineOfSight([0.5, 1.5], [1.5, 0.5]))
    #expect(!grid.lineOfSight([1.5, 0.5], [0.5, 1.5]))
    #expect(!grid.lineOfSight([0.5, 1], [2.5, 1]))
    #expect(!grid.lineOfSight([1, 0.5], [1, 2.5]))
    #expect(grid.lineOfSight([0.5, 1.5], [2.5, 1.5]))
    #expect(grid.lineOfSight([2.5, 1.5], [2.5, 1.5]))
    #expect(!grid.lineOfSight([-0.001, 1.5], [2.5, 1.5]))
    #expect(!grid.lineOfSight([3, 1.5], [2.5, 1.5]))
    #expect(!grid.lineOfSight([.infinity, 1.5], [2.5, 1.5]))
    #expect(!grid.lineOfSight([.nan, 1.5], [2.5, 1.5]))
    #expect(!grid.lineOfSight([.greatestFiniteMagnitude, 1.5], [2.5, 1.5]))
}

@Test func costOnlyAuditSearchPreservesBlockedAndReachableCellsWithoutParentStorage() throws {
    let map = room([divider, dividerDoor(at: 1.5, width: 0.7)], points: [point(.elevator, 2, -1)])
    let grid = OccupancyGrid(map: map, clearance: 0.45)
    let start = try #require(grid.nearestFreeIndex(to: [-2, -1], within: 1.5))
    let full = grid.search(from: start)
    let audit = try grid.search(from: start, storingParents: false, isCancelled: { false })
    #expect(audit.cost == full.cost)
    #expect(audit.parent.isEmpty)
    #expect(full.parent.count == grid.width * grid.height)
    #expect(audit.cost[start] == 0)
    let inaccessible = try #require(grid.index(containing: [2, -1]))
    #expect(!audit.cost[inaccessible].isFinite)
}

@Test func auditSearchThrowsWhenCancelledDuringTraversalInsteadOfReturningPartialReachability() throws {
    let grid = OccupancyGrid(map: room(points: [point(.elevator, 2, -1)]), clearance: 0.45)
    let start = try #require(grid.nearestFreeIndex(to: .zero, within: 1.5))
    var checks = 0
    #expect(throws: CancellationError.self) {
        try grid.search(from: start, storingParents: false) {
            checks += 1
            return checks >= 3
        }
    }
    #expect(checks == 3)
}
