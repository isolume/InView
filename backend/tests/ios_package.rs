//! Mirrors `CaptureStore.makeArchive` on the iPhone: a full-walk package whose native depth and
//! mesh live in binary sidecars indexed by `package-manifest.json`, with no base64 snapshot and
//! with portable frames/meshes omitted from `capture.json` to respect its JSON upload limit.
use std::path::PathBuf;

use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use inview_backend::{AppState, app, scan_package, store::ScanStore};
use serde_json::{Value, json};
use tower::ServiceExt;

const FRAMES: usize = 32;
const ANCHORS: usize = 300;

fn le_f32(values: &[f32]) -> Vec<u8> {
    values.iter().flat_map(|v| v.to_le_bytes()).collect()
}

fn package() -> Vec<u8> {
    let mut capture: Value =
        serde_json::from_slice(include_bytes!("../examples/scan.json")).unwrap();
    capture["id"] = json!("walk-1");
    capture["frames"] = json!([]);
    capture["meshes"] = json!([]);
    capture["metadata"]["raw_upload_omissions"] = json!([
        "depth_frames_exceed_upload_limit",
        "mesh_snapshot_exceeds_upload_limit"
    ]);

    let mut files: Vec<(String, Vec<u8>)> = vec![
        ("capture.json".into(), serde_json::to_vec(&capture).unwrap()),
        ("roomplan.json".into(), b"[]".to_vec()),
        ("worldmap.archive".into(), vec![1, 2, 3]),
    ];
    let mut observations = Vec::new();
    for index in 0..FRAMES {
        let id = format!("frame-{index:02}");
        // 3×2 depth padded to a 16-byte row stride, like CoreVideo's aligned buffers.
        let mut depth = vec![0u8; 16 * 2];
        for (offset, value) in [
            (0, 1.0f32),
            (4, 2.0),
            (8, 1.5),
            (16, 1.0),
            (20, 1.0),
            (24, 1.0),
        ] {
            depth[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        }
        files.push((format!("{id}.depth-f32le"), depth));
        files.push((format!("{id}.confidence-u8"), vec![2, 0, 2, 0, 2, 2, 2, 0]));
        files.push((format!("{id}.smoothed-depth-f32le"), le_f32(&[1.5; 6])));
        let rgb = (index % 3 == 0).then(|| format!("{id}.color.jpg"));
        if let Some(name) = &rgb {
            files.push((name.clone(), vec![0xff, 0xd8, 0xff, 0xd9]));
        }
        observations.push(json!({
            "id": id, "timestamp_seconds": 10.0 + index as f64, "rgb_asset": rgb,
            "map_from_camera": [1,0,0,0, 0,1,0,0, 0,0,1,0, index as f64 * 0.5, 1.4, 0, 1],
            "image": {"width": 6, "height": 4, "fx": 4, "fy": 4, "cx": 2, "cy": 1},
            "raw_depth": {
                "raw_asset": format!("{id}.depth-f32le"),
                "confidence_asset": format!("{id}.confidence-u8"),
                "smoothed_asset": format!("{id}.smoothed-depth-f32le"),
                "width": 3, "height": 2, "bytes_per_row": 16, "pixel_format": 1717855600u32,
                "confidence_bytes_per_row": 4,
                "smoothed_width": 3, "smoothed_height": 2, "smoothed_bytes_per_row": 12,
                "smoothed_pixel_format": 1717855600u32,
                "environment": {"recorded_at_unix_seconds": 1_791_000_000.0 + index as f64,
                                "latitude": 33.75, "longitude": -84.39, "horizontal_accuracy_m": 8.0}
            }
        }));
    }
    let mut anchors = Vec::new();
    for index in 0..ANCHORS {
        let id = format!("anchor-{index:03}");
        files.push((
            format!("{id}.mesh-vertices"),
            le_f32(&[0., 0., 0., 1., 0., 0., 0., 0., 1.]),
        ));
        files.push((
            format!("{id}.mesh-faces"),
            [0u32, 1, 2].iter().flat_map(|v| v.to_le_bytes()).collect(),
        ));
        files.push((
            format!("{id}.mesh-normals"),
            le_f32(&[0., 1., 0., 0., 1., 0., 0., 1., 0.]),
        ));
        files.push((format!("{id}.mesh-classification-u8"), vec![2]));
        anchors.push(json!({
            "id": id, "map_from_anchor": [1,0,0,0, 0,1,0,0, 0,0,1,0, index as f64, 0, 0, 1],
            "vertices_asset": format!("{id}.mesh-vertices"), "faces_asset": format!("{id}.mesh-faces"),
            "normals_asset": format!("{id}.mesh-normals"),
            "classification_asset": format!("{id}.mesh-classification-u8"),
            "vertex_offset": 0, "vertex_stride": 12, "vertex_format": 30, "vertex_count": 3,
            "bytes_per_index": 4, "face_count": 1, "indices_per_face": 3,
            "normal_offset": 0, "normal_stride": 12, "normal_format": 30,
            "classification_offset": 0, "classification_stride": 1
        }));
    }
    files.sort();
    let assets: Vec<Value> = files
        .iter()
        .map(|(path, bytes)| {
            let role = if path == "capture.json" { "portable_capture" } else { "opaque_sidecar" };
            json!({"path": path, "role": role, "media_type": "application/octet-stream", "bytes": bytes.len()})
        })
        .collect();
    let manifest = json!({
        "schema_version": 1, "capture_id": "walk-1",
        "map_id": capture["map_id"], "floor_id": capture["floor_id"],
        "coordinate_frame": {"units": "meters", "up_axis": "y", "handedness": "right",
                             "name": "shared_arkit_session"},
        "assets": assets, "observations": observations, "mesh_anchors": anchors,
    });
    files.push((
        "package-manifest.json".into(),
        serde_json::to_vec(&manifest).unwrap(),
    ));
    assert!(
        files.len() > 256,
        "fixture must exceed the former entry limit"
    );

    let mut tar = tar::Builder::new(Vec::new());
    for (name, bytes) in files {
        let mut header = tar::Header::new_ustar();
        header.set_size(bytes.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        tar.append_data(&mut header, format!("walk-1/{name}"), bytes.as_slice())
            .unwrap();
    }
    tar.into_inner().unwrap()
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
    let bytes = to_bytes(response.into_body(), 64 * 1024 * 1024)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

#[tokio::test]
async fn full_walk_sidecar_package_round_trips() {
    let directory: PathBuf =
        std::env::temp_dir().join(format!("inview-ios-package-{}", uuid::Uuid::new_v4()));
    let router = app(AppState {
        scans: ScanStore::open(&directory).unwrap(),
        ..AppState::default()
    });
    let (status, summary) = call(&router, "/scan-packages", "POST", package()).await;
    assert_eq!(status, StatusCode::CREATED, "{summary}");
    // The iPhone compares this summary with its own capture.json counts.
    assert_eq!(summary["frame_count"], 0);
    assert_eq!(summary["mesh_count"], 0);

    let (status, preview) = call(
        &router,
        "/scans/walk-1/raw-preview?mode=smoothed&max_points=1000",
        "GET",
        vec![],
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{preview}");
    assert_eq!(preview["packageFormat"], "binary_sidecars");
    assert_eq!(preview["frames"].as_array().unwrap().len(), FRAMES);
    assert_eq!(preview["frames"][0]["usedSmoothed"], true);
    assert_eq!(preview["frames"][0]["colorAsset"], "frame-00.color.jpg");
    assert_eq!(preview["frames"][1]["colorAsset"], Value::Null);
    // Pose comes from the manifest observation even though capture.json has no frames.
    let first = &preview["frames"][3]["points"][0];
    assert!(
        (first[0].as_f64().unwrap() - (1.5 - 0.375)).abs() < 1e-5,
        "{first}"
    );

    let (status, raw) = call(
        &router,
        "/scans/walk-1/raw-preview?mode=raw&max_points=1000",
        "GET",
        vec![],
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{raw}");
    // One confidence-zero pixel per frame is rejected; row padding is never read as depth.
    assert_eq!(raw["pointCount"], FRAMES * 5);

    let (status, mesh) = call(&router, "/scans/walk-1/native-mesh", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK, "{mesh}");
    assert_eq!(mesh["packageFormat"], "binary_sidecars");
    assert_eq!(mesh["vertexCount"], ANCHORS * 3);
    assert_eq!(mesh["meshes"][299]["vertices"][1], json!([300., 0., 0.]));

    let (status, manifest) = call(&router, "/scans/walk-1/manifest", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(manifest["observations"].as_array().unwrap().len(), FRAMES);
    let (status, roomplan) =
        call(&router, "/scans/walk-1/assets/roomplan.json", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(roomplan, json!([]));
    let (status, _) = call(&router, "/scans/walk-1/assets/missing.bin", "GET", vec![]).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let response = router
        .clone()
        .oneshot(
            Request::builder()
                .uri("/scans/walk-1/color/frame-03.color.jpg")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let (status, _) = call(
        &router,
        "/scans/walk-1/color/frame-01.color.jpg",
        "GET",
        vec![],
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // The persisted package reloads, and building evidence uses the full manifest track.
    let reopened = ScanStore::open(&directory).unwrap();
    let scan = reopened.get("walk-1").await.unwrap();
    let track = scan.camera_track();
    assert_eq!(track.len(), FRAMES);
    assert_eq!(track[2].timestamp_seconds, 12.0);
    assert_eq!(track[2].unix_seconds, Some(1_791_000_002.0));
    assert_eq!(track[4].map_from_camera.0[12], 2.0);
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn manifest_depth_without_pose_or_portable_frame_is_rejected() {
    let bytes = package();
    let mut archive = tar::Archive::new(bytes.as_slice());
    let mut files: Vec<(String, Vec<u8>)> = archive
        .entries()
        .unwrap()
        .map(|entry| {
            let mut entry = entry.unwrap();
            let path = entry.path().unwrap().to_string_lossy().into_owned();
            let mut data = Vec::new();
            std::io::Read::read_to_end(&mut entry, &mut data).unwrap();
            (path, data)
        })
        .collect();
    let manifest = files
        .iter_mut()
        .find(|(path, _)| path.ends_with("package-manifest.json"))
        .unwrap();
    let mut value: Value = serde_json::from_slice(&manifest.1).unwrap();
    value["observations"][0]
        .as_object_mut()
        .unwrap()
        .remove("map_from_camera");
    manifest.1 = serde_json::to_vec(&value).unwrap();
    let mut tar = tar::Builder::new(Vec::new());
    for (name, data) in files {
        let mut header = tar::Header::new_ustar();
        header.set_size(data.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        tar.append_data(&mut header, name, data.as_slice()).unwrap();
    }
    let error = scan_package::decode(&tar.into_inner().unwrap())
        .err()
        .expect("depth without any camera pose must be rejected");
    assert!(error.contains("unknown depth frame"), "{error}");
}
