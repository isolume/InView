//! Durable continuous capture and pose-preserving reconstruction with adaptive detail.
//! Depth neighborhoods become measured triangles; no labels or navigation clearance are inferred.
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};

use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use tokio::sync::Semaphore;

use crate::{
    alignment::{self, AlignmentFrame, AlignmentResult},
    capture::{CapturedSurface, Coordinates, DepthFrame, DetectedObject, MeshCapture, ScanBundle},
    display_mesh::{DisplayMeshOptions, simplify_display_mesh},
    geometry::{Transform, Vec3},
    recognition_service::{
        RecognitionConfig, RecognitionService, RecognitionSnapshot, RecognitionStatus,
    },
    recognized_objects::{ObjectFusion, merge_recognized},
    scene::{self, ProcessingOptions, Scene},
};

pub const MAX_CHUNK_BYTES: usize = 4 * 1024 * 1024;
const MAX_JPEG_BYTES: usize = 512 * 1024;
const MAX_DEPTH_SAMPLES: usize = 512 * 512;
const MAX_COLOR_PIXELS: usize = 1024 * 1024;
const MAX_LABELS: usize = 1024;
// These are compaction targets, never capture or reconstruction rejection limits.
const MESH_VERTEX_TARGET: usize = 250_000;
const MESH_TRIANGLE_TARGET: usize = 500_000;
const MAX_GRAPH_KEYFRAMES: usize = 64;
const MAX_REGISTRATION_POINTS: usize = 512;
const WELD_METERS: f64 = 0.02;
const MAX_COMPACTION_LEVEL: u32 = 2; // 2 -> 4 -> 8 cm, then keep growing with coverage.
// Bump this version whenever reconstruction semantics or the result contract change.
const RECONSTRUCTION_VERSION: u32 = 5;
const RESULT_CACHE: &str = "reconstruction-v5-result.json";
const SCENE_CACHE: &str = "reconstruction-v5-scene.json";
const CACHE_METADATA: &str = "reconstruction-v5-cache.json";
static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamManifest {
    pub schema_version: u32,
    pub id: String,
    pub map_id: String,
    pub floor_id: String,
    pub coordinates: Coordinates,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamChunk {
    pub sequence: usize,
    pub frame: DepthFrame,
    pub color_jpeg: String,
    #[serde(default)]
    pub surfaces: Vec<CapturedSurface>,
    #[serde(default)]
    pub objects: Vec<DetectedObject>,
    /// Coarse geographic/building context at this frame (GPS, heading, barometer), with the
    /// iPhone's `CaptureEnvironmentSample` keys. ARKit stays the only room-precision frame.
    #[serde(default)]
    pub environment: Option<Value>,
    /// Dense camera poses recorded since the previous chunk (movement between keyframes).
    #[serde(default)]
    pub poses: Vec<StreamPose>,
}

/// One camera pose of the dense movement track, in the shared ARKit session frame.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct StreamPose {
    /// ARKit uptime seconds (the clock of `frame.timestamp_seconds`).
    pub t: f64,
    /// Column-major map_from_camera.
    pub m: Transform,
    #[serde(default)]
    pub tracking: Option<String>,
    #[serde(default)]
    pub mapping: Option<String>,
}

/// Whole-capture files a client may attach to a stream before or after finishing it.
pub const STREAM_ASSETS: [&str; 4] = [
    "roomplan.json",
    "semantics.json",
    "text-observations.json",
    "camera-track.json",
];
pub const MAX_ASSET_BYTES: usize = 16 * 1024 * 1024;
const MAX_POSES_PER_CHUNK: usize = 600;
const MAX_ENVIRONMENT_KEYS: usize = 32;

#[derive(Clone, Debug, Serialize)]
pub struct StreamSummary {
    pub id: String,
    pub map_id: String,
    pub floor_id: String,
    pub next_sequence: usize,
    pub finished: bool,
    pub frame_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recognition: Option<RecognitionSnapshot>,
}

#[derive(Serialize)]
pub struct StreamResult {
    /// Derived compact geometry. Original RGB/depth observations remain on disk.
    pub capture: Value,
    pub scene: Scene,
    pub alignment: AlignmentResult,
}

#[derive(Debug)]
pub enum StreamError {
    Invalid(String),
    Malformed(String),
    Conflict(String),
    Limit(String),
    Missing,
    Unfinished,
    Busy,
    RecognitionPending,
    Storage(std::io::Error),
}

impl From<std::io::Error> for StreamError {
    fn from(value: std::io::Error) -> Self {
        Self::Storage(value)
    }
}

struct Record {
    manifest: StreamManifest,
    original: Value,
    count: usize,
    last_timestamp: Option<f64>,
    frames: HashSet<String>,
    finished: bool,
    reconstruction: Arc<Mutex<()>>,
}

impl Record {
    fn summary(&self) -> StreamSummary {
        StreamSummary {
            id: self.manifest.id.clone(),
            map_id: self.manifest.map_id.clone(),
            floor_id: self.manifest.floor_id.clone(),
            next_sequence: self.count,
            frame_count: self.count,
            finished: self.finished,
            recognition: None,
        }
    }

    fn check_next(&self, chunk: &StreamChunk) -> Result<(), StreamError> {
        if self.finished {
            return Err(StreamError::Conflict(
                "This stream is already finished.".into(),
            ));
        }
        if chunk.sequence != self.count {
            return Err(StreamError::Conflict(format!(
                "Send sequence {} before any later chunk.",
                self.count
            )));
        }
        if self
            .last_timestamp
            .is_some_and(|timestamp| chunk.frame.timestamp_seconds <= timestamp)
        {
            return Err(StreamError::Invalid(
                "Frame timestamps must increase within one continuous AR session.".into(),
            ));
        }
        if self.frames.contains(&chunk.frame.id) {
            return Err(StreamError::Invalid(
                "Each frame needs a new frame id.".into(),
            ));
        }
        Ok(())
    }

    fn accept(&mut self, chunk: StreamChunk) {
        self.count += 1;
        self.last_timestamp = Some(chunk.frame.timestamp_seconds);
        self.frames.insert(chunk.frame.id);
    }
}

struct Inner {
    root: PathBuf,
    records: Mutex<BTreeMap<String, Record>>,
    temporary: bool,
}

impl Drop for Inner {
    fn drop(&mut self) {
        if self.temporary {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}

#[derive(Clone)]
pub struct StreamStore {
    recognition: Option<RecognitionService>,
    inner: Arc<Inner>,
    processing: Arc<Semaphore>,
}

impl Default for StreamStore {
    /// The executable explicitly opens a durable directory. Defaults are private temporary stores,
    /// so router tests and embedders never write the repository's data directory accidentally.
    fn default() -> Self {
        let serial = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "inview-streams-{}-{stamp}-{serial}",
            std::process::id()
        ));
        let mut store = Self::open(path).expect("create private temporary stream store");
        Arc::get_mut(&mut store.inner).unwrap().temporary = true;
        store
    }
}

