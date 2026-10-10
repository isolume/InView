use std::{
    fs,
    io::Write,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use inview_backend::{
    AppState, app,
    capture::ScanBundle,
    streaming::{StreamError, StreamStore},
};
use serde_json::{Value, json};
use tower::ServiceExt;

const ID: &str = "61cd3d3c-1a2f-43de-a7b9-11d4c85ec3e6";
const IDENTITY: [f64; 16] = [
    1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
];
static NEXT_TEST: AtomicU64 = AtomicU64::new(0);

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "inview-stream-test-{}-{}",
            std::process::id(),
            NEXT_TEST.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn manifest() -> Value {
    json!({"schema_version":1,"id":ID,"map_id":"building","floor_id":"ground",
        "coordinates":{"units":"meters","up_axis":"y","handedness":"right"}})
}

fn chunk(sequence: usize) -> Value {
    json!({"sequence":sequence,"color_jpeg":STANDARD.encode(include_bytes!("fixtures/stream-color.jpg")),
        "frame":{"id":format!("frame-{sequence}"),"timestamp_seconds":sequence as f64 + 1.,
            "pixel_orientation":"sensor_native","map_from_camera":IDENTITY,
            "camera":{"image_width":4,"image_height":4,"fx":20.,"fy":20.,"cx":1.5,"cy":1.5},
            "depth":{"width":4,"height":4,"values_m":vec![2.;16],"confidence":vec![2;16]}}})
}

fn corner_chunk(sequence: usize) -> Value {
    let mut value = chunk(sequence);
    value["color_jpeg"] = json!(STANDARD.encode(include_bytes!("fixtures/stream-texture.jpg")));
    value["frame"]["camera"] =
        json!({"image_width":24,"image_height":18,"fx":16.,"fy":16.,"cx":11.5,"cy":8.5});
    let depths: Vec<f64> = (0..18)
        .flat_map(|y| {
            (0..24).map(move |x| {
                let dx = (x as f64 - 11.5) / 16.;
                let dy = -(y as f64 - 8.5) / 16.;
                let mut depth = 3_f64; // Observed back wall, floor, and side wall give 3D constraint normals.
                if dx > 0. {
                    depth = depth.min(0.6 / dx);
                }
                if dy < 0. {
                    depth = depth.min(-0.5 / dy);
                }
                depth
            })
        })
        .collect();
    value["frame"]["depth"] =
        json!({"width":24,"height":18,"values_m":depths,"confidence":vec![2;24*18]});
    value
}

fn finish_one(value: Value) -> Value {
    let store = StreamStore::default();
    store.create(manifest()).unwrap();
    store.append(ID, 0, value).unwrap();
    store.finish(ID, 1).unwrap();
    serde_json::to_value(store.reconstruct(ID).unwrap()).unwrap()
}

#[test]
fn measured_plane_is_a_mesh_with_original_arkit_negative_z_axes() {
    let result = finish_one(chunk(0));
    let mesh = &result["scene"]["meshes"][0];
    assert_eq!(mesh["vertices"].as_array().unwrap().len(), 16);
    assert_eq!(mesh["triangles"].as_array().unwrap().len(), 18);
    for point in mesh["vertices"].as_array().unwrap() {
        assert_eq!(point[2], -2.);
    }
    assert!(
        mesh["vertices"]
            .as_array()
            .unwrap()
            .contains(&json!([-0.15, 0.15, -2.]))
    );
    assert!(result["scene"]["surfaces"].as_array().unwrap().is_empty());
    assert!(result["scene"]["objects"].as_array().unwrap().is_empty());
    assert_eq!(
        result["capture"]["meshes"][0]["map_from_anchor"],
        json!(IDENTITY)
    );
    assert_eq!(result["capture"]["frames"], json!([]));
    let source: ScanBundle = serde_json::from_value(result["capture"].clone()).unwrap();
    source.validate().unwrap();
    assert_eq!(result["capture"]["meshes"][0]["vertices"], mesh["vertices"]);
    assert_eq!(result["capture"]["metadata"]["alignment_refined"], false);
}

#[test]
fn repeated_observations_weld_without_double_faces_and_rigid_poses_remain_aligned() {
    let store = StreamStore::default();
    store.create(manifest()).unwrap();
    store.append(ID, 0, chunk(0)).unwrap();
    let mut rotated = chunk(1);
    rotated["frame"]["map_from_camera"] = json!([
        0., 0., -1., 0., 0., 1., 0., 0., 1., 0., 0., 0., 10., 1., -4., 1.
    ]);
    store.append(ID, 1, rotated).unwrap();
    store.append(ID, 2, chunk(2)).unwrap();
    store.finish(ID, 3).unwrap();
    let first = serde_json::to_value(store.reconstruct(ID).unwrap()).unwrap();
    let second = serde_json::to_value(store.reconstruct(ID).unwrap()).unwrap();
    assert_eq!(first, second);
    let mesh = &first["scene"]["meshes"][0];
    assert_eq!(mesh["vertices"].as_array().unwrap().len(), 32);
    assert_eq!(mesh["triangles"].as_array().unwrap().len(), 36);
    assert!(
        mesh["vertices"]
            .as_array()
            .unwrap()
            .contains(&json!([8., 1.15, -3.85]))
    );
}

#[test]
fn verified_loop_corrects_depth_and_latest_observed_labels_in_one_map_frame() {
    let store = StreamStore::default();
    store.create(manifest()).unwrap();
    let positions = [
        [0., 0., 0.],
        [1., 0., 0.],
        [2., 0., 0.],
        [2., 0., 1.],
        [2., 0., 2.],
        [1., 0., 2.],
        [0., 0., 2.],
        [0., 0., 1.],
        [0.25, 0., 0.],
    ];
    let angle = 4_f64.to_radians();
    for (sequence, position) in positions.into_iter().enumerate() {
        let mut value = corner_chunk(sequence);
        let mut pose = IDENTITY;
        pose[12] = position[0];
        pose[13] = position[1];
        pose[14] = position[2];
        if sequence == 0 {
            // Delta labels belong to their measurement frame, not to the final upload's pose.
            value["objects"] = json!([
                {"id":"observed-obstacle","category":"unrecognized_fixture","map_from_object":IDENTITY,
                    "dimensions_m":[0.3,0.5,0.6],"confidence":"high"},
                {"id":"static-obstacle","category":"unrecognized_fixture","map_from_object":IDENTITY,
                    "dimensions_m":[0.2,0.3,0.4],"confidence":"high"}
            ]);
            value["surfaces"] = json!([
                {"id":"observed-wall","kind":"wall","map_from_surface":IDENTITY,"dimensions_m":[1.,2.,0.]},
                {"id":"static-wall","kind":"wall","map_from_surface":IDENTITY,"dimensions_m":[2.,2.,0.]}
            ]);
        }
        if sequence == 8 {
            pose[0] = angle.cos();
            pose[2] = -angle.sin();
            pose[8] = angle.sin();
            pose[10] = angle.cos();
            value["objects"] = json!([{"id":"observed-obstacle","category":"unrecognized_fixture",
                "map_from_object":pose,"dimensions_m":[0.4,0.5,0.6],"confidence":"high"}]);
            value["surfaces"] = json!([{"id":"observed-wall","kind":"wall",
                "map_from_surface":pose,"dimensions_m":[2.,2.,0.]}]);
        } else if sequence > 0 {
            // Other views are an unobservable single plane, not repeats of the loop's corner.
            value["frame"]["depth"]["values_m"] = json!(vec![6.; 24 * 18]);
        }
        value["frame"]["map_from_camera"] = json!(pose);
        store.append(ID, sequence, value).unwrap();
    }
    store.finish(ID, 9).unwrap();
    let result = serde_json::to_value(store.reconstruct(ID).unwrap()).unwrap();
    assert_eq!(
        result["alignment"]["optimized"], true,
        "{}",
        result["alignment"]
    );
    assert_eq!(
        result["alignment"]["frames"][0]["optimized_map_from_camera"],
        json!(IDENTITY)
    );
    assert!(
        result["alignment"]["final_cost"].as_f64().unwrap()
            < result["alignment"]["initial_cost"].as_f64().unwrap()
    );
    let final_pose = &result["alignment"]["frames"][8]["optimized_map_from_camera"];
    assert!(final_pose[12].as_f64().unwrap().abs() < 0.1);
    for corrected in [
        &result["capture"]["objects"][0]["map_from_object"],
        &result["capture"]["surfaces"][0]["map_from_surface"],
    ] {
        for (actual, expected) in corrected
            .as_array()
            .unwrap()
            .iter()
            .zip(final_pose.as_array().unwrap())
        {
            assert!((actual.as_f64().unwrap() - expected.as_f64().unwrap()).abs() < 1e-9);
        }
    }
    assert_eq!(
        result["capture"]["objects"][0]["dimensions_m"],
        json!([0.4, 0.5, 0.6])
    );
    assert_eq!(result["capture"]["metadata"]["alignment_optimized"], true);
    assert_eq!(result["capture"]["objects"][1]["id"], "static-obstacle");
    assert_eq!(
        result["capture"]["objects"][1]["map_from_object"],
        json!(IDENTITY)
    );
    assert_eq!(result["capture"]["surfaces"][1]["id"], "static-wall");
    assert_eq!(
        result["capture"]["surfaces"][1]["map_from_surface"],
        json!(IDENTITY)
    );
    assert_eq!(
        result["scene"]["objects"][1]["map_from_object"],
        json!(IDENTITY)
    );
    assert_eq!(
        result["scene"]["surfaces"][1]["map_from_surface"],
        json!(IDENTITY)
    );
    assert_eq!(
        result["capture"]["meshes"][0]["vertices"],
        result["scene"]["meshes"][0]["vertices"]
    );
}

#[test]
fn verified_already_aligned_loop_is_reported_without_a_missing_loop_warning() {
    let store = StreamStore::default();
    store.create(manifest()).unwrap();
    let positions = [
        [0., 0., 0.],
        [1., 0., 0.],
        [2., 0., 0.],
        [2., 0., 1.],
        [2., 0., 2.],
        [1., 0., 2.],
        [0., 0., 2.],
        [0., 0., 1.],
        [0., 0., 0.],
    ];
    for (sequence, position) in positions.into_iter().enumerate() {
        let mut value = corner_chunk(sequence);
        let mut pose = IDENTITY;
        pose[12] = position[0];
        pose[13] = position[1];
        pose[14] = position[2];
        value["frame"]["map_from_camera"] = json!(pose);
        if sequence > 0 && sequence < 8 {
            value["frame"]["depth"]["values_m"] = json!(vec![6.; 24 * 18]);
        }
        store.append(ID, sequence, value).unwrap();
    }
    store.finish(ID, 9).unwrap();
    let result = serde_json::to_value(store.reconstruct(ID).unwrap()).unwrap();
    assert_eq!(result["alignment"]["optimized"], false);
    assert!(
        result["alignment"]["constraints"]
            .as_array()
            .unwrap()
            .iter()
            .any(|constraint| constraint["accepted"] == true
                && constraint["reason"] == "verified_loop_already_aligned")
    );
    let warnings = result["scene"]["warnings"].as_array().unwrap();
    assert!(
        warnings
            .iter()
            .any(|value| value.as_str().unwrap().contains("already aligned"))
    );
    assert!(
        !warnings
            .iter()
            .any(|value| value.as_str().unwrap().contains("No observable"))
    );
}

#[test]
fn confidence_holes_and_discontinuities_do_not_get_filled() {
    for replacement in [json!(null), json!(0), json!(5)] {
        let mut value = chunk(0);
        value["frame"]["depth"]["values_m"][5] = replacement;
        let result = finish_one(value);
        let mesh = &result["scene"]["meshes"][0];
        assert!(mesh["triangles"].as_array().unwrap().len() < 18);
        for point in mesh["vertices"].as_array().unwrap() {
            assert_eq!(point[2], -2.);
        }
    }
    let mut value = chunk(0);
    value["frame"]["depth"]["confidence"][5] = json!(0);
    let result = finish_one(value);
    assert!(
        !result["scene"]["meshes"][0]["vertices"]
            .as_array()
            .unwrap()
            .contains(&json!([-0.05, 0.05, -2.]))
    );
    // Unknown confidence cannot create new geometry either.
    let mut value = chunk(0);
    value["frame"]["depth"]
        .as_object_mut()
        .unwrap()
        .remove("confidence");
    let store = StreamStore::default();
    store.create(manifest()).unwrap();
    store.append(ID, 0, value).unwrap();
    store.finish(ID, 1).unwrap();
    assert!(matches!(
        store.reconstruct(ID),
        Err(StreamError::Invalid(_))
    ));
}

#[test]
fn labels_are_latest_measured_observations_without_inferred_walkability() {
    let store = StreamStore::default();
    store.create(manifest()).unwrap();
    for sequence in 0..2 {
        let mut value = chunk(sequence);
        value["surfaces"] = json!([{"id":"observed-wall","kind":"wall","map_from_surface":IDENTITY,"dimensions_m":[2.+sequence as f64,2.,0.]}]);
        value["objects"] = json!([{"id":"obstacle","category":"unrecognized_fixture","confidence":"low","map_from_object":IDENTITY,"dimensions_m":[0.3,0.4,0.5]}]);
        store.append(ID, sequence, value).unwrap();
    }
    store.finish(ID, 2).unwrap();
    let result = serde_json::to_value(store.reconstruct(ID).unwrap()).unwrap();
    assert_eq!(result["scene"]["surfaces"].as_array().unwrap().len(), 1);
    assert_eq!(
        result["scene"]["surfaces"][0]["measured_dimensions_m"],
        json!([3., 2., 0.])
    );
    assert_eq!(
        result["scene"]["objects"][0]["source_category"],
        "unrecognized_fixture"
    );
    assert_eq!(result["scene"]["objects"][0]["model_key"], "bounds_v1");
}

#[test]
fn immutable_retries_gaps_timestamp_rules_and_finish_are_checked() {
    let store = StreamStore::default();
    assert!(store.create(manifest()).unwrap().0);
    assert!(!store.create(manifest()).unwrap().0);
    let mut different = manifest();
    different["floor_id"] = json!("other");
    assert!(matches!(
        store.create(different),
        Err(StreamError::Conflict(_))
    ));
    assert!(matches!(store.finish(ID, 0), Err(StreamError::Conflict(_))));
    assert!(matches!(
        store.append(ID, 1, chunk(1)),
        Err(StreamError::Conflict(_))
    ));
    assert_eq!(store.summary(ID).unwrap().next_sequence, 0);
    store.append(ID, 0, chunk(0)).unwrap();
    assert_eq!(store.append(ID, 0, chunk(0)).unwrap().next_sequence, 1);
    let mut different = chunk(0);
    different["frame"]["depth"]["values_m"][0] = json!(1.);
    assert!(matches!(
        store.append(ID, 0, different),
        Err(StreamError::Conflict(_))
    ));
    assert!(matches!(
        store.reconstruct(ID),
        Err(StreamError::Unfinished)
    ));
    let mut stale = chunk(1);
    stale["frame"]["timestamp_seconds"] = json!(1.);
    assert!(matches!(
        store.append(ID, 1, stale),
        Err(StreamError::Invalid(_))
    ));
    let mut duplicate = chunk(1);
    duplicate["frame"]["id"] = json!("frame-0");
    assert!(matches!(
        store.append(ID, 1, duplicate),
        Err(StreamError::Invalid(_))
    ));
    assert!(matches!(store.finish(ID, 2), Err(StreamError::Conflict(_))));
    assert!(store.finish(ID, 1).unwrap().finished);
    assert!(store.finish(ID, 1).unwrap().finished);
    assert!(store.append(ID, 0, chunk(0)).unwrap().finished);
    assert!(matches!(
        store.append(ID, 1, chunk(1)),
        Err(StreamError::Conflict(_))
    ));
}

#[test]
fn restart_recovers_unfinished_prefix_and_sealed_result() {
    let temp = Temp::new();
    {
        let store = StreamStore::open(&temp.0).unwrap();
        store.create(manifest()).unwrap();
        store.append(ID, 0, chunk(0)).unwrap();
        // A crash before rename leaves an unacknowledged temporary file, never a chunk.
        fs::write(temp.0.join(ID).join(".write-interrupted.tmp"), b"partial").unwrap();
    }
    let before = {
        let store = StreamStore::open(&temp.0).unwrap();
        assert_eq!(store.summary(ID).unwrap().next_sequence, 1);
        assert!(!store.summary(ID).unwrap().finished);
        store.append(ID, 1, chunk(1)).unwrap();
        store.finish(ID, 2).unwrap();
        serde_json::to_value(store.reconstruct(ID).unwrap()).unwrap()
    };
    let store = StreamStore::open(&temp.0).unwrap();
    assert!(store.summary(ID).unwrap().finished);
    assert_eq!(
        before,
        serde_json::to_value(store.reconstruct(ID).unwrap()).unwrap()
    );
    assert_eq!(store.append(ID, 0, chunk(0)).unwrap().next_sequence, 2);
}

#[test]
fn bounded_graph_keeps_first_and_final_pose_without_losing_raw_observations() {
    let store = StreamStore::default();
    store.create(manifest()).unwrap();
    for sequence in 0..65 {
        store.append(ID, sequence, chunk(sequence)).unwrap();
    }
    store.finish(ID, 65).unwrap();
    let result = serde_json::to_value(store.reconstruct(ID).unwrap()).unwrap();
    assert_eq!(result["alignment"]["frames"].as_array().unwrap().len(), 64);
    assert_eq!(result["alignment"]["frames"][0]["frame_id"], "frame-0");
    assert_eq!(result["alignment"]["frames"][63]["frame_id"], "frame-64");
    assert_eq!(result["capture"]["metadata"]["source_frame_count"], 65);
    assert_eq!(
        result["scene"]["meshes"][0]["triangles"]
            .as_array()
            .unwrap()
            .len(),
        18
    );
    assert_eq!(result["alignment"]["optimized"], false);
}

#[test]
fn incomplete_committed_disk_state_is_reported_instead_of_discarded() {
    let temp = Temp::new();
    let store = StreamStore::open(&temp.0).unwrap();
    store.create(manifest()).unwrap();
    store.append(ID, 0, chunk(0)).unwrap();
    store.append(ID, 1, chunk(1)).unwrap();
    drop(store);
    fs::remove_file(temp.0.join(ID).join("chunk-000000.json")).unwrap();
    assert!(matches!(
        StreamStore::open(&temp.0),
        Err(StreamError::Conflict(_))
    ));
}

#[test]
fn encoded_result_cache_survives_restart_and_corrupt_cache_rebuilds_originals() {
    let temp = Temp::new();
    let store = StreamStore::open(&temp.0).unwrap();
    store.create(manifest()).unwrap();
    store.append(ID, 0, chunk(0)).unwrap();
    store.finish(ID, 1).unwrap();
    let original_path = temp.0.join(ID).join("chunk-000000.json");
    let original_bytes = fs::read(&original_path).unwrap();
    let expected = serde_json::to_vec(&store.reconstruct(ID).unwrap()).unwrap();
    let cached = store.reconstruct_encoded(ID, false).unwrap();
    assert_eq!(expected, cached);
    let cache_path = temp.0.join(ID).join("reconstruction-v5-result.json");
    let modified = fs::metadata(&cache_path).unwrap().modified().unwrap();
    let scene: Value =
        serde_json::from_slice(&store.reconstruct_encoded(ID, true).unwrap()).unwrap();
    assert_eq!(
        scene,
        serde_json::from_slice::<Value>(&cached).unwrap()["scene"]
    );
    drop(store);
    let reopened = StreamStore::open(&temp.0).unwrap();
    assert_eq!(reopened.reconstruct_encoded(ID, false).unwrap(), cached);
    assert_eq!(
        fs::metadata(&cache_path).unwrap().modified().unwrap(),
        modified
    );
    fs::write(&cache_path, b"{broken cache").unwrap();
    assert_eq!(reopened.reconstruct_encoded(ID, false).unwrap(), cached);
    fs::write(&cache_path, b"{\"valid_json_but_wrong_geometry\":true}").unwrap();
    assert_eq!(reopened.reconstruct_encoded(ID, false).unwrap(), cached);
    let metadata_path = temp.0.join(ID).join("reconstruction-v5-cache.json");
    let mut metadata: Value = serde_json::from_slice(&fs::read(&metadata_path).unwrap()).unwrap();
    metadata["reconstruction_version"] = json!(999);
    fs::write(&metadata_path, metadata.to_string()).unwrap();
    assert_eq!(reopened.reconstruct_encoded(ID, false).unwrap(), cached);
    assert_eq!(
        serde_json::from_slice::<Value>(&fs::read(metadata_path).unwrap()).unwrap()["reconstruction_version"],
        5
    );
    assert_eq!(fs::read(original_path).unwrap(), original_bytes);
}

#[test]
fn dense_capture_compacts_instead_of_failing_old_mesh_limits() {
    let mut value = chunk(0);
    value["frame"]["camera"]["fx"] = json!(0.75);
    value["frame"]["camera"]["fy"] = json!(0.75);
    value["frame"]["camera"]["cx"] = json!(2.);
    value["frame"]["camera"]["cy"] = json!(2.);
    value["frame"]["depth"] = json!({"width":512,"height":512,
        "values_m":vec![2.;512*512],"confidence":vec![2;512*512]});
    let temp = Temp::new();
    let store = StreamStore::open(&temp.0).unwrap();
    store.create(manifest()).unwrap();
    store.append(ID, 0, value.clone()).unwrap();
    store.finish(ID, 1).unwrap();
    let result = serde_json::to_value(store.reconstruct(ID).unwrap()).unwrap();
    assert!(
        result["capture"]["metadata"]["mesh_compactions"]
            .as_u64()
            .unwrap()
            > 0
    );
    assert!(
        result["capture"]["metadata"]["weld_meters"]
            .as_f64()
            .unwrap()
            > 0.02
    );
    let mesh = &result["capture"]["meshes"][0];
    assert!(!mesh["triangles"].as_array().unwrap().is_empty());
    let points = mesh["vertices"].as_array().unwrap();
    // All of the measured plane, including late pixels, is represented.
    let xs: Vec<_> = points
        .iter()
        .map(|point| point[0].as_f64().unwrap())
        .collect();
    assert!(xs.iter().copied().fold(f64::INFINITY, f64::min) < -4.9);
    assert!(xs.iter().copied().fold(f64::NEG_INFINITY, f64::max) > 4.9);
    let source: ScanBundle = serde_json::from_value(result["capture"].clone()).unwrap();
    source.validate().unwrap();
    assert_eq!(mesh["vertices"], result["scene"]["meshes"][0]["vertices"]);
    assert_eq!(mesh["triangles"], result["scene"]["meshes"][0]["triangles"]);
    let display = &result["capture"]["metadata"]["display_meshes"][0];
    assert!(
        display["display_triangle_count"].as_u64().unwrap()
            < display["source_triangle_count"].as_u64().unwrap()
    );
    let original: Value =
        serde_json::from_slice(&fs::read(temp.0.join(ID).join("chunk-000000.json")).unwrap())
            .unwrap();
    assert_eq!(original, value);
}

#[test]
fn whole_building_labels_are_not_capped_by_the_per_observation_budget() {
    let temp = Temp::new();
    let store = StreamStore::open(&temp.0).unwrap();
    store.create(manifest()).unwrap();
    for sequence in 0..2 {
        let mut value = chunk(sequence);
        value["objects"] =
            json!((0..600).map(|index| json!({
            "id":format!("obstacle-{sequence}-{index}"), "category":"unclassified_obstacle",
            "map_from_object":IDENTITY, "dimensions_m":[0.3,0.4,0.5], "confidence":"low"
        })).collect::<Vec<_>>());
        value["surfaces"] = json!(
            (0..600)
                .map(|index| json!({
                    "id":format!("wall-{sequence}-{index}"), "kind":"wall",
                    "map_from_surface":IDENTITY, "dimensions_m":[1.,2.,0.]
                }))
                .collect::<Vec<_>>()
        );
        store.append(ID, sequence, value).unwrap();
    }
    assert_eq!(store.finish(ID, 2).unwrap().frame_count, 2);
    drop(store);
    assert!(
        StreamStore::open(&temp.0)
            .unwrap()
            .summary(ID)
            .unwrap()
            .finished
    );
}

#[test]
fn concurrent_result_and_scene_requests_share_finished_reconstruction() {
    let store = StreamStore::default();
    store.create(manifest()).unwrap();
    for sequence in 0..12 {
        store.append(ID, sequence, chunk(sequence)).unwrap();
    }
    store.finish(ID, 12).unwrap();
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(6));
    let workers: Vec<_> = (0..6)
        .map(|index| {
            let worker = store.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                let result: Value = serde_json::from_slice(
                    &worker.reconstruct_encoded(ID, index % 2 == 1).unwrap(),
                )
                .unwrap();
                if index % 2 == 1 {
                    result
                } else {
                    result["scene"].clone()
                }
            })
        })
        .collect();
    let results: Vec<_> = workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .collect();
    assert!(results.windows(2).all(|pair| pair[0] == pair[1]));
}

