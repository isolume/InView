use std::{collections::BTreeMap, sync::Arc};

use tokio::sync::RwLock;

use crate::graph::{Graph, GraphSummary};

/// Process-local storage. Keep database decisions out of the HTTP and routing code.
#[derive(Clone, Default)]
pub struct GraphStore {
    graphs: Arc<RwLock<BTreeMap<String, Arc<Graph>>>>,
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
