use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};

use axum::{
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use inview_backend::{
    AppState, app,
    capture::ScanBundle,
    recognition_service::RecognitionConfig,
    streaming::{StreamError, StreamStore},
};
use serde_json::{Value, json};
use tower::ServiceExt;

static NEXT: AtomicU64 = AtomicU64::new(0);
const ID: &str = "2a6b0b22-d7a6-4ecd-8086-0cb1c2d9f8d2";
const IDENTITY: [f64; 16] = [
    1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
];

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "inview-recognition-integration-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn config(&self, fail: bool) -> RecognitionConfig {
        let worker = self.0.join(if fail { "failed.py" } else { "worker.py" });
        let source = if fail {
            "import sys,json\nfor line in sys.stdin:\n r=json.loads(line);print(json.dumps({'request_id':r['request_id'],'error':'Local inference unavailable.','fatal':True}),flush=True)\n"
        } else {
            "import sys,json,time\nfor line in sys.stdin:\n r=json.loads(line);time.sleep(.2);w=r['depth_width'];indices=[y*w+x for y in range(8,24) for x in range(8,24)];print(json.dumps({'request_id':r['request_id'],'detections':[{'category':'table','score':.95,'depth_indices':indices}]}),flush=True)\n"
        };
        fs::write(&worker, source).unwrap();
        RecognitionConfig::for_worker(
            "python3",
            worker,
            if fail { "failed-v1" } else { "synthetic-v1" },
        )
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn chunk(sequence: usize) -> Value {
    let mut pose = IDENTITY;
    pose[12] = sequence as f64 * 0.18;
    json!({"sequence":sequence,"color_jpeg":STANDARD.encode(include_bytes!("fixtures/stream-color.jpg")),
        "frame":{"id":format!("frame-{sequence}"),"timestamp_seconds":1.+sequence as f64*2.,
        "pixel_orientation":"sensor_native","map_from_camera":pose,
        "camera":{"image_width":4,"image_height":4,"fx":5.,"fy":5.,"cx":1.9375,"cy":1.9375},
        "depth":{"width":32,"height":32,"values_m":(0..1024).map(|index|1.8+(index/32) as f64*0.02).collect::<Vec<_>>(),
        "confidence":vec![2;1024]}}})
}

fn populate(store: &StreamStore) {
    store
        .create(
            json!({"schema_version":1,"id":ID,"map_id":"synthetic","floor_id":"ground",
        "coordinates":{"units":"meters","up_axis":"y","handedness":"right"}}),
        )
        .unwrap();
    store.append(ID, 0, chunk(0)).unwrap();
    store.append(ID, 1, chunk(1)).unwrap();
    store.finish(ID, 2).unwrap();
}

async fn ready(store: &StreamStore) -> Value {
    for _ in 0..100 {
        match store.reconstruct_encoded(ID, false) {
            Ok(bytes) => return serde_json::from_slice(&bytes).unwrap(),
            Err(StreamError::RecognitionPending) => {
                tokio::time::sleep(Duration::from_millis(20)).await
            }
            Err(error) => panic!("Unexpected reconstruction failure: {error:?}"),
        }
    }
    panic!("Mock recognition did not complete");
}

#[tokio::test]
async fn recognition_runs_during_upload_and_returns_existing_catalog_models_with_valid_source() {
    let temp = Temp::new();
    let store = StreamStore::open(temp.0.join("streams"))
        .unwrap()
        .with_recognition(temp.config(false))
        .unwrap();
    populate(&store);
    let original_path = temp.0.join("streams").join(ID).join("chunk-000000.json");
    let original = fs::read(&original_path).unwrap();
    let router = app(AppState {
        streams: store.clone(),
        ..AppState::default()
    });
    let response = router
        .oneshot(
            Request::builder()
                .uri(format!("/streams/{ID}/result"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let pending: Value =
        serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap()).unwrap();
    assert_eq!(pending["error"]["code"], "recognition_pending");
    let result = ready(&store).await;
    assert_eq!(
        result["capture"]["metadata"]["recognition"]["worker"]["status"],
        "complete"
    );
    assert_eq!(result["capture"]["objects"].as_array().unwrap().len(), 1);
    let object = &result["scene"]["objects"][0];
    assert_eq!(object["source_category"], "table");
    assert_ne!(object["model_key"], "bounds_v1");
    assert!(object["model_meshes"].as_array().unwrap().is_empty());
    assert!(!object["parts"].as_array().unwrap().is_empty());
    assert_eq!(
        result["capture"]["metadata"]["model_catalog"],
        "photo-furniture-v1"
    );
    let capture: ScanBundle = serde_json::from_value(result["capture"].clone()).unwrap();
    capture.validate().unwrap();
    assert_eq!(
        object["measured_dimensions_m"],
        result["capture"]["objects"][0]["dimensions_m"]
    );
    assert_eq!(fs::read(original_path).unwrap(), original);
    assert_eq!(
        serde_json::from_slice::<Value>(&store.reconstruct_encoded(ID, false).unwrap()).unwrap(),
        result
    );
}

#[tokio::test]
async fn disabling_recognition_cannot_reuse_a_model_from_an_enabled_pipeline() {
    let temp = Temp::new();
    let root = temp.0.join("streams");
    let store = StreamStore::open(&root)
        .unwrap()
        .with_recognition(temp.config(false))
        .unwrap();
    populate(&store);
    let recognized = ready(&store).await;
    assert!(
        !recognized["capture"]["objects"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    drop(store);
    let disabled = StreamStore::open(&root).unwrap();
    let result: Value =
        serde_json::from_slice(&disabled.reconstruct_encoded(ID, false).unwrap()).unwrap();
    assert_eq!(
        result["capture"]["metadata"]["recognition"]["worker"]["status"],
        "disabled"
    );
    assert!(result["capture"]["objects"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn failed_recognition_keeps_depth_geometry_without_caching_a_complete_result() {
    let temp = Temp::new();
    let root = temp.0.join("streams");
    let store = StreamStore::open(&root)
        .unwrap()
        .with_recognition(temp.config(true))
        .unwrap();
    populate(&store);
    let result = ready(&store).await;
    assert_eq!(
        result["capture"]["metadata"]["recognition"]["worker"]["status"],
        "unavailable"
    );
    assert!(!result["capture"]["meshes"].as_array().unwrap().is_empty());
    assert!(!root.join(ID).join("reconstruction-v5-cache.json").exists());
    assert!(
        result["scene"]["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|warning| warning
                .as_str()
                .unwrap()
                .contains("Furniture recognition was unavailable"))
    );
}