#[test]
fn uuid_paths_and_bounded_valid_jpeg_images_are_required() {
    let store = StreamStore::default();
    for id in [
        "../escape",
        "..",
        "scan",
        "61cd3d3c-1a2f-43de-a7b9-11d4c85ec3e6/../bad",
    ] {
        let mut value = manifest();
        value["id"] = json!(id);
        assert!(matches!(store.create(value), Err(StreamError::Invalid(_))));
        assert!(matches!(store.summary(id), Err(StreamError::Invalid(_))));
    }
    store.create(manifest()).unwrap();
    for replacement in [
        json!("%%%"),
        json!(STANDARD.encode(b"not a jpeg")),
        json!(STANDARD.encode(&include_bytes!("fixtures/stream-color.jpg")[..100])),
    ] {
        let mut value = chunk(0);
        value["color_jpeg"] = replacement;
        assert!(matches!(
            store.append(ID, 0, value),
            Err(StreamError::Invalid(_))
        ));
    }
    let mut value = chunk(0);
    value["frame"]["camera"]["image_width"] = json!(8);
    value["frame"]["camera"]["image_height"] = json!(8);
    assert!(matches!(
        store.append(ID, 0, value),
        Err(StreamError::Invalid(_))
    ));
    let mut value = chunk(0);
    value["color_jpeg"] = json!("A".repeat(700_000));
    assert!(matches!(
        store.append(ID, 0, value),
        Err(StreamError::Limit(_))
    ));
    assert_eq!(store.summary(ID).unwrap().next_sequence, 0);
}

