import AccessCore
import RealityKit
import UIKit

/// Builds a 3D model of a scanned floor the way an architect's cutaway model looks: each room's floor as a
/// warm slab, walls cut down with a darker cap, door frames and glazing in the walls, furniture as
/// recognizable shapes (legs and tops, seats and backs, steps), and markers for elevators and ramps.
@MainActor
enum VenueModelBuilder {
    /// Walls are cut down to this height so you can see into the rooms from above.
    static let cutawayWallHeight: Float = 1.1
    private static let leg: Float = 0.05
    private static let slabThickness: Float = 0.05

    private static let wallMaterial = SimpleMaterial(color: UIColor(white: 0.93, alpha: 1), roughness: 0.85, isMetallic: false)
    private static let wallCapMaterial = SimpleMaterial(color: UIColor(white: 0.35, alpha: 1), roughness: 0.6, isMetallic: false)
    private static let groundMaterial = SimpleMaterial(color: UIColor(white: 0.9, alpha: 1), roughness: 1, isMetallic: false)
    private static let floorMaterial = SimpleMaterial(color: UIColor(red: 0.93, green: 0.88, blue: 0.8, alpha: 1), roughness: 0.9, isMetallic: false)
    private static let glassMaterial = SimpleMaterial(color: UIColor(red: 0.6, green: 0.82, blue: 0.95, alpha: 0.55), roughness: 0.1, isMetallic: false)
    private static let woodMaterial = SimpleMaterial(color: UIColor(red: 0.76, green: 0.64, blue: 0.5, alpha: 1), roughness: 0.8, isMetallic: false)
    private static let fabricMaterial = SimpleMaterial(color: UIColor(red: 0.55, green: 0.6, blue: 0.68, alpha: 1), roughness: 1, isMetallic: false)
    private static let whiteMaterial = SimpleMaterial(color: UIColor(white: 0.98, alpha: 1), roughness: 0.4, isMetallic: false)
    private static let applianceMaterial = SimpleMaterial(color: UIColor(white: 0.75, alpha: 1), roughness: 0.3, isMetallic: true)
    private static let darkMaterial = SimpleMaterial(color: UIColor(white: 0.15, alpha: 1), roughness: 0.3, isMetallic: false)
    private static let stairsMaterial = SimpleMaterial(color: UIColor(red: 0.93, green: 0.35, blue: 0.33, alpha: 1), roughness: 0.8, isMetallic: false)

    static func build(_ map: VenueMap) -> Entity {
        let root = Entity()
        root.addChild(ground(for: map))
        let floors = map.footprints.filter { $0.kind == .floor }
        for floor in floors {
            if let slab = slab(for: floor, floorY: map.floorY) { root.addChild(slab) }
        }
        for footprint in map.footprints where footprint.kind != .floor {
            let entity = shape(for: footprint, floorY: map.floorY)
            // Everything stands on the slab, except walls and openings, which sit at their measured base.
            let inWall = footprint.kind == .wall || footprint.kind == .door || footprint.kind == .opening || footprint.kind == .window
            let base = inWall ? footprint.bottom ?? map.floorY : map.floorY
            entity.position = SIMD3(footprint.center.x, max(base, map.floorY), footprint.center.y)
            // Footprint yaw turns +x toward +z; RealityKit's positive angle turns the other way.
            entity.orientation = simd_quatf(angle: -footprint.yaw, axis: [0, 1, 0])
            root.addChild(entity)
        }
        for point in map.points {
            root.addChild(marker(for: point, floorY: map.floorY))
        }
        return root
    }

