import Foundation
import simd
import Testing
@testable import AccessCore

private func json(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func visionBoxesFlipToATopLeftOrigin() throws {
    // A box in Vision's bottom-left space near the bottom of the image is near the top-left space's bottom.
    let box = try #require(VisionGeometry.topLeftBox((x: 0.1, y: 0.2, width: 0.3, height: 0.1)))
    #expect(abs(box[0] - 0.1) < 1e-9)
    #expect(abs(box[1] - 0.7) < 1e-9)
    #expect(abs(box[2] - 0.3) < 1e-9)
    #expect(abs(box[3] - 0.1) < 1e-9)
    // The full image maps onto itself.
    #expect(VisionGeometry.topLeftBox((x: 0, y: 0, width: 1, height: 1)) == [0, 0, 1, 1])
}

@Test func visionBoxesAreClippedAndEmptyOnesRejected() throws {
    let clipped = try #require(VisionGeometry.topLeftBox((x: -0.1, y: 0.9, width: 0.3, height: 0.2)))
    #expect(abs(clipped[0]) < 1e-9 && abs(clipped[1]) < 1e-9)
    #expect(abs(clipped[2] - 0.2) < 1e-9 && abs(clipped[3] - 0.1) < 1e-9)
    #expect(VisionGeometry.topLeftBox((x: 0.5, y: 0.5, width: 0, height: 0.1)) == nil)
    #expect(VisionGeometry.topLeftBox((x: 1.2, y: 0.5, width: 0.1, height: 0.1)) == nil)
    #expect(VisionGeometry.topLeftBox((x: .nan, y: 0.5, width: 0.1, height: 0.1)) == nil)
}

@Test func textObservationsFilterAndEncodeTheBackendSchema() throws {
    let box = (x: 0.25, y: 0.5, width: 0.5, height: 0.25)
    #expect(CaptureTextObservation.make(frameID: "f", imageAsset: "f.color.jpg", imageWidth: 480, imageHeight: 640,
                                 text: "   ", confidence: 1, visionBox: box, languages: []) == nil)
    #expect(CaptureTextObservation.make(frameID: "f", imageAsset: "f.color.jpg", imageWidth: 480, imageHeight: 640,
                                 text: "EXIT", confidence: 0.1, visionBox: box, languages: []) == nil)
    let exit = try #require(CaptureTextObservation.make(
        frameID: "depth-3", imageAsset: "depth-3.color.jpg", imageWidth: 480, imageHeight: 640,
        text: " EXIT \n", confidence: 1.2, visionBox: box, languages: ["en"]
    ))
    #expect(exit.text == "EXIT")
    #expect(exit.confidence == 1)
    let lower = try #require(CaptureTextObservation.make(
        frameID: "depth-3", imageAsset: "depth-3.color.jpg", imageWidth: 480, imageHeight: 640,
        text: "Salida", confidence: 0.5, visionBox: (x: 0.1, y: 0.1, width: 0.2, height: 0.1), languages: ["es"]
    ))
    let document = TextObservationsDocument(observations: CaptureTextObservation.sorted([lower, exit]))
    #expect(document.observations.map(\.text) == ["EXIT", "Salida"])

    let root = try json(document.encoded())
    #expect(root["schema_version"] as? Int == 1)
    #expect(root["engine"] as? String == "apple_vision")
    let first = try #require((root["observations"] as? [[String: Any]])?.first)
    #expect(Set(first.keys) == ["frame_id", "image_asset", "image_size_px", "image_orientation", "text", "confidence",
                                "bbox_norm", "bbox_sensor_norm", "languages"])
    #expect(first["image_orientation"] as? String == "upright_rotated_right_from_sensor")
    #expect(first["bbox_sensor_norm"] as? [Double] == [0.25, 0.25, 0.25, 0.5])
    #expect(first["frame_id"] as? String == "depth-3")
    #expect(first["image_size_px"] as? [Int] == [480, 640])
    #expect(first["bbox_norm"] as? [Double] == [0.25, 0.25, 0.5, 0.25])
    #expect(first["languages"] as? [String] == ["en"])
    #expect(try JSONDecoder().decode(TextObservationsDocument.self, from: document.encoded()) == document)
}

