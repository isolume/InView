use std::collections::{BTreeMap, HashMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A provisional building graph. Every surface uses its own scan's meter, y-up frame.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Graph {
    pub schema_version: u32,
    pub id: String,
    pub nodes: Vec<Node>,
    pub edges: Vec<Edge>,
    #[serde(default)]
    pub metadata: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Node {
    pub id: String,
    pub map_id: String,
    pub floor_id: String,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    #[serde(default)]
    pub label: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Point3 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl Point3 {
    fn is_finite(self) -> bool {
        self.x.is_finite() && self.y.is_finite() && self.z.is_finite()
    }

    fn distance(self, other: Self) -> f64 {
        (self.x - other.x)
            .hypot(self.y - other.y)
            .hypot(self.z - other.z)
    }
}

impl Node {
    fn position(&self) -> Point3 {
        Point3 {
            x: self.x,
            y: self.y,
            z: self.z,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Edge {
    pub id: String,
    pub from: String,
    pub to: String,
    /// Missing/null means unknown, never verified step-free.
    #[serde(default)]
    pub step_free: Option<bool>,
    #[serde(default)]
    pub availability: Availability,
    #[serde(default)]
    pub minimum_clear_width_m: Option<f64>,
    /// Maximum absolute grade along the connection, expressed as rise/run.
    #[serde(default)]
    pub maximum_slope: Option<f64>,
    pub segment: Segment,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Availability {
    Available,
    Closed,
    #[default]
    Unknown,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Segment {
    Surface {
        map_id: String,
        floor_id: String,
        path_points: Vec<Point3>,
    },
    /// One complete connector trip, including any boarding/wait time once.
    Transition {
        connector_id: String,
        kind: ConnectorKind,
        estimated_seconds: f64,
    },
}

impl Segment {
    pub fn length_m(&self) -> f64 {
        match self {
            Self::Surface { path_points, .. } => path_points
                .windows(2)
                .map(|pair| pair[0].distance(pair[1]))
                .sum(),
            Self::Transition { .. } => 0.0,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectorKind {
    Elevator,
    Stairs,
    Escalator,
}

#[derive(Serialize)]
pub struct GraphSummary {
    pub id: String,
    pub schema_version: u32,
    pub node_count: usize,
    pub edge_count: usize,
}

impl Graph {
    pub fn summary(&self) -> GraphSummary {
        GraphSummary {
            id: self.id.clone(),
            schema_version: self.schema_version,
            node_count: self.nodes.len(),
            edge_count: self.edges.len(),
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != 1 {
            return Err("Only draft schema_version 1 is supported.".into());
        }
        nonempty(&self.id, "graph id")?;
        let mut nodes = HashMap::new();
        for node in &self.nodes {
            nonempty(&node.id, "node id")?;
            nonempty(&node.map_id, "map_id")?;
            nonempty(&node.floor_id, "floor_id")?;
            if !node.position().is_finite() {
                return Err(format!("Node {} has invalid coordinates.", node.id));
            }
            if nodes.insert(node.id.as_str(), node).is_some() {
                return Err(format!("Duplicate node id: {}.", node.id));
            }
        }

        let mut edge_ids = HashSet::new();
        for edge in &self.edges {
            nonempty(&edge.id, "edge id")?;
            if !edge_ids.insert(&edge.id) {
                return Err(format!("Duplicate edge id: {}.", edge.id));
            }
            let from = nodes
                .get(edge.from.as_str())
                .ok_or_else(|| format!("Edge {} references a missing start node.", edge.id))?;
            let to = nodes
                .get(edge.to.as_str())
                .ok_or_else(|| format!("Edge {} references a missing end node.", edge.id))?;
            if edge
                .minimum_clear_width_m
                .is_some_and(|v| !v.is_finite() || v <= 0.0)
                || edge
                    .maximum_slope
                    .is_some_and(|v| !v.is_finite() || v < 0.0)
            {
                return Err(format!("Edge {} has invalid measurements.", edge.id));
            }
            match &edge.segment {
                Segment::Surface {
                    map_id,
                    floor_id,
                    path_points,
                } => {
                    if from.map_id != *map_id
                        || to.map_id != *map_id
                        || from.floor_id != *floor_id
                        || to.floor_id != *floor_id
                    {
                        return Err(format!("Surface {} crosses map or floor frames.", edge.id));
                    }
                    if path_points.len() < 2
                        || path_points.iter().any(|point| !point.is_finite())
                        || !edge.segment.length_m().is_finite()
                    {
                        return Err(format!("Surface {} needs a finite 3D path.", edge.id));
                    }
                    // Draft tolerance for exported geometry; this does not verify wall clearance.
                    if path_points[0].distance(from.position()) > 0.05
                        || path_points[path_points.len() - 1].distance(to.position()) > 0.05
                    {
                        return Err(format!("Surface {} does not meet its endpoints.", edge.id));
                    }
                }
                Segment::Transition {
                    connector_id,
                    kind,
                    estimated_seconds,
                } => {
                    nonempty(connector_id, "connector_id")?;
                    if !estimated_seconds.is_finite() || *estimated_seconds < 0.0 {
                        return Err(format!(
                            "Transition {} needs a nonnegative time estimate.",
                            edge.id
                        ));
                    }
                    if matches!(kind, ConnectorKind::Stairs | ConnectorKind::Escalator)
                        && edge.step_free == Some(true)
                    {
                        return Err(format!(
                            "Transition {} cannot be marked step-free.",
                            edge.id
                        ));
                    }
                }
            }
        }
        Ok(())
    }
}

fn nonempty(value: &str, name: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        Err(format!("{name} must not be empty."))
    } else {
        Ok(())
    }
}
