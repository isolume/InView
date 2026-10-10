//! A local, persistent image worker with bounded requests and durable mask-only caches.
//! Upload handlers enqueue stream IDs and committed prefixes; they never retain RGB frames.
use std::{
    collections::{BTreeMap, HashMap, HashSet, VecDeque},
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{
    capture::DepthFrame,
    geometry::Transform,
    recognized_objects::{Detection, canonical_category},
};

const MAX_CHUNK_BYTES: usize = 4 * 1024 * 1024;
const MAX_REPLY_BYTES: usize = 512 * 1024;
const PIPELINE_VERSION: &str = "recognition-v1-selection-2s-0.5m-20deg-sensor-rotation-v1";
static NEXT_FILE: AtomicU64 = AtomicU64::new(0);
static NEXT_REQUEST: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug)]
pub struct RecognitionConfig {
    pub python: PathBuf,
    pub worker: PathBuf,
    pub cache_key: String,
    pub request_timeout: Duration,
    pub environment: BTreeMap<String, String>,
}

impl RecognitionConfig {
    /// Construct an explicit local worker, including mocked workers in integration tests.
    pub fn for_worker(
        python: impl Into<PathBuf>,
        worker: impl Into<PathBuf>,
        cache_key: impl Into<String>,
    ) -> Self {
        Self {
            python: python.into(),
            worker: worker.into(),
            cache_key: cache_key.into(),
            request_timeout: Duration::from_secs(90),
            environment: BTreeMap::new(),
        }
    }

    pub fn from_environment() -> Result<Option<Self>, String> {
        if std::env::var("INVIEW_RECOGNITION").is_ok_and(|value| value.eq_ignore_ascii_case("off"))
        {
            return Ok(None);
        }
        let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("recognition");
        let explicit = std::env::var_os("INVIEW_RECOGNITION_PYTHON");
        let python = explicit
            .clone()
            .map(PathBuf::from)
            .unwrap_or_else(|| directory.join(".venv/bin/python"));
        let worker = directory.join("worker.py");
        if !python.is_file() || !worker.is_file() {
            return if explicit.is_some() {
                Err("The configured local recognition runtime is not installed.".into())
            } else {
                Ok(None)
            };
        }
        let cache = std::env::var_os("INVIEW_RECOGNITION_CACHE")
            .map(PathBuf::from)
            .unwrap_or_else(|| directory.join("cache"));
        let weights = std::env::var_os("INVIEW_RECOGNITION_WEIGHTS")
            .map(PathBuf::from)
            .unwrap_or_else(|| cache.join("yoloe-26s-seg.pt"));
        if !weights.is_file() {
            return if explicit.is_some() {
                Err("Install the local recognition weights before enabling the worker.".into())
            } else {
                Ok(None)
            };
        }
        let seconds: u64 = std::env::var("INVIEW_RECOGNITION_TIMEOUT_SECONDS")
            .unwrap_or_else(|_| "90".into())
            .parse()
            .map_err(|_| "Recognition timeout must be a whole number of seconds.")?;
        if !(1..=300).contains(&seconds) {
            return Err("Recognition timeout must be between 1 and 300 seconds.".into());
        }
        let mut hash = Hash64::new();
        hash.add(PIPELINE_VERSION.as_bytes());
        hash.file(&worker, 1024 * 1024)?;
        hash.file(&weights, 1024 * 1024 * 1024)?;
        for path in [
            directory.join("core.py"),
            directory.join("requirements.txt"),
            Path::new(env!("CARGO_MANIFEST_DIR")).join("src/recognized_objects.rs"),
        ] {
            if path.is_file() {
                hash.file(&path, 1024 * 1024)?;
            }
        }
        let device = std::env::var("INVIEW_RECOGNITION_DEVICE").unwrap_or_else(|_| "cpu".into());
        hash.add(device.as_bytes());
        hash.add(weights.as_os_str().as_encoded_bytes());
        let mut config =
            Self::for_worker(python, worker, format!("recognition-v1-{:016x}", hash.0));
        config.request_timeout = Duration::from_secs(seconds);
        config.environment.insert(
            "INVIEW_RECOGNITION_CACHE".into(),
            cache.to_string_lossy().into(),
        );
        config.environment.insert(
            "INVIEW_RECOGNITION_WEIGHTS".into(),
            weights.to_string_lossy().into(),
        );
        config
            .environment
            .insert("INVIEW_RECOGNITION_DEVICE".into(), device);
        Ok(Some(config))
    }
}