    /// A pale base plate under everything, a little larger than the scan.
    private static func ground(for map: VenueMap) -> Entity {
        var lower = SIMD2<Float>(-0.5, -0.5), upper = SIMD2<Float>(0.5, 0.5)
        for corner in map.footprints.flatMap(\.corners) + map.points.map(\.floorPoint) {
            lower = simd_min(lower, corner)
            upper = simd_max(upper, corner)
        }
        let size = upper - lower + 1.2
        let middle = (lower + upper) / 2
        let ground = ModelEntity(mesh: .generateBox(width: size.x, height: 0.04, depth: size.y, cornerRadius: 0.02), materials: [groundMaterial])
        ground.position = SIMD3(middle.x, map.floorY - slabThickness - 0.02, middle.y)
        return ground
    }

    /// One room's floor as a slab in the shape RoomPlan measured.
    private static func slab(for floor: Footprint, floorY: Float) -> Entity? {
        let outline = floor.corners
        let triangles = Polygon.triangulate(outline)
        guard !triangles.isEmpty else { return nil }
        let top = outline.map { SIMD3($0.x, 0, $0.y) }
        let bottom = outline.map { SIMD3($0.x, -slabThickness, $0.y) }
        var positions = top + bottom
        var normals = Array(repeating: SIMD3<Float>(0, 1, 0), count: top.count) + Array(repeating: SIMD3<Float>(0, -1, 0), count: bottom.count)
        var indices: [UInt32] = []
        // Top face both ways round, so it shows whatever the winding, and the underside too.
        for i in stride(from: 0, to: triangles.count, by: 3) {
            let a = UInt32(triangles[i]), b = UInt32(triangles[i + 1]), c = UInt32(triangles[i + 2])
            indices += [a, b, c, a, c, b]
            let n = UInt32(top.count)
            indices += [n + a, n + c, n + b]
        }
        // Side faces, with their own vertices so their normals are flat.
        for (i, corner) in outline.enumerated() {
            let next = outline[(i + 1) % outline.count]
            let edge = next - corner
            guard simd_length(edge) > 1e-4 else { continue }
            let normal = simd_normalize(SIMD3(edge.y, 0, -edge.x))
            let base = UInt32(positions.count)
            positions += [SIMD3(corner.x, 0, corner.y), SIMD3(next.x, 0, next.y), SIMD3(next.x, -slabThickness, next.y), SIMD3(corner.x, -slabThickness, corner.y)]
            normals += Array(repeating: normal, count: 4)
            indices += [base, base + 1, base + 2, base, base + 2, base + 3, base, base + 2, base + 1, base, base + 3, base + 2]
        }
        var descriptor = MeshDescriptor(name: "floor")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
        let slab = ModelEntity(mesh: mesh, materials: [floorMaterial])
        slab.position.y = floorY
        return slab
    }

    /// The footprint's shape in its own axes: x along `size.x`, z along `size.y`, y up from its bottom.
    private static func shape(for footprint: Footprint, floorY: Float) -> Entity {
        let w = footprint.size.x, d = footprint.size.y
        let h = footprint.height ?? 0.8
        switch footprint.kind {
        case .wall:
            let height = min(footprint.height ?? 2.4, cutawayWallHeight)
            let wall = box(w, height, 0.1, wallMaterial)
            // A darker cap along the cut edge, the way model walls are finished.
            wall.addChild(box(w, 0.02, 0.12, wallCapMaterial, at: [0, height / 2 - 0.01, 0]))
            return wall
        case .door, .opening:
            let wide = w >= OccupancyGrid.minimumDoorWidth
            let color = Theme.uiColor(for: wide ? .good : .warning)
            return doorway(width: w, material: SimpleMaterial(color: color, roughness: 0.5, isMetallic: false), isDoor: footprint.kind == .door)
        case .window:
            // Glazing from the sill up, but never above the cut edge of the wall.
            let sill = max(0, (footprint.bottom ?? floorY) - floorY)
            let height = max(0.1, min(footprint.height ?? 1.0, cutawayWallHeight - sill))
            let frame = Entity()
            frame.addChild(box(w, height, 0.04, glassMaterial))
            frame.addChild(box(w, 0.03, 0.08, wallCapMaterial, at: [0, height - 0.03, 0]))
            return frame
        case .stairs:
            return stairs(width: w, depth: d, height: min(max(footprint.height ?? 0.9, 0.4), 1.5))
        case .obstacle:
            return furniture(footprint.furniture, w: w, d: d, h: h)
        case .floor:
            return Entity()
        }
    }