impl StreamStore {
    /// Recover only acknowledged, contiguous immutable chunks, one bounded file at a time.
    /// A corrupt committed capture fails startup instead of quietly losing observations.
    pub fn open(root: impl Into<PathBuf>) -> Result<Self, StreamError> {
        let root = root.into();
        fs::create_dir_all(&root)?;
        let mut records = BTreeMap::new();
        for entry in fs::read_dir(&root)? {
            let entry = entry?;
            let id = entry.file_name().to_string_lossy().to_string();
            if !safe_id(&id) {
                continue;
            }
            if !entry.file_type()?.is_dir() {
                return Err(StreamError::Invalid(
                    "Stream directories must be regular directories.".into(),
                ));
            }
            let manifest_path = entry.path().join("manifest.json");
            if !manifest_path.try_exists()? {
                continue;
            }
            let original = read_value(&manifest_path, 16 * 1024)?;
            let manifest = parse_manifest(&original)?;
            if manifest.id != id {
                return Err(StreamError::Invalid(
                    "Stored stream id does not match its directory.".into(),
                ));
            }
            let mut record = empty_record(manifest, original);
            let mut sequences = Vec::new();
            for chunk_entry in fs::read_dir(entry.path())? {
                let chunk_entry = chunk_entry?;
                let name = chunk_entry.file_name().to_string_lossy().to_string();
                if let Some(sequence) = name
                    .strip_prefix("chunk-")
                    .and_then(|v| v.strip_suffix(".json"))
                {
                    let sequence: usize = sequence
                        .parse()
                        .map_err(|_| StreamError::Invalid("Invalid stored chunk name.".into()))?;
                    if name != chunk_name(sequence) {
                        return Err(StreamError::Invalid("Invalid stored chunk name.".into()));
                    }
                    sequences.push(sequence);
                }
            }
            sequences.sort_unstable();
            for sequence in sequences {
                let path = entry.path().join(chunk_name(sequence));
                file_len(&path, MAX_CHUNK_BYTES)?;
                let chunk = parse_chunk(&read_value(&path, MAX_CHUNK_BYTES)?, &record.manifest)?;
                if chunk.sequence != sequence {
                    return Err(StreamError::Invalid(
                        "Stored chunk sequence does not match its filename.".into(),
                    ));
                }
                record.check_next(&chunk)?;
                record.accept(chunk);
            }
            let finish_path = entry.path().join("finish.json");
            if finish_path.try_exists()? {
                let marker = read_value(&finish_path, 1024)?;
                if record.count == 0 || marker != json!({"chunk_count": record.count}) {
                    return Err(StreamError::Invalid(
                        "Stored finish marker does not match the complete stream.".into(),
                    ));
                }
                record.finished = true;
            }
            records.insert(id, record);
        }
        Ok(Self {
            inner: Arc::new(Inner {
                root,
                records: Mutex::new(records),
                temporary: false,
            }),
            processing: Arc::new(Semaphore::new(2)),
            recognition: None,
        })
    }

    /// Enable one local inference worker for this durable store. Tests and embedders
    /// keep their existing dependency-free geometry path unless explicitly enabled.
    pub fn with_recognition(mut self, config: RecognitionConfig) -> Result<Self, StreamError> {
        self.recognition = Some(
            RecognitionService::new(self.inner.root.clone(), Some(config))
                .map_err(StreamError::Invalid)?,
        );
        Ok(self)
    }

    fn recognition_summary(&self, mut summary: StreamSummary) -> StreamSummary {
        if let Some(service) = &self.recognition {
            summary.recognition = Some(service.snapshot(&summary.id, summary.frame_count));
        }
        summary
    }

    fn prepare_recognition(
        &self,
        id: &str,
        count: usize,
    ) -> Result<Option<RecognitionSnapshot>, StreamError> {
        let Some(service) = &self.recognition else {
            return Ok(None);
        };
        service.submit(id, count);
        let snapshot = service.snapshot(id, count);
        match snapshot.status {
            RecognitionStatus::Pending | RecognitionStatus::Running => {
                Err(StreamError::RecognitionPending)
            }
            RecognitionStatus::Complete | RecognitionStatus::Unavailable => Ok(Some(snapshot)),
        }
    }

    pub fn create(&self, original: Value) -> Result<(bool, StreamSummary), StreamError> {
        let manifest = parse_manifest(&original)?;
        let bytes = serde_json::to_vec(&original).map_err(invalid_json)?;
        if bytes.len() > 16 * 1024 {
            return Err(StreamError::Limit("Stream manifest is too large.".into()));
        }
        let mut records = self.inner.records.lock().unwrap();
        if let Some(record) = records.get(&manifest.id) {
            return if original == record.original {
                Ok((false, record.summary()))
            } else {
                Err(StreamError::Conflict(
                    "This stream id belongs to a different capture.".into(),
                ))
            };
        }
        let dir = self.inner.root.join(&manifest.id);
        fs::create_dir_all(&dir)?;
        ensure_directory(&dir)?;
        atomic_write(&dir.join("manifest.json"), &bytes)?;
        let record = empty_record(manifest, original);
        let summary = record.summary();
        records.insert(summary.id.clone(), record);
        Ok((true, summary))
    }

    pub fn summary(&self, id: &str) -> Result<StreamSummary, StreamError> {
        check_id(id)?;
        let summary = self
            .inner
            .records
            .lock()
            .unwrap()
            .get(id)
            .map(Record::summary)
            .ok_or(StreamError::Missing)?;
        Ok(self.recognition_summary(summary))
    }

    pub fn append(
        &self,
        id: &str,
        sequence: usize,
        original: Value,
    ) -> Result<StreamSummary, StreamError> {
        check_id(id)?;
        let bytes = serde_json::to_vec(&original).map_err(invalid_json)?;
        if bytes.len() > MAX_CHUNK_BYTES {
            return Err(StreamError::Limit(
                "Each chunk must be at most 4 MiB.".into(),
            ));
        }
        let mut records = self.inner.records.lock().unwrap();
        let record = records.get_mut(id).ok_or(StreamError::Missing)?;
        // Exact semantic retries are acknowledged even after finishing the stream.
        if sequence < record.count {
            let previous = read_value(
                &self.inner.root.join(id).join(chunk_name(sequence)),
                MAX_CHUNK_BYTES,
            )?;
            return if original == previous {
                let summary = record.summary();
                drop(records);
                if let Some(service) = &self.recognition {
                    service.submit(id, summary.frame_count);
                }
                Ok(self.recognition_summary(summary))
            } else {
                Err(StreamError::Conflict(
                    "This sequence already contains different observations.".into(),
                ))
            };
        }
        let chunk = parse_chunk(&original, &record.manifest)?;
        if chunk.sequence != sequence {
            return Err(StreamError::Invalid(
                "Chunk sequence must match the upload URL.".into(),
            ));
        }
        record.check_next(&chunk)?;
        atomic_write(&self.inner.root.join(id).join(chunk_name(sequence)), &bytes)?;
        record.accept(chunk);
        let summary = record.summary();
        drop(records);
        if let Some(service) = &self.recognition {
            service.submit(id, summary.frame_count);
        }
        Ok(self.recognition_summary(summary))
    }