struct Hash64(u64);
impl Hash64 {
    fn new() -> Self {
        Self(0xcbf29ce484222325)
    }
    fn add(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 = (self.0 ^ *byte as u64).wrapping_mul(0x100000001b3);
        }
    }
    fn file(&mut self, path: &Path, max: u64) -> Result<(), String> {
        let mut file = File::open(path).map_err(|_| "Recognition configuration cannot be read.")?;
        if file
            .metadata()
            .map_err(|_| "Recognition configuration cannot be read.")?
            .len()
            > max
        {
            return Err("Recognition configuration file exceeds its size limit.".into());
        }
        let mut buffer = [0u8; 64 * 1024];
        loop {
            let count = file
                .read(&mut buffer)
                .map_err(|_| "Recognition configuration cannot be read.")?;
            if count == 0 {
                break;
            }
            self.add(&buffer[..count]);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RecognitionStatus {
    Pending,
    Running,
    Complete,
    Unavailable,
}

#[derive(Clone, Debug, Serialize)]
pub struct RecognitionSnapshot {
    pub status: RecognitionStatus,
    pub frames_processed: usize,
    pub selected_frames: usize,
    pub failed_frames: usize,
    pub cache_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Clone)]
struct Record {
    target: usize,
    snapshot: RecognitionSnapshot,
    last_selected: Option<SelectionPose>,
}

#[derive(Clone, Copy)]
struct SelectionPose {
    timestamp_seconds: f64,
    map_from_camera: Transform,
}

struct Shared {
    root: PathBuf,
    config: Option<RecognitionConfig>,
    states: Mutex<HashMap<String, Record>>,
    queue: Mutex<VecDeque<String>>,
    wake: Condvar,
    stop: AtomicBool,
    unavailable: Mutex<Option<String>>,
    child: Arc<Mutex<Option<Child>>>,
}

struct Runtime {
    shared: Arc<Shared>,
    manager: Mutex<Option<JoinHandle<()>>>,
}

impl Drop for Runtime {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        self.shared.wake.notify_all();
        stop_child(&self.shared.child);
        if let Some(handle) = self.manager.lock().unwrap().take() {
            bounded_join(handle);
        }
    }
}

#[derive(Clone)]
pub struct RecognitionService {
    runtime: Arc<Runtime>,
}

impl RecognitionService {
    pub fn new(
        root: impl Into<PathBuf>,
        config: Option<RecognitionConfig>,
    ) -> Result<Self, String> {
        let root = root.into();
        if let Some(config) = &config
            && (config.cache_key.is_empty()
                || config.cache_key.len() > 256
                || config.request_timeout.is_zero()
                || config.request_timeout > Duration::from_secs(300))
        {
            return Err(
                "Recognition configuration needs a bounded cache key and request deadline.".into(),
            );
        }
        let shared = Arc::new(Shared {
            root,
            config,
            states: Mutex::new(HashMap::new()),
            queue: Mutex::new(VecDeque::new()),
            wake: Condvar::new(),
            stop: AtomicBool::new(false),
            unavailable: Mutex::new(None),
            child: Arc::new(Mutex::new(None)),
        });
        let manager = if shared.config.is_some() {
            let work = shared.clone();
            Some(
                thread::Builder::new()
                    .name("inview-recognition".into())
                    .spawn(move || run(work))
                    .map_err(|_| "The local recognition worker could not start.")?,
            )
        } else {
            None
        };
        Ok(Self {
            runtime: Arc::new(Runtime {
                shared,
                manager: Mutex::new(manager),
            }),
        })
    }

