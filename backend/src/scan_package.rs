use std::{
    collections::BTreeMap,
    io::{Cursor, Read},
    path::Component,
};

use serde::Deserialize;
use serde_json::Value;
use tar::Archive;

use crate::capture::ScanBundle;

const MAX_FILES: usize = 256;
const MAX_FILE_BYTES: u64 = 32 * 1024 * 1024;

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
struct PackageManifest {
    schema_version: u32,
    capture_id: String,
    map_id: String,
    floor_id: String,
    coordinate_frame: CoordinateFrame,
    assets: Vec<ManifestAsset>,
    #[serde(default)]
    observations: Vec<ManifestObservation>,
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
#[derive(Deserialize)]
struct ManifestObservation {
    id: String,
    rgb_asset: Option<String>,
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
    let manifest: PackageManifest = serde_json::from_value(value.clone())
        .map_err(|error| format!("package-manifest.json has an invalid shape: {error}"))?;
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
    for observation in &manifest.observations {
        if !bundle.frames.iter().any(|frame| frame.id == observation.id) {
            return Err("package-manifest.json refers to an unknown depth frame.".into());
        }
        if let Some(rgb) = &observation.rgb_asset
            && !files.contains_key(rgb)
        {
            return Err("package-manifest.json refers to a missing RGB keyframe.".into());
        }
    }
    Ok(())
}
