//! Composes per-scan navigation graphs and analysis products into one building-frame model with
//! floors, cross-scan seams and vertical connectors.
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{
    ConnectorInfo, EdgeKind, GeoReference, NavEdge, NavModel, NavNode, Poi, PoiKind, Vec3,
    horizontal_distance, levels,
};
use crate::{
    geometry::Transform,
    graph::{Availability, ConnectorKind, Graph, Segment},
};

/// Nodes from two scans this close on one level are joined (the scans overlap there).
pub const SEAM_MAX_M: f64 = 0.75;
/// A connector place/hazard attaches to a graph node on its own level within this distance.
pub const ATTACH_MAX_M: f64 = 3.0;
/// Connector candidates on different levels pair up within these horizontal distances.
pub const ELEVATOR_PAIR_M: f64 = 2.5;
pub const STAIRS_PAIR_M: f64 = 4.0;

/// One scan's contribution: its graph, analysis and transform into the building frame.
pub struct ScanLayer {
    pub scan_id: String,
    pub transform: Transform,
    pub graph: Arc<Graph>,
    pub analysis: Option<Arc<Value>>,
}

/// A volunteer-registered connector between two building-frame points.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ManualConnector {
    pub id: String,
    pub kind: ConnectorKind,
    pub from_m: Vec3,
    pub to_m: Vec3,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub estimated_seconds: Option<f64>,
}

impl ManualConnector {
    pub fn validate(&self) -> Result<(), String> {
        let valid_id = !self.id.is_empty()
            && self.id.len() <= 64
            && self
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
        if !valid_id {
            return Err("Connector ids use 1–64 letters, digits, '-' or '_'.".into());
        }
        if !self
            .from_m
            .iter()
            .chain(&self.to_m)
            .all(|v| v.is_finite() && v.abs() < 100_000.0)
        {
            return Err("Connector endpoints must be finite building-frame meters.".into());
        }
        if self
            .estimated_seconds
            .is_some_and(|s| !s.is_finite() || !(0.0..=3600.0).contains(&s))
        {
            return Err("estimated_seconds must be within 0–3600.".into());
        }
        if self.name.as_ref().is_some_and(|n| n.len() > 120) {
            return Err("Connector names are at most 120 characters.".into());
        }
        Ok(())
    }
}

fn vec3(value: Option<&Value>) -> Option<Vec3> {
    let items = value?.as_array()?;
    if items.len() < 3 {
        return None;
    }
    let point = [items[0].as_f64()?, items[1].as_f64()?, items[2].as_f64()?];
    point.iter().all(|v| v.is_finite()).then_some(point)
}

fn text(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .filter(|s| !s.trim().is_empty())
}

fn list<'a>(analysis: Option<&'a Value>, key: &str) -> impl Iterator<Item = &'a Value> {
    analysis
        .and_then(|a| a.get(key))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|v| v.is_object())
}

