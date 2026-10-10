import Foundation

/// Display templates based on the test-space photos. Captured poses and routing
/// bounds remain authoritative; the catalogue only supplies an item's silhouette.
public enum FurnitureModelCatalog {
    public static func modelKey(category: String, dimensions: [Float]) -> String? {
        guard dimensions.count == 3, dimensions.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let ratio = Double(dimensions[0]) / Double(dimensions[2])
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if supportedKeys.contains(category) { return category }
        switch category {
        case "chair", "armchair", "lounge_chair": return "lounge_chair_v1"
        case "sofa":
            return dimensions[1] <= 0.6 && ratio >= 2.8 ? "bench_v1" : "modular_sofa_v1"
        case "modular_sofa", "loveseat": return "modular_sofa_v1"
        case "table":
            return dimensions[1] <= 0.62 && (0.8...1.25).contains(ratio) ? "drum_table_v1" : "folding_table_v1"
        case "drum_table", "round_table", "ottoman": return "drum_table_v1"
        case "charging_stand": return "charging_stand_v1"
        case "lectern", "podium": return "lectern_v1"
        case "folding_table": return "folding_table_v1"
        case "sign_stand": return "sign_stand_v1"
        case "floor_sign", "caution_sign": return "floor_sign_v1"
        case "waste_bin", "trash_bin": return "waste_bin_v1"
        case "open_bin": return "open_bin_v1"
        case "bench": return "bench_v1"
        case "square_planter": return "square_planter_v1"
        case "railing": return "railing_v1"
        default: return nil
        }
    }

    /// The canonical mesh is resized in its local frame, including the inverse
    /// transpose for normals. Its center and front direction never change.
    public static func meshes(for key: String, dimensions: [Float]) throws -> [SceneModelMesh] {
        guard dimensions.count == 3, dimensions.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw SceneValidationError.invalid("This item's size could not be displayed.")
        }
        guard supportedKeys.contains(key) else { return [] }
        guard let model = try models.get()[key] else { return [] }
        let scale = zip(dimensions, model.dimensionsM).map { Double($0) / Double($1) }
        return try model.meshes.map { mesh in
            try Task.checkCancellation()
            let vertices = mesh.vertices.map { vertex in
                (0..<3).map { Float(Double(vertex[$0]) * scale[$0]) }
            }
            let normals = mesh.normals.map { normal in
                let transformed = (0..<3).map { Double(normal[$0]) / scale[$0] }
                let largest = transformed.map(abs).max() ?? 1
                let relative = transformed.map { $0 / largest }
                let length = sqrt(relative.reduce(0) { $0 + $1 * $1 })
                return relative.map { Float($0 / length) }
            }
            return SceneModelMesh(name: mesh.name, vertices: vertices, normals: normals,
                                  triangles: mesh.triangles, color: mesh.color)
        }
    }

    static func fallbackParts(for meshes: [SceneModelMesh]) -> [SceneModelPart] {
        meshes.compactMap { mesh in
            guard !mesh.vertices.isEmpty else { return nil }
            let minimum = (0..<3).map { axis in mesh.vertices.map { $0[axis] }.min()! }
            let maximum = (0..<3).map { axis in mesh.vertices.map { $0[axis] }.max()! }
            return SceneModelPart(center: zip(minimum, maximum).map { ($0 + $1) / 2 },
                                  dimensionsM: zip(minimum, maximum).map { $1 - $0 }, color: "#C4C8CA")
        }
    }

    private struct Catalog: Decodable {
        let version: Int
        let models: [Model]
    }

    private static let supportedKeys: Set<String> = [
        "lounge_chair_v1", "modular_sofa_v1", "drum_table_v1", "charging_stand_v1",
        "lectern_v1", "folding_table_v1", "sign_stand_v1", "waste_bin_v1", "open_bin_v1",
        "bench_v1", "square_planter_v1", "railing_v1", "floor_sign_v1"
    ]

    private struct Model: Decodable {
        let key: String
        let dimensionsM: [Float]
        let meshes: [SceneModelMesh]
        enum CodingKeys: String, CodingKey { case key, dimensionsM = "dimensions_m", meshes }
    }

    private static let models: Result<[String: Model], Error> = Result {
        guard let url = Bundle.module.url(forResource: "photo-furniture", withExtension: "json") else {
            throw SceneValidationError.invalid("The furniture models could not be loaded.")
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        guard catalog.version == 1 else {
            throw SceneValidationError.invalid("The furniture models could not be loaded.")
        }
        var result: [String: Model] = [:]
        for model in catalog.models {
            guard model.dimensionsM.count == 3,
                  model.dimensionsM.allSatisfy({ $0.isFinite && $0 > 0 }),
                  !model.meshes.isEmpty,
                  model.meshes.allSatisfy({ mesh in
                      !mesh.vertices.isEmpty && mesh.normals.count == mesh.vertices.count
                          && mesh.vertices.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) })
                          && mesh.normals.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) })
                  }) else {
                throw SceneValidationError.invalid("The furniture models could not be loaded.")
            }
            // Large and small drums share one template; keep the first canonical size.
            if result[model.key] == nil { result[model.key] = model }
        }
        return result
    }
}
