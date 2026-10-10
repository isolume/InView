use std::{
    collections::{BTreeMap, HashSet},
    io::{Cursor, Read},
    path::Component,
};

use serde::Deserialize;
use serde_json::Value;
use tar::Archive;

use crate::{capture::ScanBundle, geometry::Transform};

/// A full RoomPlan walk keeps up to 48 depth observations (up to 5 files each: raw, confidence,
/// smoothed depth, colour keyframe, OCR still) plus 4 files per ARKit mesh anchor, so the entry
/// limit must cover hundreds of anchors.
const MAX_FILES: usize = 4096;
const MAX_FILE_BYTES: u64 = 64 * 1024 * 1024;
/// Upper bound for one uncompressed `.inviewscan.tar` upload or persisted package.
pub const MAX_PACKAGE_BYTES: usize = 256 * 1024 * 1024;

/// Immutable binary sidecars carried with a capture. Paths are relative to the scan ID,
/// never extracted onto the server filesystem.
pub struct ScanPackage {
    pub original: Value,
    pub bundle: ScanBundle,
    /// Versioned inventory used by VLM/OCR and reconstruction workers to locate sidecars.
    pub manifest: Option<Value>,
    pub assets: BTreeMap<String, Vec<u8>>,
}

#[derive(Deserialize)]
pub(crate) struct PackageManifest {
    schema_version: u32,
    capture_id: String,
    map_id: String,
    floor_id: String,
    coordinate_frame: CoordinateFrame,
    assets: Vec<ManifestAsset>,
    #[serde(default)]
    pub observations: Vec<ManifestObservation>,
    #[serde(default)]
    pub mesh_anchors: Vec<ManifestMeshAnchor>,
}

#[derive(Deserialize)]
struct CoordinateFrame {
    units: String,
    up_axis: String,
    handedness: String,
    name: String,
}
#[derive(Deserialize)]
struct ManifestAsset {
    path: String,
    role: String,
    media_type: String,
    bytes: usize,
}
/// One calibrated depth/RGB observation. The iPhone writes these from the full raw capture,
/// so they remain usable when `capture.json` omits its portable frames for size.
#[derive(Deserialize)]
pub(crate) struct ManifestObservation {
    pub id: String,
    #[serde(default)]
    pub timestamp_seconds: Option<f64>,
    pub rgb_asset: Option<String>,
    #[serde(default)]
    pub map_from_camera: Option<Transform>,
    #[serde(default)]
    pub image: Option<ManifestImage>,
    pub raw_depth: Option<ManifestDepth>,
    /// High-resolution upright still for OCR (`<frame-id>.ocr.jpg`), sharing this observation's
    /// pose, intrinsics, and depth. Optional and additive.
    #[serde(default)]
    pub ocr_asset: Option<String>,
    #[serde(default)]
    pub ocr_image: Option<ManifestOcrImage>,
}
/// Pixel size of an OCR still: the sensor image rotated 90° clockwise and uniformly scaled.
#[derive(Clone, Copy, Deserialize)]
pub(crate) struct ManifestOcrImage {
    pub width: usize,
    pub height: usize,
}
#[derive(Clone, Copy, Deserialize)]
pub(crate) struct ManifestImage {
    pub width: usize,
    pub height: usize,
    pub fx: f64,
    pub fy: f64,
    pub cx: f64,
    pub cy: f64,
}
#[derive(Deserialize)]
pub(crate) struct ManifestDepth {
    pub raw_asset: String,
    pub confidence_asset: Option<String>,
    pub smoothed_asset: Option<String>,
    pub width: usize,
    pub height: usize,
    pub bytes_per_row: usize,
    pub pixel_format: u32,
    pub confidence_bytes_per_row: Option<usize>,
    pub smoothed_width: Option<usize>,
    pub smoothed_height: Option<usize>,
    pub smoothed_bytes_per_row: Option<usize>,
    pub smoothed_pixel_format: Option<u32>,
    #[serde(default)]
    pub environment: Option<EnvironmentSample>,
}
/// Coarse GPS/heading/barometer context. ARKit remains the only room-precision frame.
#[derive(Clone, Copy, Deserialize)]
pub(crate) struct EnvironmentSample {
    pub recorded_at_unix_seconds: Option<f64>,
}
#[derive(Deserialize)]
pub(crate) struct ManifestMeshAnchor {
    pub id: String,
    pub map_from_anchor: Transform,
    pub vertices_asset: String,
    pub faces_asset: String,
    pub normals_asset: String,
    pub classification_asset: Option<String>,
    pub vertex_offset: usize,
    pub vertex_stride: usize,
    pub vertex_count: usize,
    pub bytes_per_index: usize,
    pub face_count: usize,
    pub indices_per_face: usize,
}

