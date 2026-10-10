use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    thread,
    time::{Duration, Instant},
};

use inview_backend::{
    capture::DepthFrame,
    recognition_service::{
        RecognitionConfig, RecognitionService, RecognitionSnapshot, RecognitionStatus,
        image_rotation_degrees,
    },
};
use serde_json::{Value, json};

const ID: &str = "720f6ddd-a87b-4a84-b2a5-2b0cdeac78b6";
const OTHER: &str = "f31a47f8-0ad8-4dba-bc0f-7e09bc1bf38a";
const IDENTITY: [f64; 16] = [
    1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
];
static NEXT: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    worker: PathBuf,
    log: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "inview-recognition-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        fs::create_dir(root.join(ID)).unwrap();
        fs::create_dir(root.join(OTHER)).unwrap();
        let worker = root.join("worker.py");
        let log = root.join("requests.jsonl");
        fs::write(&worker,r#"import json,os,sys,time
mode=os.environ.get('TEST_MODE','valid')
seen=0
for line in sys.stdin:
    seen+=1
    req=json.loads(line)
    with open(os.environ['TEST_LOG'],'a') as f:
        f.write(json.dumps({'pid':os.getpid(),'rotation':req.get('image_rotation_degrees'), 'request_id':req['request_id']})+'\n')
    if mode=='timeout':
        time.sleep(30)
    if mode=='slow':
        time.sleep(.12)
    if mode=='exit':
        sys.exit(1)
    if mode=='malformed':
        print('not json',flush=True)
        continue
    if mode=='oversize':
        print('x'*600000,flush=True)
        continue
    det={'category':'chair','score':.9,'depth_indices':[0,1,4,5]}
    reply={'request_id':req['request_id'],'detections':[det]}
    if mode=='wrong_id': reply['request_id']='different'
    if mode=='error': reply={'request_id':req['request_id'],'error':'private internal details must never be exposed'}
    if mode=='error_once' and seen==1: reply={'request_id':req['request_id'],'error':'private internal details must never be exposed'}
    if mode=='fatal' or (mode=='fatal_after_one' and seen>1): reply={'request_id':req['request_id'],'error':'private internal details must never be exposed','fatal':True}
    if mode=='bad_error': reply={'request_id':req['request_id'],'error':False}
    if mode=='oversize_error': reply={'request_id':req['request_id'],'error':'x'*1025}
    if mode=='ambiguous_error': reply['error']='Error with incompatible detections'
    if mode=='unknown': det['category']='unrecognized-secret-category'
    if mode=='duplicate': det['depth_indices']=[0,0]
    if mode=='bounds': det['depth_indices']=[999999]
    if mode=='score': det['score']=2
    if mode=='many': reply['detections']=[det]*17
    if mode=='alias': det['category']='round_table'
    print(json.dumps(reply,separators=(',',':')),flush=True)
"#).unwrap();
        Self { root, worker, log }
    }
    fn config(&self, mode: &str) -> RecognitionConfig {
        let mut config = RecognitionConfig::for_worker("python3", &self.worker, "mock-model-v1");
        config.request_timeout = Duration::from_secs(2);
        config.environment.insert("TEST_MODE".into(), mode.into());
        config
            .environment
            .insert("TEST_LOG".into(), self.log.to_string_lossy().into());
        config
    }
    fn chunk(&self, id: &str, sequence: usize, timestamp: f64, x: f64) -> DepthFrame {
        let mut pose = IDENTITY;
        pose[12] = x;
        let value = json!({"sequence":sequence,"color_jpeg":"small-mock-image","frame":{
            "id":format!("frame-{sequence}"),"timestamp_seconds":timestamp,"pixel_orientation":"sensor_native","map_from_camera":pose,
            "camera":{"image_width":4,"image_height":4,"fx":4.,"fy":4.,"cx":1.5,"cy":1.5},
            "depth":{"width":4,"height":4,"values_m":vec![2.;16],"confidence":vec![2;16]}}});
        fs::write(
            self.root.join(id).join(format!("chunk-{sequence:06}.json")),
            serde_json::to_vec(&value).unwrap(),
        )
        .unwrap();
        serde_json::from_value(value["frame"].clone()).unwrap()
    }
    fn requests(&self) -> Vec<Value> {
        fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }
    fn cache(&self, sequence: usize) -> PathBuf {
        self.root
            .join(ID)
            .join(format!("recognition-v1-{sequence:06}.json"))
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn settle(service: &RecognitionService, id: &str, count: usize) -> RecognitionSnapshot {
    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        let snapshot = service.snapshot(id, count);
        if matches!(
            snapshot.status,
            RecognitionStatus::Complete | RecognitionStatus::Unavailable
        ) {
            return snapshot;
        }
        assert!(
            Instant::now() < deadline,
            "recognition stayed pending: {snapshot:?}"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn worker_is_async_persistent_selected_by_motion_and_cached_across_restart() {
    let fixture = Fixture::new();
    let first = fixture.chunk(ID, 0, 1., 0.);
    fixture.chunk(ID, 1, 1.5, 0.1); // Too close in time and pose: no inference.
    let second = fixture.chunk(ID, 2, 1.75, 0.6); // Motion creates a keyframe before two seconds.
    let third = fixture.chunk(ID, 3, 3.75, 0.6); // Time creates another keyframe.
    let other = fixture.chunk(OTHER, 0, 1., 0.);
    {
        let service = RecognitionService::new(&fixture.root, Some(fixture.config("slow"))).unwrap();
        let start = Instant::now();
        service.submit(ID, 4);
        assert!(start.elapsed() < Duration::from_millis(50));
        let result = settle(&service, ID, 4);
        assert_eq!(result.status, RecognitionStatus::Complete);
        assert_eq!(result.frames_processed, 4);
        assert_eq!(result.selected_frames, 3);
        assert_eq!(service.detections(ID, 0, &first).len(), 1);
        assert!(service.detections(ID, 1, &first).is_empty());
        assert_eq!(service.detections(ID, 2, &second).len(), 1);
        assert_eq!(service.detections(ID, 3, &third).len(), 1);
        service.submit(OTHER, 1);
        assert_eq!(
            settle(&service, OTHER, 1).status,
            RecognitionStatus::Complete
        );
        assert_eq!(service.detections(OTHER, 0, &other).len(), 1);
        let requests = fixture.requests();
        assert_eq!(requests.len(), 4);
        assert!(
            requests
                .iter()
                .all(|value| value["pid"] == requests[0]["pid"])
        );
    }
    let request_count = fixture.requests().len();
    let service = RecognitionService::new(&fixture.root, Some(fixture.config("error"))).unwrap();
    service.submit(ID, 4);
    assert_eq!(settle(&service, ID, 4).status, RecognitionStatus::Complete);
    assert_eq!(
        fixture.requests().len(),
        request_count,
        "valid cache should not spawn or invoke a worker"
    );
}

#[test]
fn prefix_growth_resumes_after_completion_and_while_in_flight() {
    let fixture = Fixture::new();
    fixture.chunk(ID, 0, 1., 0.);
    let service = RecognitionService::new(&fixture.root, Some(fixture.config("slow"))).unwrap();
    service.submit(ID, 1);
    fixture.chunk(ID, 1, 3., 0.);
    service.submit(ID, 2);
    assert_eq!(settle(&service, ID, 2).frames_processed, 2);
    fixture.chunk(ID, 2, 5., 0.);
    service.submit(ID, 3);
    assert_eq!(settle(&service, ID, 3).frames_processed, 3);
    assert_eq!(fixture.requests().len(), 3);
    service.submit(ID, 1);
    assert_eq!(service.snapshot(ID, 3).status, RecognitionStatus::Complete);
}

#[test]
fn cache_corruption_source_changes_model_changes_and_invalid_masks_are_recomputed() {
    let fixture = Fixture::new();
    let frame = fixture.chunk(ID, 0, 1., 0.);
    {
        let service =
            RecognitionService::new(&fixture.root, Some(fixture.config("valid"))).unwrap();
        service.submit(ID, 1);
        assert_eq!(settle(&service, ID, 1).status, RecognitionStatus::Complete);
    }
    for mutation in [
        "invalid_json",
        "wrong_key",
        "wrong_crc",
        "wrong_frame",
        "wrong_dimensions",
        "bad_mask",
    ] {
        let mut cache: Value =
            serde_json::from_slice(&fs::read(fixture.cache(0)).unwrap()).unwrap();
        match mutation {
            "invalid_json" => fs::write(fixture.cache(0), b"{partial").unwrap(),
            "wrong_key" => {
                cache["cache_key"] = json!("older-model");
                fs::write(fixture.cache(0), cache.to_string()).unwrap();
            }
            "wrong_crc" => {
                cache["source_crc32"] = json!(0);
                fs::write(fixture.cache(0), cache.to_string()).unwrap();
            }
            "wrong_frame" => {
                cache["source_frame_id"] = json!("wrong");
                fs::write(fixture.cache(0), cache.to_string()).unwrap();
            }
            "wrong_dimensions" => {
                cache["depth_width"] = json!(2);
                fs::write(fixture.cache(0), cache.to_string()).unwrap();
            }
            _ => {
                cache["detections"][0]["depth_indices"] = json!([1000]);
                fs::write(fixture.cache(0), cache.to_string()).unwrap();
            }
        }
        let service =
            RecognitionService::new(&fixture.root, Some(fixture.config("valid"))).unwrap();
        assert!(
            service.detections(ID, 0, &frame).is_empty(),
            "served malformedcache {mutation}"
        );
        service.submit(ID, 1);
        assert_eq!(settle(&service, ID, 1).status, RecognitionStatus::Complete);
        assert_eq!(service.detections(ID, 0, &frame).len(), 1);
    }
    let before = fixture.requests().len();
    let mut config = fixture.config("valid");
    config.cache_key = "new-model-v2".into();
    let service = RecognitionService::new(&fixture.root, Some(config)).unwrap();
    service.submit(ID, 1);
    assert_eq!(settle(&service, ID, 1).status, RecognitionStatus::Complete);
    assert_eq!(fixture.requests().len(), before + 1);
    // A pose-optimized caller retains source frame identity/depth dimensions and can use masks.
    let mut corrected = frame;
    corrected.map_from_camera.0[12] = 0.3;
    assert_eq!(service.detections(ID, 0, &corrected).len(), 1);
    drop(service);
    // An altered committed source must invalidate its old masks even with unchanged dimensions/id.
    let changed = fixture.chunk(ID, 0, 1., 0.9);
    let mut config = fixture.config("valid");
    config.cache_key = "new-model-v2".into();
    let service = RecognitionService::new(&fixture.root, Some(config)).unwrap();
    assert!(service.detections(ID, 0, &changed).is_empty());
    service.submit(ID, 1);
    assert_eq!(settle(&service, ID, 1).status, RecognitionStatus::Complete);
    assert_eq!(service.detections(ID, 0, &changed).len(), 1);
}

#[test]
fn bad_worker_outputs_have_transparent_fallback_and_never_write_a_cache() {
    for mode in [
        "wrong_id",
        "fatal",
        "bad_error",
        "oversize_error",
        "ambiguous_error",
        "unknown",
        "duplicate",
        "bounds",
        "score",
        "many",
        "malformed",
        "oversize",
        "exit",
    ] {
        let fixture = Fixture::new();
        let frame = fixture.chunk(ID, 0, 1., 0.);
        let service = RecognitionService::new(&fixture.root, Some(fixture.config(mode))).unwrap();
        service.submit(ID, 1);
        let result = settle(&service, ID, 1);
        assert_eq!(result.status, RecognitionStatus::Unavailable, "{mode}");
        assert_eq!(result.failed_frames, 1);
        assert!(!result.message.unwrap().contains("private internal"));
        assert!(!fixture.cache(0).exists());
        assert!(service.detections(ID, 0, &frame).is_empty());
    }
}

#[test]
fn recoverable_frame_error_advances_and_keeps_the_loaded_worker_for_next_frames_and_streams() {
    let fixture = Fixture::new();
    let failed = fixture.chunk(ID, 0, 1., 0.);
    let successful = fixture.chunk(ID, 1, 3., 0.);
    let other = fixture.chunk(OTHER, 0, 1., 0.);
    let service =
        RecognitionService::new(&fixture.root, Some(fixture.config("error_once"))).unwrap();
    service.submit(ID, 2);
    let result = settle(&service, ID, 2);
    assert_eq!(result.status, RecognitionStatus::Complete);
    assert_eq!(result.frames_processed, 2);
    assert_eq!(result.selected_frames, 2);
    assert_eq!(result.failed_frames, 1);
    assert!(!result.message.unwrap().contains("private internal"));
    assert!(!fixture.cache(0).exists());
    assert!(service.detections(ID, 0, &failed).is_empty());
    assert_eq!(service.detections(ID, 1, &successful).len(), 1);
    service.submit(OTHER, 1);
    let result = settle(&service, OTHER, 1);
    assert_eq!(result.status, RecognitionStatus::Complete);
    assert_eq!(result.failed_frames, 0);
    assert_eq!(service.detections(OTHER, 0, &other).len(), 1);
    let requests = fixture.requests();
    assert_eq!(requests.len(), 3);
    assert!(
        requests
            .iter()
            .all(|value| value["pid"] == requests[0]["pid"])
    );
}

#[test]
fn fatal_worker_failure_preserves_already_completed_stream_prefixes() {
    let fixture = Fixture::new();
    let first = fixture.chunk(ID, 0, 1., 0.);
    fixture.chunk(OTHER, 0, 1., 0.);
    let service =
        RecognitionService::new(&fixture.root, Some(fixture.config("fatal_after_one"))).unwrap();
    service.submit(ID, 1);
    assert_eq!(settle(&service, ID, 1).status, RecognitionStatus::Complete);
    service.submit(OTHER, 1);
    assert_eq!(
        settle(&service, OTHER, 1).status,
        RecognitionStatus::Unavailable
    );
    assert_eq!(service.snapshot(ID, 1).status, RecognitionStatus::Complete);
    assert_eq!(service.detections(ID, 0, &first).len(), 1);
    fixture.chunk(ID, 1, 3., 0.);
    service.submit(ID, 2);
    assert_eq!(
        service.snapshot(ID, 2).status,
        RecognitionStatus::Unavailable
    );
}

#[test]
fn deadline_and_shutdown_kill_the_child_without_hanging_or_preserving_partial_results() {
    let fixture = Fixture::new();
    fixture.chunk(ID, 0, 1., 0.);
    let mut config = fixture.config("timeout");
    config.request_timeout = Duration::from_millis(180);
    let service = RecognitionService::new(&fixture.root, Some(config)).unwrap();
    service.submit(ID, 1);
    let started = Instant::now();
    let result = settle(&service, ID, 1);
    assert_eq!(result.status, RecognitionStatus::Unavailable);
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(!fixture.cache(0).exists());
    let shutdown = Instant::now();
    drop(service);
    assert!(shutdown.elapsed() < Duration::from_secs(2));
    // Drop also interrupts an active long request before its normal deadline.
    let service = RecognitionService::new(&fixture.root, Some(fixture.config("timeout"))).unwrap();
    service.submit(ID, 1);
    let deadline = Instant::now() + Duration::from_secs(2);
    while fixture.requests().len() < 2 {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(10));
    }
    let shutdown = Instant::now();
    drop(service);
    assert!(shutdown.elapsed() < Duration::from_secs(2));
}

#[test]
fn deadline_also_covers_a_worker_that_never_reads_its_full_image_request() {
    let fixture = Fixture::new();
    fixture.chunk(ID, 0, 1., 0.);
    fs::write(&fixture.worker, "import time\ntime.sleep(30)\n").unwrap();
    let path = fixture.root.join(ID).join("chunk-000000.json");
    let mut chunk: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    chunk["color_jpeg"] = json!("A".repeat(700_000));
    fs::write(path, chunk.to_string()).unwrap();
    let mut config = fixture.config("valid");
    config.request_timeout = Duration::from_millis(150);
    let service = RecognitionService::new(&fixture.root, Some(config)).unwrap();
    service.submit(ID, 1);
    let started = Instant::now();
    assert_eq!(
        settle(&service, ID, 1).status,
        RecognitionStatus::Unavailable
    );
    assert!(started.elapsed() < Duration::from_secs(2));
    let stopped = Instant::now();
    drop(service);
    assert!(stopped.elapsed() < Duration::from_secs(2));
    assert!(!fixture.cache(0).exists());
}

#[test]
fn orientation_is_derived_from_the_raw_sensor_pose_without_changing_depth_calibration() {
    let fixture = Fixture::new();
    let mut frame = fixture.chunk(ID, 0, 1., 0.);
    assert_eq!(image_rotation_degrees(&frame), 0);
    frame.map_from_camera.0 = [
        0., 1., 0., 0., -1., 0., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
    ];
    assert_eq!(image_rotation_degrees(&frame), 270);
    frame.map_from_camera.0 = [
        0., -1., 0., 0., 1., 0., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
    ];
    assert_eq!(image_rotation_degrees(&frame), 90);
    frame.map_from_camera.0 = [
        -1., 0., 0., 0., 0., -1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
    ];
    assert_eq!(image_rotation_degrees(&frame), 180);
    frame.map_from_camera.0 = [
        1., 0., 0., 0., 0., 0., 1., 0., 0., -1., 0., 0., 0., 0., 0., 1.,
    ];
    assert_eq!(image_rotation_degrees(&frame), 0);
}

#[test]
fn disabled_worker_and_unsafe_ids_do_not_start_a_process() {
    let fixture = Fixture::new();
    let service = RecognitionService::new(&fixture.root, None).unwrap();
    service.submit(ID, 1);
    assert_eq!(
        service.snapshot(ID, 1).status,
        RecognitionStatus::Unavailable
    );
    assert!(fixture.requests().is_empty());
    assert!(
        service
            .detections("../escape", 0, &fixture.chunk(ID, 0, 1., 0.))
            .is_empty()
    );
}
