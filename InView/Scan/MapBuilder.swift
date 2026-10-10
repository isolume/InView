import AccessCore
import RoomPlan
import simd

/// Flattens RoomPlan's output into the floor footprints the route planner works with.
enum MapBuilder {
    /// Stairs the camera spotted that overlap stairs RoomPlan found (allowing this much slack) are the same stairs.
    private static let sameStairsSlack: Float = 1
    /// A remembered surface or object this close to one in the processed room is the same thing.
    private static let recoveredSlack: Float = 0.3

    /// RoomPlan surfaces have no depth, so walls are treated as this thick.
    private static let wallThickness: Float = 0.15
    /// Objects whose underside is higher than this above the floor (TVs, shelves) don't block a wheelchair.
    private static let overheadClearance: Float = 0.7
    /// The world origin is the phone where the scan started, usually held about this high.
    private static let assumedPhoneHeight: Float = 1.3

    /// - Parameters:
    ///   - rooms: RoomPlan's processed result for each section.
    ///   - recovered: Surfaces and objects RoomPlan reported live during a section but left out of its processed
    ///     result, usually because the volunteer walked on to another room in the same section. Added where
    ///     they don't overlap what the processed rooms have.
    ///   - spottedStairs: Stairs found by the vision model, added where RoomPlan missed them.
    static func build(rooms: [CapturedRoom], recovered: [RoomParts] = [], points: [AccessPoint], spottedStairs: [Footprint] = []) -> VenueMap {
        let parts = rooms.map(RoomParts.init)
        let walls = parts.flatMap(\.walls) + recovered.flatMap(\.walls)
        let floorY = median(walls.map { $0.transform.translation.y - $0.dimensions.y / 2 })
            ?? median((parts + recovered).flatMap(\.floors).map(\.transform.translation.y))
            ?? -assumedPhoneHeight

        var footprints = parts.flatMap { flatten($0, floorY: floorY) }
        for part in recovered {
            for footprint in flatten(part, floorY: floorY)
            where !footprints.contains(where: { $0.kind == footprint.kind && overlaps($0, footprint, slack: recoveredSlack) }) {
                footprints.append(footprint)
            }
        }
        var map = VenueMap(floorY: floorY, footprints: footprints, points: [])
        for stairs in spottedStairs { add(spottedStairs: stairs, to: &map) }
        for point in points { add(point, to: &map) }
        return map
    }

    /// Adds stairs the camera spotted, unless RoomPlan already measured stairs there.
    static func add(spottedStairs stairs: Footprint, to map: inout VenueMap) {
        guard !map.footprints.contains(where: { $0.kind == .stairs && overlaps($0, stairs, slack: sameStairsSlack) }) else { return }
        var stairs = stairs
        stairs.bottom = map.floorY
        map.footprints.append(stairs)
    }

    /// Adds an access point. RoomPlan measures door openings precisely, so elevator pins move in front of
    /// the doors they belong to.
    static func add(_ point: AccessPoint, to map: inout VenueMap) {
        map.points.append(DoorSnap.snap(point, to: map.footprints, floorY: map.floorY))
    }

    /// Floors first so everything else draws over them, then walls, the openings in them, and what stands on the floor.
    private static func flatten(_ parts: RoomParts, floorY: Float) -> [Footprint] {
        var footprints: [Footprint] = []
        for floor in parts.floors {
            footprints.append(Footprint(floor: outline(of: floor), bottom: floor.transform.translation.y))
        }
        for wall in parts.walls {
            footprints.append(Footprint(kind: .wall, transform: wall.transform, dimensions: wall.dimensions, depth: wallThickness))
        }
        for door in parts.doors {
            footprints.append(Footprint(kind: .door, transform: door.transform, dimensions: door.dimensions, depth: wallThickness))
        }
        for opening in parts.openings {
            footprints.append(Footprint(kind: .opening, transform: opening.transform, dimensions: opening.dimensions, depth: wallThickness))
        }
        for window in parts.windows {
            footprints.append(Footprint(kind: .window, transform: window.transform, dimensions: window.dimensions, depth: wallThickness))
        }
        for object in parts.objects {
            guard object.transform.translation.y - object.dimensions.y / 2 < floorY + overheadClearance else { continue }
            let kind: Footprint.Kind = object.category == .stairs ? .stairs : .obstacle
            footprints.append(Footprint(kind: kind, transform: object.transform, dimensions: object.dimensions, furniture: furniture(for: object.category)))
        }
        return footprints
    }