    /// Two posts and a lintel in the clearance color; doors also get a leaf standing ajar.
    private static func doorway(width: Float, material: SimpleMaterial, isDoor: Bool) -> Entity {
        let entity = Entity()
        let height = cutawayWallHeight + 0.02
        for side: Float in [-1, 1] {
            entity.addChild(box(0.06, height, 0.14, material, at: [side * (width / 2 - 0.03), 0, 0]))
        }
        entity.addChild(box(width, 0.06, 0.14, material, at: [0, height - 0.06, 0]))
        if isDoor {
            let leaf = box(0.04, height - 0.08, min(width - 0.12, 0.9), material, at: [-width / 2 + 0.08, 0, 0])
            leaf.position.z = (min(width - 0.12, 0.9)) / 2 * 0.7
            leaf.orientation = simd_quatf(angle: -.pi / 4, axis: [0, 1, 0])
            entity.addChild(leaf)
        }
        return entity
    }

    /// Steps rising along +z, the footprint's y axis.
    private static func stairs(width: Float, depth: Float, height: Float) -> Entity {
        let entity = Entity()
        let count = max(3, Int((height / 0.18).rounded()))
        let riser = height / Float(count), tread = depth / Float(count)
        for step in 0..<count {
            let rise = riser * Float(step + 1)
            entity.addChild(box(width, rise, tread, stairsMaterial, at: [0, 0, -depth / 2 + tread * (Float(step) + 0.5)]))
        }
        return entity
    }

    private static func furniture(_ kind: Footprint.Furniture?, w: Float, d: Float, h: Float) -> Entity {
        let entity = Entity()
        switch kind {
        case .table:
            entity.addChild(box(w, 0.04, d, woodMaterial, at: [0, h - 0.04, 0], cornerRadius: 0.015))
            addLegs(to: entity, w: w, d: d, height: h - 0.04, material: woodMaterial)
        case .chair:
            let seat = min(0.46, h * 0.55)
            entity.addChild(box(w, 0.05, d, fabricMaterial, at: [0, seat - 0.05, 0], cornerRadius: 0.02))
            // Backrest along the -z edge.
            entity.addChild(box(w, h - seat, 0.05, fabricMaterial, at: [0, seat, -d / 2 + 0.025], cornerRadius: 0.02))
            addLegs(to: entity, w: w, d: d, height: seat - 0.05, material: darkMaterial)
        case .sofa:
            let seat = min(0.45, h * 0.6)
            entity.addChild(box(w, seat, d, fabricMaterial, cornerRadius: 0.05))
            entity.addChild(box(w, h - seat, 0.2, fabricMaterial, at: [0, seat, -d / 2 + 0.1], cornerRadius: 0.05))
            for side: Float in [-1, 1] {
                entity.addChild(box(0.18, 0.2, d, fabricMaterial, at: [side * (w / 2 - 0.09), seat, 0], cornerRadius: 0.05))
            }
        case .bed:
            entity.addChild(box(w, min(0.5, h), d, whiteMaterial, cornerRadius: 0.06))
            // Headboard at the end of the longer side.
            if d >= w {
                entity.addChild(box(w, 1.0, 0.08, woodMaterial, at: [0, 0, -d / 2 + 0.04]))
            } else {
                entity.addChild(box(0.08, 1.0, d, woodMaterial, at: [-w / 2 + 0.04, 0, 0]))
            }
        case .sink, .toilet, .bathtub:
            entity.addChild(box(w, h, d, whiteMaterial, cornerRadius: min(w, d, h) * 0.3))
        case .television:
            entity.addChild(box(w, h, min(d, 0.06), darkMaterial, cornerRadius: 0.01))
        case .appliance:
            entity.addChild(box(w, h, d, applianceMaterial, cornerRadius: 0.02))
        case .storage, .fireplace, nil:
            entity.addChild(box(w, h, d, woodMaterial, cornerRadius: 0.02))
        }
        return entity
    }

