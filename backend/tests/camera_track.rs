//! The iPhone's dense `camera-track.json` and OCR stills, as staged by `CaptureStore`.
use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use inview_backend::{
    AppState, app, scan_package,
    store::{ScanStore, StoredScan, TrackSource, parse_camera_track},
};
use serde_json::{Value, json};
use tower::ServiceExt;

const OFFSET: f64 = 1_791_000_000.25;

fn pose(x: f64) -> Value {
    json!([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, 1.4, 0, 1])
}

fn camera_track() -> Value {
    let mut poses: Vec<Value> = (0..20)
        .map(|i| {
            json!({"t": 100.0 + i as f64 * 0.1, "m": pose(i as f64 * 0.05),
                   "tracking": if i < 2 { "limited:insufficient_features" } else { "normal" },
                   "mapping": if i < 10 { "limited" } else { "mapped" }})
        })
        .collect();
    // Dropped: no tracking, relocalizing jump, non-rigid matrix, time going backwards.
    poses.push(
        json!({"t": 102.5, "m": pose(9.), "tracking": "not_available", "mapping": "limited"}),
    );
    poses.push(
        json!({"t": 102.55, "m": pose(9.), "tracking": "limited:relocalizing", "mapping": "limited"}),
    );
    poses.push(json!({"t": 102.6, "m": [2,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1], "tracking": "normal", "mapping": "mapped"}));
    poses.push(json!({"t": 101.0, "m": pose(1.), "tracking": "normal", "mapping": "mapped"}));
    json!({"schema_version": 1, "clock": "arkit_uptime_seconds",
           "unix_offset_seconds": OFFSET, "sample_interval_seconds": 0.1, "poses": poses})
}