#[cfg(unix)]
#[test]
fn recovery_rejects_symlink_stream_directories() {
    let temp = Temp::new();
    let outside = Temp::new();
    std::os::unix::fs::symlink(&outside.0, temp.0.join(ID)).unwrap();
    assert!(matches!(
        StreamStore::open(&temp.0),
        Err(StreamError::Invalid(_))
    ));
}

async fn call(
    router: &Router,
    method: &str,
    path: &str,
    value: Option<Value>,
) -> (StatusCode, Value) {
    let response = router
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
                .header("content-type", "application/json")
                .body(Body::from(
                    value.map(|value| value.to_string()).unwrap_or_default(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 16 * 1024 * 1024)
        .await
        .unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

#[tokio::test]
async fn api_supports_recovery_model_result_and_oversize_chunk_errors() {
    let router = app(AppState::default());
    assert_eq!(
        call(&router, "POST", "/streams", Some(manifest())).await.0,
        StatusCode::CREATED
    );
    assert_eq!(
        call(&router, "POST", "/streams", Some(manifest())).await.0,
        StatusCode::OK
    );
    assert_eq!(
        call(&router, "GET", &format!("/streams/{ID}/result"), None)
            .await
            .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        call(
            &router,
            "PUT",
            &format!("/streams/{ID}/chunks/0"),
            Some(chunk(0))
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        call(&router, "GET", &format!("/streams/{ID}"), None)
            .await
            .1["next_sequence"],
        1
    );
    assert_eq!(
        call(
            &router,
            "POST",
            &format!("/streams/{ID}/finish"),
            Some(json!({"chunk_count":1}))
        )
        .await
        .0,
        StatusCode::OK
    );
    let result = call(&router, "GET", &format!("/streams/{ID}/result"), None).await;
    assert_eq!(result.0, StatusCode::OK);
    assert_eq!(
        result.1["scene"],
        call(&router, "GET", &format!("/streams/{ID}/scene"), None)
            .await
            .1
    );
    let missing = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    assert_eq!(
        call(&router, "GET", &format!("/streams/{missing}"), None)
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    let mut oversized = chunk(1);
    oversized["color_jpeg"] = json!("A".repeat(4 * 1024 * 1024));
    assert_eq!(
        call(
            &router,
            "PUT",
            &format!("/streams/{ID}/chunks/1"),
            Some(oversized)
        )
        .await
        .0,
        StatusCode::PAYLOAD_TOO_LARGE
    );
}

fn gzip(bytes: &[u8]) -> Vec<u8> {
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    encoder.write_all(bytes).unwrap();
    encoder.finish().unwrap()
}

async fn encoded_chunk(router: &Router, bytes: Vec<u8>, encoding: &str) -> (StatusCode, Value) {
    let response = router
        .clone()
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(format!("/streams/{ID}/chunks/0"))
                .header("content-type", "application/json")
                .header("content-encoding", encoding)
                .body(Body::from(bytes))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 16 * 1024 * 1024)
        .await
        .unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

#[tokio::test]
async fn gzip_capability_and_retries_preserve_uncompressed_originals() {
    let temp = Temp::new();
    let state = AppState {
        streams: StreamStore::open(&temp.0).unwrap(),
        ..AppState::default()
    };
    let router = app(state);
    let created = router
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/streams")
                .header("content-type", "application/json")
                .body(Body::from(manifest().to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::CREATED);
    assert_eq!(created.headers()["accept-encoding"], "gzip");
    let value = chunk(0);
    let encoded = gzip(&serde_json::to_vec(&value).unwrap());
    assert_eq!(
        encoded_chunk(&router, encoded.clone(), "gzip").await.0,
        StatusCode::OK
    );
    let path = temp.0.join(ID).join("chunk-000000.json");
    assert_eq!(
        serde_json::from_slice::<Value>(&fs::read(path).unwrap()).unwrap(),
        value
    );
    assert_eq!(
        call(
            &router,
            "PUT",
            &format!("/streams/{ID}/chunks/0"),
            Some(value)
        )
        .await
        .0,
        StatusCode::OK
    );
    call(
        &router,
        "POST",
        &format!("/streams/{ID}/finish"),
        Some(json!({"chunk_count":1})),
    )
    .await;
    assert_eq!(
        encoded_chunk(&router, encoded, "gzip").await.0,
        StatusCode::OK
    );
    let summary = router
        .oneshot(
            Request::builder()
                .uri(format!("/streams/{ID}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(summary.headers()["accept-encoding"], "gzip");
}

#[tokio::test]
async fn gzip_chunks_reject_malformed_truncated_trailing_or_oversized_data() {
    let router = app(AppState::default());
    call(&router, "POST", "/streams", Some(manifest())).await;
    let valid = gzip(&serde_json::to_vec(&chunk(0)).unwrap());
    let mut trailing = valid.clone();
    trailing.extend(b"trailing");
    let mut concatenated = valid.clone();
    concatenated.extend(&valid);
    let mut bad_crc = valid.clone();
    let crc_index = bad_crc.len() - 8;
    bad_crc[crc_index] ^= 1;
    for bytes in [
        b"not gzip".to_vec(),
        valid[..valid.len() - 3].to_vec(),
        trailing,
        concatenated,
        bad_crc,
    ] {
        assert_eq!(
            encoded_chunk(&router, bytes, "gzip").await.0,
            StatusCode::BAD_REQUEST
        );
    }
    assert_eq!(
        encoded_chunk(&router, valid, "br").await.0,
        StatusCode::UNSUPPORTED_MEDIA_TYPE
    );
    assert_eq!(
        encoded_chunk(&router, vec![1; 4 * 1024 * 1024 + 1], "gzip")
            .await
            .0,
        StatusCode::PAYLOAD_TOO_LARGE
    );
    assert_eq!(
        encoded_chunk(&router, gzip(&vec![b' '; 4 * 1024 * 1024 + 1]), "gzip")
            .await
            .0,
        StatusCode::PAYLOAD_TOO_LARGE
    );
    assert_eq!(
        call(&router, "GET", &format!("/streams/{ID}"), None)
            .await
            .1["next_sequence"],
        0
    );
}
