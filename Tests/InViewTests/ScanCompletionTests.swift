import AccessCore
import Foundation
import RoomPlan
import XCTest
import UIKit
@testable import InView

@MainActor
final class ScanCompletionTests: XCTestCase {
    func testOCRReadsRoomAndExportsMeasuredXYZWithoutServer() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            ("ROOM 204" as NSString).draw(at: CGPoint(x: 70, y: 340), withAttributes: [
                .font: UIFont.systemFont(ofSize: 70, weight: .bold), .foregroundColor: UIColor.black
            ])
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.95))
        let frame = CaptureDepthFrame(id: "sign-frame", timestampSeconds: 100,
            mapFromCamera: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1.5, 0, 1],
            camera: CaptureCameraCalibration(imageWidth: 800, imageHeight: 600, fx: 400, fy: 400, cx: 400, cy: 300),
            depth: CaptureDepthImage(width: 256, height: 192, valuesM: Array(repeating: 2, count: 256 * 192),
                                     confidence: Array(repeating: 2, count: 256 * 192)))
        let calibration = TextRecognizer.Calibration(frame: frame, floorID: "floor-2", floorY: 0, environment: nil)
        let input = TextRecognizer.Image(frameID: frame.id, asset: "sign-frame.color.jpg", jpeg: jpeg, url: nil,
                                         calibration: calibration)
        let document = await Task.detached {
            TextRecognizer.recognize([input], limits: .init(maximumImages: 1, timeBudget: 10))
        }.value
        let observation = try XCTUnwrap(document.observations.first { $0.text.contains("204") })
        let spatial = try XCTUnwrap(observation.spatial)
        XCTAssertEqual(spatial.meaning.kind, .room)
        XCTAssertEqual(spatial.z, -2, accuracy: 0.001)
        XCTAssertEqual(spatial.floorID, "floor-2")
        XCTAssertNotNil(spatial.heightAboveFloorM)
        XCTAssertNil(spatial.latitude)

        let id = UUID().uuidString
        let folder = try CaptureStore.captureDirectory(for: id)
        defer { try? FileManager.default.removeItem(at: folder) }
        var raw = snapshot()
        raw.textObservations = document.observations
        SemanticExport.stageCapturedText(raw: raw, captureID: id)
        let path = folder.appending(path: TextObservationsDocument.filename)
        var saved = try JSONDecoder().decode(TextObservationsDocument.self, from: Data(contentsOf: path))
        XCTAssertEqual(saved.captureID, id)
        XCTAssertEqual(saved.observations, document.observations)
        // A later geographic placement updates the same fixed local point, without rerunning OCR.
        let reference = BuildingMapReference(latitude: 33.75, longitude: -84.39, headingDegrees: 15)
        SemanticExport.stageCapturedText(raw: raw, captureID: id, reference: reference)
        saved = try JSONDecoder().decode(TextObservationsDocument.self, from: Data(contentsOf: path))
        XCTAssertNotNil(saved.observations.first?.spatial?.latitude)
        XCTAssertEqual(saved.observations.first?.spatial?.z, spatial.z)
    }

    private func room(includeGeometry: Bool = true, nonfiniteCurve: Bool = false) throws -> CapturedRoom {
        let wallPose: [Double] = [
            1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -0.05, -1.5, 1
        ]
        let floorPose: [Double] = [
            1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, -1.3, 0, 1
        ]
        var wall: [String: Any] = [
            "identifier": UUID().uuidString, "category": ["wall": [:]], "confidence": ["high": [:]],
            "dimensions": [4, 2.5, 0], "transform": wallPose, "story": 0,
            "polygonCorners": [], "completedEdges": [], "parentIdentifier": NSNull(), "curve": NSNull()
        ]
        if nonfiniteCurve {
            func angle(_ value: Double) throws -> Any {
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(Measurement(value: value, unit: UnitAngle.radians)))
            }
            wall["curve"] = [
                "center": [0, 0], "radius": "Infinity", "startAngle": try angle(0), "endAngle": try angle(.pi)
            ]
        }
        let floor: [String: Any] = [
            "identifier": UUID().uuidString, "category": ["floor": [:]], "confidence": ["high": [:]],
            "dimensions": [4, 3, 0], "transform": floorPose, "story": 0,
            "polygonCorners": [[-2, -1.5, 0], [2, -1.5, 0], [2, 1.5, 0], [-2, 1.5, 0]],
            "completedEdges": [], "parentIdentifier": NSNull(), "curve": NSNull()
        ]
        let document: [String: Any] = [
            "identifier": UUID().uuidString, "version": 3, "story": 0,
            "walls": includeGeometry ? [wall] : [], "floors": includeGeometry ? [floor] : [],
            "doors": [], "openings": [], "windows": [], "objects": [], "sections": []
        ]
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try decoder.decode(CapturedRoom.self, from: JSONSerialization.data(withJSONObject: document))
    }

    private func snapshot(marker: String = UUID().uuidString) -> RawScanSnapshot {
        RawScanSnapshot(meshes: [], frames: [], meshBuffers: [], depthBuffers: [],
                        metadata: .object(["test_marker": .string(marker)]))
    }

    func testNativeMetadataEncodingFailureStillPublishesValidatedMapAndScene() async throws {
        let scanID = UUID()
        let folder = try CaptureStore.captureDirectory(for: scanID.uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let completedRoom = try room(nonfiniteCurve: true)
        XCTAssertTrue(try XCTUnwrap(completedRoom.walls.first?.curve).radius.isInfinite)
        // Exercise the SDK's native serializer failure while preserving finite routing measurements.
        XCTAssertThrowsError(try JSONEncoder().encode([completedRoom]))
        let controller = ScanController(completedRooms: [completedRoom], rawSnapshot: snapshot(), scanID: scanID)
        defer { controller.stop() }
        await controller.waitForScenePreparation()

        XCTAssertEqual(controller.phase, .review)
        XCTAssertFalse(controller.isProcessingScene)
        XCTAssertNil(controller.sceneError)
        let map = try XCTUnwrap(controller.draft)
        XCTAssertEqual(map.footprints.filter { $0.kind == .wall }.count, 1)
        XCTAssertEqual(map.footprints.filter { $0.kind == .floor }.count, 1)
        XCTAssertEqual(map.floorY, -1.3, accuracy: 0.0001)
        let scene = try XCTUnwrap(controller.scene)
        XCTAssertEqual(scene.sourceScanID, scanID.uuidString)
        XCTAssertEqual(scene.surfaces.count, 2)
        let savedBundle = try JSONDecoder().decode(CaptureBundle.self,
            from: Data(contentsOf: folder.appending(path: "capture.json")))
        try savedBundle.validate()
        try scene.validate(source: savedBundle)
        XCTAssertEqual(try JSONDecoder().decode(ProcessedScene.self,
            from: Data(contentsOf: folder.appending(path: "scene.json"))), scene)

        let plistURL = folder.appending(path: "roomplan.plist")
        if FileManager.default.fileExists(atPath: plistURL.path) {
            let recovered = try PropertyListDecoder().decode([CapturedRoom].self, from: Data(contentsOf: plistURL))
            XCTAssertTrue(try XCTUnwrap(recovered.first?.walls.first?.curve).radius.isInfinite)
        } else {
            let warning = try XCTUnwrap(controller.originalScanWarning)
            XCTAssertTrue(scene.warnings.contains(warning))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "roomplan.json").path))
    }

    func testEmptyCompletedRoomShowsRetryableFailureWithoutPublishingDraft() async throws {
        let scanID = UUID()
        let folder = try CaptureStore.captureDirectory(for: scanID.uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = ScanController(completedRooms: [try room(includeGeometry: false)],
                                        rawSnapshot: snapshot(), scanID: scanID)
        defer { controller.stop() }
        await controller.waitForScenePreparation()

        XCTAssertEqual(controller.phase, .review)
        XCTAssertFalse(controller.isProcessingScene)
        XCTAssertTrue(controller.canRetryScene)
        XCTAssertNotNil(controller.sceneError)
        XCTAssertNil(controller.draft)
        XCTAssertNil(controller.scene)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "capture.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "scene.json").path))
    }

    func testRawStorageFailureRetainsInputsAndCompletesAfterRetry() async throws {
        let scanID = UUID()
        let folder = try CaptureStore.captureDirectory(for: scanID.uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blockedArchive = folder.appending(path: "raw-snapshot.json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blockedArchive, withIntermediateDirectories: true)
        let sentinel = blockedArchive.appending(path: "keep")
        try Data([99]).write(to: sentinel)
        let originalRaw = snapshot(marker: "retained-\(scanID.uuidString)")
        let controller = ScanController(completedRooms: [try room()], rawSnapshot: originalRaw, scanID: scanID)
        defer { controller.stop() }
        await controller.waitForScenePreparation()

        XCTAssertEqual(controller.phase, .review)
        XCTAssertFalse(controller.isProcessingScene)
        XCTAssertTrue(controller.canRetryScene)
        XCTAssertNotNil(controller.sceneError)
        XCTAssertNil(controller.draft)
        XCTAssertNil(controller.scene)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([99]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "capture.json").path))

        // Remove only this test's known obstacle, then retry the controller's retained inputs.
        try FileManager.default.removeItem(at: blockedArchive)
        controller.retryScene()
        await controller.waitForScenePreparation()
        XCTAssertEqual(controller.phase, .review)
        XCTAssertNil(controller.sceneError)
        XCTAssertNotNil(controller.draft)
        XCTAssertNotNil(controller.scene)
        let recoveredRaw = try CaptureStore.loadRawSnapshot(id: scanID.uuidString)
        XCTAssertEqual(recoveredRaw.metadata, originalRaw.metadata)
        XCTAssertEqual(controller.scene?.surfaces.count, 2)
    }
}
