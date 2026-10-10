import AccessCore
import Foundation
import RoomPlan
import simd

/// Projects RoomPlan into the portable capture draft without changing its session origin.
enum ScanExporter {
    static func streamingMeasurements(_ footprints: [Footprint]) -> (surfaces: [CaptureSurface], objects: [CaptureObject]) {
        (footprints.enumerated().compactMap { observedSurface($0.element, index: $0.offset) },
         footprints.enumerated().compactMap { observedObject($0.element, index: $0.offset) })
    }

    static func nativeRoomPlanData(rooms: [CapturedRoom]) throws -> Data {
        try JSONEncoder().encode(rooms)
    }

    static func rawSnapshotData(_ snapshot: RawScanSnapshot) throws -> Data {
        // The welded display mesh is derived from the native mesh buffers and saved in the
        // capture bundle; the raw archive keeps only the originals.
        var originals = snapshot
        originals.meshes = []
        return try JSONEncoder().encode(originals)
    }

    static func bundle(
        rooms: [CapturedRoom], recovered: [RoomParts] = [], raw: RawScanSnapshot?, scanID: UUID, mapID: UUID,
        floor: ScanFloorIdentity? = nil
    ) throws -> CaptureBundle {
        try Task.checkCancellation()
        // Use the map's selection rules so a room recovered from live updates also appears
        // in scene-backed navigation, without duplicating the processed measurements.
        let merged = MapBuilder.mergedParts(rooms: rooms, recovered: recovered, observed: raw?.observedFootprints ?? [])
        let parts = merged.parts
        let observed = MapBuilder.observedAdditions(raw?.observedFootprints ?? [], to: parts, floorY: merged.floorY)
        try Task.checkCancellation()
        var projectedObjects = parts.objects.sorted { $0.identifier.uuidString < $1.identifier.uuidString }.map {
            CaptureObject(
                id: $0.identifier.uuidString, category: category($0.category), confidence: confidence($0.confidence),
                mapFromObject: matrix($0.transform), dimensionsM: vector($0.dimensions)
            )
        }
        var projectedSurfaces = (parts.walls + parts.doors + parts.openings + parts.windows + parts.floors)
            .sorted { $0.identifier.uuidString < $1.identifier.uuidString }.map {
            CaptureSurface(
                id: $0.identifier.uuidString, kind: kind($0.category),
                mapFromSurface: matrix($0.transform), dimensionsM: vector($0.dimensions),
                polygonCorners: $0.category == .floor && $0.polygonCorners.count >= 3
                    ? $0.polygonCorners.map(vector) : nil
            )
        }
        // The compact observed geometry is independent of RoomPlan's room fitting and
        // depth-frame retention, so an open corridor can keep extending between sections.
        projectedSurfaces.append(contentsOf: observed.enumerated().compactMap {
            observedSurface($0.element, index: $0.offset)
        })
        projectedObjects.append(contentsOf: observed.enumerated().compactMap {
            observedObject($0.element, index: $0.offset)
        })
        var result = CaptureBundle(
                id: scanID.uuidString, mapID: mapID.uuidString, floorID: floor?.id.uuidString ?? "ground",
                meshes: raw?.meshes ?? [], frames: raw?.frames ?? [], objects: projectedObjects, surfaces: projectedSurfaces,
                metadata: .object([
                    "source": .string("iphone_roomplan_arkit"),
                    "coordinate_space": .string("shared_arkit_session"),
                    "roomplan_section_ids": .array(rooms.map { .string($0.identifier.uuidString) }),
                    "section_count": .number(Double(rooms.count)),
                    "deduplication": .string("identifier_latest_section_wins"),
                    "live_room_recovery": .string("processed_measurements_win; missing_components_recovered_without_overlap"),
                    "surface_representation": .string("centered_dimensions_and_transform_with_measured_floor_polygon_corners"),
                    "observed_surface_count": .number(Double(observed.filter { $0.kind == .floor || $0.kind == .wall }.count)),
                    "depth_obstacle_count": .number(Double(observed.filter { $0.kind == .obstacle }.count)),
                    "raw_capture": raw?.metadata ?? .object(["status": .string("not_collected")]),
                    "raw_original_storage": .string("local_raw_scan_archive"),
                    "roomplan_original_storage": .string("local_roomplan_archive"),
                ])
            )
        if let floor, case .object(var metadata) = result.metadata {
            metadata["building_id"] = .string(floor.buildingID.uuidString)
            metadata["floor_name"] = .string(floor.name)
            metadata["floor_level"] = .number(Double(floor.level))
            result.metadata = .object(metadata)
        }
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

    private static func observedObject(_ footprint: Footprint, index: Int) -> CaptureObject? {
        DepthObstacleEvidence.captureObject(from: footprint,
            id: "depth-\(footprint.id?.uuidString ?? String(index))")
    }

    private static func observedSurface(_ footprint: Footprint, index: Int) -> CaptureSurface? {
        guard let bottom = footprint.bottom, bottom.isFinite else { return nil }
        let id = "observed-\(footprint.id?.uuidString ?? String(index))"
        if footprint.kind == .floor {
            // Surface local X/Y span map X/Z; local Z points down. Keep a rigid,
            // right-handed frame matching RoomPlan's flat floor representation.
            let pose: [Float] = [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0,
                                 footprint.center.x, bottom, footprint.center.y, 1]
            return CaptureSurface(id: id, kind: "floor", mapFromSurface: pose,
                                  dimensionsM: [footprint.size.x, footprint.size.y, 0],
                                  polygonCorners: footprint.corners.map {
                                      [$0.x - footprint.center.x, $0.y - footprint.center.y, 0]
                                  })
        }
        guard footprint.kind == .wall, let height = footprint.height, height > 0 else { return nil }
        let c = cos(footprint.yaw), s = sin(footprint.yaw)
        let pose: [Float] = [c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0,
                             footprint.center.x, bottom + height / 2, footprint.center.y, 1]
        return CaptureSurface(id: id, kind: "wall", mapFromSurface: pose,
                              dimensionsM: [footprint.size.x, height, footprint.size.y])
    }

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
