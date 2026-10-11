import AccessCore
import Foundation
import RoomPlan
import UIKit

/// Builds the `semantics.json` and `text-observations.json` capture sidecars. RoomPlan values are
/// copied into AccessCore's plain models, so the encoding is tested without RoomPlan.
enum SemanticExport {
    /// Section labels (iOS 17+), story, door open state, surface outlines and confidence for each
    /// RoomPlan section. The deployment target (iOS 18) covers every API used here. Outline corners
    /// are moved from each surface's own frame into the shared ARKit session frame.
    static func rooms(_ rooms: [CapturedRoom]) -> [RoomPlanSemantics.Room] {
        rooms.map { room in
            let surfaces = room.walls + room.doors + room.openings + room.windows + room.floors
            return RoomPlanSemantics.Room(
                id: room.identifier.uuidString,
                story: room.story,
                sections: room.sections.map {
                    RoomPlanSemantics.Section(label: $0.label.rawValue, center: $0.center, story: $0.story)
                },
                surfaces: surfaces.map(surface)
            )
        }
    }

    private static func surface(_ surface: CapturedRoom.Surface) -> RoomPlanSemantics.Surface {
        let kind: String
        var isOpen: Bool?
        switch surface.category {
        case .wall: kind = "wall"
        case .opening: kind = "opening"
        case .window: kind = "window"
        case .door(let open):
            kind = "door"
            isOpen = open
        case .floor: kind = "floor"
        @unknown default: kind = String(describing: surface.category)
        }
        return RoomPlanSemantics.Surface(
            id: surface.identifier.uuidString, kind: kind, isOpen: isOpen, confidence: confidence(surface.confidence),
            story: surface.story, parentID: surface.parentIdentifier?.uuidString,
            mapFromSurface: surface.transform, dimensions: surface.dimensions,
            localPolygonCorners: surface.polygonCorners
        )
    }

    private static func confidence(_ value: CapturedRoom.Confidence) -> String {
        switch value {
        case .high: "high"
        case .medium: "medium"
        case .low: "low"
        @unknown default: "unknown"
        }
    }

    /// App and device provenance. Reads UIKit, so call on the main actor.
    @MainActor
    static func captureInfo(floorID: String) -> CaptureSemantics.CaptureInfo {
        let info = Bundle.main.infoDictionary
        return CaptureSemantics.CaptureInfo(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info?["CFBundleVersion"] as? String ?? "unknown",
            deviceModel: hardwareModel(),
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            floorID: floorID
        )
    }

    /// The hardware identifier (e.g. `iPhone16,1`), which tells LiDAR generations apart; the
    /// simulator reports the device it simulates.
    private static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model.isEmpty ? UIDevice.current.model : model
    }

    static func stageSemantics(map: VenueMap?, rooms: [CapturedRoom], capture: CaptureSemantics.CaptureInfo,
                               captureID: String, measurementTimestamps: [UUID: TimeInterval] = [:]) throws {
        try CaptureStore.stageSidecar(semanticsData(map: map, rooms: rooms, capture: capture,
                                                    measurementTimestamps: measurementTimestamps),
                                      named: CaptureSemantics.filename, id: captureID)
    }

    /// `semantics.json` bytes: geographic reference, confirmed access points, stairs and RoomPlan
    /// section labels, door states and polygons, all in the shared ARKit session frame.
    static func semanticsData(map: VenueMap?, rooms: [CapturedRoom], capture: CaptureSemantics.CaptureInfo,
                              measurementTimestamps: [UUID: TimeInterval] = [:]) throws -> Data {
        try CaptureSemantics(map: map, rooms: self.rooms(rooms), capture: capture,
                             measurementTimestamps: measurementTimestamps).encoded()
    }

    /// Saves the live OCR result even when the user never asks a server to find places.
    static func stageCapturedText(raw: RawScanSnapshot, captureID: String, reference: BuildingMapReference? = nil) {
        let existingURL = (try? CaptureStore.captureDirectory(for: captureID))?.appending(path: TextObservationsDocument.filename)
        let existing = existingURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(TextObservationsDocument.self, from: $0) }
        // A later Save must not discard the high-resolution pass performed by Find places.
        var observations = existing?.observations ?? raw.textObservations ?? []
        for index in observations.indices { observations[index].spatial?.apply(reference: reference) }
        do {
            try CaptureStore.stageSidecar(TextObservationsDocument(observations: CaptureTextObservation.sorted(observations), captureID: captureID).encoded(),
                                          named: TextObservationsDocument.filename, id: captureID)
        } catch { Log.scan.error("couldn't save spatial signs: \(error.localizedDescription, privacy: .public)") }
    }

    static func stageTextObservations(raw: RawScanSnapshot, map: VenueMap, floorID: String, captureID: String) {
        let frames = Dictionary(raw.frames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let buffers = Dictionary(raw.depthBuffers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sources = (raw.colorKeyframes ?? []).map { color in
            let calibration = frames[color.frameID].map {
                TextRecognizer.Calibration(frame: $0, floorID: floorID, floorY: map.floorY,
                    environment: buffers[color.frameID]?.environment, reference: map.geographicReference)
            }
            return TextRecognizer.Source(frameID: color.frameID, filename: color.filename, jpeg: color.jpeg,
                                         calibration: calibration)
        }
        stageTextObservations(keyframes: sources, captureID: captureID)
    }

    /// Reads text in the keyframes and any high-resolution OCR stills already staged for the capture.
    /// Optional evidence: a failure is logged and the capture continues without it.
    static func stageTextObservations(keyframes: [TextRecognizer.Source], captureID: String) {
        let directory = try? CaptureStore.captureDirectory(for: captureID)
        let images = TextRecognizer.images(keyframes: keyframes, captureDirectory: directory)
        guard !images.isEmpty else { return }
        var document = TextRecognizer.recognize(images)
        guard !Task.isCancelled else { return }
        document.captureID = captureID
        // Preserve live evidence if the bounded finish-time pass timed out on a later image.
        if let directory, let bytes = try? Data(contentsOf: directory.appending(path: TextObservationsDocument.filename)),
           let existing = try? JSONDecoder().decode(TextObservationsDocument.self, from: bytes) {
            for var observation in existing.observations {
                guard !document.observations.contains(where: {
                    $0.frameID == observation.frameID && $0.imageAsset == observation.imageAsset
                        && $0.text == observation.text && $0.bboxNorm == observation.bboxNorm
                }) else { continue }
                observation.spatial?.apply(reference: keyframes.first?.calibration?.reference)
                document.observations.append(observation)
            }
            document.observations = CaptureTextObservation.sorted(document.observations)
        }
        do {
            try CaptureStore.stageSidecar(document.encoded(), named: TextObservationsDocument.filename, id: captureID)
        } catch {
            Log.scan.error("couldn't stage text observations: \(error.localizedDescription, privacy: .public)")
        }
    }
}
