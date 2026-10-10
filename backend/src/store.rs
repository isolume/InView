use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::Arc,
};

use sha2::{Digest, Sha256};

use serde::Serialize;
use serde_json::Value;
use tokio::sync::RwLock;

use crate::{
    capture::ScanBundle,
    geometry::Transform,
    graph::{Graph, GraphSummary},
    scan_package,
};

/// Process-local storage. Keep database decisions out of the HTTP and routing code.
#[derive(Clone, Default)]
pub struct GraphStore {
    graphs: Arc<RwLock<BTreeMap<String, Arc<Graph>>>>,
}

pub struct StoredScan {
    pub original: Value,
    pub bundle: ScanBundle,
    /// Raw RoomPlan, LiDAR, color, and relocalization assets from a scan package.
    /// The current store is process-local, so these remain immutable in memory with the scan.
    pub package_assets: Option<BTreeMap<String, Vec<u8>>>,
    /// Parsed package inventory. Workers use it to select calibrated RGB/depth observations.
    pub package_manifest: Option<Value>,
}

#[derive(Clone, Default)]
pub struct ScanStore {
    scans: Arc<RwLock<BTreeMap<String, Arc<StoredScan>>>>,
    /// Regenerable worker output (floor maps, sign candidates, door checks), keyed by scan ID.
    /// Unlike source captures these may be replaced when processing is rerun.
    analyses: Arc<RwLock<BTreeMap<String, Arc<Value>>>>,
    directory: Option<Arc<PathBuf>>,
}

#[derive(Debug)]
pub enum ScanInsertError {
    Exists,
    Storage(io::Error),
}

#[derive(Serialize)]
pub struct ScanSummary {
    pub id: String,
    pub map_id: String,
    pub floor_id: String,
    pub mesh_count: usize,
    pub frame_count: usize,
    pub object_count: usize,
    pub surface_count: usize,
}

impl StoredScan {
    pub fn summary(&self) -> ScanSummary {
        let scan = &self.bundle;
        ScanSummary {
            id: scan.id.clone(),
            map_id: scan.map_id.clone(),
            floor_id: scan.floor_id.clone(),
            mesh_count: scan.meshes.len(),
            frame_count: scan.frames.len(),
            object_count: scan.objects.len(),
            surface_count: scan.surfaces.len(),
        }
    }
}

/// One camera pose in the shared scan frame, for building-map evidence and previews.
pub struct TrackPoint {
    pub timestamp_seconds: f64,
    /// iPhone wall clock from the capture's location context, when it was recorded.
    pub unix_seconds: Option<f64>,
    pub map_from_camera: Transform,
}

impl StoredScan {
    /// Prefer the package manifest: the iPhone writes it from the complete raw capture, while
    /// `capture.json` may omit portable frames to stay within the JSON upload limit.
    pub fn camera_track(&self) -> Vec<TrackPoint> {
        let manifest = self
            .package_manifest
            .as_ref()
            .and_then(|m| scan_package::parse_manifest(m).ok());
        let from_manifest: Vec<TrackPoint> = manifest
            .map(|m| {
                m.observations
                    .into_iter()
                    .filter_map(|o| {
                        let pose = o.map_from_camera.or_else(|| {
                            self.bundle
                                .frames
                                .iter()
                                .find(|f| f.id == o.id)
                                .map(|f| f.map_from_camera)
                        })?;
                        let timestamp = o.timestamp_seconds.or_else(|| {
                            self.bundle
                                .frames
                                .iter()
                                .find(|f| f.id == o.id)
                                .map(|f| f.timestamp_seconds)
                        })?;
                        Some(TrackPoint {
                            timestamp_seconds: timestamp,
                            unix_seconds: o
                                .raw_depth
                                .and_then(|d| d.environment)
                                .and_then(|e| e.recorded_at_unix_seconds)
                                .filter(|t| t.is_finite() && *t > 0.),
                            map_from_camera: pose,
                        })
                    })
                    .filter(|p| {
                        p.timestamp_seconds.is_finite() && p.map_from_camera.validate().is_ok()
                    })
                    .collect()
            })
            .unwrap_or_default();
        if !from_manifest.is_empty() {
            return from_manifest;
        }
        self.bundle
            .frames
            .iter()
            .map(|f| TrackPoint {
                timestamp_seconds: f.timestamp_seconds,
                unix_seconds: None,
                map_from_camera: f.map_from_camera,
            })
            .collect()
    }
}