    pub fn finish(&self, id: &str, chunk_count: usize) -> Result<StreamSummary, StreamError> {
        check_id(id)?;
        let mut records = self.inner.records.lock().unwrap();
        let record = records.get_mut(id).ok_or(StreamError::Missing)?;
        if record.count == 0 || chunk_count != record.count {
            return Err(StreamError::Conflict(format!(
                "Finish requires exactly {} acknowledged chunks and at least one frame.",
                record.count
            )));
        }
        if !record.finished {
            atomic_write(
                &self.inner.root.join(id).join("finish.json"),
                &serde_json::to_vec(&json!({"chunk_count": chunk_count})).unwrap(),
            )?;
            record.finished = true;
        }
        let summary = record.summary();
        drop(records);
        if let Some(service) = &self.recognition {
            service.submit(id, summary.frame_count);
        }
        Ok(self.recognition_summary(summary))
    }

    /// Stores a whole-capture attachment (`STREAM_ASSETS`) for a known stream. Re-sending
    /// replaces it; the per-frame observations themselves remain immutable.
    pub fn put_asset(&self, id: &str, name: &str, bytes: &[u8]) -> Result<(), StreamError> {
        check_id(id)?;
        if !STREAM_ASSETS.contains(&name) {
            return Err(StreamError::Invalid(format!(
                "Stream attachments are limited to {}.",
                STREAM_ASSETS.join(", ")
            )));
        }
        if bytes.len() > MAX_ASSET_BYTES {
            return Err(StreamError::Limit(
                "Stream attachments must be at most 16 MiB.".into(),
            ));
        }
        serde_json::from_slice::<Value>(bytes).map_err(invalid_json)?;
        if !self.inner.records.lock().unwrap().contains_key(id) {
            return Err(StreamError::Missing);
        }
        let dir = self.inner.root.join(id).join("assets");
        if fs::symlink_metadata(&dir).is_err() {
            fs::create_dir(&dir)?;
        }
        ensure_directory(&dir)?; // Refuses a symlink in place of the directory.
        atomic_write(&dir.join(name), bytes)
    }

    /// Attachments present for a stream, keyed by name.
    pub fn assets(&self, id: &str) -> Result<BTreeMap<String, Vec<u8>>, StreamError> {
        check_id(id)?;
        let dir = self.inner.root.join(id).join("assets");
        let mut found = BTreeMap::new();
        for name in STREAM_ASSETS {
            let path = dir.join(name);
            if path.is_file() {
                found.insert(name.to_owned(), read_bytes(&path, MAX_ASSET_BYTES)?);
            }
        }
        Ok(found)
    }

    /// Visits every accepted chunk of a finished stream in sequence order.
    pub fn for_each_chunk(
        &self,
        id: &str,
        mut visit: impl FnMut(usize, StreamChunk) -> Result<(), StreamError>,
    ) -> Result<(StreamManifest, usize), StreamError> {
        check_id(id)?;
        let (manifest, count) = {
            let records = self.inner.records.lock().unwrap();
            let record = records.get(id).ok_or(StreamError::Missing)?;
            if !record.finished {
                return Err(StreamError::Unfinished);
            }
            (record.manifest.clone(), record.count)
        };
        for sequence in 0..count {
            let chunk: StreamChunk = read_json(
                &self.inner.root.join(id).join(chunk_name(sequence)),
                MAX_CHUNK_BYTES,
            )?;
            visit(sequence, chunk)?;
        }
        Ok((manifest, count))
    }

    pub fn reconstruct(&self, id: &str) -> Result<StreamResult, StreamError> {
        self.build_reconstruction(id)
    }

    /// HTTP results are serialized once and cached durably. A second request for the same
    /// immutable finished capture joins that reconstruction instead of starting another job.
    pub fn reconstruct_encoded(&self, id: &str, scene_only: bool) -> Result<Vec<u8>, StreamError> {
        check_id(id)?;
        let (reconstruction, frame_count) = {
            let records = self.inner.records.lock().unwrap();
            let record = records.get(id).ok_or(StreamError::Missing)?;
            if !record.finished {
                return Err(StreamError::Unfinished);
            }
            (record.reconstruction.clone(), record.count)
        };
        let recognition = self.prepare_recognition(id, frame_count)?;
        let cacheable = recognition.as_ref().is_none_or(|snapshot| {
            snapshot.status == RecognitionStatus::Complete && snapshot.failed_frames == 0
        });
        let recognition_key = recognition
            .as_ref()
            .map(|snapshot| snapshot.cache_key.as_str());
        let _job = reconstruction.lock().unwrap();
        let dir = self.inner.root.join(id);
        let path = dir.join(if scene_only {
            SCENE_CACHE
        } else {
            RESULT_CACHE
        });
        if cacheable
            && let Some(bytes) =
                cached_json(&dir, &path, id, frame_count, scene_only, recognition_key)?
        {
            return Ok(bytes);
        }
        // Cache hits and callers waiting for the same job do not consume a processing slot.
        let _permit = self
            .processing
            .try_acquire()
            .map_err(|_| StreamError::Busy)?;
        let result = self.build_reconstruction(id)?;
        let result_bytes = serde_json::to_vec(&result).map_err(invalid_json)?;
        let scene_bytes = serde_json::to_vec(&result.scene).map_err(invalid_json)?;
        // A missing/failing inference worker must not permanently cache a partial model.
        if !cacheable {
            return Ok(if scene_only {
                scene_bytes
            } else {
                result_bytes
            });
        }
        // Atomic cache writes never change or replace the acknowledged original observations.
        atomic_write(&dir.join(RESULT_CACHE), &result_bytes)?;
        atomic_write(&dir.join(SCENE_CACHE), &scene_bytes)?;
        let metadata = CacheMetadata {
            reconstruction_version: RECONSTRUCTION_VERSION,
            source_stream_id: id.to_owned(),
            source_frame_count: frame_count,
            recognition_key: recognition_key.map(str::to_owned),
            result: CacheFile::new(&result_bytes),
            scene: CacheFile::new(&scene_bytes),
        };
        // Write validity metadata last, so interrupted cache writes are always rebuilt.
        atomic_write(
            &dir.join(CACHE_METADATA),
            &serde_json::to_vec(&metadata).map_err(invalid_json)?,
        )?;
        Ok(if scene_only {
            scene_bytes
        } else {
            result_bytes
        })
    }

