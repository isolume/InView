use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use inview_backend::{
    AppState, app,
    capture::{Confidence, ScanBundle},
    geometry::{Bounds, Transform, Vec3},
    scene::{self, ProcessingOptions},
};
use serde_json::{Value, json};
use tower::ServiceExt;

fn fixture() -> Value {
    serde_json::from_str(include_str!("../examples/scan.json")).unwrap()
}

fn bundle(value: Value) -> ScanBundle {
    serde_json::from_value(value).unwrap()
}

fn identity() -> Transform {
    Transform([
        1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0,
    ])
}

fn near(actual: Vec3, expected: Vec3) {
    for (actual, expected) in actual.into_iter().zip(expected) {
        assert!((actual - expected).abs() < 1e-9, "{actual} != {expected}");
    }
}

#[test]
fn synthetic_room_produces_shell_furniture_and_measured_fallback() {
    let scan = bundle(fixture());
    let scene = scene::process(&scan, ProcessingOptions::default()).unwrap();
    assert_eq!(scene.source_scan_id, "demo-room");
    assert_eq!(scene.map_id, "demo-room-map");
    assert_eq!(scene.floor_id, "ground");
    assert_eq!(scene.surfaces.len(), 3);
    assert_eq!(scene.objects.len(), 4);
    for object in &scene.objects {
        for part in &object.parts {
            for axis in 0..3 {
                assert!(
                    part.center[axis].abs() + part.dimensions_m[axis] / 2.0
                        <= object.measured_dimensions_m[axis] / 2.0 + 1e-10,
                    "Display part extends outside measured obstacle {}",
                    object.source_id
                );
            }
        }
    }
    assert_eq!(
        scene
            .objects
            .iter()
            .map(|object| object.model_key)
            .collect::<Vec<_>>(),
        [
            "lounge_chair_v1",
            "modular_sofa_v1",
            "folding_table_v1",
            "bounds_v1"
        ]
    );
    let unknown = &scene.objects[3];
    assert_eq!(unknown.source_category, "unrecognized_fixture");
    near(unknown.measured_dimensions_m, [0.6, 0.65, 0.5]);
    near(unknown.parts[0].dimensions_m, [0.6, 0.65, 0.5]);
    assert!(
        scene
            .warnings
            .iter()
            .any(|warning| warning.contains("measured boxes"))
    );

    // Zero-thickness planes acquire display thickness without changing their measurements.
    near(scene.surfaces[0].measured_dimensions_m, [6.0, 0.0, 5.0]);
    near(scene.surfaces[0].render_dimensions_m, [6.0, 0.025, 5.0]);
    near(scene.surfaces[1].measured_dimensions_m, [6.0, 2.8, 0.0]);
}

#[test]
fn column_major_rotation_and_translation_align_mesh_and_obstacle_bounds() {
    let transform = Transform([
        0.0, 0.0, -1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 10.0, 2.0, -4.0, 1.0,
    ]);
    transform.validate().unwrap();
    near(transform.point([1.0, 2.0, 3.0]), [13.0, 4.0, -5.0]);

    let mut scan = bundle(fixture());
    scan.meshes[0].map_from_anchor = transform;
    scan.objects[0].map_from_object = transform;
    scan.objects[0].dimensions_m = [2.0, 4.0, 6.0];
    let scene = scene::process(&scan, ProcessingOptions::default()).unwrap();
    near(scene.meshes[0].vertices[0], [9.8, 2.0, -3.75]);
    assert_eq!(scene.meshes[0].triangles, [[0, 1, 2]]);
    assert_eq!(
        scene.meshes[0].classifications.as_ref().unwrap(),
        &["unknown"]
    );

    let obstacle = &scene.objects[0];
    near(obstacle.obstacle_bounds.min, [7.0, 0.0, -5.0]);
    near(obstacle.obstacle_bounds.max, [13.0, 4.0, -3.0]);
    assert_eq!(obstacle.obstacle_corners.len(), 8);
    assert_eq!(obstacle.map_from_object, transform);

    // A 45-degree box needs more than the transformed local min/max corners.
    let root = 0.5_f64.sqrt();
    let diagonal = Transform([
        root, 0.0, -root, 0.0, 0.0, 1.0, 0.0, 0.0, root, 0.0, root, 0.0, 0.0, 0.0, 0.0, 1.0,
    ]);
    let bounds = Bounds::from_points(&diagonal.box_corners([2.0, 2.0, 2.0])).unwrap();
    near(bounds.min, [-2.0 * root, -1.0, -2.0 * root]);
    near(bounds.max, [2.0 * root, 1.0, 2.0 * root]);
}

