use std::{
    collections::BTreeMap,
    io::{Cursor, Read},
    path::Component,
};

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
    pub assets: BTreeMap<String, Vec<u8>>,
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

    Ok(ScanPackage {
        original,
        bundle,
        assets,
    })
}
