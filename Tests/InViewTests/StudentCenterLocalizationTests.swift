import AccessCore
import ARKit
import CryptoKit
import Foundation
import simd
import XCTest
@testable import InView

@MainActor
final class StudentCenterLocalizationTests: XCTestCase {
    private struct Registration: Decodable {
        let archiveSHA256: String
        let archiveBytes: Int
        let mapSHA256: String
    }

    private func resource(_ name: String, extension ext: String) throws -> URL {
        try XCTUnwrap(StudentCenterLocalization.resourceURL(name, extension: ext))
    }

    private func bundledMap() throws -> VenueMap {
        try XCTUnwrap(StudentCenterCatalog.map())
    }

    private func assertVector(_ actual: SIMD4<Float>, equals expected: SIMD4<Float>,
                              accuracy: Float = 0.0001, file: StaticString = #filePath,
                              line: UInt = #line) {
        for component in 0..<4 {
            XCTAssertEqual(actual[component], expected[component], accuracy: accuracy,
                           "Component \(component)", file: file, line: line)
        }
    }

    func testBundledArchiveAndMapMatchRegistrationMetadata() throws {
        let metadataURL = try resource("student-center-east-floor-2-localization", extension: "json")
        let metadata = try JSONDecoder().decode(Registration.self, from: Data(contentsOf: metadataURL))
        let archiveURL = try resource("student-center-east-floor-2", extension: "arworldmap")
        let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let mapURL = try resource("student-center-east-floor-2-navigation", extension: "json")
        let map = try Data(contentsOf: mapURL)

        XCTAssertGreaterThan(metadata.archiveBytes, 0)
        XCTAssertEqual(archive.count, metadata.archiveBytes)
        XCTAssertEqual(SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
                       metadata.archiveSHA256)
        XCTAssertEqual(SHA256.hash(data: map).map { String(format: "%02x", $0) }.joined(),
                       metadata.mapSHA256)
        // Byte integrity is testable on Simulator; ARWorldMap decoding needs supported ARKit hardware.
    }

    func testRegistrationPlacesNativeFloorAtCanonicalFloorHeight() throws {
        let map = try bundledMap()
        let transform = try XCTUnwrap(StudentCenterLocalization.mapFromWorld(for: map))
        let sourceFloor: Float = -1.5322381

        for position in [SIMD2<Float>(0, 0), SIMD2(-5.297282, 2.5336292), SIMD2(-17, 27)] {
            let registered = transform * SIMD4(position.x, sourceFloor, position.y, 1)
            XCTAssertEqual(registered.y, map.floorY, accuracy: 0.0001)
            XCTAssertEqual(registered.w, 1)
        }
        XCTAssertEqual(simd_determinant(transform), 1, accuracy: 0.0001,
                       "Localization must preserve the metric scale of depth and routes")
    }

    func testRegistrationDirectionAndInverseOriginMatchObservedWall() throws {
        let map = try bundledMap()
        let mapFromWorld = try XCTUnwrap(StudentCenterLocalization.mapFromWorld(for: map))
        // RoomPlan wall 51D412D7, used by the recorded rigid fit into the canonical lounge.
        let sourceWallFloor = SIMD4<Float>(-5.297282, -1.5322381, 2.5336292, 1)
        let registeredWallFloor = SIMD4<Float>(20.857033, -1.5936141, -7.1286273, 1)
        assertVector(mapFromWorld * sourceWallFloor, equals: registeredWallFloor)
        let registeredWallPoint = SIMD2(registeredWallFloor.x, registeredWallFloor.z)
        // Reconciled geometry splits this measured wall around its doorway, so
        // verify the observed point against its retained segment, not an old centroid.
        let canonicalWall = try XCTUnwrap(map.footprints.first {
            let local = $0.local(registeredWallPoint)
            return $0.kind == .wall && abs(local.x) <= $0.size.x / 2 && abs(local.y) < 0.001
        })
        XCTAssertEqual(canonicalWall.local(registeredWallPoint).y, 0, accuracy: 0.001)

        let sourceWallDirection = SIMD4<Float>(-0.9255238, 0, 0.3786894, 0)
        assertVector(mapFromWorld * sourceWallDirection,
                     equals: SIMD4(0.98593564, 0, -0.16712535, 0))

        // setWorldOrigin takes the desired map origin expressed in the saved world's coordinates.
        let worldFromMap = mapFromWorld.inverse
        assertVector(worldFromMap * SIMD4(0, 0, 0, 1),
                     equals: SIMD4(13.495995, 0.061376, -8.983572, 1))
        assertVector(worldFromMap * registeredWallFloor, equals: sourceWallFloor)
    }