    private static func addLegs(to entity: Entity, w: Float, d: Float, height: Float, material: SimpleMaterial) {
        guard height > 0 else { return }
        for x: Float in [-1, 1] {
            for z: Float in [-1, 1] {
                let position = SIMD3(x * (w / 2 - leg), 0, z * (d / 2 - leg))
                entity.addChild(box(leg, height, leg, material, at: position))
            }
        }
    }

    private static func marker(for point: AccessPoint, floorY: Float) -> Entity {
        let entity = Entity()
        entity.position = SIMD3(point.position.x, floorY, point.position.z)
        let color = point.isTooSteep ? Theme.uiColor(for: .warning) : point.signCategory?.uiTint ?? point.kind.uiTint
        let material = SimpleMaterial(color: color, roughness: 0.4, isMetallic: false)
        switch point.kind {
        case .elevator:
            entity.addChild(box(0.9, 2.1, 0.15, material, cornerRadius: 0.04))
        case .ramp:
            entity.addChild(ModelEntity(mesh: wedge(width: 1.0, length: 1.6, slopeDegrees: point.slopeDegrees ?? 4), materials: [material]))
        case .destination:
            entity.addChild(box(0.06, 1.2, 0.06, material))
            entity.addChild(box(0.45, 0.28, 0.04, material, at: SIMD3(0.225, 0.9, 0)))
        }
        let label = BillboardLabel(fontSize: 0.16)
        label.set(point.title, background: color)
        label.entity.position.y = 2.5
        entity.addChild(label.entity)
        return entity
    }

    /// A box sitting on y = 0 (or on `position.y`), centered in x and z.
    private static func box(_ w: Float, _ h: Float, _ d: Float, _ material: SimpleMaterial, at position: SIMD3<Float> = .zero, cornerRadius: Float = 0) -> ModelEntity {
        let entity = ModelEntity(mesh: .generateBox(width: w, height: h, depth: d, cornerRadius: min(cornerRadius, min(w, h, d) / 2)), materials: [material])
        entity.position = position + SIMD3(0, h / 2, 0)
        return entity
    }

    /// A ramp: a sloped surface rising along +z.
    private static func wedge(width: Float, length: Float, slopeDegrees: Float) -> MeshResource {
        let rise = tan(slopeDegrees * .pi / 180) * length
        let x = width / 2, z = length / 2
        let a = SIMD3<Float>(-x, 0, -z), b = SIMD3<Float>(x, 0, -z), c = SIMD3<Float>(x, 0, z), d = SIMD3<Float>(-x, 0, z)
        let e = SIMD3<Float>(-x, rise, z), f = SIMD3<Float>(x, rise, z)
        let faces: [[SIMD3<Float>]] = [[a, b, f, e], [d, c, f, e], [a, b, c, d], [a, d, e], [b, c, f]]

        // Every face gets its own vertices and is emitted both ways round, so it lights correctly
        // from either side without relying on face culling.
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for face in faces {
            let normal = simd_normalize(simd_cross(face[1] - face[0], face[2] - face[0]))
            for (side, sideNormal) in [(face, normal), (Array(face.reversed()), -normal)] {
                let base = UInt32(positions.count)
                positions += side
                normals += Array(repeating: sideNormal, count: side.count)
                for i in 1..<(side.count - 1) {
                    indices += [base, base + UInt32(i), base + UInt32(i + 1)]
                }
            }
        }
        var descriptor = MeshDescriptor(name: "ramp")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try! MeshResource.generate(from: [descriptor])
    }
}
