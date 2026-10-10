use std::{collections::BTreeMap, sync::Arc};

use serde::Serialize;
use serde_json::Value;
use tokio::sync::RwLock;

use crate::{
    capture::ScanBundle,
    graph::{Graph, GraphSummary},
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

impl ScanStore {
    /// Captures are immutable. Corrections or a new capture receive a new scan id.
    pub async fn insert(&self, scan: StoredScan) -> Result<(), ()> {
        let mut scans = self.scans.write().await;
        if scans.contains_key(&scan.bundle.id) {
            return Err(());
        }
        scans.insert(scan.bundle.id.clone(), Arc::new(scan));
        Ok(())
    }

    pub async fn get(&self, id: &str) -> Option<Arc<StoredScan>> {
        self.scans.read().await.get(id).cloned()
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