    func testCompatibilityAcceptsReorderedFootprintsAndUpdatedPlaceAnnotations() throws {
        var map = try bundledMap()
        let original = try XCTUnwrap(StudentCenterLocalization.mapFromWorld(for: map))
        map.footprints.reverse()
        map.createdAt = Date(timeIntervalSince1970: 1)
        map.points = [AccessPoint(kind: .destination, name: "Updated meeting point",
                                  position: SIMD3(20, map.floorY, -7), source: .manual,
                                  confidence: 1)]
        let updated = try XCTUnwrap(StudentCenterLocalization.mapFromWorld(for: map))

        for column in 0..<4 {
            assertVector(updated[column], equals: original[column])
        }
    }

    func testCompatibilityRejectsChangedGeometryAndFloorCoverage() throws {
        let bundled = try bundledMap()
        var movedWall = bundled
        let wallIndex = try XCTUnwrap(movedWall.footprints.firstIndex { $0.kind == .wall })
        movedWall.footprints[wallIndex].center.x += 0.25
        XCTAssertNil(StudentCenterLocalization.mapFromWorld(for: movedWall))

        var missingFootprint = bundled
        missingFootprint.footprints.remove(at: wallIndex)
        XCTAssertNil(StudentCenterLocalization.mapFromWorld(for: missingFootprint))

        var changedCoverage = bundled
        changedCoverage.requiresMeasuredFloorCoverage = bundled.requiresMeasuredFloorCoverage == true ? false : true
        XCTAssertNil(StudentCenterLocalization.mapFromWorld(for: changedCoverage))
    }

    func testCompatibilityRejectsOptimizedMapAndAnotherFloor() throws {
        var map = try bundledMap()
        map.requiresOptimizedLocalization = true
        XCTAssertNil(StudentCenterLocalization.mapFromWorld(for: map))

        map = try bundledMap()
        map.floorY += 4
        XCTAssertNil(StudentCenterLocalization.mapFromWorld(for: map))
    }

    func testAlignmentWaitsForCurrentRunAndNormalTracking() {
        var alignment = NavigationSessionAlignment()
        XCTAssertEqual(alignment.next(timestamp: 99, trackingIsNormal: true), .wait)
        alignment.reset(startedAt: 100, needsOriginChange: true)

        XCTAssertEqual(alignment.next(timestamp: 99, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 100, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 101, trackingIsNormal: false), .wait)
        XCTAssertFalse(alignment.isReady)
        XCTAssertEqual(alignment.next(timestamp: 102, trackingIsNormal: true), .changeOrigin)
        XCTAssertFalse(alignment.isReady)
    }

    func testAlignmentChangesOriginOnceAndWaitsForANewerNormalFrame() {
        var alignment = NavigationSessionAlignment()
        alignment.reset(startedAt: 100, needsOriginChange: true)
        XCTAssertEqual(alignment.next(timestamp: 101, trackingIsNormal: true), .changeOrigin)

        XCTAssertEqual(alignment.next(timestamp: 100.5, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 101, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 102, trackingIsNormal: false), .wait)
        XCTAssertFalse(alignment.isReady)
        XCTAssertEqual(alignment.next(timestamp: 103, trackingIsNormal: true), .ready)
        XCTAssertTrue(alignment.isReady)
        XCTAssertEqual(alignment.next(timestamp: 104, trackingIsNormal: true), .ready)
    }

    func testAlignmentRejectsFramesCapturedBeforeOriginChangeCompleted() {
        var alignment = NavigationSessionAlignment()
        alignment.reset(startedAt: 10, needsOriginChange: true)
        XCTAssertEqual(alignment.next(timestamp: 11, trackingIsNormal: true), .changeOrigin)

        alignment.didChangeOrigin(at: 12)
        XCTAssertEqual(alignment.next(timestamp: 11.5, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 12, trackingIsNormal: true), .wait)
        XCTAssertFalse(alignment.isReady)
        XCTAssertEqual(alignment.next(timestamp: 12.1, trackingIsNormal: true), .ready)
        XCTAssertTrue(alignment.isReady)
    }

