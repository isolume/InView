//! Durable continuous capture and a bounded, pose-preserving reconstruction baseline.
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
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Semaphore;

use crate::{
    alignment::{self, AlignmentFrame, AlignmentResult},
    capture::{CapturedSurface, Coordinates, DepthFrame, DetectedObject, MeshCapture, ScanBundle},
    geometry::{Transform, Vec3},
    scene::{self, ProcessingOptions, Scene},
};

pub const MAX_CHUNK_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_FRAMES: usize = 10_000;
pub const MAX_STREAM_BYTES: u64 = 2 * 1024 * 1024 * 1024;
pub const MAX_RESULT_BYTES: usize = 64 * 1024 * 1024;
const MAX_JPEG_BYTES: usize = 512 * 1024;
const MAX_DEPTH_SAMPLES: usize = 512 * 512;
const MAX_COLOR_PIXELS: usize = 1024 * 1024;
const MAX_LABELS: usize = 1024;
const MAX_VERTICES: usize = 250_000;
const MAX_TRIANGLES: usize = 500_000;
const MAX_GRAPH_KEYFRAMES: usize = 64;
const MAX_REGISTRATION_POINTS: usize = 512;
const WELD_METERS: f64 = 0.02;
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
}

#[derive(Clone, Debug, Serialize)]
pub struct StreamSummary {
    pub id: String,
    pub map_id: String,
    pub floor_id: String,
    pub next_sequence: usize,
    pub finished: bool,
    pub frame_count: usize,
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
    Conflict(String),
    Limit(String),
    ResultTooLarge,
    Missing,
    Unfinished,
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
    bytes: u64,
    last_timestamp: Option<f64>,
    frames: HashSet<String>,
    surfaces: HashSet<String>,
    objects: HashSet<String>,
    finished: bool,
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
        }
    }

    fn check_next(&self, chunk: &StreamChunk, bytes: u64) -> Result<(), StreamError> {
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
        if self.count >= MAX_FRAMES || self.bytes + bytes > MAX_STREAM_BYTES {
            return Err(StreamError::Limit("The scan reached its frame or storage limit. Finish this scan before capturing more.".into()));
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
        for (seen, ids) in [
            (
                &self.surfaces,
                chunk
                    .surfaces
                    .iter()
                    .map(|v| v.id.as_str())
                    .collect::<Vec<_>>(),
            ),
            (
                &self.objects,
                chunk
                    .objects
                    .iter()
                    .map(|v| v.id.as_str())
                    .collect::<Vec<_>>(),
            ),
        ] {
            if seen.len() + ids.into_iter().filter(|id| !seen.contains(*id)).count() > MAX_LABELS {
                return Err(StreamError::Limit(
                    "The scan reached its observed-label limit.".into(),
                ));
            }
        }
        Ok(())
    }

    fn accept(&mut self, chunk: StreamChunk, bytes: u64) {
        self.count += 1;
        self.bytes += bytes;
        self.last_timestamp = Some(chunk.frame.timestamp_seconds);
        self.frames.insert(chunk.frame.id);
        self.surfaces
            .extend(chunk.surfaces.into_iter().map(|value| value.id));
        self.objects
            .extend(chunk.objects.into_iter().map(|value| value.id));
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
    inner: Arc<Inner>,
    pub(crate) processing: Arc<Semaphore>,
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
            if sequences.len() > MAX_FRAMES {
                return Err(StreamError::Limit(
                    "Stored stream exceeds the frame limit.".into(),
                ));
            }
            for sequence in sequences {
                let path = entry.path().join(chunk_name(sequence));
                let bytes = file_len(&path, MAX_CHUNK_BYTES)?;
                let chunk = parse_chunk(&read_value(&path, MAX_CHUNK_BYTES)?, &record.manifest)?;
                if chunk.sequence != sequence {
                    return Err(StreamError::Invalid(
                        "Stored chunk sequence does not match its filename.".into(),
                    ));
                }
                record.check_next(&chunk, bytes)?;
                record.accept(chunk, bytes);
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
        })
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
        self.inner
            .records
            .lock()
            .unwrap()
            .get(id)
            .map(Record::summary)
            .ok_or(StreamError::Missing)
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
                Ok(record.summary())
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
        record.check_next(&chunk, bytes.len() as u64)?;
        atomic_write(&self.inner.root.join(id).join(chunk_name(sequence)), &bytes)?;
        record.accept(chunk, bytes.len() as u64);
        Ok(record.summary())
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
        Ok(record.summary())
    }

    pub fn reconstruct(&self, id: &str) -> Result<StreamResult, StreamError> {
        check_id(id)?;
        let (manifest, count) = {
            let records = self.inner.records.lock().unwrap();
            let record = records.get(id).ok_or(StreamError::Missing)?;
            if !record.finished {
                return Err(StreamError::Unfinished);
            }
            (record.manifest.clone(), record.count)
        };
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
            let original = read_value(
                &self.inner.root.join(id).join(chunk_name(sequence)),
                MAX_CHUNK_BYTES,
            )?;
            let chunk: StreamChunk = serde_json::from_value(original).map_err(invalid_json)?;
            alignment_frames.push(registration_frame(&chunk)?);
        }
        let alignment = alignment::align(&alignment_frames).map_err(StreamError::Invalid)?;
        let mut fusion = TriangleFusion::default();
        let mut objects = BTreeMap::new();
        let mut surfaces = BTreeMap::new();
        for sequence in 0..count {
            // Decode and release each observation before reading the next. JPEG was validated
            // at ingestion; reconstruction uses measured depth and the supplied rigid pose.
            let original = read_value(
                &self.inner.root.join(id).join(chunk_name(sequence)),
                MAX_CHUNK_BYTES,
            )?;
            let mut chunk: StreamChunk = serde_json::from_value(original).map_err(invalid_json)?;
            let correction = alignment.correction_for(chunk.frame.timestamp_seconds);
            chunk.frame.map_from_camera = compose(correction, chunk.frame.map_from_camera);
            for object in &mut chunk.objects {
                object.map_from_object = compose(correction, object.map_from_object);
            }
            for surface in &mut chunk.surfaces {
                surface.map_from_surface = compose(correction, surface.map_from_surface);
            }
            fusion.integrate(&chunk.frame)?;
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
        let meshes = if fusion.triangles.is_empty() {
            vec![]
        } else {
            vec![MeshCapture {
                id: "stream-depth-fusion".into(),
                map_from_anchor: identity(),
                vertices: fusion.vertices,
                triangles: fusion.triangles,
                classifications: None,
            }]
        };
        let capture = ScanBundle {
            schema_version: 1,
            id: manifest.id.clone(),
            map_id: manifest.map_id,
            floor_id: manifest.floor_id,
            coordinates: manifest.coordinates,
            meshes,
            frames: vec![],
            objects: objects.into_values().collect(),
            surfaces: surfaces.into_values().collect(),
        };
        if capture.meshes.is_empty() && capture.objects.is_empty() && capture.surfaces.is_empty() {
            return Err(StreamError::Invalid("No connected, confident depth surface was captured. Scan closer to surfaces with adequate lighting and try again.".into()));
        }
        let mut scene =
            scene::process(&capture, ProcessingOptions::default()).map_err(StreamError::Invalid)?;
        scene.warnings.push(if alignment.optimized {
            "Measured depth geometry and observed labels use loop-optimized camera poses. Live AR navigation needs localization against this corrected map. RGB texturing and automatic floor/object recognition are not implemented.".into()
        } else if alignment.constraints.iter().any(|constraint| constraint.accepted) {
            "A verified loop was already aligned; geometry retains the original ARKit poses. RGB texturing and automatic floor/object recognition are not implemented.".into()
        } else {
            "No observable, verified loop closure was accepted; geometry uses the original ARKit poses. RGB texturing and automatic floor/object recognition are not implemented.".into()
        });
        let mut value = serde_json::to_value(&capture).map_err(invalid_json)?;
        value["metadata"] = json!({
            "source_stream_id": manifest.id, "source_frame_count": count,
            "reconstruction_method": "depth_triangle_fusion_v1",
            "coordinate_frame": "original_arkit_session", "alignment_refined": alignment.optimized,
            "alignment_optimized": alignment.optimized,
            "alignment_keyframe_count": key_count, "correction_interpolation": "rigid_by_timestamp",
            "weld_meters": WELD_METERS,
        });
        let result = StreamResult {
            capture: value,
            scene,
            alignment,
        };
        // Count serialized bytes without allocating a second result-sized buffer. Native clients
        // receive a complete compact source plus scene, never a truncated mesh or partial JSON.
        let mut counter = BoundedWriter { count: 0 };
        if let Err(error) = serde_json::to_writer(&mut counter, &result) {
            if counter.count > MAX_RESULT_BYTES {
                return Err(StreamError::ResultTooLarge);
            }
            return Err(invalid_json(error));
        }
        Ok(result)
    }
}