    fn build_reconstruction(&self, id: &str) -> Result<StreamResult, StreamError> {
        check_id(id)?;
        let (manifest, count) = {
            let records = self.inner.records.lock().unwrap();
            let record = records.get(id).ok_or(StreamError::Missing)?;
            if !record.finished {
                return Err(StreamError::Unfinished);
            }
            (record.manifest.clone(), record.count)
        };
        let recognition = self.prepare_recognition(id, count)?;
        // Retain a small uniformly spaced pose graph including the first and final observation.
        // All unselected raw frames remain on disk and are reintegrated with rigid corrections
        // interpolated by timestamp between their neighboring graph frames.
        let key_count = count.min(MAX_GRAPH_KEYFRAMES);
        let mut alignment_frames = Vec::with_capacity(key_count);
        for index in 0..key_count {
            let sequence = if key_count == 1 {
                0
            } else {
                index * (count - 1) / (key_count - 1)
            };
            let chunk: StreamChunk = read_json(
                &self.inner.root.join(id).join(chunk_name(sequence)),
                MAX_CHUNK_BYTES,
            )?;
            alignment_frames.push(registration_frame(&chunk)?);
        }
        let alignment = alignment::align(&alignment_frames).map_err(StreamError::Invalid)?;
        let mut fusion = TriangleFusion::default();
        let mut objects = BTreeMap::new();
        let mut recognized = ObjectFusion::default();
        let mut surfaces = BTreeMap::new();
        for sequence in 0..count {
            // Decode and release each observation before reading the next. JPEG was validated
            // at ingestion; reconstruction uses measured depth and the supplied rigid pose.
            let mut chunk: StreamChunk = read_json(
                &self.inner.root.join(id).join(chunk_name(sequence)),
                MAX_CHUNK_BYTES,
            )?;
            let correction = alignment.correction_for(chunk.frame.timestamp_seconds);
            chunk.frame.map_from_camera = compose(correction, chunk.frame.map_from_camera);
            if let Some(service) = &self.recognition {
                recognized.integrate(
                    &chunk.frame,
                    &service.detections(id, sequence, &chunk.frame),
                );
            }
            for object in &mut chunk.objects {
                object.map_from_object = compose(correction, object.map_from_object);
            }
            for surface in &mut chunk.surfaces {
                surface.map_from_surface = compose(correction, surface.map_from_surface);
            }
            fusion.integrate(&chunk.frame);
            objects.extend(
                chunk
                    .objects
                    .into_iter()
                    .map(|value| (value.id.clone(), value)),
            );
            surfaces.extend(
                chunk
                    .surfaces
                    .into_iter()
                    .map(|value| (value.id.clone(), value)),
            );
        }
        let weld_meters = fusion.cell_meters();
        let mesh_compactions = fusion.compaction_level;
        let (objects, recognition_merge) =
            merge_recognized(objects.into_values().collect(), recognized.finish());
        let mut display_reports = Vec::new();
        let meshes = if fusion.triangles.is_empty() {
            vec![]
        } else {
            let measured = MeshCapture {
                id: "stream-depth-fusion".into(),
                map_from_anchor: identity(),
                vertices: fusion.vertices,
                triangles: fusion.triangles,
                classifications: None,
            };
            // Both returned halves must share the compact display geometry. Observed
            // surfaces and obstacle bounds remain measured independently for navigation.
            let (display, report) = simplify_display_mesh(measured, DisplayMeshOptions::default())
                .map_err(StreamError::Invalid)?;
            display_reports.push(report);
            vec![display]
        };
        let capture = ScanBundle {
            schema_version: 1,
            id: manifest.id.clone(),
            map_id: manifest.map_id,
            floor_id: manifest.floor_id,
            coordinates: manifest.coordinates,
            meshes,
            frames: vec![],
            objects,
            surfaces: surfaces.into_values().collect(),
        };
        if capture.meshes.is_empty() && capture.objects.is_empty() && capture.surfaces.is_empty() {
            return Err(StreamError::Invalid("No connected, confident depth surface was captured. Scan closer to surfaces with adequate lighting and try again.".into()));
        }
        let mut scene =
            scene::process_with_catalog_references(&capture, ProcessingOptions::default())
                .map_err(StreamError::Invalid)?;
        // The app already bundles these catalog assets. Send model placements, not
        // thousands of repeated vertices for each chair. Older viewers can render
        // the existing coarse parts. Unknown objects also need only their bounds.
        scene.warnings.push(if alignment.optimized {
            "Measured depth geometry and observed labels use loop-optimized camera poses. Live AR navigation needs localization against this corrected map. RGB texturing and automatic floor recognition are not implemented.".into()
        } else if alignment.constraints.iter().any(|constraint| constraint.accepted) {
            "A verified loop was already aligned; geometry retains the original ARKit poses. RGB texturing and automatic floor recognition are not implemented.".into()
        } else {
            "No observable, verified loop closure was accepted; geometry uses the original ARKit poses. RGB texturing and automatic floor recognition are not implemented.".into()
        });
        match recognition.as_ref().map(|snapshot| &snapshot.status) {
            Some(RecognitionStatus::Complete) if recognition.as_ref().is_some_and(|snapshot| snapshot.failed_frames > 0) => scene.warnings.push("Some camera views could not be recognized. Confirmed furniture uses measured depth; other areas retain measured geometry.".into()),
            Some(RecognitionStatus::Complete) => scene.warnings.push("Furniture types are estimated from camera views; dimensions come from measured depth. Uncertain objects keep measured shapes.".into()),
            Some(_) => scene.warnings.push("Furniture recognition was unavailable. The map retains measured geometry and supplied labels.".into()),
            None => scene.warnings.push("Furniture recognition is disabled. The map retains measured geometry and supplied labels.".into()),
        }
        if mesh_compactions > 0
            || display_reports
                .iter()
                .any(|report| report.display_triangle_count < report.source_triangle_count)
        {
            scene.warnings.push(
                "Map detail was reduced for this large scan. Original measurements remain saved."
                    .into(),
            );
        }
        let mut value = serde_json::to_value(&capture).map_err(invalid_json)?;
        value["metadata"] = json!({
            "source_stream_id": manifest.id, "source_frame_count": count,
            "reconstruction_method": "adaptive_depth_fusion_recognition_display_v5",
            "coordinate_frame": "original_arkit_session", "alignment_refined": alignment.optimized,
            "alignment_optimized": alignment.optimized,
            "alignment_keyframe_count": key_count, "correction_interpolation": "rigid_by_timestamp",
            "weld_meters": weld_meters, "mesh_compactions": mesh_compactions,
            "display_meshes": display_reports,
            "model_catalog": "photo-furniture-v1",
            "recognition": {"worker": recognition.map(|snapshot| serde_json::to_value(snapshot).unwrap())
                .unwrap_or_else(|| json!({"status":"disabled"})),
                "fusion": recognized.stats(), "merge": recognition_merge},
        });
        let result = StreamResult {
            capture: value,
            scene,
            alignment,
        };
        Ok(result)
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CacheMetadata {
    reconstruction_version: u32,
    source_stream_id: String,
    source_frame_count: usize,
    recognition_key: Option<String>,
    result: CacheFile,
    scene: CacheFile,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CacheFile {
    bytes: usize,
    crc32: u32,
}
impl CacheFile {
    fn new(bytes: &[u8]) -> Self {
        let mut checksum = flate2::Crc::new();
        checksum.update(bytes);
        Self {
            bytes: bytes.len(),
            crc32: checksum.sum(),
        }
    }
    fn matches(&self, bytes: &[u8]) -> bool {
        let actual = Self::new(bytes);
        actual.bytes == self.bytes && actual.crc32 == self.crc32
    }
}

fn cached_json(
    dir: &Path,
    path: &Path,
    id: &str,
    frame_count: usize,
    scene_only: bool,
    recognition_key: Option<&str>,
) -> Result<Option<Vec<u8>>, StreamError> {
    let metadata_path = dir.join(CACHE_METADATA);
    if !path.try_exists()? || !metadata_path.try_exists()? {
        return Ok(None);
    }
    let metadata: CacheMetadata = match read_json(&metadata_path, 4096) {
        Ok(metadata) => metadata,
        Err(StreamError::Invalid(_) | StreamError::Limit(_)) => return Ok(None),
        Err(error) => return Err(error),
    };
    if metadata.reconstruction_version != RECONSTRUCTION_VERSION
        || metadata.source_stream_id != id
        || metadata.source_frame_count != frame_count
        || metadata.recognition_key.as_deref() != recognition_key
    {
        return Ok(None);
    }
    let expected = if scene_only {
        &metadata.scene
    } else {
        &metadata.result
    };
    let file = fs::symlink_metadata(path)?;
    if !file.file_type().is_file() || file.len() != expected.bytes as u64 {
        return Ok(None);
    };
    // Results have no aggregate size cutoff. Chunk reads remain separately bounded.
    let bytes = fs::read(path)?;
    // Detect accidental corruption, including valid JSON with changed geometry. This is
    // derived data; only the backend writes it after validating the immutable raw source.
    if !expected.matches(&bytes) {
        return Ok(None);
    }
    Ok(Some(bytes))
}

fn empty_record(manifest: StreamManifest, original: Value) -> Record {
    Record {
        manifest,
        original,
        count: 0,
        last_timestamp: None,
        frames: HashSet::new(),
        finished: false,
        reconstruction: Arc::new(Mutex::new(())),
    }
}

fn parse_manifest(original: &Value) -> Result<StreamManifest, StreamError> {
    let manifest: StreamManifest =
        serde_json::from_value(original.clone()).map_err(invalid_json)?;
    check_id(&manifest.id)?;
    if manifest.schema_version != 1
        || manifest.map_id.trim().is_empty()
        || manifest.floor_id.trim().is_empty()
        || manifest.map_id.len() > 256
        || manifest.floor_id.len() > 256
        || manifest.coordinates.units != "meters"
        || manifest.coordinates.up_axis != "y"
        || manifest.coordinates.handedness != "right"
    {
        return Err(StreamError::Invalid("Streams need schema_version 1, map/floor ids, and right-handed y-up coordinates in meters.".into()));
    }
    Ok(manifest)
}

fn parse_chunk(original: &Value, manifest: &StreamManifest) -> Result<StreamChunk, StreamError> {
    let chunk: StreamChunk = serde_json::from_value(original.clone()).map_err(invalid_json)?;
    if chunk.frame.id.len() > 256
        || chunk.frame.depth.values_m.len() > MAX_DEPTH_SAMPLES
        || chunk.frame.camera.image_width > 2048
        || chunk.frame.camera.image_height > 2048
        || chunk
            .frame
            .camera
            .image_width
            .checked_mul(chunk.frame.camera.image_height)
            .is_none_or(|v| v > MAX_COLOR_PIXELS)
        || chunk.surfaces.len() > MAX_LABELS
        || chunk.objects.len() > MAX_LABELS
    {
        return Err(StreamError::Limit(
            "Frame resolution or observed-label count exceeds the streaming limit.".into(),
        ));
    }
    // Reuse the portable validator for rigid poses, matching calibration/depth dimensions,
    // confidence buffers, finite samples, measured labels, and unique identifiers.
    let probe = ScanBundle {
        schema_version: 1,
        id: manifest.id.clone(),
        map_id: manifest.map_id.clone(),
        floor_id: manifest.floor_id.clone(),
        coordinates: manifest.coordinates.clone(),
        meshes: vec![],
        frames: vec![chunk.frame.clone()],
        objects: chunk.objects.clone(),
        surfaces: chunk.surfaces.clone(),
    };
    probe.validate().map_err(StreamError::Invalid)?;
    validate_context(&chunk)?;
    if chunk.color_jpeg.len() > MAX_JPEG_BYTES.div_ceil(3) * 4 {
        return Err(StreamError::Limit(
            "Frame JPEG must be at most 512 KiB.".into(),
        ));
    }
    let jpeg = STANDARD
        .decode(&chunk.color_jpeg)
        .map_err(|_| StreamError::Invalid("color_jpeg must be valid standard base64.".into()))?;
    if jpeg.len() > MAX_JPEG_BYTES {
        return Err(StreamError::Limit(
            "Frame JPEG must be at most 512 KiB.".into(),
        ));
    }
    let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(&jpeg));
    decoder.set_max_decoding_buffer_size(MAX_COLOR_PIXELS * 4);
    decoder.read_info().map_err(|_| {
        StreamError::Invalid("color_jpeg must contain a readable JPEG image.".into())
    })?;
    let info = decoder
        .info()
        .ok_or_else(|| StreamError::Invalid("JPEG dimensions are missing.".into()))?;
    if info.width as usize != chunk.frame.camera.image_width
        || info.height as usize != chunk.frame.camera.image_height
    {
        return Err(StreamError::Invalid(
            "JPEG dimensions must match the sensor-native camera calibration.".into(),
        ));
    }
    decoder.decode().map_err(|_| {
        StreamError::Invalid("color_jpeg contains invalid or incomplete image data.".into())
    })?;
    Ok(chunk)
}

/// Environment samples hold only finite numbers (or nulls); poses are rigid, finite, bounded.
fn validate_context(chunk: &StreamChunk) -> Result<(), StreamError> {
    if let Some(environment) = &chunk.environment {
        let fields = environment
            .as_object()
            .ok_or_else(|| StreamError::Invalid("environment must be an object.".into()))?;
        let numeric = |value: &Value| value.is_null() || value.as_f64().is_some_and(f64::is_finite);
        if fields.len() > MAX_ENVIRONMENT_KEYS
            || fields
                .iter()
                .any(|(key, value)| key.len() > 64 || !numeric(value))
        {
            return Err(StreamError::Invalid(
                "environment must contain at most 32 finite numeric fields.".into(),
            ));
        }
    }
    if chunk.poses.len() > MAX_POSES_PER_CHUNK {
        return Err(StreamError::Limit(
            "Too many movement poses in one chunk.".into(),
        ));
    }
    for pose in &chunk.poses {
        let short = |label: &Option<String>| label.as_ref().is_none_or(|v| v.len() <= 64);
        if !pose.t.is_finite()
            || pose.t < 0.0
            || pose.m.validate().is_err()
            || !short(&pose.tracking)
            || !short(&pose.mapping)
        {
            return Err(StreamError::Invalid(
                "Movement poses need finite times and rigid transforms.".into(),
            ));
        }
    }
    Ok(())
}

fn invalid_json(error: serde_json::Error) -> StreamError {
    StreamError::Invalid(error.to_string())
}

fn safe_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn check_id(id: &str) -> Result<(), StreamError> {
    if safe_id(id) {
        Ok(())
    } else {
        Err(StreamError::Invalid(
            "Stream ids must be UUID strings.".into(),
        ))
    }
}

fn chunk_name(sequence: usize) -> String {
    format!("chunk-{sequence:06}.json")
}

fn ensure_directory(path: &Path) -> Result<(), StreamError> {
    if fs::symlink_metadata(path)?.file_type().is_dir() {
        Ok(())
    } else {
        Err(StreamError::Invalid(
            "Stream paths must be regular directories.".into(),
        ))
    }
}

fn file_len(path: &Path, max: usize) -> Result<u64, StreamError> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() || metadata.len() > max as u64 {
        return Err(StreamError::Invalid(
            "Stored stream file is not a bounded regular file.".into(),
        ));
    }
    Ok(metadata.len())
}

fn read_bytes(path: &Path, max: usize) -> Result<Vec<u8>, StreamError> {
    file_len(path, max)?;
    let mut bytes = Vec::new();
    File::open(path)?
        .take(max as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > max {
        return Err(StreamError::Limit(
            "Stored stream file is too large.".into(),
        ));
    }
    Ok(bytes)
}

fn read_json<T: DeserializeOwned>(path: &Path, max: usize) -> Result<T, StreamError> {
    serde_json::from_slice(&read_bytes(path, max)?).map_err(invalid_json)
}

fn read_value(path: &Path, max: usize) -> Result<Value, StreamError> {
    read_json(path, max)
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), StreamError> {
    let parent = path.parent().unwrap();
    ensure_directory(parent)?;
    let serial = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
    let temporary = parent.join(format!(".write-{}-{serial}.tmp", std::process::id()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

fn identity() -> Transform {
    Transform([
        1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0,
    ])
}

fn compose(left: Transform, right: Transform) -> Transform {
    Transform(std::array::from_fn(|index| {
        let row = index % 4;
        let col = index / 4;
        (0..4)
            .map(|inner| left.0[inner * 4 + row] * right.0[col * 4 + inner])
            .sum()
    }))
}

fn registration_frame(chunk: &StreamChunk) -> Result<AlignmentFrame, StreamError> {
    let frame = &chunk.frame;
    let mut camera_frame = frame.clone();
    camera_frame.map_from_camera = identity();
    let valid = frame
        .depth
        .values_m
        .iter()
        .enumerate()
        .filter_map(|(index, depth)| {
            let depth = (*depth)?;
            let confidence = frame.depth.confidence.as_ref()?[index];
            (confidence >= 1 && (0.15..=8.0).contains(&depth)).then_some((index, depth))
        })
        .collect::<Vec<_>>();
    let stride = valid.len().div_ceil(MAX_REGISTRATION_POINTS).max(1);
    let points = valid
        .into_iter()
        .step_by(stride)
        .map(|(index, depth)| camera_frame.point_in_map(index, depth))
        .collect();
    let jpeg = STANDARD
        .decode(&chunk.color_jpeg)
        .map_err(|_| StreamError::Invalid("Stored JPEG base64 is invalid.".into()))?;
    let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(jpeg));
    decoder.set_max_decoding_buffer_size(MAX_COLOR_PIXELS * 4);
    decoder
        .read_info()
        .map_err(|_| StreamError::Invalid("Stored JPEG is invalid.".into()))?;
    let info = decoder
        .info()
        .ok_or_else(|| StreamError::Invalid("Stored JPEG dimensions are missing.".into()))?;
    let pixels = decoder
        .decode()
        .map_err(|_| StreamError::Invalid("Stored JPEG cannot be decoded.".into()))?;
    let channels = info.pixel_format.pixel_bytes();
    // Sensor-native 16x12 RGB thumbnail. Keep spatial appearance, not only a histogram:
    // different blank-looking corridors should not become loops on color alone.
    let mut visual_signature = Vec::with_capacity(16 * 12 * 3);
    for row in 0..12 {
        for col in 0..16 {
            let x = ((2 * col + 1) * info.width as usize / 32).min(info.width as usize - 1);
            let y = ((2 * row + 1) * info.height as usize / 24).min(info.height as usize - 1);
            let offset = (y * info.width as usize + x) * channels;
            let color = match info.pixel_format {
                jpeg_decoder::PixelFormat::RGB24 => {
                    [pixels[offset], pixels[offset + 1], pixels[offset + 2]]
                }
                jpeg_decoder::PixelFormat::CMYK32 => std::array::from_fn(|axis| {
                    255u8.saturating_sub(pixels[offset + axis].saturating_add(pixels[offset + 3]))
                }),
                _ => [pixels[offset]; 3],
            };
            visual_signature.extend(color.map(|value| value as f64 / 255.0));
        }
    }
    Ok(AlignmentFrame {
        id: frame.id.clone(),
        timestamp_seconds: frame.timestamp_seconds,
        pose: frame.map_from_camera,
        points,
        visual_signature,
    })
}

struct TriangleFusion {
    vertices: Vec<Vec3>,
    triangles: Vec<[usize; 3]>,
    // Keep each measured face's normal through every compaction, preventing accumulated folds.
    source_normals: Vec<Vec3>,
    voxels: HashMap<[i64; 3], usize>,
    faces: HashSet<[usize; 3]>,
    compaction_level: u32,
    vertex_target: usize,
    triangle_target: usize,
}

struct PreparedTriangle {
    keys: [[i64; 3]; 3],
    positions: [Vec3; 3],
}

impl Default for TriangleFusion {
    fn default() -> Self {
        Self {
            vertices: Vec::new(),
            triangles: Vec::new(),
            source_normals: Vec::new(),
            voxels: HashMap::new(),
            faces: HashSet::new(),
            compaction_level: 0,
            vertex_target: MESH_VERTEX_TARGET,
            triangle_target: MESH_TRIANGLE_TARGET,
        }
    }
}

impl TriangleFusion {
    fn cell_meters(&self) -> f64 {
        WELD_METERS * (1u32 << self.compaction_level) as f64
    }

    fn voxel_key(&self, position: Vec3) -> [i64; 3] {
        // Nested cells make every finer cell belong to exactly one coarser cell,
        // including at negative coordinates. First measured representatives stay
        // within one final cell of their source without accumulated displacement.
        let factor = 1i64 << self.compaction_level;
        position.map(|value| ((value / WELD_METERS).floor() as i64).div_euclid(factor))
    }

    fn integrate(&mut self, frame: &DepthFrame) {
        let width = frame.depth.width;
        let height = frame.depth.height;
        if width < 2 || height < 2 {
            return;
        }
        // A sample belongs to up to six triangles. Unproject it once, preserving the
        // exact coordinates and triangle order while avoiding per-triangle allocation.
        let projected: Vec<_> = frame
            .depth
            .values_m
            .iter()
            .enumerate()
            .map(|(index, depth)| {
                let depth = (*depth)?;
                let confidence = frame.depth.confidence.as_ref()?[index];
                (confidence >= 1 && (0.15..=8.0).contains(&depth))
                    .then(|| (depth, frame.point_in_map(index, depth)))
            })
            .collect();
        for row in 0..height - 1 {
            for col in 0..width - 1 {
                let tl = row * width + col;
                // Clockwise in image space faces towards the camera after y-up conversion.
                for pixels in [
                    [tl, tl + width, tl + 1],
                    [tl + 1, tl + width, tl + width + 1],
                ] {
                    let [Some(a), Some(b), Some(c)] = pixels.map(|index| projected[index]) else {
                        continue;
                    };
                    let depths = [a.0, b.0, c.0];
                    let nearest = depths.iter().copied().fold(f64::INFINITY, f64::min);
                    let farthest = depths.iter().copied().fold(0.0, f64::max);
                    // Do not bridge foreground/background silhouettes or missing samples.
                    if farthest - nearest > (nearest * 0.05).max(0.05) {
                        continue;
                    }
                    let positions = [a.1, b.1, c.1];
                    self.add_triangle(positions);
                }
            }
        }
    }

    fn add_triangle(&mut self, positions: [Vec3; 3]) {
        let Some(source_normal) = Self::measured_normal(positions) else {
            return;
        };
        loop {
            let Some(prepared) = self.prepare_triangle(positions, source_normal) else {
                return;
            };
            let new_vertices = prepared
                .keys
                .iter()
                .filter(|key| !self.voxels.contains_key(*key))
                .count();
            if self.compaction_level < MAX_COMPACTION_LEVEL
                && (self.vertices.len() + new_vertices > self.vertex_target
                    || self.triangles.len() + 1 > self.triangle_target)
            {
                self.compact();
                // The offending observation and all later coverage are still integrated.
                continue;
            }
            self.insert_triangle(prepared, source_normal);
            return;
        }
    }

    fn prepare_triangle(
        &self,
        positions: [Vec3; 3],
        source_normal: Vec3,
    ) -> Option<PreparedTriangle> {
        let keys = positions.map(|position| self.voxel_key(position));
        if keys[0] == keys[1] || keys[0] == keys[2] || keys[1] == keys[2] {
            return None;
        }
        if let [Some(a), Some(b), Some(c)] = keys.map(|key| self.voxels.get(&key).copied()) {
            let mut canonical = [a, b, c];
            canonical.sort_unstable();
            if self.faces.contains(&canonical) {
                return None;
            }
        }
        let mapped = std::array::from_fn(|index| {
            self.voxels
                .get(&keys[index])
                .map_or(positions[index], |vertex| self.vertices[*vertex])
        });
        let mapped_normal = Self::measured_normal(mapped)?;
        let dot: f64 = mapped_normal
            .iter()
            .zip(source_normal)
            .map(|(a, b)| a * b)
            .sum();
        let mapped_length: f64 = mapped_normal.iter().map(|v| v * v).sum();
        let source_length: f64 = source_normal.iter().map(|v| v * v).sum();
        // Reject a fold or a normal change over 60 degrees instead of manufacturing a face.
        if dot <= 0. || dot * dot < 0.25 * mapped_length * source_length {
            return None;
        }
        Some(PreparedTriangle {
            keys,
            positions: mapped,
        })
    }

    fn measured_normal(positions: [Vec3; 3]) -> Option<Vec3> {
        let a = std::array::from_fn::<_, 3, _>(|i| positions[1][i] - positions[0][i]);
        let b = std::array::from_fn::<_, 3, _>(|i| positions[2][i] - positions[0][i]);
        let cross = [
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        ];
        if cross.iter().map(|v| v * v).sum::<f64>() < 1e-12 {
            return None;
        }
        // Very coarse angular samples should not fill broad regions between observations.
        if positions.iter().enumerate().any(|(i, p)| {
            let q = positions[(i + 1) % 3];
            p.iter().zip(q).map(|(p, q)| (p - q) * (p - q)).sum::<f64>() > 0.25
        }) {
            return None;
        }
        Some(cross)
    }

    fn insert_triangle(&mut self, prepared: PreparedTriangle, source_normal: Vec3) {
        let mut triangle = [0usize; 3];
        for (i, vertex) in triangle.iter_mut().enumerate() {
            *vertex = *self.voxels.entry(prepared.keys[i]).or_insert_with(|| {
                let index = self.vertices.len();
                self.vertices.push(prepared.positions[i]);
                index
            });
        }
        let mut canonical = triangle;
        canonical.sort_unstable();
        self.faces.insert(canonical);
        self.triangles.push(triangle);
        self.source_normals.push(source_normal);
    }

    fn compact(&mut self) {
        self.compaction_level += 1;
        let vertices = std::mem::take(&mut self.vertices);
        let triangles = std::mem::take(&mut self.triangles);
        let normals = std::mem::take(&mut self.source_normals);
        self.voxels.clear();
        self.faces.clear();
        // Preserve insertion order and measured representatives. Only faces supported
        // by earlier measurements are remapped; holes are never explicitly filled.
        for (triangle, normal) in triangles.into_iter().zip(normals) {
            if let Some(prepared) =
                self.prepare_triangle(triangle.map(|index| vertices[index]), normal)
            {
                self.insert_triangle(prepared, normal);
            }
        }
    }
}

#[cfg(test)]
mod reconstruction_tests {
    use super::*;

    fn add_patch(fusion: &mut TriangleFusion, offset: f64, jitter: f64, spacing: f64) {
        for row in 0..5 {
            for col in 0..5 {
                let x = offset + col as f64 * spacing + jitter;
                let y = row as f64 * spacing + jitter;
                let points = [
                    [x, y, -2.],
                    [x + spacing, y, -2.],
                    [x, y + spacing, -2.],
                    [x + spacing, y + spacing, -2.],
                ];
                fusion.add_triangle([points[0], points[1], points[2]]);
                fusion.add_triangle([points[1], points[3], points[2]]);
            }
        }
    }

    #[test]
    fn soft_targets_keep_early_and_late_coverage_and_never_reject_a_building() {
        let build = || {
            let mut fusion = TriangleFusion {
                vertex_target: 25,
                triangle_target: 30,
                ..Default::default()
            };
            for region in 0..12 {
                add_patch(&mut fusion, region as f64 * 2. - 8., 0., 0.1);
            }
            fusion
        };
        let fusion = build();
        let repeated = build();
        assert_eq!(fusion.compaction_level, MAX_COMPACTION_LEVEL);
        assert!(fusion.vertices.len() > fusion.vertex_target);
        assert!(fusion.triangles.len() > fusion.triangle_target);
        assert!(fusion.vertices.iter().any(|point| point[0] < -7.9));
        assert!(fusion.vertices.iter().any(|point| point[0] > 14.4));
        assert_eq!(fusion.vertices, repeated.vertices);
        assert_eq!(fusion.triangles, repeated.triangles);
        for (triangle, source_normal) in fusion.triangles.iter().zip(&fusion.source_normals) {
            let normal =
                TriangleFusion::measured_normal(triangle.map(|index| fusion.vertices[index]))
                    .unwrap();
            assert!(
                normal
                    .iter()
                    .zip(source_normal)
                    .map(|(a, b)| a * b)
                    .sum::<f64>()
                    > 0.
            );
        }
    }

    #[test]
    fn moving_overlapping_views_remain_compact_after_the_soft_target() {
        let mut fusion = TriangleFusion {
            vertex_target: 25,
            triangle_target: 30,
            ..Default::default()
        };
        for view in 0..80 {
            add_patch(&mut fusion, -0.24, (view % 4) as f64 * 0.003, 0.04);
        }
        assert_eq!(fusion.compaction_level, MAX_COMPACTION_LEVEL);
        assert!(!fusion.triangles.is_empty());
        assert!(fusion.triangles.len() < 80);
        assert!(fusion.vertices.iter().all(|point| point[2] == -2.));
        assert_eq!(fusion.source_normals.len(), fusion.triangles.len());
    }

    #[test]
    fn remapped_faces_cannot_fold_or_tilt_away_from_their_measurement() {
        let measured = [
            [0.079, 0.079, -2.],
            [0.081, 0.079, -2.],
            [0.079, 0.081, -2.],
        ];
        let normal = TriangleFusion::measured_normal(measured).unwrap();
        for representatives in [
            [
                [0.079, 0.079, -2.],
                [0.081, 0.001, -2.],
                [0.001, 0.081, -2.],
            ],
            [
                [0.079, 0.079, -2.],
                [0.081, 0.079, -1.921],
                [0.079, 0.081, -2.],
            ],
        ] {
            let mut fusion = TriangleFusion {
                compaction_level: MAX_COMPACTION_LEVEL,
                ..Default::default()
            };
            for point in representatives {
                fusion
                    .voxels
                    .insert(fusion.voxel_key(point), fusion.vertices.len());
                fusion.vertices.push(point);
            }
            assert!(fusion.prepare_triangle(measured, normal).is_none());
        }
    }

    #[test]
    fn compaction_preserves_a_large_confidence_hole_and_depth_discontinuities() {
        let mut frame: DepthFrame = serde_json::from_value(json!({
            "id":"hole", "timestamp_seconds":1., "pixel_orientation":"sensor_native", "map_from_camera":identity(),
            "camera":{"image_width":33,"image_height":33,"fx":50.,"fy":50.,"cx":16.,"cy":16.},
            "depth":{"width":33,"height":33,"values_m":vec![2.;33*33],"confidence":vec![2;33*33]}
        }))
        .unwrap();
        for row in 11..22 {
            for col in 11..22 {
                frame.depth.confidence.as_mut().unwrap()[row * 33 + col] = 0;
            }
        }
        let mut fusion = TriangleFusion {
            vertex_target: 100,
            triangle_target: 100,
            ..Default::default()
        };
        fusion.integrate(&frame);
        assert_eq!(fusion.compaction_level, MAX_COMPACTION_LEVEL);
        assert!(!fusion.triangles.is_empty());
        for triangle in &fusion.triangles {
            let p = triangle.map(|index| fusion.vertices[index]);
            let signs = std::array::from_fn::<_, 3, _>(|i| {
                let a = p[i];
                let b = p[(i + 1) % 3];
                a[0] * b[1] - a[1] * b[0]
            });
            assert!(
                signs.iter().any(|value| *value > 0.) && signs.iter().any(|value| *value < 0.),
                "a remapped measured face filled the center of the confidence hole: {p:?}"
            );
        }
        frame.depth.confidence = Some(vec![2; 33 * 33]);
        for row in 0..33 {
            for col in 16..33 {
                frame.depth.values_m[row * 33 + col] = Some(5.);
            }
        }
        let mut fusion = TriangleFusion {
            vertex_target: 100,
            triangle_target: 100,
            ..Default::default()
        };
        fusion.integrate(&frame);
        assert_eq!(fusion.compaction_level, MAX_COMPACTION_LEVEL);
        for triangle in &fusion.triangles {
            let depths = triangle.map(|index| fusion.vertices[index][2]);
            assert_eq!(depths[0], depths[1]);
            assert_eq!(depths[1], depths[2]);
        }
    }

    #[test]
    fn cached_results_larger_than_the_former_64_mib_limit_remain_readable() {
        let store = StreamStore::default();
        let id = "ebcb2c65-e1cd-4517-a02a-c204579b2f24";
        let dir = store.inner.root.join(id);
        fs::create_dir(&dir).unwrap();
        let mut bytes = b"{}".to_vec();
        bytes.resize(64 * 1024 * 1024 + 1, b' ');
        let metadata = CacheMetadata {
            reconstruction_version: RECONSTRUCTION_VERSION,
            source_stream_id: id.into(),
            source_frame_count: 1,
            recognition_key: None,
            result: CacheFile::new(&bytes),
            scene: CacheFile::new(&bytes),
        };
        fs::write(dir.join(RESULT_CACHE), &bytes).unwrap();
        fs::write(
            dir.join(CACHE_METADATA),
            serde_json::to_vec(&metadata).unwrap(),
        )
        .unwrap();
        let cached = cached_json(&dir, &dir.join(RESULT_CACHE), id, 1, false, None)
            .unwrap()
            .unwrap();
        assert_eq!(cached.len(), bytes.len());
        assert_eq!(serde_json::from_slice::<Value>(&cached).unwrap(), json!({}));
    }
}
