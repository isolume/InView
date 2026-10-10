use std::{fs, path::PathBuf, sync::Arc};

use axum::{
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use inview_backend::{
    AppState, app, scan_package,
    store::{GraphStore, ScanStore},
};
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

fn demo_graph(id: &str, label: &str) -> Vec<u8> {
    let mut graph: Value =
        serde_json::from_slice(include_bytes!("../examples/graph.json")).unwrap();
    graph["id"] = Value::from(id);
    graph["nodes"][0]["label"] = Value::from(label);
    serde_json::to_vec(&graph).unwrap()
}

#[tokio::test]
async fn graphs_survive_restart_and_replacements_persist() {
    let dir = temporary_directory();
    let graphs_dir = dir.join("graphs");
    let first = AppState {
        graphs: GraphStore::open(&graphs_dir).unwrap(),
        ..AppState::default()
    };
    let (status, summary) = send(
        first.clone(),
        "/graphs/scan-1-nav",
        "PUT",
        demo_graph("scan-1-nav", "Front door"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(summary["node_count"], 4);
    let (status, _) = send(
        first.clone(),
        "/graphs/scan-1-nav",
        "PUT",
        demo_graph("scan-1-nav", "Main entrance"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    // Invalid replacements are rejected before touching disk.
    let mut invalid: Value = serde_json::from_slice(&demo_graph("scan-1-nav", "x")).unwrap();
    invalid["schema_version"] = Value::from(2);
    let (status, _) = send(
        first,
        "/graphs/scan-1-nav",
        "PUT",
        serde_json::to_vec(&invalid).unwrap(),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);

    let files: Vec<_> = fs::read_dir(&graphs_dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(
        files.len(),
        1,
        "one replaceable file, no temp leftovers: {files:?}"
    );

    let restarted = AppState {
        graphs: GraphStore::open(&graphs_dir).unwrap(),
        ..AppState::default()
    };
    let (status, graph) = send(restarted.clone(), "/graphs/scan-1-nav", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(graph["nodes"][0]["label"], "Main entrance");
    let (status, list) = send(restarted.clone(), "/graphs", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(list.as_array().unwrap().len(), 1);
    let (status, route) = send(
        restarted,
        "/graphs/scan-1-nav/routes",
        "POST",
        br#"{"from":"entrance","to":"room-204"}"#.to_vec(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{route}");
    fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn corrupt_invalid_or_misnamed_graph_files_are_skipped() {
    let dir = temporary_directory();
    let graphs_dir = dir.join("graphs");
    let state = AppState {
        graphs: GraphStore::open(&graphs_dir).unwrap(),
        ..AppState::default()
    };
    assert_eq!(
        send(state, "/graphs/good", "PUT", demo_graph("good", "Lobby"))
            .await
            .0,
        StatusCode::OK
    );
    fs::write(graphs_dir.join("corrupt.json"), b"{ not json").unwrap();
    // Valid graph JSON, but the file name is not the hash of its id.
    fs::write(
        graphs_dir.join("misnamed.json"),
        demo_graph("other", "Hall"),
    )
    .unwrap();
    let mut invalid: Value = serde_json::from_slice(&demo_graph("bad", "x")).unwrap();
    invalid["edges"][0]["to"] = Value::from("missing-node");
    fs::write(
        graphs_dir.join("invalid.json"),
        serde_json::to_vec(&invalid).unwrap(),
    )
    .unwrap();
    fs::write(graphs_dir.join("notes.txt"), b"ignored").unwrap();

    let state = AppState {
        graphs: GraphStore::open(&graphs_dir).unwrap(),
        ..AppState::default()
    };
    let (status, list) = send(state.clone(), "/graphs", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK);
    let ids: Vec<_> = list
        .as_array()
        .unwrap()
        .iter()
        .map(|g| g["id"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(ids, ["good"]);
    assert_eq!(
        send(state, "/graphs/other", "GET", vec![]).await.0,
        StatusCode::NOT_FOUND
    );
    fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn scan_directory_tolerates_graph_subdirectory() {
    let dir = temporary_directory();
    GraphStore::open(dir.join("graphs")).unwrap();
    ScanStore::open(&dir).unwrap();
    fs::remove_dir_all(dir).unwrap();
}
