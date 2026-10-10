//! A finished continuous stream becomes an ordinary scan package: corrected poses, upright RGB,
//! depth sidecars, environment samples, the movement track and phone attachments all reach the
//! scan store, so the analysis pipeline runs on streamed scans unchanged.
use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use inview_backend::{AppState, app};
use serde_json::{Value, json};
use tower::ServiceExt;

const ID: &str = "7d1f5a58-5d1e-4cf3-9c1a-2b6f7c1e9a10";

fn pose(x: f64) -> [f64; 16] {
    [
        1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., x, 0., 0., 1.,
    ]
}

fn chunk(sequence: usize) -> Value {
    let depths: Vec<f64> = (0..18)
        .flat_map(|y| {
            (0..24).map(move |x| {
                let dx = (x as f64 - 11.5) / 16.;
                let dy = -(y as f64 - 8.5) / 16.;
                let mut depth = 3_f64;
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
    let t = sequence as f64 + 1.;
    json!({
        "sequence": sequence,
        "color_jpeg": STANDARD.encode(include_bytes!("fixtures/stream-texture.jpg")),
        "frame": {"id": format!("frame-{sequence}"), "timestamp_seconds": t,
            "pixel_orientation": "sensor_native", "map_from_camera": pose(0.01 * sequence as f64),
            "camera": {"image_width": 24, "image_height": 18, "fx": 16., "fy": 16., "cx": 11.5, "cy": 8.5},
            "depth": {"width": 24, "height": 18, "values_m": depths, "confidence": vec![2; 24 * 18]}},
        "environment": {"recorded_at_unix_seconds": 1_791_000_000. + t, "latitude": 33.7756,
            "longitude": -84.3963, "horizontal_accuracy_m": 6., "heading_degrees": 90.,
            "heading_accuracy_degrees": 10., "relative_altitude_m": 0.1, "pressure_kpa": 101.2},
        "poses": (1..4).map(|k| json!({"t": t - 1. + 0.25 * k as f64, "m": pose(0.0025 * k as f64),
            "tracking": "normal", "mapping": "mapped"})).collect::<Vec<_>>(),
    })
}

async fn send(router: &Router, method: &str, path: &str, body: Vec<u8>) -> (StatusCode, Value) {
    let response = router
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
                .header("content-type", "application/json")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 64 * 1024 * 1024)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn json_bytes(value: Value) -> Vec<u8> {
    serde_json::to_vec(&value).unwrap()
}

#[tokio::test]
async fn finished_stream_is_packaged_as_a_scan_with_movement_geo_and_attachments() {
    let state = AppState::default();
    let router = app(state.clone());
    let manifest = json!({"schema_version": 1, "id": ID, "map_id": ID, "floor_id": "ground",
        "coordinates": {"units": "meters", "up_axis": "y", "handedness": "right"}});
    assert_eq!(
        send(&router, "POST", "/streams", json_bytes(manifest))
            .await
            .0,
        StatusCode::CREATED
    );
    for sequence in 0..3 {
        let (status, body) = send(
            &router,
            "PUT",
            &format!("/streams/{ID}/chunks/{sequence}"),
            json_bytes(chunk(sequence)),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{body}");
    }
    let semantics = json!({"schema_version": 1, "coordinate_frame": "shared_arkit_session",
        "geographic_reference": {"latitude": 33.7756, "longitude": -84.3963, "heading_degrees": 90.},
        "access_points": [{"kind": "elevator", "name": "Lift A", "position": [1., 0., -2.]}]});
    let (status, _) = send(
        &router,
        "PUT",
        &format!("/streams/{ID}/assets/semantics.json"),
        json_bytes(semantics),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = send(
        &router,
        "PUT",
        &format!("/streams/{ID}/assets/evil.json"),
        b"{}".to_vec(),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(
        send(
            &router,
            "POST",
            &format!("/streams/{ID}/finish"),
            json_bytes(json!({"chunk_count": 3}))
        )
        .await
        .0,
        StatusCode::OK
    );
    let (status, result) = send(&router, "GET", &format!("/streams/{ID}/result"), vec![]).await;
    assert_eq!(status, StatusCode::OK, "{result}");

    // Packaging runs in the background after the result is served.
    let mut packaged = false;
    for _ in 0..100 {
        if state.scans.get(ID).await.is_some() {
            packaged = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(packaged, "stream was not packaged as a scan");

    let (status, manifest) = send(&router, "GET", &format!("/scans/{ID}/manifest"), vec![]).await;
    assert_eq!(status, StatusCode::OK);
    let observations = manifest["observations"].as_array().unwrap();
    assert_eq!(observations.len(), 3);
    assert_eq!(manifest["source"]["kind"], "continuous_stream");
    let first = &observations[0];
    assert_eq!(
        first["rgb_image"]["orientation"],
        "upright_rotated_right_from_sensor"
    );
    assert_eq!(
        (
            first["rgb_image"]["width"].as_u64(),
            first["rgb_image"]["height"].as_u64()
        ),
        (Some(18), Some(24))
    );
    assert_eq!(first["raw_depth"]["environment"]["latitude"], 33.7756);
    assert_eq!(first["image"]["width"], 24);

    let (status, track) = send(&router, "GET", &format!("/scans/{ID}/camera-track"), vec![]).await;
    assert_eq!(status, StatusCode::OK, "{track}");
    assert_eq!(track["source"], "camera_track_sidecar");
    // 3 keyframe poses + 3 movement poses per chunk (one coincides with the previous keyframe time).
    assert!(track["poses"].as_array().unwrap().len() >= 9, "{track}");
    assert!(track["poses"][1]["unix_seconds"].as_f64().unwrap() > 1_791_000_000.);

    let (status, stored) = send(
        &router,
        "GET",
        &format!("/scans/{ID}/assets/semantics.json"),
        vec![],
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(stored["access_points"][0]["name"], "Lift A");

    // Depth sidecars decode through the native LiDAR reader, with upright colour keyframes.
    let (status, preview) = send(
        &router,
        "GET",
        &format!("/scans/{ID}/raw-preview?mode=raw&max_points=1000"),
        vec![],
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{preview}");
    assert_eq!(preview["packageFormat"], "binary_sidecars");
    assert_eq!(preview["frames"].as_array().unwrap().len(), 3);
    assert!(
        preview["frames"][0]["colorAsset"]
            .as_str()
            .unwrap()
            .ends_with(".color.jpg")
    );
}

#[tokio::test]
async fn stream_context_is_validated() {
    let router = app(AppState::default());
    let manifest = json!({"schema_version": 1, "id": ID, "map_id": ID, "floor_id": "ground",
        "coordinates": {"units": "meters", "up_axis": "y", "handedness": "right"}});
    send(&router, "POST", "/streams", json_bytes(manifest)).await;
    let mut bad = chunk(0);
    bad["environment"] = json!({"latitude": "north"});
    assert_eq!(
        send(
            &router,
            "PUT",
            &format!("/streams/{ID}/chunks/0"),
            json_bytes(bad)
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    let mut bad = chunk(0);
    bad["poses"][0]["m"][0] = json!(2.0);
    assert_eq!(
        send(
            &router,
            "PUT",
            &format!("/streams/{ID}/chunks/0"),
            json_bytes(bad)
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        send(
            &router,
            "PUT",
            &format!("/streams/{ID}/chunks/0"),
            json_bytes(chunk(0))
        )
        .await
        .0,
        StatusCode::OK
    );
}

#[tokio::test]
async fn full_stream_package_keeps_ocr_evidence_corrects_sidecars_and_previews_240_frames() {
    use inview_backend::{
        alignment::{AlignedFrame, AlignmentResult},
        geometry::Transform,
        scan_package,
        store::StoredScan,
        stream_scan,
        streaming::StreamStore,
    };
    let streams = StreamStore::default();
    streams
        .create(
            json!({"schema_version":1,"id":ID,"map_id":"demo-room-map","floor_id":"ground",
        "coordinates":{"units":"meters","up_axis":"y","handedness":"right"}}),
        )
        .unwrap();
    for sequence in 0..240 {
        streams.append(ID, sequence, chunk(sequence)).unwrap();
    }
    let semantics = json!({"schema_version":1,"coordinate_frame":"shared_arkit_session","access_points":[
        {"id":"recorded","kind":"elevator","name":"Lift A","timestamp_seconds":240.,"position":[1.,0.,-2.],"requires_assistance":true},
        {"id":"manual","kind":"destination","position":[2.,0.,-2.]}]});
    let native = json!([{"doors":[{"identifier":"door","timestamp_seconds":240.,"transform":pose(1.),
        "polygonCorners":[[0.,0.,0.],[1.,0.,0.]],"category":{"door":{"isOpen":true}}}]}]);
    let track = json!({"schema_version":1,"clock":"arkit_uptime_seconds","unix_offset_seconds":1791000000.,
        "poses":[{"t":1.,"m":pose(0.)},{"t":240.,"m":pose(1.)}]});
    let text = json!({"schema_version":1,"observations":[
        {"frame_id":"frame-17","image_asset":"old-keyframe.jpg","text":"Lift A"},
        {"frame_id":"missing-frame","image_asset":"missing.jpg","text":"Untraceable"}]});
    for (name, value) in [
        ("semantics.json", &semantics),
        ("roomplan.json", &native),
        ("camera-track.json", &track),
        ("text-observations.json", &text),
    ] {
        streams
            .put_asset(ID, name, &serde_json::to_vec(value).unwrap())
            .unwrap();
    }
    streams.finish(ID, 240).unwrap();
    // The sealed evidence accepts identical retries, but cannot change after packaging begins.
    streams
        .put_asset(
            ID,
            "semantics.json",
            &serde_json::to_vec(&semantics).unwrap(),
        )
        .unwrap();
    assert!(streams.put_asset(ID, "semantics.json", b"{}").is_err());
    let alignment = AlignmentResult {
        reference_frame: "original_arkit_session".into(),
        optimized: true,
        frames: vec![
            AlignedFrame {
                frame_id: "frame-0".into(),
                timestamp_seconds: 1.,
                original_map_from_camera: Transform(pose(0.)),
                optimized_map_from_camera: Transform(pose(0.)),
            },
            AlignedFrame {
                frame_id: "frame-239".into(),
                timestamp_seconds: 240.,
                original_map_from_camera: Transform(pose(0.)),
                optimized_map_from_camera: Transform(pose(0.5)),
            },
        ],
        constraints: vec![],
        initial_cost: 1.,
        final_cost: 0.,
    };
    let capture: Value = serde_json::from_str(include_str!("../examples/scan.json")).unwrap();
    let result = serde_json::to_vec(&json!({"capture":capture,"alignment":alignment})).unwrap();
    let archive = stream_scan::build_package(&streams, ID, &result).unwrap();
    let package = scan_package::decode(&archive).unwrap();
    let read = |name: &str| -> Value { serde_json::from_slice(&package.assets[name]).unwrap() };
    assert_eq!(read("source-semantics.json"), semantics);
    assert_eq!(read("source-roomplan.json"), native);
    assert_eq!(read("source-camera-track.json"), track);
    assert_eq!(read("source-text-observations.json"), text);
    let corrected = read("semantics.json");
    assert_eq!(corrected["access_points"].as_array().unwrap().len(), 1);
    assert_eq!(corrected["access_points"][0]["position"][0], 1.5);
    assert_eq!(corrected["access_points"][0]["requires_assistance"], true);
    assert_eq!(read("roomplan.json")[0]["doors"][0]["transform"][12], 1.5);
    assert_eq!(
        read("roomplan.json")[0]["doors"][0]["polygonCorners"],
        native[0]["doors"][0]["polygonCorners"]
    );
    assert_eq!(read("camera-track.json")["poses"][0]["m"][12], 0.);
    assert_eq!(read("camera-track.json")["poses"][1]["m"][12], 1.5);
    let ocr = read("text-observations.json");
    assert_eq!(ocr["observations"].as_array().unwrap().len(), 1);
    assert_eq!(ocr["observations"][0]["image_asset"], "s00017.color.jpg");
    assert!(
        package
            .assets
            .contains_key(ocr["observations"][0]["image_asset"].as_str().unwrap())
    );
    assert_eq!(read("derivation.json")["omitted_spatial_records"], 2);
    assert_eq!(
        package.manifest.as_ref().unwrap()["observations"]
            .as_array()
            .unwrap()
            .len(),
        240
    );
    let state = AppState::default();
    state
        .scans
        .insert(
            StoredScan {
                original: package.original,
                bundle: package.bundle,
                package_assets: Some(package.assets),
                package_manifest: package.manifest,
            },
            None,
        )
        .await
        .unwrap();
    let router = app(state);
    let (status, preview) = send(
        &router,
        "GET",
        &format!("/scans/{ID}/raw-preview?mode=raw&max_points=1000"),
        vec![],
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{preview}");
    assert_eq!(preview["frames"].as_array().unwrap().len(), 240);
}
