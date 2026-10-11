import Foundation
import Testing
@testable import AccessCore

struct SpatialSignsTests {
    private func observation(_ text: String = "ROOM 204 →") -> CaptureTextObservation {
        CaptureTextObservation(frameID: "f", imageAsset: "f.color.jpg", imageSizePx: [100, 100],
                               text: text, confidence: 0.95, bboxNorm: [0.3, 0.3, 0.4, 0.4], languages: [])
    }
    private func frame() -> CaptureDepthFrame {
        CaptureDepthFrame(id: "f", timestampSeconds: 100,
            mapFromCamera: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 10, 3, 20, 1],
            camera: CaptureCameraCalibration(imageWidth: 100, imageHeight: 100, fx: 100, fy: 100, cx: 50, cy: 50),
            depth: CaptureDepthImage(width: 10, height: 10, valuesM: Array(repeating: 2, count: 100), confidence: Array(repeating: 2, count: 100)))
    }

    @Test func recognizesSignTypesAndPrintRelativeDirections() {
        #expect(SignMeaning.classify("Emergency EXIT ←")?.kind == .exit)
        #expect(SignMeaning.classify("Emergency EXIT ←")?.directions == ["left"])
        #expect(SignMeaning.classify("B204")?.kind == .room)
        #expect(SignMeaning.classify("Room 204 →")?.directions == ["right"])
        #expect(SignMeaning.classify("Library ahead")?.kind == .direction)
        #expect(SignMeaning.classify("Stairwell A")?.kind == .stairs)
        #expect(SignMeaning.classify("Lift")?.kind == .elevator)
        #expect(SignMeaning.classify("Restrooms")?.kind == .restroom)
        #expect(SignMeaning.classify("BRIGHT") == nil)
        #expect(SignMeaning.classify("EXITING") == nil)
        #expect(SignMeaning.classify("Welcome") == nil)
    }

    @Test func exactXYZAndIndependentElevationDatums() throws {
        let environment = CaptureEnvironmentSample(recordedAtUnixSeconds: 1000, altitudeM: 300, verticalAccuracyM: 4,
                                                    relativeAltitudeM: 6)
        let result = try #require(SignLocalizer.locate(observation(), frame: frame(), floorID: "floor-2", floorY: 1,
                                                      environment: environment))
        #expect(result.x == 10)
        #expect(result.y == 3)
        #expect(result.z == 18)
        #expect(result.floorID == "floor-2")
        #expect(result.heightAboveFloorM == 2)
        #expect(result.altitudeMSLM == 300)
        #expect(result.environment?.relativeAltitudeM == 6)
        #expect(result.latitude == nil)
        #expect(!result.destinationVerified)
        #expect(result.depthSampleCount == 9)
    }

    @Test func respectsPoseRotationAndVerticalImageCoordinates() throws {
        var f = frame()
        // Rotate camera 90 degrees about y: forward (-z) now points -x.
        f.mapFromCamera = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 10, 3, 20, 1]
        let result = try #require(SignLocalizer.locate(observation(), frame: f))
        #expect(result.x == 8)
        #expect(result.y == 3)
        #expect(result.z == 20)
        var o = observation()
        o.bboxSensorNorm = [0.3, 0.1, 0.4, 0.4]
        let raised = try #require(SignLocalizer.locate(o, frame: frame()))
        #expect(abs(raised.y - 3.4) < 0.001)
    }

    @Test func refusesMissingNoisyOrUncalibratedDepth() {
        var f = frame()
        f.depth.confidence = nil
        #expect(SignLocalizer.locate(observation(), frame: f) == nil)
        f = frame(); f.depth.confidence = Array(repeating: 0, count: 100)
        #expect(SignLocalizer.locate(observation(), frame: f) == nil)
        f = frame(); f.depth.valuesM[55] = 6
        #expect(SignLocalizer.locate(observation(), frame: f) == nil)
        f = frame(); f.camera.fx = 0
        #expect(SignLocalizer.locate(observation(), frame: f) == nil)
        f = frame(); f.id = "wrong-frame"
        #expect(SignLocalizer.locate(observation(), frame: f) == nil)
        f = frame(); f.mapFromCamera[12] = .nan
        #expect(SignLocalizer.locate(observation(), frame: f) == nil)
        var o = observation(); o.confidence = 0.4
        #expect(SignLocalizer.locate(o, frame: frame()) == nil)
    }

    @Test func noFloorOrAltitudeIsNotZeroElevation() throws {
        let result = try #require(SignLocalizer.locate(observation(), frame: frame()))
        #expect(result.floorElevationM == nil)
        #expect(result.heightAboveFloorM == nil)
        #expect(result.altitudeMSLM == nil)
    }

    @Test func explicitGeographicPlacementCanBeReplacedAndRemoved() throws {
        var result = try #require(SignLocalizer.locate(observation(), frame: frame()))
        let reference = BuildingMapReference(latitude: 33.75, longitude: -84.39, headingDegrees: 90, horizontalAccuracyM: 8)
        result.apply(reference: reference)
        let expected = try reference.coordinate(for: SIMD2(result.x, result.z))
        #expect(result.latitude == expected.latitude)
        #expect(result.longitude == expected.longitude)
        #expect(result.horizontalAccuracyM == 8)
        result.apply(reference: nil)
        #expect(result.latitude == nil && result.longitude == nil)
    }

    @Test func additiveSchemaRoundTripAndLegacyCompatibility() throws {
        var o = observation()
        let legacy = try TextObservationsDocument(observations: [o]).encoded()
        #expect(try JSONDecoder().decode(TextObservationsDocument.self, from: legacy).observations[0].spatial == nil)
        o.spatial = SignLocalizer.locate(o, frame: frame())
        let document = TextObservationsDocument(observations: [o])
        let data = try document.encoded()
        #expect(try JSONDecoder().decode(TextObservationsDocument.self, from: data) == document)
        let string = String(decoding: data, as: UTF8.self)
        #expect(string.contains("\"coordinate_frame\":\"capture_map_meters_y_up\""))
        #expect(string.contains("\"x\":10"))
    }
}