impl ManifestImage {
    fn valid(&self) -> bool {
        (1..=16_384).contains(&self.width)
            && (1..=16_384).contains(&self.height)
            && [self.fx, self.fy, self.cx, self.cy]
                .iter()
                .all(|v| v.is_finite())
            && self.fx > 0.
            && self.fy > 0.
    }
}

pub(crate) fn parse_manifest(value: &Value) -> Result<PackageManifest, String> {
    serde_json::from_value(value.clone())
        .map_err(|error| format!("package-manifest.json has an invalid shape: {error}"))
}

pub fn decode(bytes: &[u8]) -> Result<ScanPackage, String> {
    let mut archive = Archive::new(Cursor::new(bytes));
    let mut root: Option<String> = None;
    let mut assets = BTreeMap::new();

    for entry in archive
        .entries()
        .map_err(|error| format!("Invalid scan archive: {error}"))?
    {
        let mut entry = entry.map_err(|error| format!("Invalid scan archive entry: {error}"))?;
        if !entry.header().entry_type().is_file() {
            return Err("A scan archive may only contain regular files.".into());
        }
        let size = entry.size();
        if size > MAX_FILE_BYTES {
            return Err("A scan archive contains a file that is too large.".into());
        }
        let path = entry
            .path()
            .map_err(|error| format!("Invalid scan archive path: {error}"))?;
        let components: Vec<_> = path.components().collect();
        let [Component::Normal(package_id), Component::Normal(filename)] = components.as_slice()
        else {
            return Err("Archive files must use <scan-id>/<filename> paths.".into());
        };
        let package_id = package_id
            .to_str()
            .ok_or("Archive paths must be valid UTF-8.")?
            .to_owned();
        let filename = filename
            .to_str()
            .ok_or("Archive paths must be valid UTF-8.")?
            .to_owned();
        if filename.is_empty() || filename == "." || filename == ".." {
            return Err("Archive filenames are invalid.".into());
        }
        match &root {
            Some(expected) if expected != &package_id => {
                return Err("All archive files must share one scan-id directory.".into());
            }
            None => root = Some(package_id),
            _ => {}
        }
        if assets.len() >= MAX_FILES || assets.contains_key(&filename) {
            return Err(
                "Archive files must have unique names and stay within the file limit.".into(),
            );
        }
        let mut contents = Vec::with_capacity(size as usize);
        entry
            .read_to_end(&mut contents)
            .map_err(|error| format!("Could not read scan archive entry: {error}"))?;
        assets.insert(filename, contents);
    }

    let root = root.ok_or("A scan archive cannot be empty.")?;
    let capture = assets
        .get("capture.json")
        .ok_or("A scan archive needs capture.json.")?;
    let original: Value = serde_json::from_slice(capture)
        .map_err(|error| format!("capture.json is invalid: {error}"))?;
    let bundle: ScanBundle = serde_json::from_value(original.clone())
        .map_err(|error| format!("capture.json is invalid: {error}"))?;
    bundle.validate()?;
    if bundle.id != root {
        return Err("The archive directory must match capture.json id.".into());
    }
    let manifest = assets
        .get("package-manifest.json")
        .map(|bytes| {
            serde_json::from_slice::<Value>(bytes)
                .map_err(|error| format!("package-manifest.json is invalid: {error}"))
        })
        .transpose()?;
    if let Some(manifest) = &manifest {
        validate_manifest(manifest, &bundle, &assets)?;
    }

    Ok(ScanPackage {
        original,
        bundle,
        manifest,
        assets,
    })
}