pub fn compose(layers: &[ScanLayer], manual: &[ManualConnector]) -> NavModel {
    let mut model = NavModel::default();
    let mut door_nodes: Vec<(usize, Poi)> = Vec::new();

    for (layer_index, layer) in layers.iter().enumerate() {
        let t = layer.transform;
        let meta = &layer.graph.metadata;
        let kinds = meta.get("node_kinds");
        let mut local = BTreeMap::new();
        for node in &layer.graph.nodes {
            let index = model.nodes.len();
            local.insert(node.id.clone(), index);
            let id = format!("{}:{}", layer.scan_id, node.id);
            model.node_index.insert(id.clone(), index);
            model.nodes.push(NavNode {
                id,
                scan_id: layer.scan_id.clone(),
                position: t.point([node.x, node.y, node.z]),
                level: 0,
                kind: kinds
                    .and_then(|k| k.get(&node.id))
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                label: node.label.clone(),
            });
        }
        let details = meta.get("edges");
        for edge in &layer.graph.edges {
            let (Some(&from), Some(&to)) = (local.get(&edge.from), local.get(&edge.to)) else {
                continue;
            };
            // The worker emits each connection as `<base>f` / `<base>r` sharing `metadata.edges[base]`.
            let base_id = edge.id.strip_suffix(['f', 'r']).unwrap_or(&edge.id);
            let hazards = details
                .and_then(|d| d.get(base_id))
                .and_then(|d| d.get("hazards"))
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|h| h.as_str().map(str::to_owned).or_else(|| text(h, "id")))
                        .collect()
                })
                .unwrap_or_default();
            let (points, kind, seconds, connector) = match &edge.segment {
                Segment::Surface { path_points, .. } => (
                    path_points
                        .iter()
                        .map(|p| t.point([p.x, p.y, p.z]))
                        .collect::<Vec<_>>(),
                    EdgeKind::Surface,
                    None,
                    None,
                ),
                Segment::Transition {
                    connector_id,
                    kind,
                    estimated_seconds,
                } => (
                    vec![model.nodes[from].position, model.nodes[to].position],
                    EdgeKind::from(*kind),
                    Some(*estimated_seconds),
                    Some(ConnectorInfo {
                        id: connector_id.clone(),
                        source: "graph",
                        name: None,
                        refs: BTreeMap::new(),
                    }),
                ),
            };
            let length_m = points.windows(2).map(|w| super::distance(w[0], w[1])).sum();
            model.edges.push(NavEdge {
                id: format!("{}:{}", layer.scan_id, edge.id),
                from,
                to,
                points,
                length_m,
                kind,
                step_free: edge.step_free,
                width_m: edge.minimum_clear_width_m,
                slope: edge.maximum_slope,
                closed: edge.availability == Availability::Closed,
                seconds,
                hazards,
                connector,
            });
        }
        // Doors: the worker records which node stands for each door and its clearance verdict.
        if let Some(map) = meta.get("door_nodes").and_then(Value::as_object) {
            for (door_id, node) in map {
                let Some(&index) = node.as_str().and_then(|n| local.get(n)) else {
                    continue;
                };
                let info = meta
                    .get("doors")
                    .and_then(|d| d.get(door_id))
                    .cloned()
                    .unwrap_or(json!({}));
                let accessible = info.get("meets_clear_width").and_then(Value::as_bool);
                door_nodes.push((
                    index,
                    Poi {
                        id: door_id.clone(),
                        scan_id: layer.scan_id.clone(),
                        kind: PoiKind::Door,
                        category: "door".into(),
                        name: None,
                        position: model.nodes[index].position,
                        level: 0,
                        accessible,
                        detail: info,
                    },
                ));
            }
        }
        let analysis = layer.analysis.as_deref();
        for place in list(analysis, "places") {
            let Some(position) = vec3(place.get("position_m")) else {
                continue;
            };
            model.places.push(Poi {
                id: text(place, "id").unwrap_or_else(|| format!("place-{}", model.places.len())),
                scan_id: layer.scan_id.clone(),
                kind: PoiKind::Place,
                category: text(place, "category").unwrap_or_else(|| "unknown".into()),
                name: text(place, "name"),
                position: t.point(position),
                level: 0,
                accessible: None,
                detail: json!({"confidence": place.get("confidence"), "access_point_kind": place.get("access_point_kind")}),
            });
        }
        for (index, hazard) in list(analysis, "hazards").enumerate() {
            let Some(position) = vec3(hazard.get("position_m")) else {
                continue;
            };
            let severity = text(hazard, "severity");
            model.hazards.push(Poi {
                id: text(hazard, "id").unwrap_or_else(|| format!("hazard-{index}")),
                scan_id: layer.scan_id.clone(),
                kind: PoiKind::Hazard,
                category: text(hazard, "kind").unwrap_or_else(|| "hazard".into()),
                name: None,
                position: t.point(position),
                level: 0,
                accessible: Some(severity.as_deref() != Some("barrier")),
                detail: json!({"severity": severity, "measure": hazard.get("measure")}),
            });
        }
        for (index, sign) in list(analysis, "signs").enumerate() {
            let Some(position) = vec3(sign.get("position_m")) else {
                continue;
            };
            model.signs.push(Poi {
                id: text(sign, "id").unwrap_or_else(|| format!("sign-{index:03}")),
                scan_id: layer.scan_id.clone(),
                kind: PoiKind::Sign,
                category: text(sign, "category")
                    .or_else(|| text(sign, "kind"))
                    .unwrap_or_else(|| "sign".into()),
                name: text(sign, "text"),
                position: t.point(position),
                level: 0,
                accessible: None,
                detail: json!({"pictograms": sign.get("pictograms"), "arrows": sign.get("arrows")}),
            });
        }
        if layer_index == 0 {
            // The building frame is the reference (first) scan's frame.
            model.georef = analysis.and_then(|a| a.get("georef")).and_then(|g| {
                let r = GeoReference {
                    latitude: g.get("latitude")?.as_f64()?,
                    longitude: g.get("longitude")?.as_f64()?,
                    heading_degrees: g.get("heading_degrees")?.as_f64()?,
                };
                r.is_valid().then_some(r)
            });
        }
    }

    // Floors from node heights; every other point stands on the floor at or below it.
    let heights: Vec<f64> = model.nodes.iter().map(|n| n.position[1]).collect();
    model.levels = levels::cluster(&heights);
    for node in &mut model.nodes {
        node.level = levels::level_of(&model.levels, node.position[1]);
    }
    let levels_list = model.levels.clone();
    for poi in model
        .places
        .iter_mut()
        .chain(&mut model.hazards)
        .chain(&mut model.signs)
    {
        poi.level = levels::level_of(&levels_list, poi.position[1]);
    }
    for (index, mut door) in door_nodes {
        door.level = model.nodes[index].level;
        model.doors.insert(index, door);
    }
    // A surface edge climbing between floors inside one scan is a stair flight.
    for edge in &mut model.edges {
        if edge.kind == EdgeKind::Surface
            && model.nodes[edge.from].level != model.nodes[edge.to].level
            && edge.step_free != Some(true)
        {
            edge.kind = EdgeKind::Stairs;
            edge.step_free = Some(false);
        }
    }

    stitch_seams(&mut model);
    infer_connectors(&mut model);
    add_manual_connectors(&mut model, manual);

    model.out = vec![Vec::new(); model.nodes.len()];
    for (index, edge) in model.edges.iter().enumerate() {
        model.out[edge.from].push(index);
    }
    if model.levels.len() > 1 && !model.edges.iter().any(|e| e.kind.is_connector()) {
        model.notices.push(
            "Several floors were found but no connector links them; register elevators or stairs as building connectors."
                .into(),
        );
    }
    model
}