    pub fn submit(&self, id: &str, frame_count: usize) {
        let shared = &self.runtime.shared;
        if !safe_id(id)
            || frame_count == 0
            || shared.config.is_none()
            || shared.stop.load(Ordering::Acquire)
        {
            return;
        }
        if shared.unavailable.lock().unwrap().is_some() {
            return;
        }
        let mut states = shared.states.lock().unwrap();
        let record = states.entry(id.into()).or_insert_with(|| Record {
            target: 0,
            last_selected: None,
            snapshot: self.initial_snapshot(RecognitionStatus::Pending, None),
        });
        if frame_count <= record.target {
            return;
        }
        record.target = frame_count;
        if record.snapshot.status != RecognitionStatus::Running {
            record.snapshot.status = RecognitionStatus::Pending;
        }
        drop(states);
        let mut queue = shared.queue.lock().unwrap();
        if !queue.iter().any(|queued| queued == id) {
            queue.push_back(id.into());
        }
        drop(queue);
        shared.wake.notify_one();
    }

    pub fn snapshot(&self, id: &str, frame_count: usize) -> RecognitionSnapshot {
        let shared = &self.runtime.shared;
        if shared.config.is_none() {
            return self.initial_snapshot(
                RecognitionStatus::Unavailable,
                Some("Furniture recognition is not enabled on this backend.".into()),
            );
        }
        let unavailable = shared.unavailable.lock().unwrap().clone();
        let states = shared.states.lock().unwrap();
        if let Some(record) = states.get(id) {
            let mut snapshot = record.snapshot.clone();
            if snapshot.status == RecognitionStatus::Complete
                && snapshot.frames_processed < frame_count
            {
                snapshot.status = if unavailable.is_some() {
                    snapshot.message = unavailable;
                    RecognitionStatus::Unavailable
                } else {
                    RecognitionStatus::Pending
                };
            }
            snapshot
        } else if let Some(message) = unavailable {
            self.initial_snapshot(RecognitionStatus::Unavailable, Some(message))
        } else {
            self.initial_snapshot(RecognitionStatus::Pending, None)
        }
    }

    fn initial_snapshot(
        &self,
        status: RecognitionStatus,
        message: Option<String>,
    ) -> RecognitionSnapshot {
        RecognitionSnapshot {
            status,
            frames_processed: 0,
            selected_frames: 0,
            failed_frames: 0,
            cache_key: self
                .runtime
                .shared
                .config
                .as_ref()
                .map(|c| c.cache_key.clone())
                .unwrap_or_else(|| "recognition-disabled-v1".into()),
            message,
        }
    }

    /// Only validated, complete cached masks are returned, including after pose optimization.
    pub fn detections(&self, id: &str, sequence: usize, frame: &DepthFrame) -> Vec<Detection> {
        let shared = &self.runtime.shared;
        let Some(config) = &shared.config else {
            return vec![];
        };
        if !safe_id(id) {
            return vec![];
        }
        let Ok(bytes) = read_regular(&chunk_path(&shared.root, id, sequence), MAX_CHUNK_BYTES)
        else {
            return vec![];
        };
        read_cache(
            &cache_path(&shared.root, id, sequence),
            config,
            frame,
            crc32(&bytes),
        )
        .unwrap_or_default()
    }
}