#[test]
fn transforms_reject_reflection_scale_shear_and_projective_or_nonfinite_values() {
    for (index, value) in [
        (0, -1.0),
        (0, 2.0),
        (4, 0.25),
        (3, 0.1),
        (15, 0.0),
        (12, f64::NAN),
    ] {
        let mut invalid = identity();
        invalid.0[index] = value;
        assert!(
            invalid.validate().is_err(),
            "accepted change at {index}: {value}"
        );
    }
}

#[test]
fn depth_unprojection_scales_intrinsics_to_depth_resolution_and_keeps_camera_axes() {
    let scan = bundle(fixture());
    let frame = &scan.frames[0];
    // Depth pixel (1, 0) is color pixel (2, 0): on the optical x-axis and above it.
    near(frame.point_in_map(1, 2.0), [0.0, 1.9, -0.2]);
    // Bottom-right depth pixel maps to color pixel (4, 2), below the optical axis.
    near(frame.point_in_map(5, 2.5), [1.25, 0.775, -0.7]);

    let mut frame = frame.clone();
    frame.map_from_camera = identity();
    near(frame.point_in_map(1, 2.0), [0.0, 0.5, -2.0]);
    near(frame.point_in_map(5, 2.5), [1.25, -0.625, -2.5]);
}

#[test]
fn depth_filter_omits_null_zero_and_low_confidence_without_losing_provenance() {
    let scene = scene::process(&bundle(fixture()), ProcessingOptions::default()).unwrap();
    assert_eq!(scene.point_cloud.len(), 3);
    assert!(
        scene
            .point_cloud
            .iter()
            .all(|point| point.source_frame_id == "depth-frame-001")
    );
    assert_eq!(
        scene
            .point_cloud
            .iter()
            .map(|point| point.confidence)
            .collect::<Vec<_>>(),
        [Some(2), Some(1), Some(2)]
    );
    near(scene.point_cloud[0].position, [0.0, 1.9, -0.2]);
    near(scene.point_cloud[1].position, [0.0, 0.9, -0.2]);
    near(scene.point_cloud[2].position, [1.25, 0.775, -0.7]);
}