fn nearest_node(model: &NavModel, point: Vec3, level: usize, max_m: f64) -> Option<usize> {
    model
        .nodes
        .iter()
        .enumerate()
        .filter(|(_, n)| n.level == level)
        .map(|(i, n)| (i, super::distance(n.position, point)))
        .filter(|(_, d)| *d <= max_m)
        .min_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(i, _)| i)
}

fn push_pair(
    model: &mut NavModel,
    a: usize,
    b: usize,
    kind: EdgeKind,
    seconds: Option<f64>,
    connector: Option<ConnectorInfo>,
    id: &str,
) {
    let step_free = match kind {
        EdgeKind::Elevator | EdgeKind::Ramp => Some(true),
        EdgeKind::Stairs | EdgeKind::Escalator => Some(false),
        _ => None,
    };
    for (suffix, from, to) in [("f", a, b), ("r", b, a)] {
        let points = vec![model.nodes[from].position, model.nodes[to].position];
        let length_m = super::distance(points[0], points[1]);
        model.edges.push(NavEdge {
            id: format!("{id}{suffix}"),
            from,
            to,
            points,
            length_m,
            kind,
            step_free,
            width_m: None,
            slope: None,
            closed: false,
            seconds,
            hazards: vec![],
            connector: connector.clone(),
        });
    }
}

/// Joins overlapping scans on the same floor at their closest nodes.
fn stitch_seams(model: &mut NavModel) {
    let mut pairs = BTreeSet::new();
    for (i, a) in model.nodes.iter().enumerate() {
        let best = model
            .nodes
            .iter()
            .enumerate()
            .filter(|(_, b)| b.scan_id != a.scan_id && b.level == a.level)
            .map(|(j, b)| (j, super::distance(a.position, b.position)))
            .filter(|(_, d)| *d <= SEAM_MAX_M)
            .min_by(|x, y| x.1.total_cmp(&y.1));
        if let Some((j, _)) = best {
            pairs.insert((i.min(j), i.max(j)));
        }
    }
    for (n, (i, j)) in pairs.into_iter().enumerate() {
        push_pair(
            model,
            i,
            j,
            EdgeKind::Seam,
            None,
            None,
            &format!("seam-{n:04}"),
        );
    }
}

struct Candidate {
    kind: EdgeKind,
    node: usize,
    level: usize,
    position: Vec3,
    refs: BTreeMap<String, String>,
    name: Option<String>,
}

