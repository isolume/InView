//! Map-client output: per-level walking legs and connector legs (how indoor maps draw a route on
//! each floor with a hand-off between floors) and turn-by-turn steps with landmark anchoring.
use serde::Serialize;

use super::{
    GeoReference, NavModel, Vec3,
    features::{Feature, Line},
    levels,
    paths::{Path, seconds},
    round_point, round3,
};

/// Polyline simplification tolerance (metres) and the distance under which bends merge.
const SIMPLIFY_M: f64 = 0.1;
const MERGE_TURNS_M: f64 = 1.5;
/// Landmarks just before (or at) a turn anchor its instruction.
const ANCHOR_BEFORE_M: f64 = 4.0;
const ANCHOR_AFTER_M: f64 = 1.0;

#[derive(Clone, Debug, Serialize)]
pub struct ConnectorLeg {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub direction: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub feature_id: Option<String>,
    pub from_level_id: String,
    pub to_level_id: String,
    pub estimated_seconds: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct Leg {
    /// `walk` (draw on `level_id`) or `connector` (switch floors).
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub level_id: String,
    pub polyline_m: Vec<Vec3>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub polyline_lonlat: Option<Vec<[f64; 2]>>,
    pub distance_m: f64,
    /// `[min_x, min_z, max_x, max_z]` in the building frame.
    pub bbox_m: [f64; 4],
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connector: Option<ConnectorLeg>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Step {
    pub index: usize,
    pub maneuver: &'static str,
    pub instruction: String,
    pub distance_m: f64,
    pub duration_s: f64,
    pub level_id: String,
    pub position_m: Vec3,
    pub distance_along_m: f64,
    pub feature_ids: Vec<String>,
}

/// Douglas–Peucker on the floor plane; returns kept indices (always the endpoints).
pub fn simplify(points: &[Vec3], tolerance: f64) -> Vec<usize> {
    fn recurse(points: &[Vec3], first: usize, last: usize, tolerance: f64, keep: &mut Vec<usize>) {
        let (a, b) = (points[first], points[last]);
        let (dx, dz) = (b[0] - a[0], b[2] - a[2]);
        let length = dx.hypot(dz);
        let mut worst = (0.0, first);
        for (i, p) in points.iter().enumerate().take(last).skip(first + 1) {
            let d = if length < 1e-9 {
                super::horizontal_distance(*p, a)
            } else {
                ((p[0] - a[0]) * dz - (p[2] - a[2]) * dx).abs() / length
            };
            if d > worst.0 {
                worst = (d, i);
            }
        }
        if worst.0 > tolerance {
            recurse(points, first, worst.1, tolerance, keep);
            keep.push(worst.1);
            recurse(points, worst.1, last, tolerance, keep);
        }
    }
    if points.len() < 3 {
        return (0..points.len()).collect();
    }
    let mut keep = vec![0];
    recurse(points, 0, points.len() - 1, tolerance, &mut keep);
    keep.push(points.len() - 1);
    keep.sort_unstable();
    keep.dedup();
    keep
}

fn bbox(points: &[Vec3]) -> [f64; 4] {
    let mut b = [
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    ];
    for p in points {
        b = [
            b[0].min(p[0]),
            b[1].min(p[2]),
            b[2].max(p[0]),
            b[3].max(p[2]),
        ];
    }
    b.map(round3)
}

/// Walking legs per level and connector legs between them.
pub fn legs(
    model: &NavModel,
    path: &Path,
    line: &Line,
    features: &[Feature],
    georef: Option<GeoReference>,
    speed: f64,
) -> Vec<Leg> {
    let mut legs = Vec::new();
    let mut leg_from = 0usize;
    let walk = |from: usize, to: usize, legs: &mut Vec<Leg>| {
        if to <= from {
            return;
        }
        let raw = &line.points[from..=to];
        let kept: Vec<Vec3> = simplify(raw, SIMPLIFY_M)
            .into_iter()
            .map(|i| round_point(raw[i]))
            .collect();
        let level = levels::level_of(&model.levels, raw[0][1]);
        legs.push(Leg {
            kind: "walk",
            level_id: model.level_id(level).to_owned(),
            polyline_lonlat: georef
                .map(|g| kept.iter().filter_map(|p| g.lon_lat(p[0], p[2])).collect()),
            distance_m: round3(line.along[to] - line.along[from]),
            bbox_m: bbox(&kept),
            polyline_m: kept,
            connector: None,
        });
    };
    for (i, &e) in path.edges.iter().enumerate() {
        let edge = &model.edges[e];
        let (from_level, to_level) = (model.nodes[edge.from].level, model.nodes[edge.to].level);
        if !edge.kind.is_connector() || from_level == to_level {
            continue;
        }
        let start = line.edge_vertex[i];
        let end = line
            .edge_vertex
            .get(i + 1)
            .copied()
            .unwrap_or(line.points.len() - 1);
        walk(leg_from, start, &mut legs);
        let points: Vec<Vec3> = line.points[start..=end]
            .iter()
            .map(|p| round_point(*p))
            .collect();
        legs.push(Leg {
            kind: "connector",
            level_id: model.level_id(from_level).to_owned(),
            polyline_lonlat: georef.map(|g| {
                points
                    .iter()
                    .filter_map(|p| g.lon_lat(p[0], p[2]))
                    .collect()
            }),
            distance_m: round3(line.along[end] - line.along[start]),
            bbox_m: bbox(&points),
            polyline_m: points,
            connector: Some(ConnectorLeg {
                kind: edge.kind.as_str(),
                direction: if to_level > from_level { "up" } else { "down" },
                feature_id: features
                    .iter()
                    .find(|f| f.refs.get("edge_id") == Some(&edge.id))
                    .map(|f| f.id.clone()),
                from_level_id: model.level_id(from_level).to_owned(),
                to_level_id: model.level_id(to_level).to_owned(),
                estimated_seconds: round3(seconds(edge, speed)),
            }),
        });
        leg_from = end;
    }
    walk(leg_from, line.points.len() - 1, &mut legs);
    legs
}

#[derive(Clone)]
struct Event {
    along: f64,
    maneuver: &'static str,
    position: Vec3,
    angle: f64,
    extra_seconds: f64,
    text: String,
    features: Vec<String>,
}

fn turn_maneuver(angle_degrees: f64) -> Option<&'static str> {
    let magnitude = angle_degrees.abs();
    let left = angle_degrees > 0.0;
    Some(match magnitude {
        m if m < 30.0 => return None,
        m if m < 60.0 => {
            if left {
                "slight_left"
            } else {
                "slight_right"
            }
        }
        m if m < 120.0 => {
            if left {
                "left"
            } else {
                "right"
            }
        }
        m if m < 150.0 => {
            if left {
                "sharp_left"
            } else {
                "sharp_right"
            }
        }
        _ => "u_turn",
    })
}

fn turn_text(maneuver: &str) -> &'static str {
    match maneuver {
        "slight_left" => "Bear left",
        "slight_right" => "Bear right",
        "left" => "Turn left",
        "right" => "Turn right",
        "sharp_left" => "Turn sharply left",
        "sharp_right" => "Turn sharply right",
        _ => "Turn around",
    }
}