@Test func semanticsExportConfirmedPointsStairsGeographyAndRoomPlanLabels() throws {
    var map = VenueMap(
        floorY: -1.2,
        footprints: [
            Footprint(kind: .wall, center: [0, 0], size: [4, 0.15], yaw: 0),
            Footprint(kind: .stairs, center: [2, 1], size: [1, 3], yaw: 0, bottom: -1.2, height: 0.8),
            Footprint(kind: .stairs, center: [-2, 1], size: [1, 2], yaw: .pi / 2, id: UUID()),
        ],
        points: [
            AccessPoint(kind: .ramp, name: "South ramp", position: [1, -1.2, 2], source: .detected,
                        confidence: 0.8, slopeDegrees: 6, requiresAssistance: false),
            AccessPoint(kind: .elevator, position: [3, -1.2, -1], source: .manual, confidence: 1, requiresAssistance: true),
        ]
    )
    map.geographicReference = BuildingMapReference(latitude: 33.75, longitude: -84.39, headingDegrees: 12, horizontalAccuracyM: 5)

    let door = RoomPlanSemantics.Surface(
        id: "door-1", kind: "door", isOpen: true, confidence: "high", story: 0, parentID: "wall-1",
        mapFromSurface: simd_float4x4(columns: ([1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [1, 0, 2, 1])), dimensions: [0.9, 2, 0],
        localPolygonCorners: [[-0.45, -1, 0], [0.45, 1, 0]]
    )
    let room = RoomPlanSemantics.Room(
        id: "room-1", story: 0,
        sections: [RoomPlanSemantics.Section(label: "kitchen", center: [1, -1.2, 1], story: 0)],
        surfaces: [door]
    )
    let capture = CaptureSemantics.CaptureInfo(appVersion: "0.1.0", appBuild: "1", deviceModel: "iPhone16,1",
                                               systemName: "iOS", systemVersion: "18.2", floorID: "ground")
    let semantics = CaptureSemantics(map: map, rooms: [room], capture: capture)

    #expect(semantics.accessPoints.map(\.kind) == ["elevator", "ramp"])
    #expect(semantics.stairsFootprints.map(\.source) == ["roomplan", "detected"])
    #expect(door.polygonCornersM == [[0.55, -1, 2], [1.45, 1, 2]])

    let root = try json(semantics.encoded())
    #expect(root["schema_version"] as? Int == 1)
    #expect(root["coordinate_frame"] as? String == "shared_arkit_session")
    let geo = try #require(root["geographic_reference"] as? [String: Any])
    #expect(geo["latitude"] as? Double == 33.75)
    #expect(geo["heading_degrees"] as? Double == 12)
    #expect(geo["horizontal_accuracy_m"] as? Double == 5)
    let ramp = try #require((root["access_points"] as? [[String: Any]])?.last)
    #expect(ramp["name"] as? String == "South ramp")
    #expect(ramp["source"] as? String == "detected")
    #expect(ramp["slope_degrees"] as? Double == 6)
    #expect(ramp["requires_assistance"] as? Bool == false)
    let roomJSON = try #require(((root["roomplan"] as? [String: Any])?["rooms"] as? [[String: Any]])?.first)
    #expect((roomJSON["sections"] as? [[String: Any]])?.first?["label"] as? String == "kitchen")
    let surface = try #require((roomJSON["surfaces"] as? [[String: Any]])?.first)
    #expect(surface["is_open"] as? Bool == true)
    #expect(surface["parent_id"] as? String == "wall-1")
    #expect((surface["map_from_surface"] as? [Double])?[12] == 1)
    #expect((root["capture"] as? [String: Any])?["floor_id"] as? String == "ground")
    #expect(try JSONDecoder().decode(CaptureSemantics.self, from: semantics.encoded()) == semantics)
}

@Test func semanticsWithoutAMapStayValid() throws {
    let capture = CaptureSemantics.CaptureInfo(appVersion: "1", appBuild: "1", deviceModel: "x", systemName: "iOS",
                                               systemVersion: "18", floorID: "ground")
    let root = try json(CaptureSemantics(map: nil, rooms: [], capture: capture).encoded())
    #expect(root["geographic_reference"] == nil)
    #expect((root["access_points"] as? [Any])?.isEmpty == true)
    #expect((root["stairs_footprints"] as? [Any])?.isEmpty == true)
}

/// A non-square upright image (480×640) is the 640×480 sensor image rotated 90° clockwise, so the
/// exported sensor box must land on the same physical pixels the frame's intrinsics describe.
@Test func sensorBoxIsTheUprightBoxRotatedBackIntoTheSensorImage() throws {
    let (uprightW, uprightH) = (480.0, 640.0)
    let (sensorW, sensorH) = (uprightH, uprightW)  // Landscape sensor: 640×480.
    // Text near the top-right of the upright image: x 300–420 px, y 40–100 px.
    let observation = try #require(CaptureTextObservation.make(
        frameID: "f", imageAsset: "f.color.jpg", imageWidth: Int(uprightW), imageHeight: Int(uprightH), text: "214",
        confidence: 0.9, visionBox: (x: 300 / uprightW, y: 1 - 100 / uprightH, width: 120 / uprightW, height: 60 / uprightH),
        languages: []
    ))
    let upright = observation.bboxNorm, sensor = observation.bboxSensorNorm
    #expect(observation.imageOrientation == CaptureImageOrientation.uprightRotatedRightFromSensor)
    // Every upright corner (px, py) maps to sensor pixel (py, H_up − px) for a clockwise rotation.
    for (px, py) in [(300.0, 40.0), (420.0, 40.0), (300.0, 100.0), (420.0, 100.0)] {
        let (sx, sy) = (py, uprightW - px)
        #expect(sx / sensorW >= sensor[0] - 1e-6 && sx / sensorW <= sensor[0] + sensor[2] + 1e-6)
        #expect(sy / sensorH >= sensor[1] - 1e-6 && sy / sensorH <= sensor[1] + sensor[3] + 1e-6)
    }
    // Width and height swap: 120×60 upright px is 60×120 sensor px.
    #expect(abs(sensor[2] * sensorW - upright[3] * uprightH) < 1e-3)
    #expect(abs(sensor[3] * sensorH - upright[2] * uprightW) < 1e-3)
    #expect(abs(sensor[0] - 40 / sensorW) < 1e-6 && abs(sensor[1] - 60 / sensorH) < 1e-6)
}