fn connector_seconds(kind: EdgeKind, span: usize) -> f64 {
    let span = span.max(1) as f64;
    match kind {
        EdgeKind::Elevator => 20.0 + 4.0 * span,
        EdgeKind::Escalator => 10.0 * span,
        EdgeKind::Ramp => 15.0 * span,
        _ => 12.0 * span,
    }
}

/// Pairs elevator/stairs/escalator evidence on different floors into transitions.
fn infer_connectors(model: &mut NavModel) {
    let mut candidates = Vec::new();
    let sources = model
        .places
        .iter()
        .map(|p| (p, "place_id"))
        .chain(model.hazards.iter().map(|h| (h, "hazard_id")));
    for (poi, key) in sources {
        let kind = match poi.category.as_str() {
            "elevator" => EdgeKind::Elevator,
            "stairs" => EdgeKind::Stairs,
            "escalator" => EdgeKind::Escalator,
            "ramp" => EdgeKind::Ramp,
            _ => continue,
        };
        let Some(node) = nearest_node(model, poi.position, poi.level, ATTACH_MAX_M) else {
            continue;
        };
        let mut refs = BTreeMap::new();
        refs.insert(key.to_owned(), poi.id.clone());
        refs.insert("scan_id".into(), poi.scan_id.clone());
        candidates.push(Candidate {
            kind,
            node,
            level: poi.level,
            position: poi.position,
            refs,
            name: poi.name.clone(),
        });
    }
    let mut made = BTreeSet::new();
    let mut count = 0;
    for (i, a) in candidates.iter().enumerate() {
        for b in &candidates[i + 1..] {
            if a.kind != b.kind || a.level == b.level || a.node == b.node {
                continue;
            }
            let reach = if a.kind == EdgeKind::Stairs {
                STAIRS_PAIR_M
            } else {
                ELEVATOR_PAIR_M
            };
            let span = a.level.abs_diff(b.level);
            // Stairs climb one flight at a time; elevators and escalators link any pair they serve.
            if horizontal_distance(a.position, b.position) > reach
                || (a.kind == EdgeKind::Stairs && span != 1)
            {
                continue;
            }
            if !made.insert((a.node.min(b.node), a.node.max(b.node))) {
                continue;
            }
            let mut refs = a.refs.clone();
            // Keep each evidence id under its own key; prefix only when both ends share a key.
            for (k, v) in &b.refs {
                if refs.get(k).is_some_and(|existing| existing != v) {
                    refs.insert(format!("to_{k}"), v.clone());
                } else {
                    refs.insert(k.clone(), v.clone());
                }
            }
            let id = format!("connector-{count:03}");
            count += 1;
            let info = ConnectorInfo {
                id: id.clone(),
                source: "inferred",
                name: a.name.clone().or(b.name.clone()),
                refs,
            };
            let (low, high) = if a.level < b.level {
                (a.node, b.node)
            } else {
                (b.node, a.node)
            };
            push_pair(
                model,
                low,
                high,
                a.kind,
                Some(connector_seconds(a.kind, span)),
                Some(info),
                &id,
            );
        }
    }
    if count > 0 {
        model.notices.push(format!(
            "{count} floor connector(s) were inferred from places and hazards; verify them before relying on them."
        ));
    }
}

fn add_manual_connectors(model: &mut NavModel, manual: &[ManualConnector]) {
    for connector in manual {
        let from_level = levels::level_of(&model.levels, connector.from_m[1]);
        let to_level = levels::level_of(&model.levels, connector.to_m[1]);
        let (Some(a), Some(b)) = (
            nearest_node(model, connector.from_m, from_level, 5.0),
            nearest_node(model, connector.to_m, to_level, 5.0),
        ) else {
            model.notices.push(format!(
                "Connector {} is not near the navigation graph and was skipped.",
                connector.id
            ));
            continue;
        };
        let kind = EdgeKind::from(connector.kind);
        let seconds = connector
            .estimated_seconds
            .unwrap_or_else(|| connector_seconds(kind, from_level.abs_diff(to_level)));
        let mut refs = BTreeMap::new();
        refs.insert("connector_id".into(), connector.id.clone());
        let info = ConnectorInfo {
            id: connector.id.clone(),
            source: "manual",
            name: connector.name.clone(),
            refs,
        };
        push_pair(
            model,
            a,
            b,
            kind,
            Some(seconds),
            Some(info),
            &format!("manual-{}", connector.id),
        );
    }
}
