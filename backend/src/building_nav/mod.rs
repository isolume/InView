//! 3D, multi-level route planning over a building (or a single scan) for map clients.
//!
//! Scans' navigation graphs (`<scan>-nav`, produced by the worker) and analysis products (places,
//! hazards, signs, doors, georef) are composed into one graph in the building frame using the
//! building's versioned alignments. Floors are clustered from node heights, vertical connectors
//! (elevators, stairs, escalators) are inferred from places/hazards or registered manually, and
//! several distinct paths are returned, each split into per-level legs with steps, the features met
//! along the way, and an honest accessibility verdict (`accessible`, `not_accessible`, `unverified`).
pub mod compose;
pub mod features;
pub mod geo;
pub mod levels;
pub mod paths;
pub mod plan;
pub mod render;

use std::collections::{BTreeMap, HashMap};

use serde::Serialize;
use serde_json::Value;

use crate::graph::ConnectorKind;

pub type Vec3 = [f64; 3];

/// 2010 ADA accessible-route screening thresholds (also in the worker's contracts).
pub const ROUTE_MIN_CLEAR_M: f64 = 0.915;
pub const RAMP_MAX_SLOPE: f64 = 1.0 / 12.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EdgeKind {
    Surface,
    /// Stitched join between two scans' graphs on one level.
    Seam,
    Elevator,
    Stairs,
    Escalator,
    /// A reviewed ramp between levels or frames: step-free, slope unverified unless measured.
    Ramp,
}

impl From<ConnectorKind> for EdgeKind {
    fn from(kind: ConnectorKind) -> Self {
        match kind {
            ConnectorKind::Elevator => Self::Elevator,
            ConnectorKind::Stairs => Self::Stairs,
            ConnectorKind::Escalator => Self::Escalator,
            ConnectorKind::Ramp => Self::Ramp,
        }
    }
}

impl EdgeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Surface => "surface",
            Self::Seam => "scan_seam",
            Self::Elevator => "elevator",
            Self::Stairs => "stairs",
            Self::Escalator => "escalator",
            Self::Ramp => "ramp",
        }
    }

    pub fn is_connector(self) -> bool {
        matches!(
            self,
            Self::Elevator | Self::Stairs | Self::Escalator | Self::Ramp
        )
    }
}

#[derive(Clone, Debug)]
pub struct NavNode {
    pub id: String,
    pub scan_id: String,
    pub position: Vec3,
    pub level: usize,
    pub kind: Option<String>,
    pub label: Option<String>,
}

#[derive(Clone, Debug)]
pub struct ConnectorInfo {
    pub id: String,
    /// `inferred` (from places/hazards), `manual`, or `graph`.
    pub source: &'static str,
    pub name: Option<String>,
    pub refs: BTreeMap<String, String>,
}

#[derive(Clone, Debug)]
pub struct NavEdge {
    pub id: String,
    pub from: usize,
    pub to: usize,
    pub points: Vec<Vec3>,
    pub length_m: f64,
    pub kind: EdgeKind,
    pub step_free: Option<bool>,
    pub width_m: Option<f64>,
    pub slope: Option<f64>,
    pub closed: bool,
    /// Connector trip time (transitions); surfaces derive time from length.
    pub seconds: Option<f64>,
    /// Hazard ids the worker found crossing this edge.
    pub hazards: Vec<String>,
    pub connector: Option<ConnectorInfo>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PoiKind {
    Place,
    Hazard,
    Sign,
    Door,
}

/// A point of interest from a scan's analysis, in the building frame.
#[derive(Clone, Debug)]
pub struct Poi {
    pub id: String,
    pub scan_id: String,
    pub kind: PoiKind,
    /// Place category, hazard kind, sign category, or `door`.
    pub category: String,
    pub name: Option<String>,
    pub position: Vec3,
    pub level: usize,
    pub accessible: Option<bool>,
    pub detail: Value,
}

#[derive(Clone, Debug, Serialize)]
pub struct Level {
    pub id: String,
    pub index: usize,
    pub name: String,
    pub elevation_m: f64,
}

/// The reference capture's geographic placement (building frame = reference scan frame).
#[derive(Clone, Copy, Debug, Serialize)]
pub struct GeoReference {
    pub latitude: f64,
    pub longitude: f64,
    pub heading_degrees: f64,
}

#[derive(Debug, Default)]
pub struct NavModel {
    pub nodes: Vec<NavNode>,
    pub edges: Vec<NavEdge>,
    /// Outgoing edge indices per node.
    pub out: Vec<Vec<usize>>,
    pub levels: Vec<Level>,
    pub places: Vec<Poi>,
    pub hazards: Vec<Poi>,
    pub signs: Vec<Poi>,
    /// Door details keyed by the node that represents the door.
    pub doors: HashMap<usize, Poi>,
    pub node_index: HashMap<String, usize>,
    pub georef: Option<GeoReference>,
    pub notices: Vec<String>,
}

impl NavModel {
    pub fn level_id(&self, level: usize) -> &str {
        self.levels
            .get(level)
            .map(|l| l.id.as_str())
            .unwrap_or("L0")
    }

    pub fn level_by_id(&self, id: &str) -> Option<usize> {
        self.levels.iter().position(|l| l.id == id)
    }
}

pub fn distance(a: Vec3, b: Vec3) -> f64 {
    ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt()
}

pub fn horizontal_distance(a: Vec3, b: Vec3) -> f64 {
    (a[0] - b[0]).hypot(a[2] - b[2])
}

pub fn round3(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}

pub fn round_point(p: Vec3) -> Vec3 {
    p.map(round3)
}
