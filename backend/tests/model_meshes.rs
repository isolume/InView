use std::collections::BTreeMap;

use inview_backend::{
    capture::ScanBundle,
    geometry::Vec3,
    model_meshes::{ModelMesh, furniture_meshes},
    scene::{ProcessingOptions, process},
};

fn cross(a: Vec3, b: Vec3) -> Vec3 {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn sub(a: Vec3, b: Vec3) -> Vec3 {
    std::array::from_fn(|axis| a[axis] - b[axis])
}
fn dot(a: Vec3, b: Vec3) -> f64 {
    (0..3).map(|axis| a[axis] * b[axis]).sum()
}

fn check_mesh(mesh: &ModelMesh, size: Vec3) {
    assert_eq!(mesh.vertices.len(), mesh.normals.len());
    assert!(!mesh.triangles.is_empty(), "{} has no faces", mesh.name);
    for (vertex, normal) in mesh.vertices.iter().zip(&mesh.normals) {
        assert!(
            vertex
                .iter()
                .chain(normal)
                .all(|coordinate| coordinate.is_finite())
        );
        assert!((dot(*normal, *normal) - 1.0).abs() < 1e-10);
        for axis in 0..3 {
            assert!(
                vertex[axis].abs() <= size[axis] / 2.0 + 1e-10,
                "{} exceeds measured box: {vertex:?}",
                mesh.name
            );
        }
    }
    let mut volume = 0.0;
    let mut edges = BTreeMap::<([i64; 3], [i64; 3]), usize>::new();
    for &triangle in &mesh.triangles {
        assert!(
            triangle
                .into_iter()
                .all(|index| index < mesh.vertices.len())
        );
        let [a, b, c] = triangle.map(|index| mesh.vertices[index]);
        let face = cross(sub(b, a), sub(c, a));
        assert!(
            dot(face, face) > 1e-22,
            "{} has degenerate triangle {triangle:?}",
            mesh.name
        );
        let normals = std::array::from_fn(|axis| {
            triangle
                .iter()
                .map(|&index| mesh.normals[index][axis])
                .sum()
        });
        assert!(
            dot(face, normals) > 0.0,
            "{} has inverted winding",
            mesh.name
        );
        volume += dot(a, cross(b, c)) / 6.0;
        for pair in [[a, b], [b, c], [c, a]] {
            let mut pair =
                pair.map(|point| point.map(|coordinate| (coordinate * 1e9).round() as i64));
            pair.sort();
            *edges.entry((pair[0], pair[1])).or_default() += 1;
        }
    }
    assert!(volume > 0.0, "{} has inward faces or no volume", mesh.name);
    assert!(
        edges.values().all(|&count| count == 2),
        "{} has an open or nonmanifold geometric seam",
        mesh.name
    );
}

#[test]
fn sculpted_furniture_has_closed_outward_faces_and_fits_measured_dimensions() {
    for size in [
        [0.6, 0.9, 0.55],
        [2.2, 0.85, 0.95],
        [1.8, 0.75, 1.0],
        [0.1, 3.0, 0.3],
    ] {
        for key in [
            "chair_v2",
            "sofa_v2",
            "table_v2",
            "storage_v2",
            "bed_v2",
            "sink_v2",
            "plant_v2",
            "rug_v2",
            "bounds_v1",
        ] {
            let meshes = furniture_meshes(key, size);
            assert!(!meshes.is_empty());
            for mesh in &meshes {
                check_mesh(mesh, size);
            }
        }
    }
}

#[test]
fn architectural_furniture_uses_real_thicknesses_smooth_curves_and_small_clean_bevels() {
    let chair = furniture_meshes("chair_v2", [0.72, 0.95, 0.75]);
    let seat = chair
        .iter()
        .find(|mesh| mesh.name == "thin upholstered seat pad")
        .unwrap();
    let bounds = |mesh: &ModelMesh| -> [[f64; 2]; 3] {
        std::array::from_fn(|axis| {
            [
                mesh.vertices
                    .iter()
                    .map(|point| point[axis])
                    .fold(f64::INFINITY, f64::min),
                mesh.vertices
                    .iter()
                    .map(|point| point[axis])
                    .fold(f64::NEG_INFINITY, f64::max),
            ]
        })
    };
    let seat_bounds = bounds(seat);
    assert!(
        (seat_bounds[1][1] - seat_bounds[1][0] - 0.052).abs() < 1e-9,
        "Seat pad must be thin upholstery rather than an inflated pillow"
    );
    let back = chair
        .iter()
        .find(|mesh| mesh.name == "bent plywood back")
        .unwrap();
    let rear_at_center = back
        .vertices
        .iter()
        .filter(|point| point[0].abs() < 1e-9)
        .map(|point| point[2])
        .fold(f64::NEG_INFINITY, f64::max);
    let rear_at_edge = back
        .vertices
        .iter()
        .filter(|point| point[0].abs() > 0.30)
        .map(|point| point[2])
        .fold(f64::NEG_INFINITY, f64::max);
    assert!(rear_at_center - rear_at_edge > 0.064);
    let normals = back
        .normals
        .iter()
        .filter(|normal| normal[2] < -0.9)
        .map(|normal| (normal[0] * 1e9).round() as i64)
        .collect::<std::collections::BTreeSet<_>>();
    assert!(
        normals.len() > 40,
        "Bent plywood must have continuous, finely sampled surface normals"
    );
    let leg = chair
        .iter()
        .find(|mesh| mesh.name.starts_with("splayed hardwood leg "))
        .unwrap();
    let bottom = bounds(leg)[1][0];
    let top = bounds(leg)[1][1];
    let ring_bounds = |y: f64| {
        let xs: Vec<_> = leg
            .vertices
            .iter()
            .filter(|point| (point[1] - y).abs() < 1e-10)
            .map(|point| point[0])
            .collect();
        [
            xs.iter().copied().fold(f64::INFINITY, f64::min),
            xs.iter().copied().fold(f64::NEG_INFINITY, f64::max),
        ]
    };
    let upper = ring_bounds(top);
    let lower = ring_bounds(bottom);
    assert!(
        (upper[1] - upper[0] - 0.046).abs() < 1e-9,
        "Wood frame members use measured physical section widths"
    );
    assert!(upper[1] - upper[0] > lower[1] - lower[0]);
    assert!(((upper[0] + upper[1]) - (lower[0] + lower[1])).abs() > 0.07);
    let sofa = furniture_meshes("sofa_v2", [3.0, 0.95, 1.0]);
    assert_eq!(
        sofa.iter()
            .filter(|mesh| mesh.name.starts_with("aligned seat cushion "))
            .count(),
        3
    );
    assert_eq!(
        sofa.iter()
            .filter(|mesh| mesh.name.starts_with("aligned back cushion "))
            .count(),
        3
    );
    assert_eq!(
        sofa.iter()
            .filter(|mesh| mesh.name.starts_with("clean sofa arm "))
            .count(),
        2
    );
    assert!(
        !sofa
            .iter()
            .any(|mesh| mesh.name.starts_with("upholstery seam "))
    );
    let arm = sofa
        .iter()
        .find(|mesh| mesh.name.starts_with("clean sofa arm "))
        .unwrap();
    let arm_bounds = bounds(arm);
    assert!(
        (arm_bounds[0][1] - arm_bounds[0][0] - 0.115).abs() < 1e-9,
        "Arms must not expand with the full sofa width"
    );
    let cushion = sofa
        .iter()
        .find(|mesh| mesh.name == "aligned seat cushion 1")
        .unwrap();
    assert!((bounds(cushion)[1][1] - bounds(cushion)[1][0] - 0.112).abs() < 1e-9);
    assert!(
        cushion
            .normals
            .iter()
            .filter(|normal| normal[1] > 1.0 - 1e-10)
            .count()
            >= 4,
        "Broad cushion tops are planar with a small soft edge"
    );
    assert!(
        cushion.vertices.len() > 800,
        "Small curved transitions must be sampled densely enough for native close-ups"
    );
    let table = furniture_meshes("table_v2", [1.45, 0.42, 0.85]);
    assert_eq!(
        table
            .iter()
            .filter(|mesh| mesh.name.starts_with("square tapered leg "))
            .count(),
        4
    );
    assert_eq!(
        table.len(),
        5,
        "Table display keeps only slab and structural legs"
    );
    let tabletop = table
        .iter()
        .find(|mesh| mesh.name == "tabletop slab")
        .unwrap();
    let top_bounds = bounds(tabletop);
    assert!((top_bounds[1][1] - top_bounds[1][0] - 0.044).abs() < 1e-9);
    let edge_points = tabletop
        .vertices
        .iter()
        .filter(|point| (point[1] - (0.21 - 0.003)).abs() < 1e-9)
        .map(|point| {
            (
                (point[0] * 1e9).round() as i64,
                (point[2] * 1e9).round() as i64,
            )
        })
        .collect::<std::collections::BTreeSet<_>>();
    assert!(
        edge_points.len() >= 60,
        "Table corners must be smooth curves, not an octagonal clipped slab"
    );
}

#[test]
fn scene_emits_rebuilt_display_meshes_without_changing_source_obstacles() {
    let bundle: ScanBundle = serde_json::from_str(include_str!("../examples/scan.json")).unwrap();
    let scene = process(&bundle, ProcessingOptions::default()).unwrap();
    assert_eq!(scene.processing_version, 3);
    for (object, captured) in scene.objects.iter().zip(&bundle.objects) {
        assert_eq!(object.map_from_object, captured.map_from_object);
        assert_eq!(object.measured_dimensions_m, captured.dimensions_m);
        assert_eq!(
            object.obstacle_corners,
            captured.map_from_object.box_corners(captured.dimensions_m)
        );
        for mesh in &object.model_meshes {
            check_mesh(mesh, object.measured_dimensions_m);
        }
    }
    let fallback = scene
        .objects
        .iter()
        .find(|object| object.model_key == "bounds_v1")
        .unwrap();
    assert_eq!(fallback.model_meshes.len(), 1);
    assert_eq!(fallback.model_meshes[0].name, "measured unknown object");
    let encoded = serde_json::to_value(&scene).unwrap();
    assert!(encoded["objects"][0]["model_meshes"][0]["vertices"].is_array());
    assert!(encoded["objects"][0]["model_meshes"][0]["normals"].is_array());
}

#[test]
fn templates_are_deterministic_and_extreme_positive_sizes_keep_finite_normals() {
    let first = serde_json::to_value(furniture_meshes("sofa_v2", [2.2, 0.85, 0.95])).unwrap();
    let second = serde_json::to_value(furniture_meshes("sofa_v2", [2.2, 0.85, 0.95])).unwrap();
    assert_eq!(first, second);
    for mesh in furniture_meshes("table_v2", [f64::MIN_POSITIVE / 2.0, 1.0, 10.0]) {
        assert!(
            mesh.vertices
                .iter()
                .flatten()
                .all(|value| value.is_finite())
        );
        for normal in &mesh.normals {
            assert!(normal.iter().all(|value| value.is_finite()));
            assert!((dot(*normal, *normal) - 1.0).abs() < 1e-10);
        }
    }
}

#[test]
fn supplied_categories_select_templates_without_inserting_objects_or_changing_source_labels() {
    let mut bundle: ScanBundle =
        serde_json::from_str(include_str!("../examples/scan.json")).unwrap();
    bundle.objects.truncate(1);
    for (category, key) in [
        ("chair", "chair_v2"),
        ("sofa", "sofa_v2"),
        ("table", "table_v2"),
        ("storage", "storage_v2"),
        ("cabinet", "storage_v2"),
        ("bed", "bed_v2"),
        ("sink", "sink_v2"),
        ("plant", "plant_v2"),
        ("rug", "rug_v2"),
        ("unsupported", "bounds_v1"),
    ] {
        bundle.objects[0].category = category.into();
        let scene = process(&bundle, ProcessingOptions::default()).unwrap();
        assert_eq!(
            scene.objects.len(),
            1,
            "A category must not synthesize extra capture objects"
        );
        assert_eq!(scene.objects[0].source_category, category);
        assert_eq!(scene.objects[0].model_key, key);
        assert_eq!(
            scene.objects[0].obstacle_corners,
            bundle.objects[0]
                .map_from_object
                .box_corners(bundle.objects[0].dimensions_m)
        );
    }
    bundle.objects[0].category = "plant".into();
    bundle.objects[0].confidence = inview_backend::capture::Confidence::Low;
    let scene = process(&bundle, ProcessingOptions::default()).unwrap();
    assert_eq!(scene.objects[0].model_key, "bounds_v1");
    assert_eq!(scene.objects[0].model_meshes.len(), 1);
}

#[test]
fn catalog_details_are_geometry_including_hollow_basin_and_closed_planter_leaves() {
    let console = furniture_meshes("storage_v2", [2.0, 0.85, 0.45]);
    assert_eq!(
        console
            .iter()
            .filter(|mesh| mesh.name.starts_with("inset cabinet door"))
            .count(),
        2
    );
    assert_eq!(
        console
            .iter()
            .filter(|mesh| mesh.name.starts_with("console oak foot"))
            .count(),
        4
    );
    let sink = furniture_meshes("sink_v2", [1.0; 3]);
    let basin = sink
        .iter()
        .find(|mesh| mesh.name == "recessed ceramic basin")
        .unwrap();
    assert!(
        basin.vertices.iter().any(|point| point[0].abs() < 1e-10
            && (point[2] + 0.055).abs() < 1e-10
            && (point[1] - 0.234).abs() < 1e-10),
        "Inner bowl floor must be recessed below the rim"
    );
    assert!(
        basin
            .vertices
            .iter()
            .any(|point| (point[1] - 0.48).abs() < 1e-10)
    );
    let plant = furniture_meshes("plant_v2", [0.6, 1.15, 0.6]);
    assert_eq!(
        plant
            .iter()
            .filter(|mesh| mesh.name.starts_with("sculpted leaf "))
            .count(),
        8
    );
    for mesh in &plant {
        check_mesh(mesh, [0.6, 1.15, 0.6]);
    }
    let rug = furniture_meshes("rug_v2", [3.0, 0.012, 2.4]);
    for mesh in &rug {
        check_mesh(mesh, [3.0, 0.012, 2.4]);
    }
}

#[test]
fn all_display_models_use_a_quiet_neutral_palette_without_incidental_trim() {
    for key in [
        "chair_v2",
        "sofa_v2",
        "table_v2",
        "storage_v2",
        "bed_v2",
        "sink_v2",
        "plant_v2",
        "rug_v2",
        "bounds_v1",
    ] {
        for mesh in furniture_meshes(key, [1.0; 3]) {
            let rgb: Vec<_> = [1, 3, 5]
                .into_iter()
                .map(|offset| u8::from_str_radix(&mesh.color[offset..offset + 2], 16).unwrap())
                .collect();
            assert!(
                rgb[0] <= rgb[1] && rgb[1] <= rgb[2] && rgb[2] - rgb[0] <= 22,
                "{} should be off-white or cool neutral gray, got {}",
                mesh.name,
                mesh.color
            );
            assert!(
                rgb[0] >= 175,
                "Scenery should stay quiet rather than high contrast"
            );
        }
    }
    assert_eq!(furniture_meshes("rug_v2", [1.0; 3]).len(), 1);
    assert!(
        !furniture_meshes("storage_v2", [1.0; 3])
            .iter()
            .any(|mesh| mesh.name.starts_with("cabinet pull"))
    );
}
