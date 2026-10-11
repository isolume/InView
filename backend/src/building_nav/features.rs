//! Everything a path meets (doors, connectors, narrow passages, hazards, signs, landmarks) and the
//! route's accessibility verdict.
use std::collections::{BTreeMap, HashSet};

use serde::Serialize;
use serde_json::{Value, json};

use super::{
    EdgeKind, NavModel, Poi, PoiKind, RAMP_MAX_SLOPE, ROUTE_MIN_CLEAR_M, Vec3, levels,
    paths::{Path, Verdict, accessible_verdict},
    round_point, round3,
};

/// Hazards this close to the walked line are on the route; signs and places within the larger
/// radii are landmarks a person passes.
const HAZARD_NEAR_M: f64 = 1.0;
const SIGN_NEAR_M: f64 = 3.0;
const PLACE_NEAR_M: f64 = 2.0;
/// Running slopes above 1:20 are ramps (2010 ADA §403.3 / §405).
const RUNNING_SLOPE_MAX: f64 = 1.0 / 20.0;

#[derive(Clone, Debug, Serialize)]
pub struct Feature {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub position_m: Vec3,
    pub level_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to_level_id: Option<String>,
    pub distance_along_m: f64,
    /// `true`/`false` when known; `null` when unverified or not an accessibility question.
    pub accessible: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub refs: BTreeMap<String, String>,
    pub detail: Value,
}