struct BoundedWriter {
    count: usize,
}
impl Write for BoundedWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.count = self.count.saturating_add(bytes.len());
        if self.count > MAX_RESULT_BYTES {
            Err(std::io::Error::other("stream result exceeds 64 MiB"))
        } else {
            Ok(bytes.len())
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn empty_record(manifest: StreamManifest, original: Value) -> Record {
    Record {
        manifest,
        original,
        count: 0,
        bytes: 0,
        last_timestamp: None,
        frames: HashSet::new(),
        surfaces: HashSet::new(),
        objects: HashSet::new(),
        finished: false,
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

fn read_value(path: &Path, max: usize) -> Result<Value, StreamError> {
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
    serde_json::from_slice(&bytes).map_err(invalid_json)
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

#[derive(Default)]
struct TriangleFusion {
    vertices: Vec<Vec3>,
    triangles: Vec<[usize; 3]>,
    voxels: HashMap<[i64; 3], usize>,
    faces: HashSet<[usize; 3]>,
}

impl TriangleFusion {
    fn integrate(&mut self, frame: &DepthFrame) -> Result<(), StreamError> {
        let width = frame.depth.width;
        let height = frame.depth.height;
        if width < 2 || height < 2 {
            return Ok(());
        }
        let valid = |index: usize| {
            let depth = frame.depth.values_m[index]?;
            let confidence = frame.depth.confidence.as_ref()?[index];
            (confidence >= 1 && (0.15..=8.0).contains(&depth)).then_some(depth)
        };
        for row in 0..height - 1 {
            for col in 0..width - 1 {
                let tl = row * width + col;
                // Clockwise in image space faces towards the camera after y-up conversion.
                for pixels in [
                    [tl, tl + width, tl + 1],
                    [tl + 1, tl + width, tl + width + 1],
                ] {
                    let Some(depths) = pixels.map(valid).into_iter().collect::<Option<Vec<_>>>()
                    else {
                        continue;
                    };
                    let nearest = depths.iter().copied().fold(f64::INFINITY, f64::min);
                    let farthest = depths.iter().copied().fold(0.0, f64::max);
                    // Do not bridge foreground/background silhouettes or missing samples.
                    if farthest - nearest > (nearest * 0.05).max(0.05) {
                        continue;
                    }
                    let positions =
                        std::array::from_fn(|i| frame.point_in_map(pixels[i], depths[i]));
                    self.add_triangle(positions)?;
                }
            }
        }
        Ok(())
    }

    fn add_triangle(&mut self, positions: [Vec3; 3]) -> Result<(), StreamError> {
        let keys = positions.map(|p| p.map(|v| (v / WELD_METERS).round() as i64));
        if keys[0] == keys[1] || keys[0] == keys[2] || keys[1] == keys[2] {
            return Ok(());
        }
        let a = std::array::from_fn::<_, 3, _>(|i| positions[1][i] - positions[0][i]);
        let b = std::array::from_fn::<_, 3, _>(|i| positions[2][i] - positions[0][i]);
        let cross = [
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        ];
        if cross.iter().map(|v| v * v).sum::<f64>() < 1e-12 {
            return Ok(());
        }
        // Very coarse angular samples should not fill broad regions between observations.
        if positions.iter().enumerate().any(|(i, p)| {
            let q = positions[(i + 1) % 3];
            p.iter().zip(q).map(|(p, q)| (p - q) * (p - q)).sum::<f64>() > 0.25
        }) {
            return Ok(());
        }
        let new_vertices = keys
            .iter()
            .filter(|key| !self.voxels.contains_key(*key))
            .count();
        if self.vertices.len() + new_vertices > MAX_VERTICES {
            return Err(StreamError::Limit("This scan exceeds the reconstruction vertex limit. A larger-scene reconstruction pipeline is required.".into()));
        }
        let mut triangle = [0usize; 3];
        for i in 0..3 {
            triangle[i] = *self.voxels.entry(keys[i]).or_insert_with(|| {
                let index = self.vertices.len();
                self.vertices.push(positions[i]);
                index
            });
        }
        let mut canonical = triangle;
        canonical.sort_unstable();
        if self.faces.contains(&canonical) {
            return Ok(());
        }
        if self.triangles.len() >= MAX_TRIANGLES {
            return Err(StreamError::Limit("This scan exceeds the reconstruction triangle limit. A larger-scene reconstruction pipeline is required.".into()));
        }
        self.faces.insert(canonical);
        self.triangles.push(triangle);
        Ok(())
    }
}