fn run(shared: Arc<Shared>) {
    let mut worker: Option<Worker> = None;
    while !shared.stop.load(Ordering::Acquire) {
        let item = {
            let mut queue = shared.queue.lock().unwrap();
            while queue.is_empty() && !shared.stop.load(Ordering::Acquire) {
                queue = shared
                    .wake
                    .wait_timeout(queue, Duration::from_millis(100))
                    .unwrap()
                    .0;
            }
            if shared.stop.load(Ordering::Acquire) {
                break;
            }
            queue.pop_front()
        };
        let Some(id) = item else {
            continue;
        };
        let outcome = process_stream(&shared, &id, &mut worker);
        if let Err(message) = outcome {
            *shared.unavailable.lock().unwrap() = Some(message.clone());
            let mut states = shared.states.lock().unwrap();
            if let Some(record) = states.get_mut(&id) {
                record.snapshot.failed_frames += 1;
            }
            for record in states.values_mut() {
                if record.snapshot.status != RecognitionStatus::Complete {
                    record.snapshot.status = RecognitionStatus::Unavailable;
                    record.snapshot.message = Some(message.clone());
                }
            }
            shared.queue.lock().unwrap().clear();
            break;
        }
    }
}

fn process_stream(shared: &Shared, id: &str, worker: &mut Option<Worker>) -> Result<(), String> {
    let config = shared.config.as_ref().unwrap();
    let mut batch = 0;
    loop {
        if shared.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        let (sequence, target, previous) = {
            let mut states = shared.states.lock().unwrap();
            let record = states.get_mut(id).unwrap();
            if record.snapshot.frames_processed >= record.target {
                record.snapshot.status = RecognitionStatus::Complete;
                return Ok(());
            }
            record.snapshot.status = RecognitionStatus::Running;
            (
                record.snapshot.frames_processed,
                record.target,
                record.last_selected,
            )
        };
        let bytes = read_regular(&chunk_path(&shared.root, id, sequence), MAX_CHUNK_BYTES)
            .map_err(|_| "A committed recognition frame could not be read.")?;
        let value: Value = serde_json::from_slice(&bytes)
            .map_err(|_| "A committed recognition frame is invalid.")?;
        let frame: DepthFrame =
            serde_json::from_value(value.get("frame").cloned().unwrap_or(Value::Null))
                .map_err(|_| "A committed recognition frame is invalid.")?;
        validate_frame(&frame)?;
        let selected = previous
            .as_ref()
            .is_none_or(|last| select_frame(last, &frame));
        let mut frame_failed = false;
        if selected {
            let path = cache_path(&shared.root, id, sequence);
            let source_crc = crc32(&bytes);
            if read_cache(&path, config, &frame, source_crc).is_none() {
                if worker.is_none() {
                    *worker = Some(Worker::start(config, shared.child.clone())?);
                }
                let jpeg = value
                    .get("color_jpeg")
                    .and_then(Value::as_str)
                    .ok_or("The committed recognition image is missing.")?;
                let request_id = format!(
                    "{}-{}",
                    std::process::id(),
                    NEXT_REQUEST.fetch_add(1, Ordering::Relaxed)
                );
                let request = json!({"request_id":request_id,"color_jpeg":jpeg,"depth_width":frame.depth.width,
                    "depth_height":frame.depth.height,"image_rotation_degrees": image_rotation_degrees(&frame)});
                let response = worker.as_ref().unwrap().request(
                    request,
                    &request_id,
                    config.request_timeout,
                    &shared.stop,
                )?;
                if let Some(mut detections) = response {
                    validate_detections(&mut detections, frame.depth.width * frame.depth.height)?;
                    let cache = CachedDetections {
                        version: 1,
                        cache_key: config.cache_key.clone(),
                        source_frame_id: frame.id.clone(),
                        depth_width: frame.depth.width,
                        depth_height: frame.depth.height,
                        source_crc32: source_crc,
                        detections,
                    };
                    let encoded = serde_json::to_vec(&cache)
                        .map_err(|_| "Recognition masks could not be saved.")?;
                    atomic_write(&path, &encoded)
                        .map_err(|_| "Recognition masks could not be saved.")?;
                } else {
                    frame_failed = true;
                }
            }
        }
        let mut states = shared.states.lock().unwrap();
        let record = states.get_mut(id).unwrap();
        record.snapshot.frames_processed += 1;
        if frame_failed {
            record.snapshot.failed_frames += 1;
            record.snapshot.message = Some(
                "Some images could not be recognized; measured geometry remains available.".into(),
            );
        }
        if selected {
            record.snapshot.selected_frames += 1;
            record.last_selected = Some(SelectionPose {
                timestamp_seconds: frame.timestamp_seconds,
                map_from_camera: frame.map_from_camera,
            });
        }
        if record.target != target {
            record.snapshot.status = RecognitionStatus::Running;
        }
        batch += 1;
        if batch >= 8 && record.snapshot.frames_processed < record.target {
            drop(states);
            let mut queue = shared.queue.lock().unwrap();
            if !queue.iter().any(|queued| queued == id) {
                queue.push_back(id.into());
            }
            return Ok(());
        }
    }
}

