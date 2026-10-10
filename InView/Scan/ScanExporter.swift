import AccessCore
import Foundation
import RoomPlan
import simd

/// Projects RoomPlan into the portable capture draft without changing its session origin.
enum ScanExporter {
    static let maximumUploadBytes = 32 * 1024 * 1024

    static func nativeRoomPlanData(rooms: [CapturedRoom]) throws -> Data {
        try JSONEncoder().encode(rooms)
    }

    static func rawSnapshotData(_ snapshot: RawScanSnapshot) throws -> Data {
        try JSONEncoder().encode(snapshot)
    }

    static func bundle(
        rooms: [CapturedRoom], raw: RawScanSnapshot?, scanID: UUID, mapID: UUID,
        worldMapAsset: String? = nil
    ) throws -> CaptureBundle {
        let native = try JSONDecoder().decode(JSONValue.self, from: nativeRoomPlanData(rooms: rooms))
        // Adjacent sections can report the same component. Retain its latest measured state.
        var objects: [UUID: CapturedRoom.Object] = [:]
        var surfaces: [UUID: CapturedRoom.Surface] = [:]
        for room in rooms {
            for object in room.objects { objects[object.identifier] = object }
            for surface in room.walls + room.doors + room.openings + room.windows + room.floors {
                surfaces[surface.identifier] = surface
            }
        }
        let projectedObjects = objects.values.sorted { $0.identifier.uuidString < $1.identifier.uuidString }.map {
            CaptureObject(
                id: $0.identifier.uuidString, category: category($0.category), confidence: confidence($0.confidence),
                mapFromObject: matrix($0.transform), dimensionsM: vector($0.dimensions)
            )
        }
        let projectedSurfaces = surfaces.values.sorted { $0.identifier.uuidString < $1.identifier.uuidString }.map {
            CaptureSurface(
                id: $0.identifier.uuidString, kind: kind($0.category),
                mapFromSurface: matrix($0.transform), dimensionsM: vector($0.dimensions)
            )
        }
        var meshes = raw?.meshes ?? []
        var frames = raw?.frames ?? []
        let colorAssets = raw?.colorKeyframes.map(\.filename) ?? []
        var omissions: [String] = []

        func makeBundle() -> CaptureBundle {
            CaptureBundle(
                id: scanID.uuidString, mapID: mapID.uuidString,
                meshes: meshes, frames: frames, objects: projectedObjects, surfaces: projectedSurfaces,
                metadata: .object([
                    "source": .string("iphone_roomplan_arkit"),
                    "coordinate_space": .string("shared_arkit_session"),
                    "roomplan_section_ids": .array(rooms.map { .string($0.identifier.uuidString) }),
                    "section_count": .number(Double(rooms.count)),
                    "deduplication": .string("identifier_latest_section_wins"),
                    "surface_representation": .string("native_centered_dimensions_and_transform; polygon_corners_retained_in_roomplan_original"),
                    "raw_capture": raw?.metadata ?? .object(["status": .string("not_collected")]),
                    "raw_upload_omissions": .array(omissions.map(JSONValue.string)),
                    "raw_original_storage": .string("local_raw_scan_archive"),
                    "assets": .object([
                        "roomplan": .string("roomplan.json"),
                        "raw_snapshot": .string("raw-snapshot.json"),
                        "world_map": worldMapAsset.map(JSONValue.string) ?? .null,
                        "color_keyframes": .array(colorAssets.map(JSONValue.string)),
                    ]),
                ]),
                roomplanOriginal: native
            )
        }

        var result = makeBundle()
        if try JSONEncoder().encode(result).count > maximumUploadBytes, !frames.isEmpty {
            // Never truncate a calibrated image or a mesh. Optional layers travel whole or remain local.
            frames = []
            omissions.append("depth_frames_exceed_upload_limit; full_selected_frames_preserved_locally")
            result = makeBundle()
        }
        if try JSONEncoder().encode(result).count > maximumUploadBytes, !meshes.isEmpty {
            meshes = []
            omissions.append("mesh_snapshot_exceeds_upload_limit; complete_snapshot_preserved_locally")
            result = makeBundle()
        }
        guard try JSONEncoder().encode(result).count <= maximumUploadBytes else {
            throw ExportError.captureTooLarge
        }
        guard !projectedObjects.isEmpty || !projectedSurfaces.isEmpty || !meshes.isEmpty || !frames.isEmpty else {
            throw ExportError.emptyCapture
        }
        return result
    }

    static func matrix(_ value: simd_float4x4) -> [Float] {
        (0..<4).flatMap { column in (0..<4).map { row in value[column][row] } }
    }

    static func vector(_ value: SIMD3<Float>) -> [Float] { [value.x, value.y, value.z] }

    private static func confidence(_ value: CapturedRoom.Confidence) -> CaptureConfidence {
        switch value {
        case .high: .high
        case .medium: .medium
        case .low: .low
        @unknown default: .unknown
        }
    }

    private static func category(_ value: CapturedRoom.Object.Category) -> String {
        switch value {
        case .storage: "storage"
        case .refrigerator: "refrigerator"
        case .stove: "stove"
        case .bed: "bed"
        case .sink: "sink"
        case .washerDryer: "washer_dryer"
        case .toilet: "toilet"
        case .bathtub: "bathtub"
        case .oven: "oven"
        case .dishwasher: "dishwasher"
        case .table: "table"
        case .sofa: "sofa"
        case .chair: "chair"
        case .fireplace: "fireplace"
        case .television: "television"
        case .stairs: "stairs"
        @unknown default: String(describing: value)
        }
    }

    private static func kind(_ value: CapturedRoom.Surface.Category) -> String {
        switch value {
        case .wall: "wall"
        case .opening: "opening"
        case .window: "window"
        case .door: "door"
        case .floor: "floor"
        @unknown default: String(describing: value)
        }
    }

    enum ExportError: LocalizedError {
        case captureTooLarge
        case emptyCapture

        var errorDescription: String? {
            switch self {
            case .captureTooLarge: "This scan is too large to upload. Its original capture is saved on this phone."
            case .emptyCapture: "The scan doesn't contain a room yet. Try scanning more of the space."
            }
        }
    }
}
