use std::{
    cmp::Ordering,
    collections::{BinaryHeap, HashMap},
};

use serde::{Deserialize, Serialize};

use crate::graph::{Availability, ConnectorKind, Edge, Graph, Segment};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouteRequest {
    pub from: String,
    pub to: String,
    #[serde(default)]
    pub requirements: Requirements,
    #[serde(default = "default_speed")]
    pub movement_speed_mps: f64,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Requirements {
    #[serde(default)]
    pub requires_step_free: bool,
    pub minimum_clear_width_m: Option<f64>,
    pub maximum_slope: Option<f64>,
}

fn default_speed() -> f64 {
    1.0
}

impl RouteRequest {
    pub fn validate(&self) -> Result<(), String> {
        if !self.movement_speed_mps.is_finite() || self.movement_speed_mps <= 0.0 {
            return Err("movement_speed_mps must be positive and finite.".into());
        }
        if self
            .requirements
            .minimum_clear_width_m
            .is_some_and(|v| !v.is_finite() || v <= 0.0)
            || self
                .requirements
                .maximum_slope
                .is_some_and(|v| !v.is_finite() || v < 0.0)
        {
            return Err("Route requirements need valid clearance and slope values.".into());
        }
        Ok(())
    }
}

#[derive(Debug, Serialize)]
pub struct Route {
    pub graph_id: String,
    pub schema_version: u32,
    pub node_ids: Vec<String>,
    pub segments: Vec<RouteSegment>,
    /// Includes surface travel and connector estimates; not a measured arrival time.
    pub estimated_seconds: f64,
    pub requirements: Requirements,
}

#[derive(Debug, Serialize)]
pub struct RouteSegment {
    pub edge_id: String,
    pub from: String,
    pub to: String,
    pub from_map_id: String,
    pub to_map_id: String,
    pub from_floor_id: String,
    pub to_floor_id: String,
    #[serde(flatten)]
    pub geometry: Segment,
}

#[derive(Debug, PartialEq)]
pub enum RouteError {
    UnknownNode,
    NoVerifiedRoute,
    InvalidCost,
}

#[derive(PartialEq)]
struct Visit {
    cost: f64,
    node: usize,
}
impl Eq for Visit {}
impl PartialOrd for Visit {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Visit {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .cost
            .total_cmp(&self.cost)
            .then_with(|| other.node.cmp(&self.node))
    }
}

/// Search a validated snapshot. No coordinate snapping or relaxation of requirements.
pub fn find_route(graph: &Graph, request: &RouteRequest) -> Result<Route, RouteError> {
    let indices: HashMap<_, _> = graph
        .nodes
        .iter()
        .enumerate()
        .map(|(index, node)| (node.id.as_str(), index))
        .collect();
    let &start = indices
        .get(request.from.as_str())
        .ok_or(RouteError::UnknownNode)?;
    let &goal = indices
        .get(request.to.as_str())
        .ok_or(RouteError::UnknownNode)?;
    let mut adjacency = vec![Vec::new(); graph.nodes.len()];
    for (index, edge) in graph.edges.iter().enumerate() {
        if eligible(edge, &request.requirements) {
            adjacency[indices[edge.from.as_str()]].push(index);
        }
    }
    let mut distance = vec![f64::INFINITY; graph.nodes.len()];
    let mut previous = vec![None; graph.nodes.len()];
    let mut queue = BinaryHeap::new();
    let mut invalid_cost = false;
    distance[start] = 0.0;
    queue.push(Visit {
        cost: 0.0,
        node: start,
    });
    while let Some(Visit { cost, node }) = queue.pop() {
        if cost > distance[node] {
            continue;
        }
        if node == goal {
            break;
        }
        for &edge_index in &adjacency[node] {
            let edge = &graph.edges[edge_index];
            let next = indices[edge.to.as_str()];
            let candidate = cost + edge_seconds(edge, request.movement_speed_mps);
            if !candidate.is_finite() {
                invalid_cost = true;
                continue;
            }
            if candidate < distance[next] {
                distance[next] = candidate;
                previous[next] = Some((node, edge_index));
                queue.push(Visit {
                    cost: candidate,
                    node: next,
                });
            }
        }
    }
    if !distance[goal].is_finite() {
        return Err(if invalid_cost {
            RouteError::InvalidCost
        } else {
            RouteError::NoVerifiedRoute
        });
    }

    let mut edge_indices = Vec::new();
    let mut cursor = goal;
    while cursor != start {
        let (parent, edge_index) = previous[cursor].ok_or(RouteError::NoVerifiedRoute)?;
        edge_indices.push(edge_index);
        cursor = parent;
    }
    edge_indices.reverse();
    let mut node_ids = vec![request.from.clone()];
    let segments = edge_indices
        .into_iter()
        .map(|index| {
            let edge = &graph.edges[index];
            let from = &graph.nodes[indices[edge.from.as_str()]];
            let to = &graph.nodes[indices[edge.to.as_str()]];
            node_ids.push(edge.to.clone());
            RouteSegment {
                edge_id: edge.id.clone(),
                from: edge.from.clone(),
                to: edge.to.clone(),
                from_map_id: from.map_id.clone(),
                to_map_id: to.map_id.clone(),
                from_floor_id: from.floor_id.clone(),
                to_floor_id: to.floor_id.clone(),
                geometry: edge.segment.clone(),
            }
        })
        .collect();
    Ok(Route {
        graph_id: graph.id.clone(),
        schema_version: graph.schema_version,
        node_ids,
        segments,
        estimated_seconds: distance[goal],
        requirements: request.requirements.clone(),
    })
}

fn eligible(edge: &Edge, requirements: &Requirements) -> bool {
    if edge.availability != Availability::Available {
        return false;
    }
    if requirements.requires_step_free
        && (edge.step_free != Some(true)
            || matches!(
                edge.segment,
                Segment::Transition {
                    kind: ConnectorKind::Stairs | ConnectorKind::Escalator,
                    ..
                }
            ))
    {
        return false;
    }
    if let Some(minimum) = requirements.minimum_clear_width_m
        && !edge
            .minimum_clear_width_m
            .is_some_and(|width| width >= minimum)
    {
        return false;
    }
    if let Some(maximum) = requirements.maximum_slope
        && !edge.maximum_slope.is_some_and(|slope| slope <= maximum)
    {
        return false;
    }
    true
}

fn edge_seconds(edge: &Edge, speed: f64) -> f64 {
    match &edge.segment {
        Segment::Surface { .. } => edge.segment.length_m() / speed,
        Segment::Transition {
            estimated_seconds, ..
        } => *estimated_seconds,
    }
}