#[derive(Clone, Debug, Serialize)]
pub struct Issue {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub feature_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edge_id: Option<String>,
    pub reason: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct Accessibility {
    /// `accessible`, `not_accessible`, or `unverified`.
    pub status: &'static str,
    pub blocking: Vec<Issue>,
    pub unverified: Vec<Issue>,
}

/// The walked 3D line of a path with the cumulative walking distance at each vertex.
pub struct Line {
    pub points: Vec<Vec3>,
    pub along: Vec<f64>,
    /// Distance along the route where each path edge starts.
    pub edge_start: Vec<f64>,
    /// Index into `points` where each path edge starts.
    pub edge_vertex: Vec<usize>,
}

pub fn line(model: &NavModel, path: &Path) -> Line {
    let mut points: Vec<Vec3> = Vec::new();
    let mut along: Vec<f64> = Vec::new();
    let mut edge_start = Vec::with_capacity(path.edges.len());
    let mut edge_vertex = Vec::with_capacity(path.edges.len());
    let mut total = 0.0;
    if let Some(&first) = path.nodes.first() {
        points.push(model.nodes[first].position);
        along.push(0.0);
    }
    for &e in &path.edges {
        edge_start.push(total);
        edge_vertex.push(points.len() - 1);
        let edge = &model.edges[e];
        let pts = if edge.points.len() >= 2 {
            edge.points.clone()
        } else {
            vec![
                model.nodes[edge.from].position,
                model.nodes[edge.to].position,
            ]
        };
        for p in pts.into_iter().skip(1) {
            let last = *points.last().unwrap();
            // Riding a lift or escalator adds no walking distance; stairs count their slope length.
            total += match edge.kind {
                EdgeKind::Elevator | EdgeKind::Escalator => 0.0,
                EdgeKind::Stairs | EdgeKind::Ramp => super::distance(last, p),
                _ => super::horizontal_distance(last, p),
            };
            points.push(p);
            along.push(total);
        }
    }
    Line {
        points,
        along,
        edge_start,
        edge_vertex,
    }
}

/// Nearest approach of a point to the line on its level: (distance, distance along the route).
fn project(line: &Line, model: &NavModel, point: Vec3, level: usize) -> Option<(f64, f64)> {
    let mut best: Option<(f64, f64)> = None;
    for i in 1..line.points.len() {
        let (a, b) = (line.points[i - 1], line.points[i]);
        if levels::level_of(&model.levels, a[1]) != level
            || levels::level_of(&model.levels, b[1]) != level
        {
            continue;
        }
        let (dx, dz) = (b[0] - a[0], b[2] - a[2]);
        let length2 = dx * dx + dz * dz;
        let t = if length2 > 0.0 {
            (((point[0] - a[0]) * dx + (point[2] - a[2]) * dz) / length2).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let q = [a[0] + t * dx, a[1], a[2] + t * dz];
        let d = super::horizontal_distance(q, point);
        let s = line.along[i - 1] + t * (line.along[i] - line.along[i - 1]);
        if best.is_none_or(|(bd, _)| d < bd) {
            best = Some((d, s));
        }
    }
    best
}

fn refs(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect()
}

fn poi_feature(model: &NavModel, poi: &Poi, kind: &str, along: f64) -> Feature {
    let key = match poi.kind {
        PoiKind::Hazard => "hazard_id",
        PoiKind::Sign => "sign_id",
        PoiKind::Door => "door_id",
        PoiKind::Place => "place_id",
    };
    let mut detail = poi.detail.clone();
    if let Some(object) = detail.as_object_mut() {
        object.insert("category".into(), json!(poi.category));
    }
    Feature {
        id: String::new(),
        kind: kind.to_owned(),
        position_m: round_point(poi.position),
        level_id: model.level_id(poi.level).to_owned(),
        to_level_id: None,
        distance_along_m: round3(along),
        accessible: poi.accessible,
        name: poi.name.clone(),
        refs: refs(&[(key, &poi.id), ("scan_id", &poi.scan_id)]),
        detail,
    }
}

fn hazard_type(kind: &str) -> &str {
    match kind {
        "step" | "stairs" | "ramp" | "level_change" | "drop_off" | "low_headroom"
        | "protruding_object" => kind,
        _ => "hazard",
    }
}

fn edge_feature(
    model: &NavModel,
    edge_index: usize,
    kind: &str,
    position: Vec3,
    along: f64,
    accessible: Option<bool>,
    detail: Value,
) -> Feature {
    let edge = &model.edges[edge_index];
    let from = &model.nodes[edge.from];
    Feature {
        id: String::new(),
        kind: kind.into(),
        position_m: round_point(position),
        level_id: model.level_id(from.level).to_owned(),
        to_level_id: None,
        distance_along_m: round3(along),
        accessible,
        name: None,
        refs: refs(&[("edge_id", &edge.id)]),
        detail,
    }
}

/// Features along a path in route order, plus the route's accessibility verdict.
pub fn collect(
    model: &NavModel,
    path: &Path,
    line: &Line,
    origin: Option<&Poi>,
    destination: Option<&Poi>,
) -> (Vec<Feature>, Accessibility) {
    let mut features: Vec<Feature> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    // The feature each path edge produced (for linking accessibility issues to features).
    let mut produced: Vec<Option<usize>> = vec![None; path.edges.len()];
    let mut narrow_run: Option<usize> = None;

    for (i, &e) in path.edges.iter().enumerate() {
        let edge = &model.edges[e];
        let start = line.edge_start[i];
        let mut door_feature = None;
        let from = &model.nodes[edge.from];
        if let Some(door) = model.doors.get(&edge.from)
            && seen.insert(format!("door:{}:{}", door.scan_id, door.id))
        {
            door_feature = Some(features.len());
            features.push(poi_feature(model, door, "door", start));
        }
        let middle = start + 0.5 * edge.length_m;
        let mid_point = edge
            .points
            .get(edge.points.len() / 2)
            .copied()
            .unwrap_or(from.position);
        match edge.kind {
            EdgeKind::Stairs | EdgeKind::Elevator | EdgeKind::Escalator | EdgeKind::Ramp => {
                narrow_run = None;
                let to_level = model.nodes[edge.to].level;
                let mut r = edge
                    .connector
                    .as_ref()
                    .map(|c| c.refs.clone())
                    .unwrap_or_default();
                r.insert("edge_id".into(), edge.id.clone());
                if let Some(c) = &edge.connector {
                    r.insert("connector_id".into(), c.id.clone());
                }
                let kind = edge.kind.as_str();
                // The places/hazards evidencing this connector are part of it, not separate features.
                let scans: Vec<&String> = r
                    .iter()
                    .filter(|(k, _)| k.ends_with("scan_id"))
                    .map(|(_, v)| v)
                    .collect();
                for (key, value) in &r {
                    let family = if key.ends_with("hazard_id") {
                        "hazard"
                    } else if key.ends_with("place_id") {
                        "place"
                    } else {
                        continue;
                    };
                    for scan in &scans {
                        seen.insert(format!("{family}:{scan}:{value}"));
                    }
                }
                produced[i] = Some(features.len());
                features.push(Feature {
                    id: String::new(),
                    kind: kind.into(),
                    position_m: round_point(from.position),
                    level_id: model.level_id(from.level).to_owned(),
                    to_level_id: (to_level != from.level).then(|| model.level_id(to_level).to_owned()),
                    distance_along_m: round3(start),
                    accessible: match super::paths::accessible_verdict(model, edge) {
                        super::paths::Verdict::Pass => Some(true),
                        super::paths::Verdict::Unknown(_) => None,
                        super::paths::Verdict::Fail(_) => Some(false),
                    },
                    name: edge.connector.as_ref().and_then(|c| c.name.clone()),
                    refs: r,
                    detail: json!({
                        "estimated_seconds": edge.seconds,
                        "source": edge.connector.as_ref().map(|c| c.source).unwrap_or("graph"),
                        "rise_m": round3(model.nodes[edge.to].position[1] - from.position[1]),
                        "direction": if model.nodes[edge.to].position[1] >= from.position[1] { "up" } else { "down" },
                    }),
                });
            }
            EdgeKind::Seam => {
                narrow_run = None;
                produced[i] = Some(features.len());
                features.push(edge_feature(
                    model,
                    e,
                    "scan_seam",
                    from.position,
                    start,
                    None,
                    json!({"note": "join between two scans; geometry here is unverified"}),
                ));
            }
            EdgeKind::Surface => {
                match edge.width_m.filter(|w| *w < ROUTE_MIN_CLEAR_M) {
                    Some(width) => match narrow_run {
                        // Contiguous narrow edges form one passage.
                        Some(index) => {
                            let current = features[index].detail["min_clear_width_m"]
                                .as_f64()
                                .unwrap_or(width);
                            features[index].detail["min_clear_width_m"] =
                                json!(round3(current.min(width)));
                            produced[i].get_or_insert(index);
                        }
                        None => {
                            narrow_run = Some(features.len());
                            produced[i].get_or_insert(features.len());
                            features.push(edge_feature(model, e, "narrow_passage", mid_point, middle, Some(false),
                                json!({"min_clear_width_m": round3(width), "required_m": ROUTE_MIN_CLEAR_M})));
                        }
                    },
                    None => narrow_run = None,
                }
                if edge.step_free == Some(true)
                    && let Some(slope) = edge.slope.filter(|s| *s > RUNNING_SLOPE_MAX)
                {
                    produced[i].get_or_insert(features.len());
                    features.push(edge_feature(
                        model,
                        e,
                        "ramp",
                        mid_point,
                        middle,
                        Some(slope <= RAMP_MAX_SLOPE),
                        json!({"slope": round3(slope), "max_slope": round3(RAMP_MAX_SLOPE)}),
                    ));
                }
                for hazard_id in &edge.hazards {
                    let Some(poi) = model
                        .hazards
                        .iter()
                        .find(|h| &h.id == hazard_id && h.scan_id == from.scan_id)
                    else {
                        continue;
                    };
                    if seen.insert(format!("hazard:{}:{}", poi.scan_id, poi.id)) {
                        produced[i].get_or_insert(features.len());
                        features.push(poi_feature(model, poi, hazard_type(&poi.category), middle));
                    }
                }
            }
        }
        // An edge's own feature explains its verdict better than the door it starts at.
        if let Some(door) = door_feature {
            produced[i].get_or_insert(door);
        }
    }
    // Things the walked line passes close to; the endpoints themselves are not landmarks.
    let destination_key = destination.map(|d| format!("place:{}:{}", d.scan_id, d.id));
    if let Some(place) = origin {
        seen.insert(format!("place:{}:{}", place.scan_id, place.id));
    }
    let nearby = model
        .hazards
        .iter()
        .map(|p| (p, HAZARD_NEAR_M, "hazard"))
        .chain(model.signs.iter().map(|p| (p, SIGN_NEAR_M, "sign")))
        .chain(model.places.iter().map(|p| (p, PLACE_NEAR_M, "place")));
    for (poi, radius, family) in nearby {
        let key = format!("{family}:{}:{}", poi.scan_id, poi.id);
        if seen.contains(&key) || Some(&key) == destination_key.as_ref() {
            continue;
        }
        let Some((d, s)) = project(line, model, poi.position, poi.level) else {
            continue;
        };
        if d > radius {
            continue;
        }
        seen.insert(key);
        let kind = match family {
            // A stairwell or ramp beside the route is a hazard to note, not a connector it takes.
            "hazard" if matches!(poi.category.as_str(), "stairs" | "ramp" | "escalator") => {
                "hazard"
            }
            "hazard" => hazard_type(&poi.category),
            "sign" => "sign",
            _ => "landmark",
        };
        let mut feature = poi_feature(model, poi, kind, s);
        if family != "hazard" {
            feature.accessible = None;
        }
        feature.detail["offset_m"] = json!(round3(d));
        feature.detail["nearby"] = json!(true);
        feature.detail["category"] = json!(poi.category);
        features.push(feature);
    }
    if let Some(place) = destination {
        let total = line.along.last().copied().unwrap_or(0.0);
        let mut feature = poi_feature(model, place, "destination", total);
        feature.accessible = None;
        features.push(feature);
    }

    // Route order and stable ids (f1, f2, ...).
    let mut order: Vec<usize> = (0..features.len()).collect();
    order.sort_by(|&a, &b| {
        features[a]
            .distance_along_m
            .total_cmp(&features[b].distance_along_m)
            .then(a.cmp(&b))
    });
    for (rank, &index) in order.iter().enumerate() {
        features[index].id = format!("f{}", rank + 1);
    }
    let feature_id = |i: usize| produced[i].map(|f| features[f].id.clone());

    let mut blocking = Vec::new();
    let mut unverified = Vec::new();
    let mut seen_reasons = HashSet::new();
    for (i, &e) in path.edges.iter().enumerate() {
        let edge = &model.edges[e];
        match accessible_verdict(model, edge) {
            Verdict::Pass => {}
            Verdict::Fail(reason) => {
                if seen_reasons.insert((reason, feature_id(i).unwrap_or_else(|| edge.id.clone()))) {
                    blocking.push(Issue {
                        feature_id: feature_id(i),
                        edge_id: Some(edge.id.clone()),
                        reason: reason.into(),
                    });
                }
            }
            Verdict::Unknown(reason) => {
                // One entry per reason per feature keeps the list readable.
                if seen_reasons.insert((reason, feature_id(i).unwrap_or_default())) {
                    unverified.push(Issue {
                        feature_id: feature_id(i),
                        edge_id: Some(edge.id.clone()),
                        reason: reason.into(),
                    });
                }
            }
        }
    }
    for feature in &features {
        if feature.kind == "door" && feature.accessible == Some(false) {
            blocking.push(Issue {
                feature_id: Some(feature.id.clone()),
                edge_id: None,
                reason: "door clear width below minimum".into(),
            });
        }
        if feature.kind == "door" && feature.accessible.is_none() {
            unverified.push(Issue {
                feature_id: Some(feature.id.clone()),
                edge_id: None,
                reason: "door clear width unknown".into(),
            });
        }
    }
    let status = if !blocking.is_empty() {
        "not_accessible"
    } else if !unverified.is_empty() {
        "unverified"
    } else {
        "accessible"
    };
    let mut sorted: Vec<Feature> = Vec::with_capacity(features.len());
    for index in order {
        sorted.push(features[index].clone());
    }
    (
        sorted,
        Accessibility {
            status,
            blocking,
            unverified,
        },
    )
}
