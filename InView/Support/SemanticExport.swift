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
                               captureID: String) throws {
        let semantics = CaptureSemantics(map: map, rooms: self.rooms(rooms), capture: capture)
        try CaptureStore.stageSidecar(semantics.encoded(), named: CaptureSemantics.filename, id: captureID)
    }

    /// Reads text in the keyframes and any high-resolution OCR stills already staged for the capture.
    /// Optional evidence: a failure is logged and the capture continues without it.
    static func stageTextObservations(keyframes: [TextRecognizer.Source], captureID: String) {
        let directory = try? CaptureStore.captureDirectory(for: captureID)
        let images = TextRecognizer.images(keyframes: keyframes, captureDirectory: directory)
        guard !images.isEmpty else { return }
        let document = TextRecognizer.recognize(images)
        guard !Task.isCancelled else { return }
        do {
            try CaptureStore.stageSidecar(document.encoded(), named: TextObservationsDocument.filename, id: captureID)
        } catch {
            Log.scan.error("couldn't stage text observations: \(error.localizedDescription, privacy: .public)")
        }
    }
}