#[test]
fn missing_depth_confidence_is_explicitly_opt_in() {
    let mut scan = bundle(fixture());
    scan.frames[0].depth.confidence = None;
    let required = scene::process(&scan, ProcessingOptions::default()).unwrap();
    assert!(required.point_cloud.is_empty());
    assert!(
        required
            .warnings
            .iter()
            .any(|warning| warning.contains("without confidence"))
    );

    let permissive = scene::process(
        &scan,
        ProcessingOptions {
            minimum_depth_confidence: None,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(permissive.point_cloud.len(), 4);
    assert!(
        permissive
            .point_cloud
            .iter()
            .all(|point| point.confidence.is_none())
    );
}

#[test]
fn confidence_changes_display_model_without_removing_measured_obstacles() {
    let mut scan = bundle(fixture());
    scan.objects[0].confidence = Confidence::Low;
    scan.objects[2].confidence = Confidence::Unknown;
    let default = scene::process(&scan, ProcessingOptions::default()).unwrap();
    assert_eq!(default.objects[0].model_key, "bounds_v1");
    assert_eq!(default.objects[1].model_key, "modular_sofa_v1");
    assert_eq!(default.objects[2].model_key, "bounds_v1");
    assert_eq!(default.objects.len(), scan.objects.len());

    let high = scene::process(
        &scan,
        ProcessingOptions {
            minimum_object_confidence: Confidence::High,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(high.objects[1].model_key, "bounds_v1");
    for (before, after) in default.objects.iter().zip(&high.objects) {
        assert_eq!(before.obstacle_corners, after.obstacle_corners);
        assert_eq!(before.obstacle_bounds, after.obstacle_bounds);
        assert_eq!(before.source_category, after.source_category);
    }
}

#[test]
fn raw_only_capture_retains_mesh_without_inventing_furniture() {
    let mut scan = bundle(fixture());
    scan.objects.clear();
    scan.surfaces.clear();
    scan.frames.clear();
    let scene = scene::process(&scan, ProcessingOptions::default()).unwrap();
    assert!(scene.objects.is_empty());
    assert!(scene.surfaces.is_empty());
    assert_eq!(scene.meshes.len(), 1);
    assert_eq!(scene.meshes[0].source_id, "raw-obstacle-001");
    near(scene.meshes[0].vertices[0], [1.85, 0.0, -1.9]);
    assert!(scene.warnings.iter().any(|warning| {
        warning.contains("No object labels were supplied. The map retains measured geometry.")
    }));
}

#[test]
fn point_cap_samples_across_frames_and_processing_is_deterministic() {
    let mut scan = bundle(fixture());
    let mut frame = scan.frames[0].clone();
    frame.id = "depth-frame-002".into();
    frame.timestamp_seconds += 0.25;
    for frame in [&mut scan.frames[0], &mut frame] {
        frame.depth.values_m = vec![Some(1.0); 6];
        frame.depth.confidence = Some(vec![2; 6]);
    }
    scan.frames.push(frame);
    let options = ProcessingOptions {
        max_points: 3,
        ..Default::default()
    };
    let first = scene::process(&scan, options.clone()).unwrap();
    let second = scene::process(&scan, options).unwrap();
    assert_eq!(first.point_cloud.len(), 3);
    assert!(
        first
            .point_cloud
            .iter()
            .any(|point| point.source_frame_id == "depth-frame-001")
    );
    assert!(
        first
            .point_cloud
            .iter()
            .any(|point| point.source_frame_id == "depth-frame-002")
    );
    assert_eq!(
        serde_json::to_value(first).unwrap(),
        serde_json::to_value(second).unwrap()
    );
}

fn invalid_payloads() -> Vec<Value> {
    let mut cases = Vec::new();
    for (pointer, value) in [
        ("/schema_version", json!(2)),
        ("/coordinates/units", json!("centimeters")),
        ("/coordinates/up_axis", json!("z")),
        ("/coordinates/handedness", json!("left")),
        ("/objects/0/dimensions_m/0", json!(0)),
        ("/surfaces/0/dimensions_m", json!([0, 0, 5])),
        ("/meshes/0/triangles/0/2", json!(99)),
        ("/meshes/0/triangles/0/2", json!(1)),
        ("/meshes/0/classifications", json!([])),
        ("/frames/0/timestamp_seconds", json!(-1)),
        ("/frames/0/pixel_orientation", json!("portrait")),
        ("/frames/0/camera/image_width", json!(0)),
        ("/frames/0/camera/image_height", json!(6)),
        ("/frames/0/camera/fx", json!(0)),
        ("/frames/0/camera/fx", json!(1e-320)),
        ("/frames/0/depth/values_m", json!([1])),
        ("/frames/0/depth/values_m/0", json!(-1)),
        ("/frames/0/depth/confidence/0", json!(3)),
        ("/frames/0/depth/confidence", json!([2])),
    ] {
        let mut invalid = fixture();
        *invalid.pointer_mut(pointer).unwrap() = value;
        cases.push(invalid);
    }
    let mut duplicate = fixture();
    duplicate["objects"][1]["id"] = duplicate["objects"][0]["id"].clone();
    cases.push(duplicate);
    let mut empty = fixture();
    for field in ["objects", "surfaces", "meshes", "frames"] {
        empty[field] = json!([]);
    }
    cases.push(empty);
    cases
}

#[test]
fn invalid_capture_geometry_and_frame_metadata_are_rejected() {
    for value in invalid_payloads() {
        assert!(bundle(value).validate().is_err());
    }
    let mut scan = bundle(fixture());
    scan.meshes[0].vertices[0][0] = f64::INFINITY;
    assert!(scan.validate().is_err());
}

async fn call_raw(
    app: &Router,
    method: &str,
    uri: &str,
    payload: Option<Value>,
) -> (StatusCode, String, Vec<u8>) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(uri)
                .header("content-type", "application/json")
                .body(Body::from(
                    payload.map(|value| value.to_string()).unwrap_or_default(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let content_type = response
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();
    // Detailed display meshes may be larger than their small capture request.
    let bytes = to_bytes(response.into_body(), 16 * 1024 * 1024)
        .await
        .unwrap();
    (status, content_type, bytes.to_vec())
}

async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    payload: Option<Value>,
) -> (StatusCode, Value) {
    let (status, _, bytes) = call_raw(app, method, uri, payload).await;
    (status, serde_json::from_slice(&bytes).unwrap())
}

#[tokio::test]
async fn multiroom_originals_can_exceed_the_single_room_upload_budget() {
    let app = app(AppState::default());
    let mut source = fixture();
    // Native RoomPlan originals grow across sections even when projected geometry is small.
    source["roomplan_original"] = json!({ "sections": "x".repeat(3 * 1024 * 1024) });
    let (status, _) = call(&app, "POST", "/scans", Some(source.clone())).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(call(&app, "GET", "/scans/demo-room", None).await.1, source);
}

#[tokio::test]
async fn uploaded_floating_point_measurements_round_trip_without_drift() {
    let app = app(AppState::default());
    let mut source = fixture();
    // These are actual iPhone JSONEncoder values, including a 90-degree rotation.
    // A one-ULP change makes the native client's immutable-source retry fail.
    source["metadata"]["precise_values"] = json!([
        -1.8250000476837158_f64,
        -1.5249998569488525_f64,
        6.123234e-17_f64
    ]);
    let (status, _) = call(&app, "POST", "/scans", Some(source.clone())).await;
    assert_eq!(status, StatusCode::CREATED);
    let returned = call(&app, "GET", "/scans/demo-room", None).await.1;
    assert_eq!(returned, source);
    let values = returned["metadata"]["precise_values"].as_array().unwrap();
    for (value, expected) in values.iter().zip([
        -1.8250000476837158_f64,
        -1.5249998569488525_f64,
        6.123234e-17_f64,
    ]) {
        assert_eq!(value.as_f64().unwrap().to_bits(), expected.to_bits());
    }
}

#[tokio::test]
async fn upload_preserves_unknown_source_fields_and_processing_does_not_mutate_capture() {
    let app = app(AppState::default());
    let mut source = fixture();
    source["future_export"] = json!({ "version": 99, "payload": [1, 2, 3] });
    source["frames"][0]["color_asset"] = json!("opaque-reference-never-downloaded");
    let (status, summary) = call(&app, "POST", "/scans", Some(source.clone())).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(summary["id"], "demo-room");
    assert_eq!(summary["object_count"], 4);
    assert_eq!(summary["surface_count"], 3);
    assert_eq!(call(&app, "GET", "/scans", None).await.1, json!([summary]));
    assert_eq!(call(&app, "GET", "/scans/demo-room", None).await.1, source);
    let default = call(&app, "GET", "/scans/demo-room/scene", None).await;
    assert_eq!(default.0, StatusCode::OK);
    assert_eq!(default.1["source_scan_id"], "demo-room");
    let processed = call(&app, "POST", "/scans/demo-room/process", Some(json!({}))).await;
    assert_eq!(processed.0, StatusCode::OK);
    assert_eq!(processed.1, default.1);
    assert_eq!(call(&app, "GET", "/scans/demo-room", None).await.1, source);
}

#[tokio::test]
async fn immutable_scan_ids_conflict_and_invalid_uploads_leave_state_unchanged() {
    let app = app(AppState::default());
    let source = fixture();
    assert_eq!(
        call(&app, "POST", "/scans", Some(source.clone())).await.0,
        StatusCode::CREATED
    );
    let mut replacement = source.clone();
    replacement["objects"][0]["category"] = json!("table");
    let (status, error) = call(&app, "POST", "/scans", Some(replacement)).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(error["error"]["code"], "scan_exists");

    for (index, mut invalid) in invalid_payloads().into_iter().enumerate() {
        invalid["id"] = json!(format!("invalid-{index}"));
        let (status, error) = call(&app, "POST", "/scans", Some(invalid)).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(error["error"]["code"], "invalid_input");
    }
    assert_eq!(
        call(&app, "GET", "/scans", None)
            .await
            .1
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(call(&app, "GET", "/scans/demo-room", None).await.1, source);
}

#[tokio::test]
async fn processing_options_and_missing_scans_return_structured_errors() {
    let app = app(AppState::default());
    for uri in [
        "/scans/missing",
        "/scans/missing/scene",
        "/scans/missing/preview",
    ] {
        let (status, error) = call(&app, "GET", uri, None).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(error["error"]["code"], "scan_not_found");
    }
    assert_eq!(
        call(&app, "POST", "/scans/missing/process", Some(json!({})))
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    call(&app, "POST", "/scans", Some(fixture())).await;
    for options in [
        json!({ "max_points": 0 }),
        json!({ "max_points": 100001 }),
        json!({ "minimum_depth_confidence": 3 }),
    ] {
        let (status, error) = call(&app, "POST", "/scans/demo-room/process", Some(options)).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(error["error"]["code"], "invalid_input");
    }
    let (status, error) = call(
        &app,
        "POST",
        "/scans/demo-room/process",
        Some(json!({ "max_ponts": 1 })),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(error["error"]["code"], "invalid_json");
}

#[tokio::test]
async fn preview_is_html_for_an_existing_scan() {
    let app = app(AppState::default());
    call(&app, "POST", "/scans", Some(fixture())).await;
    let (status, content_type, bytes) =
        call_raw(&app, "GET", "/scans/demo-room/preview", None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(content_type.starts_with("text/html"));
    assert!(
        String::from_utf8(bytes)
            .unwrap()
            .to_ascii_lowercase()
            .contains("<!doctype html>")
    );
}

#[tokio::test]
async fn scan_processing_keeps_reviewed_graph_and_routes_unchanged() {
    let app = app(AppState::default());
    let graph: Value = serde_json::from_str(include_str!("../examples/graph.json")).unwrap();
    let route_request: Value =
        serde_json::from_str(include_str!("../examples/route.json")).unwrap();
    call(&app, "PUT", "/graphs/demo-building", Some(graph.clone())).await;
    let stored_graph = call(&app, "GET", "/graphs/demo-building", None).await.1;
    let before = call(
        &app,
        "POST",
        "/graphs/demo-building/routes",
        Some(route_request.clone()),
    )
    .await;
    assert_eq!(before.0, StatusCode::OK);
    call(&app, "POST", "/scans", Some(fixture())).await;
    assert_eq!(
        call(&app, "POST", "/scans/demo-room/process", Some(json!({})))
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        call(&app, "GET", "/graphs/demo-building", None).await.1,
        stored_graph
    );
    assert_eq!(
        call(&app, "GET", "/graphs", None)
            .await
            .1
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let after = call(
        &app,
        "POST",
        "/graphs/demo-building/routes",
        Some(route_request),
    )
    .await;
    assert_eq!(after, before);

    let empty = app_with_empty_state();
    call(&empty, "POST", "/scans", Some(fixture())).await;
    call(&empty, "GET", "/scans/demo-room/scene", None).await;
    assert_eq!(call(&empty, "GET", "/graphs", None).await.1, json!([]));
}

fn app_with_empty_state() -> Router {
    app(AppState::default())
}