fn validate_manifest(
    value: &Value,
    bundle: &ScanBundle,
    files: &BTreeMap<String, Vec<u8>>,
) -> Result<(), String> {
    let manifest = parse_manifest(value)?;
    if manifest.schema_version != 1
        || manifest.capture_id != bundle.id
        || manifest.map_id != bundle.map_id
        || manifest.floor_id != bundle.floor_id
    {
        return Err("package-manifest.json does not identify the embedded capture.".into());
    }
    if manifest.coordinate_frame.units != bundle.coordinates.units
        || manifest.coordinate_frame.up_axis != bundle.coordinates.up_axis
        || manifest.coordinate_frame.handedness != bundle.coordinates.handedness
        || manifest.coordinate_frame.name != "shared_arkit_session"
    {
        return Err("package-manifest.json does not use the capture coordinate frame.".into());
    }
    if manifest.assets.is_empty()
        || !manifest
            .assets
            .iter()
            .any(|asset| asset.path == "capture.json" && asset.role == "portable_capture")
    {
        return Err("package-manifest.json must index capture.json.".into());
    }
    for asset in &manifest.assets {
        let bytes = files
            .get(&asset.path)
            .ok_or("package-manifest.json refers to a missing asset.")?;
        if bytes.len() != asset.bytes
            || asset.path.contains('/')
            || asset.path.is_empty()
            || asset.role.is_empty()
            || asset.media_type.is_empty()
        {
            return Err("package-manifest.json contains an invalid asset record.".into());
        }
    }
    let mut observation_ids = HashSet::new();
    for observation in &manifest.observations {
        if !observation_ids.insert(observation.id.as_str()) {
            return Err("package-manifest.json repeats a depth observation.".into());
        }
        let portable = bundle.frames.iter().any(|frame| frame.id == observation.id);
        let calibrated = observation
            .map_from_camera
            .is_some_and(|pose| pose.validate().is_ok())
            && observation.image.is_some_and(|image| image.valid());
        // Large walks may omit portable frames from capture.json; the manifest then carries the pose.
        if !(portable || calibrated && observation.raw_depth.is_some()) {
            return Err("package-manifest.json refers to an unknown depth frame.".into());
        }
        if let Some(rgb) = &observation.rgb_asset
            && !files.contains_key(rgb)
        {
            return Err("package-manifest.json refers to a missing RGB keyframe.".into());
        }
        if let Some(ocr) = &observation.ocr_asset
            && !files.contains_key(ocr)
        {
            return Err("package-manifest.json refers to a missing OCR still.".into());
        }
        if let Some(size) = observation.ocr_image
            && !((1..=16_384).contains(&size.width) && (1..=16_384).contains(&size.height))
        {
            return Err("package-manifest.json contains an invalid OCR still size.".into());
        }
        if let Some(depth) = &observation.raw_depth {
            for asset in [
                Some(&depth.raw_asset),
                depth.confidence_asset.as_ref(),
                depth.smoothed_asset.as_ref(),
            ]
            .into_iter()
            .flatten()
            {
                if !files.contains_key(asset) {
                    return Err("package-manifest.json refers to a missing depth sidecar.".into());
                }
            }
        }
    }
    for mesh in &manifest.mesh_anchors {
        if mesh.id.is_empty() || mesh.map_from_anchor.validate().is_err() {
            return Err("package-manifest.json contains an invalid mesh anchor.".into());
        }
        for asset in [
            Some(&mesh.vertices_asset),
            Some(&mesh.faces_asset),
            Some(&mesh.normals_asset),
            mesh.classification_asset.as_ref(),
        ]
        .into_iter()
        .flatten()
        {
            if !files.contains_key(asset) {
                return Err("package-manifest.json refers to a missing mesh sidecar.".into());
            }
        }
    }
    Ok(())
}