    /// A floor surface's outline on the (x, z) plane. RoomPlan gives the polygon in the surface's own frame,
    /// whose x and y axes span the floor; without one, the surface's rectangle is used.
    private static func outline(of floor: CapturedRoom.Surface) -> [SIMD2<Float>] {
        let local: [SIMD3<Float>] = floor.polygonCorners.count >= 3
            ? floor.polygonCorners
            : [[-1, -1, 0], [1, -1, 0], [1, 1, 0], [-1, 1, 0]].map { $0 * SIMD3(floor.dimensions.x / 2, floor.dimensions.y / 2, 0) }
        return local.map { corner in
            let world = floor.transform * SIMD4(corner, 1)
            return SIMD2(world.x, world.z)
        }
    }

    /// Whether two footprints' areas come within `slack` of each other.
    private static func overlaps(_ a: Footprint, _ b: Footprint, slack: Float) -> Bool {
        let reach = (simd_length(a.size) + simd_length(b.size)) / 2 + slack
        guard simd_distance(a.center, b.center) < reach else { return false }
        // Close enough by bounding circles; confirm with a corner or center inside the other, grown by the slack.
        let inside = { (point: SIMD2<Float>, footprint: Footprint) -> Bool in
            let local = footprint.local(point)
            return abs(local.x) <= footprint.size.x / 2 + slack && abs(local.y) <= footprint.size.y / 2 + slack
        }
        return ([b.center] + b.corners).contains { inside($0, a) } || ([a.center] + a.corners).contains { inside($0, b) }
    }

    private static func furniture(for category: CapturedRoom.Object.Category) -> Footprint.Furniture? {
        switch category {
        case .table: .table
        case .chair: .chair
        case .sofa: .sofa
        case .bed: .bed
        case .storage: .storage
        case .refrigerator, .stove, .oven, .dishwasher, .washerDryer: .appliance
        case .sink: .sink
        case .toilet: .toilet
        case .bathtub: .bathtub
        case .television: .television
        case .fireplace: .fireplace
        case .stairs: nil
        @unknown default: nil
        }
    }

    private static func median(_ values: [Float]) -> Float? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }
}

/// The surfaces and objects of a room, in the pieces MapBuilder flattens.
struct RoomParts {
    var walls: [CapturedRoom.Surface] = []
    var doors: [CapturedRoom.Surface] = []
    var openings: [CapturedRoom.Surface] = []
    var windows: [CapturedRoom.Surface] = []
    var floors: [CapturedRoom.Surface] = []
    var objects: [CapturedRoom.Object] = []

    init() {}

    init(_ room: CapturedRoom) {
        walls = room.walls
        doors = room.doors
        openings = room.openings
        windows = room.windows
        floors = room.floors
        objects = room.objects
    }

    var isEmpty: Bool {
        walls.isEmpty && doors.isEmpty && openings.isEmpty && windows.isEmpty && floors.isEmpty && objects.isEmpty
    }

    var count: Int {
        walls.count + doors.count + openings.count + windows.count + floors.count + objects.count
    }
}

/// Everything RoomPlan reported while a section was live, by identifier, with the latest version of each.
///
/// RoomPlan models one room at a time. When the volunteer walks on into another room without starting a new
/// section, its processed result re-fits to where they ended up and drops the first room. The live updates
/// still described that room, so this remembers them, and `missing(from:)` is what the result left out.
struct RoomMemory {
    private var walls: [UUID: CapturedRoom.Surface] = [:]
    private var doors: [UUID: CapturedRoom.Surface] = [:]
    private var openings: [UUID: CapturedRoom.Surface] = [:]
    private var windows: [UUID: CapturedRoom.Surface] = [:]
    private var floors: [UUID: CapturedRoom.Surface] = [:]
    private var objects: [UUID: CapturedRoom.Object] = [:]

    var count: Int { walls.count + doors.count + openings.count + windows.count + floors.count + objects.count }

    mutating func remember(_ room: CapturedRoom) {
        for wall in room.walls { walls[wall.identifier] = wall }
        for door in room.doors { doors[door.identifier] = door }
        for opening in room.openings { openings[opening.identifier] = opening }
        for window in room.windows { windows[window.identifier] = window }
        for floor in room.floors { floors[floor.identifier] = floor }
        for object in room.objects { objects[object.identifier] = object }
    }

    /// What was seen live but isn't in the processed room.
    func missing(from room: CapturedRoom) -> RoomParts {
        var parts = RoomParts()
        parts.walls = Self.missing(walls, from: room.walls.map(\.identifier))
        parts.doors = Self.missing(doors, from: room.doors.map(\.identifier))
        parts.openings = Self.missing(openings, from: room.openings.map(\.identifier))
        parts.windows = Self.missing(windows, from: room.windows.map(\.identifier))
        parts.floors = Self.missing(floors, from: room.floors.map(\.identifier))
        parts.objects = Self.missing(objects, from: room.objects.map(\.identifier))
        return parts
    }

    private static func missing<Item>(_ seen: [UUID: Item], from kept: [UUID]) -> [Item] {
        let kept = Set(kept)
        return seen.filter { !kept.contains($0.key) }.map(\.value)
    }
}