/// A package with one manifest observation (carrying an OCR still) and optional extra files.
fn package(track: Option<Vec<u8>>, ocr_file: bool) -> Vec<u8> {
    let mut capture: Value =
        serde_json::from_slice(include_bytes!("../examples/scan.json")).unwrap();
    capture["id"] = json!("track-1");
    capture["frames"] = json!([]);
    let mut files: Vec<(String, Vec<u8>)> = vec![
        ("capture.json".into(), serde_json::to_vec(&capture).unwrap()),
        ("obs-1.depth-f32le".into(), vec![0; 6 * 4]),
    ];
    if ocr_file {
        files.push(("obs-1.ocr.jpg".into(), vec![0xff, 0xd8, 0xff, 0xd9]));
    }
    if let Some(track) = track {
        files.push(("camera-track.json".into(), track));
    }
    let assets: Vec<Value> = files
        .iter()
        .map(|(path, bytes)| {
            let role = if path == "capture.json" { "portable_capture" } else { "opaque_sidecar" };
            json!({"path": path, "role": role, "media_type": "application/octet-stream", "bytes": bytes.len()})
        })
        .collect();
    let manifest = json!({
        "schema_version": 1, "capture_id": "track-1",
        "map_id": capture["map_id"], "floor_id": capture["floor_id"],
        "coordinate_frame": {"units": "meters", "up_axis": "y", "handedness": "right",
                             "name": "shared_arkit_session"},
        "assets": assets,
        "observations": [{
            "id": "obs-1", "timestamp_seconds": 100.5, "map_from_camera": pose(3.),
            "image": {"width": 6, "height": 4, "fx": 4, "fy": 4, "cx": 2, "cy": 1},
            "raw_depth": {"raw_asset": "obs-1.depth-f32le", "width": 3, "height": 2,
                          "bytes_per_row": 12, "pixel_format": 1717855600u32},
            "ocr_asset": "obs-1.ocr.jpg",
            "ocr_image": {"width": 1440, "height": 1920, "orientation": "rotated_90_cw_from_sensor"}
        }],
    });
    files.push((
        "package-manifest.json".into(),
        serde_json::to_vec(&manifest).unwrap(),
    ));
    let mut tar = tar::Builder::new(Vec::new());
    for (name, bytes) in files {
        let mut header = tar::Header::new_ustar();
        header.set_size(bytes.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        tar.append_data(&mut header, format!("track-1/{name}"), bytes.as_slice())
            .unwrap();
    }
    tar.into_inner().unwrap()
}

fn stored(bytes: &[u8]) -> StoredScan {
    let package = scan_package::decode(bytes).unwrap();
    StoredScan {
        original: package.original,
        bundle: package.bundle,
        package_assets: Some(package.assets),
        package_manifest: package.manifest,
    }
}

async fn call(router: &Router, path: &str, method: &str, data: Vec<u8>) -> (StatusCode, Value) {
    let response = router
        .clone()
        .oneshot(
            Request::builder()
                .uri(path)
                .method(method)
                .header("content-type", "application/x-tar")
                .body(Body::from(data))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 16 * 1024 * 1024)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

#[test]
fn dense_track_is_validated_and_converted_to_unix_time() {
    let points = parse_camera_track(&serde_json::to_vec(&camera_track()).unwrap()).unwrap();
    assert_eq!(points.len(), 20);
    assert_eq!(
        points[0].tracking.as_deref(),
        Some("limited:insufficient_features")
    );
    assert_eq!(points[19].mapping.as_deref(), Some("mapped"));
    assert!((points[5].timestamp_seconds - 100.5).abs() < 1e-9);
    assert!((points[5].unix_seconds.unwrap() - (100.5 + OFFSET)).abs() < 1e-6);
    assert!(
        points
            .windows(2)
            .all(|w| w[0].timestamp_seconds < w[1].timestamp_seconds)
    );

    let mut other_clock = camera_track();
    other_clock["clock"] = json!("unix_seconds");
    assert!(parse_camera_track(&serde_json::to_vec(&other_clock).unwrap()).is_err());
    let mut no_offset = camera_track();
    no_offset["unix_offset_seconds"] = Value::Null;
    let points = parse_camera_track(&serde_json::to_vec(&no_offset).unwrap()).unwrap();
    assert!(points.iter().all(|p| p.unix_seconds.is_none()));
}

#[test]
fn sidecar_is_preferred_and_bad_sidecars_fall_back_to_the_manifest() {
    let dense = stored(&package(
        Some(serde_json::to_vec(&camera_track()).unwrap()),
        true,
    ));
    let (track, source) = dense.camera_track_with_source();
    assert_eq!(source, TrackSource::CameraTrackSidecar);
    assert_eq!(track.len(), 20);

    for bad in [
        b"{not json".to_vec(),
        br#"{"schema_version":2,"clock":"arkit_uptime_seconds","poses":[]}"#.to_vec(),
    ] {
        let scan = stored(&package(Some(bad), true));
        let (track, source) = scan.camera_track_with_source();
        assert_eq!(source, TrackSource::PackageManifest);
        assert_eq!(track.len(), 1);
        assert_eq!(track[0].map_from_camera.0[12], 3.0);
        assert!(track[0].tracking.is_none());
    }
    let (_, source) = stored(&package(None, true)).camera_track_with_source();
    assert_eq!(source, TrackSource::PackageManifest);
}

#[test]
fn manifest_ocr_still_must_exist() {
    let error = scan_package::decode(&package(None, false))
        .err()
        .expect("an OCR still reference without its file must be rejected");
    assert!(error.contains("missing OCR still"), "{error}");
}

#[tokio::test]
async fn camera_track_endpoint_serves_dense_poses_with_unix_times() {
    let directory =
        std::env::temp_dir().join(format!("inview-camera-track-{}", uuid::Uuid::new_v4()));
    let router = app(AppState {
        scans: ScanStore::open(&directory).unwrap(),
        ..AppState::default()
    });
    let bytes = package(Some(serde_json::to_vec(&camera_track()).unwrap()), true);
    let (status, summary) = call(&router, "/scan-packages", "POST", bytes).await;
    assert_eq!(status, StatusCode::CREATED, "{summary}");

    let (status, body) = call(&router, "/scans/track-1/camera-track", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["source"], "camera_track_sidecar");
    let poses = body["poses"].as_array().unwrap();
    assert_eq!(poses.len(), 20);
    assert_eq!(poses[3]["tracking"], "normal");
    assert_eq!(
        poses[3]["position_m"],
        json!([0.15000000000000002, 1.4, 0.0])
    );
    let unix = poses[3]["unix_seconds"].as_f64().unwrap();
    assert!((unix - (100.3 + OFFSET)).abs() < 1e-6, "{unix}");

    let (status, manifest) = call(&router, "/scans/track-1/manifest", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(manifest["observations"][0]["ocr_asset"], "obs-1.ocr.jpg");
    let (status, _) = call(
        &router,
        "/scans/track-1/assets/obs-1.ocr.jpg",
        "GET",
        vec![],
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // The persisted package reloads with its dense track.
    let reopened = ScanStore::open(&directory).unwrap();
    let (track, source) = reopened
        .get("track-1")
        .await
        .unwrap()
        .camera_track_with_source();
    assert_eq!(source, TrackSource::CameraTrackSidecar);
    assert_eq!(track.len(), 20);
    std::fs::remove_dir_all(directory).unwrap();
}