fn describe(feature: &Feature) -> Option<String> {
    let name = feature.name.clone().or_else(|| {
        feature
            .detail
            .get("category")
            .and_then(|c| c.as_str())
            .map(|c| c.replace('_', " "))
    })?;
    Some(match feature.kind.as_str() {
        "sign" => format!("after the {name} sign"),
        _ => format!("at {name}"),
    })
}

/// Turn-by-turn steps (machine-readable `maneuver` plus an English instruction).
pub fn steps(
    model: &NavModel,
    path: &Path,
    line: &Line,
    features: &[Feature],
    origin_name: Option<&str>,
    destination_name: Option<&str>,
    speed: f64,
) -> Vec<Step> {
    let total = line.along.last().copied().unwrap_or(0.0);
    let mut events: Vec<Event> = Vec::new();

    // Turns on each walking stretch (connectors split stretches).
    let mut stretch_from = 0usize;
    let mut stretches = Vec::new();
    for (i, &e) in path.edges.iter().enumerate() {
        let edge = &model.edges[e];
        if edge.kind.is_connector() && model.nodes[edge.from].level != model.nodes[edge.to].level {
            stretches.push((stretch_from, line.edge_vertex[i]));
            stretch_from = line
                .edge_vertex
                .get(i + 1)
                .copied()
                .unwrap_or(line.points.len() - 1);
        }
    }
    stretches.push((stretch_from, line.points.len() - 1));
    for (from, to) in stretches {
        if to <= from + 1 {
            continue;
        }
        let kept: Vec<usize> = simplify(&line.points[from..=to], SIMPLIFY_M)
            .into_iter()
            .map(|i| from + i)
            .collect();
        for k in 1..kept.len().saturating_sub(1) {
            let (a, b, c) = (
                line.points[kept[k - 1]],
                line.points[kept[k]],
                line.points[kept[k + 1]],
            );
            // Floor-plane vectors as (east = x, north = −z): counter-clockwise is a left turn.
            let (v1, v2) = ([b[0] - a[0], a[2] - b[2]], [c[0] - b[0], b[2] - c[2]]);
            if v1[0].hypot(v1[1]) < 0.2 || v2[0].hypot(v2[1]) < 0.2 {
                continue;
            }
            let angle = (v1[0] * v2[1] - v1[1] * v2[0])
                .atan2(v1[0] * v2[0] + v1[1] * v2[1])
                .to_degrees();
            let along = line.along[kept[k]];
            // Bends closer together than a stride merge into one turn.
            if let Some(last) = events.last_mut()
                && along - last.along < MERGE_TURNS_M
                && last.angle != 0.0
            {
                last.angle += angle;
                continue;
            }
            events.push(Event {
                along,
                maneuver: "",
                position: b,
                angle,
                extra_seconds: 0.0,
                text: String::new(),
                features: vec![],
            });
        }
    }
    events.retain_mut(|event| match turn_maneuver(event.angle) {
        Some(maneuver) => {
            event.maneuver = maneuver;
            true
        }
        None => false,
    });
    for event in &mut events {
        let anchor = features
            .iter()
            .filter(|f| matches!(f.kind.as_str(), "sign" | "landmark"))
            .filter(|f| {
                f.distance_along_m >= event.along - ANCHOR_BEFORE_M
                    && f.distance_along_m <= event.along + ANCHOR_AFTER_M
            })
            .min_by(|a, b| {
                (a.distance_along_m - event.along)
                    .abs()
                    .total_cmp(&(b.distance_along_m - event.along).abs())
            });
        event.text = match anchor.and_then(describe) {
            Some(phrase) => format!("{} {phrase}", turn_text(event.maneuver)),
            None => turn_text(event.maneuver).to_owned(),
        };
        if let Some(f) = anchor {
            event.features.push(f.id.clone());
        }
    }

    // Floor changes.
    for feature in features.iter().filter(|f| {
        f.to_level_id.is_some()
            && matches!(
                f.kind.as_str(),
                "elevator" | "stairs" | "escalator" | "ramp"
            )
    }) {
        let Some(to_level_id) = &feature.to_level_id else {
            continue;
        };
        let to_name = model
            .level_by_id(to_level_id)
            .map(|l| model.levels[l].name.clone())
            .unwrap_or_else(|| to_level_id.clone());
        let up = feature.detail.get("direction").and_then(|d| d.as_str()) != Some("down");
        let ride = feature
            .detail
            .get("estimated_seconds")
            .and_then(|s| s.as_f64())
            .unwrap_or(0.0);
        let way = if up { "up" } else { "down" };
        let base = Event {
            along: feature.distance_along_m,
            maneuver: "",
            position: feature.position_m,
            angle: 0.0,
            extra_seconds: ride,
            text: String::new(),
            features: vec![feature.id.clone()],
        };
        match feature.kind.as_str() {
            "elevator" => {
                events.push(Event {
                    maneuver: "enter_elevator",
                    text: format!("Take the elevator {way} to {to_name}"),
                    ..base.clone()
                });
                events.push(Event {
                    maneuver: "exit_elevator",
                    text: format!("Exit the elevator on {to_name}"),
                    extra_seconds: 0.0,
                    along: feature.distance_along_m + 1e-6,
                    ..base
                });
            }
            "stairs" => events.push(Event {
                maneuver: if up { "stairs_up" } else { "stairs_down" },
                text: format!("Take the stairs {way} to {to_name}"),
                ..base
            }),
            "ramp" => events.push(Event {
                maneuver: if up { "ramp_up" } else { "ramp_down" },
                text: format!("Take the ramp {way} to {to_name}"),
                ..base
            }),
            _ => events.push(Event {
                maneuver: if up { "escalator_up" } else { "escalator_down" },
                text: format!("Take the escalator {way} to {to_name}"),
                ..base
            }),
        }
    }
    // Doors that aren't already at a turn.
    for door in features.iter().filter(|f| f.kind == "door") {
        if let Some(turn) = events
            .iter_mut()
            .find(|e| (e.along - door.distance_along_m).abs() < MERGE_TURNS_M)
        {
            turn.features.push(door.id.clone());
            continue;
        }
        let narrow = door.accessible == Some(false);
        let text = if narrow {
            match door.detail.get("clear_width_m").and_then(|w| w.as_f64()) {
                Some(width) => format!("Go through the door (narrow: {width:.2} m)"),
                None => "Go through the narrow door".to_owned(),
            }
        } else {
            "Go through the door".to_owned()
        };
        events.push(Event {
            along: door.distance_along_m,
            maneuver: "pass_door",
            position: door.position_m,
            angle: 0.0,
            extra_seconds: 0.0,
            text,
            features: vec![door.id.clone()],
        });
    }
    events.sort_by(|a, b| a.along.total_cmp(&b.along));

    // Depart and arrive frame the list.
    let start = line.points.first().copied().unwrap_or_default();
    let end = line.points.last().copied().unwrap_or_default();
    let mut all = vec![Event {
        along: 0.0,
        maneuver: "depart",
        position: start,
        angle: 0.0,
        extra_seconds: 0.0,
        text: origin_name
            .map(|n| format!("Start at {n}"))
            .unwrap_or_else(|| "Start walking".to_owned()),
        features: vec![],
    }];
    all.extend(events);
    let destination_feature = features
        .iter()
        .find(|f| f.kind == "destination")
        .map(|f| f.id.clone());
    all.push(Event {
        along: total,
        maneuver: "arrive",
        position: end,
        angle: 0.0,
        extra_seconds: 0.0,
        text: destination_name
            .map(|n| format!("Arrive at {n}"))
            .unwrap_or_else(|| "Arrive at your destination".to_owned()),
        features: destination_feature.into_iter().collect(),
    });
    // Hazards and narrow passages belong to the step leading up to them.
    let warnings: Vec<&Feature> = features
        .iter()
        .filter(|f| {
            matches!(
                f.kind.as_str(),
                "narrow_passage"
                    | "step"
                    | "level_change"
                    | "drop_off"
                    | "low_headroom"
                    | "protruding_object"
                    | "ramp"
                    | "scan_seam"
            )
        })
        .collect();
    let count = all.len();
    (0..count)
        .map(|i| {
            let event = &all[i];
            let next_along = all.get(i + 1).map(|n| n.along).unwrap_or(total);
            let distance = (next_along - event.along).max(0.0);
            let mut feature_ids = event.features.clone();
            for w in &warnings {
                if w.distance_along_m >= event.along
                    && w.distance_along_m < next_along
                    && !feature_ids.contains(&w.id)
                {
                    feature_ids.push(w.id.clone());
                }
            }
            let mut instruction = event.text.clone();
            if distance >= 1.0 && event.maneuver != "arrive" && event.maneuver != "enter_elevator" {
                instruction.push_str(&format!(
                    ", then continue for {} m",
                    distance.round() as i64
                ));
            }
            Step {
                index: i,
                maneuver: event.maneuver,
                instruction,
                distance_m: round3(distance),
                duration_s: round3(distance / speed + event.extra_seconds),
                level_id: model
                    .level_id(levels::level_of(&model.levels, event.position[1]))
                    .to_owned(),
                position_m: round_point(event.position),
                distance_along_m: round3(event.along),
                feature_ids,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simplification_keeps_corners_and_drops_collinear_points() {
        let points = [
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [2.0, 0.0, 0.0],
            [2.0, 0.0, -2.0],
        ];
        assert_eq!(simplify(&points, 0.1), vec![0, 2, 3]);
    }

    #[test]
    fn turns_are_classified_by_angle_and_side() {
        assert_eq!(turn_maneuver(10.0), None);
        assert_eq!(turn_maneuver(45.0), Some("slight_left"));
        assert_eq!(turn_maneuver(-90.0), Some("right"));
        assert_eq!(turn_maneuver(135.0), Some("sharp_left"));
        assert_eq!(turn_maneuver(170.0), Some("u_turn"));
    }
}