    func testRetryClearsReadyStateAndRequiresANewOriginChange() {
        var alignment = NavigationSessionAlignment()
        alignment.reset(startedAt: 100, needsOriginChange: true)
        XCTAssertEqual(alignment.next(timestamp: 101, trackingIsNormal: true), .changeOrigin)
        XCTAssertEqual(alignment.next(timestamp: 102, trackingIsNormal: true), .ready)

        alignment.reset(startedAt: 200, needsOriginChange: true)
        XCTAssertFalse(alignment.isReady)
        XCTAssertEqual(alignment.next(timestamp: 102, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 200, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 201, trackingIsNormal: true), .changeOrigin)
        XCTAssertEqual(alignment.next(timestamp: 201, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 202, trackingIsNormal: true), .ready)
        XCTAssertTrue(alignment.isReady)
    }

    func testSessionWithoutRegistrationBecomesReadyOnFirstNewNormalFrame() {
        var alignment = NavigationSessionAlignment()
        alignment.reset(startedAt: 100, needsOriginChange: false)
        XCTAssertEqual(alignment.next(timestamp: 100, trackingIsNormal: true), .wait)
        XCTAssertEqual(alignment.next(timestamp: 101, trackingIsNormal: false), .wait)
        XCTAssertEqual(alignment.next(timestamp: 102, trackingIsNormal: true), .ready)
        XCTAssertTrue(alignment.isReady)

        alignment.reset(startedAt: 200, needsOriginChange: false)
        XCTAssertFalse(alignment.isReady)
        XCTAssertEqual(alignment.next(timestamp: 201, trackingIsNormal: true), .ready)
    }

    private func waitForLoad(_ controller: NavigationController,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while controller.phase == .loading, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(controller.phase, .loading, "Map loading timed out", file: file, line: line)
    }

    private func assertBundledLoad(_ controller: NavigationController,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(controller.map, file: file, line: line)
        XCTAssertTrue(controller.usesBundledMap, file: file, line: line)
        XCTAssertEqual(controller.phase, .browsing, file: file, line: line)
        if ARWorldTrackingConfiguration.isSupported {
            XCTAssertTrue(controller.canGuide, controller.unavailableReason ?? "Missing saved location data",
                          file: file, line: line)
            XCTAssertNil(controller.unavailableReason, file: file, line: line)
        } else {
            XCTAssertFalse(controller.canGuide, file: file, line: line)
            XCTAssertEqual(controller.unavailableReason,
                           StudentCenterLocalization.Failure.unsupportedDevice.localizedDescription,
                           file: file, line: line)
        }
    }

    func testControllerReloadsBundledLocalizationAfterFloorAndSharedMapChanges() async throws {
        let bundled = try bundledMap()
        let controller = NavigationController(map: bundled, usesBundledMap: true)
        defer { controller.stop() }
        let selected = try XCTUnwrap(bundled.points.last)
        controller.selectDestination(selected)
        controller.start()
        try await waitForLoad(controller)
        assertBundledLoad(controller)
        XCTAssertEqual(controller.selectedDestination?.id, selected.id,
                       "A place selected while the archive loads must remain the destination")

        controller.showSharedMap(nil)
        XCTAssertEqual(controller.phase, .noMap)
        XCTAssertNil(controller.map)
        XCTAssertFalse(controller.canGuide)

        controller.reload(map: bundled, usesBundledMap: true)
        XCTAssertEqual(controller.phase, .loading)
        try await waitForLoad(controller)
        assertBundledLoad(controller)

        var annotated = bundled
        let newPlace = AccessPoint(kind: .destination, name: "Shared meeting point",
                                   position: SIMD3(20, bundled.floorY, -7), source: .manual, confidence: 1)
        annotated.points = [newPlace]
        controller.showSharedMap(annotated)
        XCTAssertEqual(controller.phase, .loading,
                       "A compatible shared floor must reload its matching localization assets")
        try await waitForLoad(controller)
        assertBundledLoad(controller)
        XCTAssertEqual(controller.map?.points, [newPlace], "Loading must preserve the shared place annotations")

        var incompatible = annotated
        let wallIndex = try XCTUnwrap(incompatible.footprints.firstIndex { $0.kind == .wall })
        incompatible.footprints[wallIndex].center.x += 0.25
        controller.showSharedMap(incompatible)
        controller.start()
        XCTAssertEqual(controller.phase, .browsing)
        XCTAssertEqual(controller.map?.footprints, incompatible.footprints)
        XCTAssertFalse(controller.canGuide, "A different floor geometry must not reuse the last saved world map")
        XCTAssertNotNil(controller.unavailableReason)
    }
}
