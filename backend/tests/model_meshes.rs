use std::collections::BTreeMap;

use inview_backend::{
    capture::ScanBundle,
    geometry::Vec3,
    model_meshes::{ModelMesh, furniture_meshes, photo_model_key},
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
        ("chair", "lounge_chair_v1"),
        ("sofa", "modular_sofa_v1"),
        ("table", "folding_table_v1"),
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

const PHOTO_KEYS: [&str; 13] = [
    "lounge_chair_v1",
    "modular_sofa_v1",
    "drum_table_v1",
    "charging_stand_v1",
    "lectern_v1",
    "folding_table_v1",
    "sign_stand_v1",
    "waste_bin_v1",
    "open_bin_v1",
    "bench_v1",
    "square_planter_v1",
    "railing_v1",
    "floor_sign_v1",
];

#[test]
fn photo_furniture_is_closed_outward_and_bounded_at_every_measured_size() {
    for key in PHOTO_KEYS {
        for size in [
            [1.0; 3],
            [0.6, 0.9, 0.55],
            [2.8, 0.48, 0.52],
            [0.1, 3.0, 0.3],
        ] {
            let meshes = furniture_meshes(key, size);
            assert!(!meshes.is_empty(), "{key} must contain display geometry");
            for mesh in &meshes {
                check_mesh(mesh, size);
            }
        }
        for size in [[f64::MIN_POSITIVE / 2.0, 1.0, 10.0], [1e100, 1e-100, 1.0]] {
            for mesh in furniture_meshes(key, size) {
                assert!(
                    mesh.vertices
                        .iter()
                        .flatten()
                        .all(|coordinate| coordinate.is_finite())
                );
                assert!(
                    mesh.normals
                        .iter()
                        .all(|normal| normal.iter().all(|v| v.is_finite())
                            && (dot(*normal, *normal) - 1.0).abs() < 1e-10)
                );
            }
        }
    }
}

#[test]
fn photo_category_selection_uses_shape_and_preserves_explicit_labels() {
    assert_eq!(
        photo_model_key(" Chair ", [0.9, 0.8, 0.9]),
        Some("lounge_chair_v1")
    );
    assert_eq!(photo_model_key("sofa", [3.0, 0.48, 0.5]), Some("bench_v1"));
    assert_eq!(
        photo_model_key("sofa", [2.3, 0.85, 0.9]),
        Some("modular_sofa_v1")
    );
    assert_eq!(
        photo_model_key("table", [1.25, 0.42, 1.25]),
        Some("drum_table_v1")
    );
    assert_eq!(
        photo_model_key("table", [0.54, 0.5, 0.56]),
        Some("drum_table_v1")
    );
    assert_eq!(
        photo_model_key("table", [1.6, 0.74, 0.7]),
        Some("folding_table_v1")
    );
    for (category, key) in [
        ("armchair", "lounge_chair_v1"),
        ("lounge_chair", "lounge_chair_v1"),
        ("modular_sofa", "modular_sofa_v1"),
        ("loveseat", "modular_sofa_v1"),
        ("round_table", "drum_table_v1"),
        ("ottoman", "drum_table_v1"),
        ("charging_stand", "charging_stand_v1"),
        ("podium", "lectern_v1"),
        ("folding_table", "folding_table_v1"),
        ("sign_stand", "sign_stand_v1"),
        ("trash_bin", "waste_bin_v1"),
        ("open_bin", "open_bin_v1"),
        ("bench", "bench_v1"),
        ("square_planter", "square_planter_v1"),
        ("railing", "railing_v1"),
        ("caution_sign", "floor_sign_v1"),
    ] {
        assert_eq!(photo_model_key(category, [1.0; 3]), Some(key));
    }
    assert_eq!(photo_model_key("plant", [1.0; 3]), None);
    assert_eq!(photo_model_key("unrecognized_fixture", [1.0; 3]), None);
}
