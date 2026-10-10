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
        try JSONEncoder().encode(snapshot)
    }

    static func bundle(
        rooms: [CapturedRoom], recovered: [RoomParts] = [], raw: RawScanSnapshot?, scanID: UUID, mapID: UUID,
        floor: ScanFloorIdentity? = nil
    ) throws -> CaptureBundle {
        try Task.checkCancellation()
        let merged = MapBuilder.mergedParts(rooms: rooms, recovered: recovered, observed: raw?.observedFootprints ?? [])
        return try bundle(parts: merged.parts, floorY: merged.floorY, rooms: rooms, raw: raw,
                          scanID: scanID, mapID: mapID, floor: floor,
                          assemblyMethod: "completed_roomplan_measurements")
    }

    /// Canonical structural projection, independent of original depth meshes and live-room fitting.
    /// Raw data stays in its separate archive; retained depth frames remain available as evidence.
    static func bundle(
        parts: RoomParts, floorY: Float, rooms: [CapturedRoom], raw: RawScanSnapshot?, scanID: UUID, mapID: UUID,
        floor: ScanFloorIdentity? = nil, assemblyMethod: String
    ) throws -> CaptureBundle {
        try Task.checkCancellation()
        let observed = MapBuilder.observedAdditions(raw?.observedFootprints ?? [], to: parts, floorY: floorY)
        try Task.checkCancellation()
        let projectedObjects = parts.objects.sorted { $0.identifier.uuidString < $1.identifier.uuidString }.map {
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
        // Keep exact uncovered floor regions, never raw walls, mesh fragments or obstacle samples.
        projectedSurfaces.append(contentsOf: observed.enumerated().compactMap {
            observedSurface($0.element, index: $0.offset)
        })
        var result = CaptureBundle(
                id: scanID.uuidString, mapID: mapID.uuidString, floorID: floor?.id.uuidString ?? "ground",
                meshes: [], frames: raw?.frames ?? [], objects: projectedObjects, surfaces: projectedSurfaces,
                metadata: .object([
                    "source": .string("iphone_roomplan_arkit"),
                    "coordinate_space": .string("shared_arkit_session"),
                    "roomplan_section_ids": .array(rooms.map { .string($0.identifier.uuidString) }),
                    "section_count": .number(Double(rooms.count)),
                    "assembly": .string(assemblyMethod),
                    "live_room_recovery": .string("original_evidence_only"),
                    "surface_representation": .string("centered_dimensions_and_transform_with_measured_floor_polygon_corners"),
                    "observed_surface_count": .number(Double(observed.count)),
                    "depth_obstacle_count": .number(0),
                    "walk_trace_sample_count": .number(Double(raw?.walkTrace?.samples.count ?? 0)),
                    "walk_trace_storage": .string("local_raw_scan_archive"),
                    "walk_trace_use": .string("coverage_review_only_not_walkable_geometry"),
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
        guard !parts.walls.isEmpty || !parts.floors.isEmpty else {
            throw ExportError.emptyCapture
        }
        try result.validate()
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

/// One on-device finishing operation. Multi-room scans must succeed through Apple's native merge;
/// concatenating rejected or incompatible rooms would silently publish broken geometry.
enum RoomPlanAssembly {
    struct Prepared: Sendable {
        let rooms: [CapturedRoom]
        let parts: RoomParts
        let floorY: Float
        let bundle: CaptureBundle
        let map: VenueMap
        let structureData: Data?
    }

    static func prepare(
        rooms: [CapturedRoom], raw: RawScanSnapshot?, scanID: UUID, mapID: UUID,
        floor: ScanFloorIdentity? = nil, points: [AccessPoint] = [], spottedStairs: [Footprint] = []
    ) async throws -> Prepared {
        try Task.checkCancellation()
        guard !rooms.isEmpty else { throw ScanExporter.ExportError.emptyCapture }
        // Validate the completed input before handing it to the native merger. Do not include
        // supplemental measurements when checking the original shared coordinate space.
        let source = try await ScanWork.run {
            let source = MapBuilder.mergedParts(rooms: rooms)
            _ = try ScanExporter.bundle(parts: source.parts, floorY: source.floorY, rooms: rooms, raw: nil,
                                        scanID: scanID, mapID: mapID, floor: floor,
                                        assemblyMethod: "input_validation")
            return source.parts
        }

        let canonicalRooms: [CapturedRoom]
        let canonicalParts: RoomParts
        let structure: CapturedStructure?
        if rooms.count == 1 {
            canonicalRooms = rooms
            canonicalParts = source
            structure = nil
        } else {
            let builder = StructureBuilder(options: [.beautifyObjects])
            // An SDK alignment, size or processing error is intentionally propagated. Originals
            // have already been archived by the caller and the previous saved map stays intact.
            let merged = try await builder.capturedStructure(from: rooms)
            try Task.checkCancellation()
            guard !merged.rooms.isEmpty else { throw ScanExporter.ExportError.emptyCapture }
            canonicalRooms = merged.rooms
            canonicalParts = RoomParts(merged)
            structure = merged
        }
        try Task.checkCancellation()
        return try await ScanWork.run {
            let floorY = MapBuilder.floorHeight(canonicalParts, observed: raw?.observedFootprints ?? [])
            let bundle = try ScanExporter.bundle(parts: canonicalParts, floorY: floorY, rooms: canonicalRooms,
                                                 raw: raw, scanID: scanID, mapID: mapID, floor: floor,
                                                 assemblyMethod: structure == nil ? "native_single_room" : "native_structure_builder")
            try validateSharedFrame(original: source, canonical: canonicalParts)
            let map = MapBuilder.build(parts: canonicalParts, floorY: floorY, points: points,
                                       spottedStairs: spottedStairs, observed: raw?.observedFootprints ?? [])
            try Task.checkCancellation()
            return Prepared(rooms: canonicalRooms, parts: canonicalParts, floorY: floorY, bundle: bundle,
                            map: map, structureData: try structure.map { try JSONEncoder().encode($0) })
        }
    }

    /// Detect a gross change of origin without trying to second-guess RoomPlan's wall fitting.
    /// Finite rigid poses and measured polygons have already passed CaptureBundle validation.
    private static func validateSharedFrame(original: RoomParts, canonical: RoomParts) throws {
        func bounds(_ parts: RoomParts) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
            var lower = SIMD3<Float>(repeating: .infinity), upper = SIMD3<Float>(repeating: -.infinity)
            func include(_ point: SIMD3<Float>) {
                lower = simd_min(lower, point)
                upper = simd_max(upper, point)
            }
            for surface in parts.walls + parts.doors + parts.openings + parts.windows + parts.floors {
                let corners = surface.polygonCorners.count >= 3 ? surface.polygonCorners : (0..<8).map { index in
                    surface.dimensions * SIMD3<Float>(index & 1 == 0 ? -0.5 : 0.5,
                                                       index & 2 == 0 ? -0.5 : 0.5,
                                                       index & 4 == 0 ? -0.5 : 0.5)
                }
                for corner in corners {
                    let world = surface.transform * SIMD4(corner, 1)
                    include(SIMD3(world.x, world.y, world.z))
                }
            }
            return lower.x.isFinite && lower.y.isFinite && lower.z.isFinite ? (lower, upper) : nil
        }
        guard let original = bounds(original), let canonical = bounds(canonical) else {
            throw ScanExporter.ExportError.emptyCapture
        }
        // Native refinement may extend a fitted wall a little; a structure moved outside this
        // generous measured envelope cannot safely share the archived ARWorldMap and evidence.
        let tolerance = SIMD3<Float>(repeating: 2)
        guard canonical.min.x >= original.min.x - tolerance.x,
              canonical.min.y >= original.min.y - tolerance.y,
              canonical.min.z >= original.min.z - tolerance.z,
              canonical.max.x <= original.max.x + tolerance.x,
              canonical.max.y <= original.max.y + tolerance.y,
              canonical.max.z <= original.max.z + tolerance.z else {
            throw CaptureValidationError.invalid("The rooms couldn't be aligned with the saved scan. The original captures are still saved.")
        }
    }
}