impl ScanStore {
    /// Load immutable captures on startup; corrupt or mismatched files fail startup rather than
    /// quietly hiding captures already referenced by persistent building maps.
    pub fn open(directory: impl AsRef<Path>) -> io::Result<Self> {
        let directory = directory.as_ref().to_path_buf();
        fs::create_dir_all(&directory)?;
        let mut scans = BTreeMap::new();
        for entry in fs::read_dir(&directory)? {
            let entry = entry?;
            let path = entry.path();
            if !entry.file_type()?.is_file() {
                continue;
            }
            let extension = path.extension().and_then(|v| v.to_str());
            if !matches!(extension, Some("json" | "tar")) {
                continue;
            }
            let size = entry.metadata()?.len();
            if size > scan_package::MAX_PACKAGE_BYTES as u64 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Persisted scan exceeds upload limit",
                ));
            }
            let bytes = fs::read(&path)?;
            let scan = if extension == Some("tar") {
                let package = scan_package::decode(&bytes).map_err(invalid_scan)?;
                StoredScan {
                    original: package.original,
                    bundle: package.bundle,
                    package_assets: Some(package.assets),
                    package_manifest: package.manifest,
                }
            } else {
                let original: Value = serde_json::from_slice(&bytes).map_err(invalid_scan)?;
                let bundle: ScanBundle =
                    serde_json::from_value(original.clone()).map_err(invalid_scan)?;
                bundle.validate().map_err(invalid_scan)?;
                StoredScan {
                    original,
                    bundle,
                    package_assets: None,
                    package_manifest: None,
                }
            };
            if path.file_stem().and_then(|v| v.to_str())
                != Some(scan_filename(&scan.bundle.id).as_str())
                || scans
                    .insert(scan.bundle.id.clone(), Arc::new(scan))
                    .is_some()
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Persisted scan identity mismatch or duplicate",
                ));
            }
        }
        let analyses = load_analyses(&directory.join("analysis"))?;
        Ok(Self {
            scans: Arc::new(RwLock::new(scans)),
            analyses: Arc::new(RwLock::new(analyses)),
            directory: Some(Arc::new(directory)),
        })
    }

    /// Captures are immutable. If configured, persist the exact original JSON or TAR archive
    /// before publishing to memory, so a failed disk write never acknowledges an upload.
    pub async fn insert(
        &self,
        scan: StoredScan,
        archive: Option<Vec<u8>>,
    ) -> Result<(), ScanInsertError> {
        let mut scans = self.scans.write().await;
        if scans.contains_key(&scan.bundle.id) {
            return Err(ScanInsertError::Exists);
        }
        if let Some(directory) = &self.directory {
            let id = scan.bundle.id.clone();
            let bytes = match archive {
                Some(bytes) => bytes,
                None => serde_json::to_vec(&scan.original)
                    .map_err(|error| ScanInsertError::Storage(invalid_scan(error)))?,
            };
            let extension = if scan.package_assets.is_some() {
                "tar"
            } else {
                "json"
            };
            let path = directory.join(format!("{}.{}", scan_filename(&id), extension));
            let directory = directory.clone();
            tokio::task::spawn_blocking(move || persist_immutable(&directory, &path, &bytes))
                .await
                .map_err(|error| ScanInsertError::Storage(io::Error::other(error)))?
                .map_err(ScanInsertError::Storage)?;
        }
        scans.insert(scan.bundle.id.clone(), Arc::new(scan));
        Ok(())
    }

    pub async fn get(&self, id: &str) -> Option<Arc<StoredScan>> {
        self.scans.read().await.get(id).cloned()
    }

    pub async fn analysis(&self, id: &str) -> Option<Arc<Value>> {
        self.analyses.read().await.get(id).cloned()
    }

    /// Replaces the derived analysis for a scan, persisting it first when a directory is set.
    pub async fn put_analysis(&self, id: &str, analysis: Value) -> io::Result<()> {
        let mut analyses = self.analyses.write().await;
        if let Some(directory) = &self.directory {
            let directory = directory.join("analysis");
            let path = directory.join(format!("{}.json", scan_filename(id)));
            let bytes = serde_json::to_vec(&analysis).map_err(invalid_scan)?;
            tokio::task::spawn_blocking(move || persist_replaceable(&directory, &path, &bytes))
                .await
                .map_err(io::Error::other)??;
        }
        analyses.insert(id.to_owned(), Arc::new(analysis));
        Ok(())
    }

    pub async fn list(&self) -> Vec<ScanSummary> {
        self.scans
            .read()
            .await
            .values()
            .map(|scan| scan.summary())
            .collect()
    }
}

fn invalid_scan(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}

// Hex filenames avoid path traversal even if a valid capture ID includes slashes or Unicode.
fn scan_filename(id: &str) -> String {
    format!("{:x}", Sha256::digest(id.as_bytes()))
}

fn load_analyses(directory: &Path) -> io::Result<BTreeMap<String, Arc<Value>>> {
    let mut analyses = BTreeMap::new();
    if !directory.is_dir() {
        return Ok(analyses);
    }
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        if path.extension().and_then(|v| v.to_str()) != Some("json") {
            continue;
        }
        // Derived output can always be regenerated; never block startup on it.
        let parsed = fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
        match parsed.and_then(|v| Some((v.get("scan_id")?.as_str()?.to_owned(), v))) {
            Some((id, value)) => {
                analyses.insert(id, Arc::new(value));
            }
            None => tracing::warn!(path = %path.display(), "Ignoring unreadable scan analysis"),
        }
    }
    Ok(analyses)
}

fn persist_replaceable(directory: &Path, path: &Path, bytes: &[u8]) -> io::Result<()> {
    fs::create_dir_all(directory)?;
    let temp = directory.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        output.write_all(bytes)?;
        output.sync_all()?;
        fs::rename(&temp, path)?;
        fs::File::open(directory)?.sync_all()
    })();
    let _ = fs::remove_file(&temp);
    result
}

fn persist_immutable(directory: &Path, path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temp = directory.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        output.write_all(bytes)?;
        output.sync_all()?;
        // Unlike rename, a hard link fails if another process already persisted this ID.
        fs::hard_link(&temp, path)?;
        fs::File::open(directory)?.sync_all()?;
        Ok(())
    })();
    let _ = fs::remove_file(&temp);
    result
}

impl GraphStore {
    pub async fn get(&self, id: &str) -> Option<Arc<Graph>> {
        self.graphs.read().await.get(id).cloned()
    }

    pub async fn put(&self, graph: Graph) {
        self.graphs
            .write()
            .await
            .insert(graph.id.clone(), Arc::new(graph));
    }

    pub async fn list(&self) -> Vec<GraphSummary> {
        self.graphs
            .read()
            .await
            .values()
            .map(|graph| graph.summary())
            .collect()
    }
}
