import AccessCore
import Foundation
import RoomPlan
import simd

/// Projects RoomPlan into the portable capture draft without changing its session origin.
enum ScanExporter {
    static func nativeRoomPlanData(rooms: [CapturedRoom]) throws -> Data {
        try JSONEncoder().encode(rooms)
    }

    static func rawSnapshotData(_ snapshot: RawScanSnapshot) throws -> Data {
        try JSONEncoder().encode(snapshot)
    }

    static func bundle(
        rooms: [CapturedRoom], recovered: [RoomParts] = [], raw: RawScanSnapshot?, scanID: UUID, mapID: UUID
    ) throws -> CaptureBundle {
        try Task.checkCancellation()
        // Use the map's selection rules so a room recovered from live updates also appears
        // in scene-backed navigation, without duplicating the processed measurements.
        let parts = MapBuilder.mergedParts(rooms: rooms, recovered: recovered).parts
        try Task.checkCancellation()
        let projectedObjects = parts.objects.sorted { $0.identifier.uuidString < $1.identifier.uuidString }.map {
            CaptureObject(
                id: $0.identifier.uuidString, category: category($0.category), confidence: confidence($0.confidence),
                mapFromObject: matrix($0.transform), dimensionsM: vector($0.dimensions)
            )
        }
        let projectedSurfaces = (parts.walls + parts.doors + parts.openings + parts.windows + parts.floors)
            .sorted { $0.identifier.uuidString < $1.identifier.uuidString }.map {
            CaptureSurface(
                id: $0.identifier.uuidString, kind: kind($0.category),
                mapFromSurface: matrix($0.transform), dimensionsM: vector($0.dimensions)
            )
        }
        let result = CaptureBundle(
                id: scanID.uuidString, mapID: mapID.uuidString,
                meshes: raw?.meshes ?? [], frames: raw?.frames ?? [], objects: projectedObjects, surfaces: projectedSurfaces,
                metadata: .object([
                    "source": .string("iphone_roomplan_arkit"),
                    "coordinate_space": .string("shared_arkit_session"),
                    "roomplan_section_ids": .array(rooms.map { .string($0.identifier.uuidString) }),
                    "section_count": .number(Double(rooms.count)),
                    "deduplication": .string("identifier_latest_section_wins"),
                    "live_room_recovery": .string("processed_measurements_win; missing_components_recovered_without_overlap"),
                    "surface_representation": .string("native_centered_dimensions_and_transform; polygon_corners_retained_in_roomplan_original"),
                    "raw_capture": raw?.metadata ?? .object(["status": .string("not_collected")]),
                    "raw_original_storage": .string("local_raw_scan_archive"),
                    "roomplan_original_storage": .string("local_roomplan_archive"),
                ])
            )
        // Native RoomPlan JSON is archived separately. Expanding it into a second JSON tree and
        // embedding it here duplicates every section. Upload limits belong to the network client;
        // local navigation must work even for captures too large to send.
        guard !projectedObjects.isEmpty || !projectedSurfaces.isEmpty || !result.meshes.isEmpty || !result.frames.isEmpty else {
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
        case emptyCapture

        var errorDescription: String? {
            switch self {
            case .emptyCapture: "The scan doesn't contain a room yet. Try scanning more of the space."
            }
        }
    }
}
