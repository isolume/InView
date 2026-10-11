import Foundation
import simd
import Testing
@testable import AccessCore

@Test func fastestChoosesTheShorterPassageInsteadOfTheFirstWidestGrid() throws {
    let destination = point(.elevator, 3, 0)
    let planner = RoutePlanner(map: room([
        // An 80 cm opening in the middle and a wider passage at the far end.
        // No doorway override: each opening keeps its actual obstacle clearance.
        wall(from: [0, -3], to: [0, -0.4]),
        wall(from: [0, 0.4], to: [0, 1.5]),
    ], points: [destination]))
    let stepFree = try #require(planner.route(from: [-3, 0], to: destination,
                                            conditions: RoutePreference.stepFree.conditions()))
    let fastest = try #require(planner.route(from: [-3, 0], to: destination,
                                           conditions: RoutePreference.fastest.conditions()))
    #expect(stepFree.preference == .stepFree)
    #expect(fastest.preference == .fastest)
    #expect(stepFree.clearance == 0.45)
    #expect(fastest.clearance == 0.3)
    #expect(try #require(crossing(of: stepFree)) > 1.5)
    #expect(abs(try #require(crossing(of: fastest))) < 0.3)
    #expect(fastest.length + 1 < stepFree.length)
    #expect(fastest.estimatedSeconds < stepFree.estimatedSeconds)
}

@Test func stepFreePreferenceNeverFallsBackToAWalkingWidth() throws {
    let destination = point(.elevator, 3, 0)
    let planner = RoutePlanner(map: room([
        wall(from: [0, -3], to: [0, -0.4]),
        wall(from: [0, 0.4], to: [0, 3]),
    ], points: [destination]))
    #expect(planner.route(from: [-3, 0], to: destination, conditions: RoutePreference.stepFree.conditions()) == nil)
    #expect(planner.nearestRoute(from: [-3, 0], conditions: RoutePreference.stepFree.conditions()) == nil)
    #expect(try #require(planner.route(from: [-3, 0], to: destination,
                                     conditions: RoutePreference.fastest.conditions())).clearance == 0.3)
    // Measurement audits retain their existing ability to describe the tight passage.
    #expect(try #require(planner.route(from: [-3, 0], to: destination)).isNarrow)
}

@Test func fastestNeverUsesTheTightAuditOnlyClearance() throws {
    let destination = point(.elevator, 3, 0)
    let planner = RoutePlanner(map: room([
        wall(from: [0, -3], to: [0, -0.3]),
        wall(from: [0, 0.3], to: [0, 3]),
    ], points: [destination]))
    #expect(try #require(planner.route(from: [-3, 0], to: destination)).clearance == 0.15)
    #expect(planner.route(from: [-3, 0], to: destination, conditions: RoutePreference.fastest.conditions()) == nil)
    #expect(planner.route(from: [-3, 0], to: destination,
                         conditions: RouteConditions(minimumClearance: 0.15, preference: .fastest)) == nil)
}

@Test func routePreferencesApplyDifferentSlopeLimitsWithoutAssumingUnknownRampsAreUsable() throws {
    var steep = point(.ramp, -1, 0)
    steep.slopeDegrees = 7
    let unknown = point(.ramp, 2, 0)
    var invalid = point(.ramp, 2, 1)
    invalid.slopeDegrees = .nan
    let planner = RoutePlanner(map: room(points: [steep, unknown, invalid]))
    #expect(planner.route(from: [-3, 0], to: steep, conditions: RoutePreference.stepFree.conditions()) == nil)
    #expect(planner.nearestRoute(from: [-3, 0], conditions: RoutePreference.stepFree.conditions()) == nil)
    let fastest = try #require(planner.nearestRoute(from: [-3, 0], conditions: RoutePreference.fastest.conditions()))
    #expect(fastest.destination.id == steep.id)
    for preference in RoutePreference.allCases {
        #expect(planner.route(from: [-3, 0], to: unknown, conditions: preference.conditions()) == nil)
        #expect(planner.route(from: [-3, 0], to: invalid, conditions: preference.conditions()) == nil)
    }
    // The low-level Fastest initializer also keeps its finite-slope requirement.
    #expect(planner.route(from: [-3, 0], to: unknown, conditions: RouteConditions(preference: .fastest)) == nil)
}

@Test func fastestRerouteKeepsPreferenceDestinationAndRequestedClearance() throws {
    let destination = point(.elevator, 3, 0)
    let alternative = point(.elevator, -2, 1)
    let planner = RoutePlanner(map: room([
        wall(from: [0, -3], to: [0, -1]),
        wall(from: [0, 1], to: [0, 3]),
    ], points: [destination, alternative]))
    let original = try #require(planner.route(from: [-3, 0], to: destination,
                                            conditions: RoutePreference.fastest.conditions()))
    #expect(original.clearance == 0.45)
    let updated = try #require(planner.reroute(original, from: [-3, 0],
                                             conditions: RouteConditions(obstacles: [[0, 0]])))
    #expect(updated.preference == .fastest)
    #expect(updated.destination.id == destination.id)
    #expect(updated.clearance == 0.3)
    #expect(planner.reroute(original, from: [-3, 0],
                           conditions: RouteConditions(unavailable: [destination.id])) == nil)

    var wider = RoutePreference.fastest.conditions()
    wider.minimumClearance = 0.45
    let wideOriginal = try #require(planner.route(from: [-3, 0], to: destination, conditions: wider))
    #expect(planner.reroute(wideOriginal, from: [-3, 0],
                           conditions: RouteConditions(obstacles: [[0, 0]])) == nil)
}

@Test func fastestRerouteRetainsItsRampEligibilityWhenNoNewPreferenceIsSupplied() throws {
    var ramp = point(.ramp, 3, 0)
    ramp.slopeDegrees = 7
    let planner = RoutePlanner(map: room(points: [ramp]))
    let original = try #require(planner.route(from: [-3, 0], to: ramp, conditions: RoutePreference.fastest.conditions()))
    let updated = try #require(planner.reroute(original, from: [-2, 0]))
    #expect(updated.preference == .fastest)
    #expect(updated.destination.id == ramp.id)
    #expect(updated.length < original.length)
}

@Test func localFastestRoutingDoesNotTurnAStairsFootprintIntoAFloorConnection() {
    let destination = point(.elevator, 3, 0)
    let stairs = Footprint(kind: .stairs, center: [0, 0], size: [1, 6], yaw: 0)
    let planner = RoutePlanner(map: room([stairs], points: [destination]))
    for preference in RoutePreference.allCases {
        #expect(planner.route(from: [-3, 0], to: destination, conditions: preference.conditions()) == nil)
    }
}

@Test func preferencesUseTheSameTravelSpeedAndHaveStableSavedValues() throws {
    #expect(RoutePreference.stepFree.walkingSpeedMetersPerSecond == 1)
    #expect(RoutePreference.fastest.walkingSpeedMetersPerSecond == 1)
    #expect(try JSONDecoder().decode(RoutePreference.self, from: Data(#""step_free""#.utf8)) == .stepFree)
    #expect(try JSONDecoder().decode(RoutePreference.self, from: Data(#""fastest""#.utf8)) == .fastest)
    let destination = point(.elevator, 3, 0)
    let planner = RoutePlanner(map: room(points: [destination]))
    for preference in RoutePreference.allCases {
        let route = try #require(planner.route(from: [-3, 0], to: destination, conditions: preference.conditions()))
        #expect(abs(route.estimatedSeconds - Double(route.length)) < 1e-6)
    }
}
