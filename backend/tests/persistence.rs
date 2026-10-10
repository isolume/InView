use std::{fs, path::PathBuf, sync::Arc};

use axum::{
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use inview_backend::{AppState, app, scan_package, store::ScanStore};
use serde_json::Value;
use tower::ServiceExt;

fn temporary_directory() -> PathBuf {
    std::env::temp_dir().join(format!("inview-scans-{}", uuid::Uuid::new_v4()))
}

fn archive(capture: &[u8]) -> Vec<u8> {
    let mut builder = tar::Builder::new(Vec::new());
    for (name, bytes) in [
        ("capture.json", capture),
        ("worldmap.archive", &[1_u8, 2, 3][..]),
    ] {
        let mut header = tar::Header::new_ustar();
        header.set_size(bytes.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        builder
            .append_data(&mut header, format!("demo-room/{name}"), bytes)
            .unwrap();
    }
    builder.into_inner().unwrap()
}

async fn send(state: AppState, uri: &str, method: &str, body: Vec<u8>) -> (StatusCode, Value) {
    let response = app(state)
        .oneshot(
            Request::builder()
                .uri(uri)
                .method(method)
                .header("content-type", "application/json")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let body = to_bytes(response.into_body(), 32 * 1024 * 1024)
        .await
        .unwrap();
    (status, serde_json::from_slice(&body).unwrap())
}

#[tokio::test]
async fn bearer_token_guards_health_scans_and_buildings() {
    let state = AppState {
        api_token: Some(Arc::from("this-is-a-long-test-access-token-12345")),
        ..AppState::default()
    };
    let denied = app(state.clone())
        .oneshot(
            Request::builder()
                .uri("/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::UNAUTHORIZED);
    let denied = app(state.clone())
        .oneshot(
            Request::builder()
                .uri("/api/buildings")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::UNAUTHORIZED);
    let allowed = app(state.clone())
        .oneshot(
            Request::builder()
                .uri("/health")
                .header(
                    "Authorization",
                    "Bearer this-is-a-long-test-access-token-12345",
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(allowed.status(), StatusCode::OK);
    let malformed = app(state)
        .oneshot(
            Request::builder()
                .uri("/health")
                .header(
                    "Authorization",
                    "Bearer this-is-a-long-test-access-token-12346",
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(malformed.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn json_scan_is_immutable_and_available_after_restart() {
    let dir = temporary_directory();
    let capture = include_bytes!("../examples/scan.json").to_vec();
    let first = AppState {
        scans: ScanStore::open(&dir).unwrap(),
        ..AppState::default()
    };
    assert_eq!(
        send(first.clone(), "/scans", "POST", capture.clone())
            .await
            .0,
        StatusCode::CREATED
    );
    assert_eq!(
        send(first, "/scans", "POST", capture).await.0,
        StatusCode::CONFLICT
    );
    let second = AppState {
        scans: ScanStore::open(&dir).unwrap(),
        ..AppState::default()
    };
    let (status, source) = send(second.clone(), "/scans/demo-room", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(source["id"], "demo-room");
    assert_eq!(
        send(second, "/scans/demo-room/scene", "GET", vec![])
            .await
            .0,
        StatusCode::OK
    );
    fs::remove_dir_all(&dir).unwrap();
}

#[tokio::test]
async fn archive_and_sidecars_survive_restart_without_database_blobs() {
    let dir = temporary_directory();
    let raw = archive(include_bytes!("../examples/scan.json"));
    let first = AppState {
        scans: ScanStore::open(&dir).unwrap(),
        ..AppState::default()
    };
    assert_eq!(
        send(first, "/scan-packages", "POST", raw.clone()).await.0,
        StatusCode::CREATED
    );
    let entries: Vec<_> = fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].extension().unwrap(), "tar");
    assert_eq!(fs::read(&entries[0]).unwrap(), raw);
    let second = ScanStore::open(&dir).unwrap();
    let scan = second.get("demo-room").await.unwrap();
    assert_eq!(
        scan.package_assets.as_ref().unwrap()["worldmap.archive"],
        [1, 2, 3]
    );
    assert_eq!(scan.bundle.id, "demo-room");
    assert!(scan_package::decode(&raw).is_ok());
    fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn corrupt_archive_fails_startup() {
    let dir = temporary_directory();
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join(format!("{}.tar", "0".repeat(64))),
        b"not an archive",
    )
    .unwrap();
    assert!(ScanStore::open(&dir).is_err());
    fs::remove_dir_all(&dir).unwrap();
}

#[tokio::test]
async fn scan_id_never_becomes_a_disk_path() {
    let dir = temporary_directory();
    let mut source: Value =
        serde_json::from_slice(include_bytes!("../examples/scan.json")).unwrap();
    source["id"] = "../../escape".into();
    let state = AppState {
        scans: ScanStore::open(&dir).unwrap(),
        ..AppState::default()
    };
    assert_eq!(
        send(
            state,
            "/scans",
            "POST",
            serde_json::to_vec(&source).unwrap()
        )
        .await
        .0,
        StatusCode::CREATED
    );
    let files: Vec<_> = fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].to_str().unwrap().len(), 64 + ".json".len());
    fs::remove_dir_all(&dir).unwrap();
}

#[tokio::test]
async fn analysis_is_validated_replaceable_and_survives_restart() {
    let directory = temporary_directory();
    let state = AppState {
        scans: ScanStore::open(&directory).unwrap(),
        ..AppState::default()
    };
    let scan = include_bytes!("../examples/scan.json").to_vec();
    assert_eq!(
        send(state.clone(), "/scans", "POST", scan).await.0,
        StatusCode::CREATED
    );
    let (status, _) = send(state.clone(), "/scans/demo-room/analysis", "GET", vec![]).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let wrong = serde_json::to_vec(
        &serde_json::json!({"schema_version":1,"scan_id":"other","frame":"shared_arkit_session"}),
    )
    .unwrap();
    let (status, _) = send(state.clone(), "/scans/demo-room/analysis", "PUT", wrong).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    for run in [1, 2] {
        let body = serde_json::json!({"schema_version":1,"scan_id":"demo-room","frame":"shared_arkit_session","run":run});
        let (status, _) = send(
            state.clone(),
            "/scans/demo-room/analysis",
            "PUT",
            serde_json::to_vec(&body).unwrap(),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }
    let reopened = AppState {
        scans: ScanStore::open(&directory).unwrap(),
        ..AppState::default()
    };
    let (status, stored) = send(reopened.clone(), "/scans/demo-room/analysis", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(stored["run"], 2);
    let (status, track) = send(reopened, "/scans/demo-room/camera-track", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        track["poses"][0]["position_m"],
        serde_json::json!([0., 1.4, 1.8])
    );
    std::fs::remove_dir_all(directory).unwrap();
}