fn select_frame(last: &SelectionPose, current: &DepthFrame) -> bool {
    let distance = (12..15)
        .map(|i| (current.map_from_camera.0[i] - last.map_from_camera.0[i]).powi(2))
        .sum::<f64>()
        .sqrt();
    let trace = [0, 4, 8]
        .into_iter()
        .map(|start| {
            (0..3)
                .map(|axis| {
                    current.map_from_camera.0[start + axis] * last.map_from_camera.0[start + axis]
                })
                .sum::<f64>()
        })
        .sum::<f64>();
    current.timestamp_seconds - last.timestamp_seconds >= 2.0
        || distance >= 0.5
        || ((trace - 1.0) * 0.5).clamp(-1.0, 1.0).acos() >= 20f64.to_radians()
}

pub fn image_rotation_degrees(frame: &DepthFrame) -> u16 {
    let right = frame.map_from_camera.0[1];
    let down = -frame.map_from_camera.0[5];
    if right.hypot(down) < 0.25 {
        0
    } else if right.abs() > down.abs() {
        if right > 0.0 { 270 } else { 90 }
    } else if down > 0.0 {
        180
    } else {
        0
    }
}

fn validate_frame(frame: &DepthFrame) -> Result<(), String> {
    frame
        .map_from_camera
        .validate()
        .map_err(|_| "Recognition camera pose is invalid.")?;
    if frame.id.is_empty()
        || frame.id.len() > 256
        || !frame.timestamp_seconds.is_finite()
        || frame.timestamp_seconds < 0.0
        || frame
            .depth
            .width
            .checked_mul(frame.depth.height)
            .is_none_or(|count| {
                count == 0 || count > 512 * 512 || count != frame.depth.values_m.len()
            })
    {
        return Err("Recognition depth frame is invalid.".into());
    }
    Ok(())
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CachedDetections {
    version: u32,
    cache_key: String,
    source_frame_id: String,
    depth_width: usize,
    depth_height: usize,
    source_crc32: u32,
    detections: Vec<Detection>,
}

fn read_cache(
    path: &Path,
    config: &RecognitionConfig,
    frame: &DepthFrame,
    source_crc32: u32,
) -> Option<Vec<Detection>> {
    let bytes = read_regular(path, MAX_REPLY_BYTES).ok()?;
    let mut cache: CachedDetections = serde_json::from_slice(&bytes).ok()?;
    if cache.version != 1
        || cache.cache_key != config.cache_key
        || cache.source_frame_id != frame.id
        || cache.depth_width != frame.depth.width
        || cache.depth_height != frame.depth.height
        || cache.source_crc32 != source_crc32
    {
        return None;
    }
    validate_detections(
        &mut cache.detections,
        frame.depth.width.checked_mul(frame.depth.height)?,
    )
    .ok()?;
    Some(cache.detections)
}

fn validate_detections(detections: &mut Vec<Detection>, count: usize) -> Result<(), String> {
    if detections.len() > 16 {
        return Err("The recognition worker returned too many objects.".into());
    }
    for detection in detections {
        let category = canonical_category(&detection.category)
            .ok_or("The recognition worker returned an unsupported object type.")?;
        if !detection.score.is_finite()
            || !(0.0..=1.0).contains(&detection.score)
            || detection.depth_indices.len() > 2048
        {
            return Err("The recognition worker returned invalid object measurements.".into());
        }
        let mut seen = HashSet::new();
        if detection
            .depth_indices
            .iter()
            .any(|&index| index >= count || !seen.insert(index))
        {
            return Err("The recognition worker returned invalid depth mask indices.".into());
        }
        detection.category = category.into();
    }
    Ok(())
}

enum WorkerReply {
    Json(Value),
    Error,
}
struct Worker {
    input: Option<SyncSender<Vec<u8>>>,
    replies: Receiver<WorkerReply>,
    child: Arc<Mutex<Option<Child>>>,
    writer: Option<JoinHandle<()>>,
    reader: Option<JoinHandle<()>>,
}
impl Worker {
    fn start(
        config: &RecognitionConfig,
        child_slot: Arc<Mutex<Option<Child>>>,
    ) -> Result<Self, String> {
        let mut child = Command::new(&config.python)
            .arg(&config.worker)
            .envs(&config.environment)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| "The local furniture recognition worker could not start.")?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or("The recognition input pipe is unavailable.")?;
        let stdout = child
            .stdout
            .take()
            .ok_or("The recognition output pipe is unavailable.")?;
        *child_slot.lock().unwrap() = Some(child);
        let (input, requests) = mpsc::sync_channel::<Vec<u8>>(1);
        let (sender, replies) = mpsc::sync_channel(2);
        let errors = sender.clone();
        let writer = thread::spawn(move || {
            while let Ok(bytes) = requests.recv() {
                if stdin.write_all(&bytes).and_then(|_| stdin.flush()).is_err() {
                    let _ = errors.send(WorkerReply::Error);
                    break;
                }
            }
        });
        let reader = thread::spawn(move || {
            let mut output = BufReader::new(stdout);
            loop {
                let mut line = Vec::new();
                let read = output
                    .by_ref()
                    .take(MAX_REPLY_BYTES as u64 + 1)
                    .read_until(b'\n', &mut line);
                if read.is_err()
                    || line.is_empty()
                    || line.len() > MAX_REPLY_BYTES
                    || line.last() != Some(&b'\n')
                {
                    let _ = sender.send(WorkerReply::Error);
                    break;
                }
                match serde_json::from_slice(&line) {
                    Ok(value) => {
                        if sender.send(WorkerReply::Json(value)).is_err() {
                            break;
                        }
                    }
                    Err(_) => {
                        let _ = sender.send(WorkerReply::Error);
                        break;
                    }
                }
            }
        });
        Ok(Self {
            input: Some(input),
            replies,
            child: child_slot,
            writer: Some(writer),
            reader: Some(reader),
        })
    }

    fn request(
        &self,
        value: Value,
        id: &str,
        timeout: Duration,
        stop: &AtomicBool,
    ) -> Result<Option<Vec<Detection>>, String> {
        let mut bytes =
            serde_json::to_vec(&value).map_err(|_| "The recognition request is invalid.")?;
        if bytes.len() > MAX_CHUNK_BYTES {
            return Err("The recognition request exceeds its size limit.".into());
        }
        bytes.push(b'\n');
        self.input
            .as_ref()
            .unwrap()
            .try_send(bytes)
            .map_err(|_| "The recognition worker stopped accepting frames.")?;
        let deadline = Instant::now() + timeout;
        loop {
            if stop.load(Ordering::Acquire) {
                return Err("Furniture recognition was stopped.".into());
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return Err(
                    "Furniture recognition timed out; the measured map remains available.".into(),
                );
            };
            match self
                .replies
                .recv_timeout(remaining.min(Duration::from_millis(100)))
            {
                Ok(WorkerReply::Json(reply)) => {
                    if reply.get("request_id").and_then(Value::as_str) != Some(id) {
                        return Err("Furniture recognition is unavailable; the measured map remains available.".into());
                    }
                    if let Some(error) = reply.get("error") {
                        if error.as_str().is_none_or(|text| text.len() > 1024)
                            || reply.get("detections").is_some()
                            || reply.get("fatal").is_some_and(|value| !value.is_boolean())
                        {
                            return Err(
                                "The recognition worker returned an invalid response.".into()
                            );
                        }
                        if reply.get("fatal").and_then(Value::as_bool) == Some(true) {
                            return Err("Furniture recognition is unavailable; the measured map remains available.".into());
                        }
                        return Ok(None);
                    }
                    return serde_json::from_value(
                        reply.get("detections").cloned().unwrap_or(Value::Null),
                    )
                    .map(Some)
                    .map_err(|_| "The recognition worker returned an invalid response.".into());
                }
                Ok(WorkerReply::Error) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(
                        "Furniture recognition stopped; the measured map remains available.".into(),
                    );
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
        }
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        self.input.take();
        stop_child(&self.child);
        if let Some(handle) = self.writer.take() {
            bounded_join(handle);
        }
        if let Some(handle) = self.reader.take() {
            bounded_join(handle);
        }
    }
}

fn stop_child(slot: &Mutex<Option<Child>>) {
    let mut slot = slot.lock().unwrap();
    if let Some(mut child) = slot.take() {
        let _ = child.kill();
        let deadline = Instant::now() + Duration::from_millis(300);
        while child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
    }
}
fn bounded_join(handle: JoinHandle<()>) {
    let deadline = Instant::now() + Duration::from_millis(300);
    while !handle.is_finished() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    if handle.is_finished() {
        let _ = handle.join();
    }
}

fn safe_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn chunk_path(root: &Path, id: &str, sequence: usize) -> PathBuf {
    root.join(id).join(format!("chunk-{sequence:06}.json"))
}
fn cache_path(root: &Path, id: &str, sequence: usize) -> PathBuf {
    root.join(id)
        .join(format!("recognition-v1-{sequence:06}.json"))
}
fn read_regular(path: &Path, max: usize) -> std::io::Result<Vec<u8>> {
    if !fs::symlink_metadata(path.parent().unwrap())?
        .file_type()
        .is_dir()
    {
        return Err(std::io::Error::other("invalid recognition directory"));
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() || metadata.len() > max as u64 {
        return Err(std::io::Error::other("invalid bounded recognition file"));
    }
    let mut bytes = Vec::new();
    File::open(path)?
        .take(max as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > max {
        return Err(std::io::Error::other("recognition file too large"));
    }
    Ok(bytes)
}
fn atomic_write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if bytes.len() > MAX_REPLY_BYTES {
        return Err(std::io::Error::other("recognition cache too large"));
    }
    let parent = path.parent().unwrap();
    if !fs::symlink_metadata(parent)?.file_type().is_dir() {
        return Err(std::io::Error::other("invalid recognition directory"));
    }
    let temp = parent.join(format!(
        ".recognition-write-{}-{}.tmp",
        std::process::id(),
        NEXT_FILE.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        File::open(parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(temp);
    }
    result
}

const fn crc_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut value = i as u32;
        let mut bit = 0;
        while bit < 8 {
            value = if value & 1 == 1 {
                0xedb88320 ^ (value >> 1)
            } else {
                value >> 1
            };
            bit += 1;
        }
        table[i] = value;
        i += 1;
    }
    table
}
fn crc32(bytes: &[u8]) -> u32 {
    const TABLE: [u32; 256] = crc_table();
    let mut crc = !0u32;
    for &byte in bytes {
        crc = TABLE[((crc as u8) ^ byte) as usize] ^ (crc >> 8);
    }
    !crc
}
