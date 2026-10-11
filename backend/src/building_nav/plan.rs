//! Request → resolved endpoints → distinct, profile-labelled routes ready for a map client.
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{
    EdgeKind, Level, NavModel, Poi, Vec3, features, horizontal_distance, levels,
    paths::{self, Path, Profile},
    render, round_point, round3,
};

/// Endpoints snap to a graph node on their level within this distance.
pub const SNAP_MAX_M: f64 = 5.0;
/// An alternative sharing this fraction of its length with a kept route is not shown.
pub const MAX_OVERLAP: f64 = 0.7;
pub const MAX_ROUTES: usize = 5;

/// Exactly one of: a place, a graph node, a building-frame position, or a coordinate.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Endpoint {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub place_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub node_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position_m: Option<Vec3>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latitude: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub longitude: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub level_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouteRequest {
    pub from: Endpoint,
    pub to: Endpoint,
    #[serde(default = "default_profiles")]
    pub profiles: Vec<Profile>,
    /// Extra distinct alternatives per profile beyond its best route.
    #[serde(default = "default_alternatives")]
    pub alternatives: usize,
    /// Pin a building map version (building scope only).
    #[serde(default)]
    pub version: Option<i32>,
    #[serde(default = "default_speed")]
    pub speed_mps: f64,
}

fn default_profiles() -> Vec<Profile> {
    vec![Profile::Fastest, Profile::Accessible]
}
fn default_alternatives() -> usize {
    2
}
fn default_speed() -> f64 {
    1.2
}

impl RouteRequest {
    pub fn validate(&self) -> Result<(), String> {
        if self.profiles.is_empty() || self.profiles.len() > 3 {
            return Err("Ask for 1–3 profiles: fastest, accessible, low_vision.".into());
        }
        if self.alternatives > 4 {
            return Err("alternatives must be 0–4.".into());
        }
        if !self.speed_mps.is_finite() || !(0.2..=3.0).contains(&self.speed_mps) {
            return Err("speed_mps must be within 0.2–3.0.".into());
        }
        self.from.validate()?;
        self.to.validate()
    }
}

impl Endpoint {
    pub fn validate(&self) -> Result<(), String> {
        let endpoint = self;
        {
            let given = [
                endpoint.place_id.is_some(),
                endpoint.node_id.is_some(),
                endpoint.position_m.is_some(),
                endpoint.latitude.is_some() || endpoint.longitude.is_some(),
            ];
            if given.iter().filter(|g| **g).count() != 1 {
                return Err("Each endpoint needs exactly one of place_id, node_id, position_m, or latitude+longitude.".into());
            }
            if (endpoint.latitude.is_some()) != (endpoint.longitude.is_some()) {
                return Err("Give latitude and longitude together.".into());
            }
            if endpoint
                .position_m
                .is_some_and(|p| !p.iter().all(|v| v.is_finite()))
            {
                return Err("position_m must be three finite meters.".into());
            }
        }
        Ok(())
    }
}

#[derive(Debug, Serialize)]
pub struct ResolvedEndpoint {
    pub node_id: String,
    pub position_m: Vec3,
    pub level_id: String,
    pub snapped_distance_m: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub place_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PlannedRoute {
    pub id: String,
    pub rank: usize,
    pub labels: Vec<String>,
    pub profile: &'static str,
    pub distance_m: f64,
    pub duration_s: f64,
    pub level_changes: usize,
    pub levels: Vec<String>,
    pub accessibility: features::Accessibility,
    pub features: Vec<features::Feature>,
    pub legs: Vec<render::Leg>,
    pub steps: Vec<render::Step>,
}

#[derive(Debug, Serialize)]
pub struct Unreachable {
    pub profile: &'static str,
    pub reason: String,
}

#[derive(Debug, Serialize)]
pub struct RouteResponse {
    pub levels: Vec<Level>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub georef: Option<super::GeoReference>,
    pub origin: ResolvedEndpoint,
    pub destination: ResolvedEndpoint,
    pub routes: Vec<PlannedRoute>,
    pub unreachable: Vec<Unreachable>,
    pub notices: Vec<String>,
}

#[derive(Debug, PartialEq)]
pub enum PlanError {
    Invalid(String),
    EndpointNotFound(&'static str),
    NoRoute,
}

pub(crate) fn nearest(model: &NavModel, point: Vec3, level: usize) -> Option<(usize, f64)> {
    model
        .nodes
        .iter()
        .enumerate()
        .filter(|(_, n)| n.level == level)
        .map(|(i, n)| (i, horizontal_distance(n.position, point)))
        .filter(|(_, d)| *d <= SNAP_MAX_M)
        .min_by(|a, b| a.1.total_cmp(&b.1))
}

pub(crate) fn resolve<'m>(
    model: &'m NavModel,
    endpoint: &Endpoint,
    which: &'static str,
) -> Result<(usize, f64, Option<&'m Poi>), PlanError> {
    let missing = || PlanError::EndpointNotFound(which);
    let level_for = |y: f64| -> Result<usize, PlanError> {
        match &endpoint.level_id {
            Some(id) => model
                .level_by_id(id)
                .ok_or_else(|| PlanError::Invalid(format!("Unknown level {id}."))),
            None => Ok(levels::level_of(&model.levels, y)),
        }
    };
    if let Some(place_id) = &endpoint.place_id {
        let place = model
            .places
            .iter()
            .find(|p| &p.id == place_id)
            .ok_or_else(missing)?;
        let (node, d) = nearest(model, place.position, place.level).ok_or_else(missing)?;
        return Ok((node, d, Some(place)));
    }
    if let Some(node_id) = &endpoint.node_id {
        return model
            .node_index
            .get(node_id)
            .map(|&n| (n, 0.0, None))
            .ok_or_else(missing);
    }
    if let Some(position) = endpoint.position_m {
        let level = level_for(position[1])?;
        let (node, d) = nearest(model, position, level).ok_or_else(missing)?;
        return Ok((node, d, None));
    }
    if let (Some(latitude), Some(longitude)) = (endpoint.latitude, endpoint.longitude) {
        let georef = model.georef.ok_or_else(|| {
            PlanError::Invalid(
                "This map has no geographic reference; use a place or position.".into(),
            )
        })?;
        let [x, z] = georef
            .local(latitude, longitude)
            .ok_or_else(|| PlanError::Invalid("Invalid coordinate.".into()))?;
        let level = level_for(model.levels.first().map(|l| l.elevation_m).unwrap_or(0.0))?;
        let y = model.levels[level].elevation_m;
        let (node, d) = nearest(model, [x, y, z], level).ok_or_else(missing)?;
        return Ok((node, d, None));
    }
    Err(missing())
}

pub(crate) fn resolved(
    model: &NavModel,
    node: usize,
    snapped: f64,
    place: Option<&Poi>,
) -> ResolvedEndpoint {
    let n = &model.nodes[node];
    ResolvedEndpoint {
        node_id: n.id.clone(),
        position_m: round_point(n.position),
        level_id: model.level_id(n.level).to_owned(),
        snapped_distance_m: round3(snapped),
        place_id: place.map(|p| p.id.clone()),
        name: place
            .and_then(|p| p.name.clone())
            .or_else(|| n.label.clone()),
    }
}

fn assemble(
    model: &NavModel,
    path: &Path,
    profile: Profile,
    labels: Vec<String>,
    speed: f64,
    origin: Option<&Poi>,
    destination: Option<&Poi>,
) -> PlannedRoute {
    let line = features::line(model, path);
    let (feature_list, accessibility) = features::collect(model, path, &line, origin, destination);
    let legs = render::legs(model, path, &line, &feature_list, model.georef, speed);
    let origin_name = origin.and_then(|p| p.name.as_deref());
    let destination_name = destination.and_then(|p| p.name.as_deref());
    let steps = render::steps(
        model,
        path,
        &line,
        &feature_list,
        origin_name,
        destination_name,
        speed,
    );
    let level_changes = path
        .edges
        .iter()
        .filter(|&&e| {
            let edge = &model.edges[e];
            edge.kind.is_connector() && model.nodes[edge.from].level != model.nodes[edge.to].level
        })
        .count();
    let mut levels_visited: Vec<String> = Vec::new();
    for &node in &path.nodes {
        let id = model.level_id(model.nodes[node].level).to_owned();
        if levels_visited.last() != Some(&id) {
            levels_visited.push(id);
        }
    }
    PlannedRoute {
        id: String::new(),
        rank: 0,
        labels,
        profile: profile.as_str(),
        distance_m: round3(line.along.last().copied().unwrap_or(0.0)),
        duration_s: round3(
            path.edges
                .iter()
                .map(|&e| paths::seconds(&model.edges[e], speed))
                .sum(),
        ),
        level_changes,
        levels: levels_visited,
        accessibility,
        features: feature_list,
        legs,
        steps,
    }
}

/// Plans up to `MAX_ROUTES` distinct routes between two endpoints in the composed model.
pub fn plan(model: &NavModel, request: &RouteRequest) -> Result<RouteResponse, PlanError> {
    request.validate().map_err(PlanError::Invalid)?;
    let (from, from_snap, origin_place) = resolve(model, &request.from, "from")?;
    let (to, to_snap, destination_place) = resolve(model, &request.to, "to")?;
    let speed = request.speed_mps;
    let mut kept: Vec<(Path, Profile, Vec<String>)> = Vec::new();
    let mut unreachable = Vec::new();
    for &profile in &request.profiles {
        let weight = |e: usize| paths::cost(model, &model.edges[e], profile, speed);
        // Search a few extra candidates: near-duplicates of kept routes are filtered out.
        let candidates =
            paths::alternatives(model, from, to, 1 + request.alternatives * 3, &weight);
        if candidates.is_empty() {
            let reason = match profile {
                Profile::Accessible if model.edges.iter().any(|e| e.kind == EdgeKind::Stairs) => {
                    "No step-free route: every connection between these points needs stairs, a narrow passage, or a steep slope.".to_owned()
                }
                Profile::Accessible => "No step-free route meets the accessible-route criteria.".to_owned(),
                _ => "These points are not connected in the captured navigation graph.".to_owned(),
            };
            unreachable.push(super::plan::Unreachable {
                profile: profile.as_str(),
                reason,
            });
            continue;
        }
        let mut taken = 0;
        for (n, candidate) in candidates.into_iter().enumerate() {
            if taken > request.alternatives {
                break;
            }
            let label = if n == 0 {
                profile.as_str().to_owned()
            } else {
                "alternative".to_owned()
            };
            // The same path found by another profile gains this profile's label instead.
            if let Some(existing) = kept.iter_mut().find(|(p, _, _)| p.edges == candidate.edges) {
                if n == 0 && !existing.2.contains(&label) {
                    existing.2.push(label);
                }
                taken += 1;
                continue;
            }
            if kept
                .iter()
                .any(|(p, _, _)| paths::overlap(model, &candidate, p) >= MAX_OVERLAP)
                && n != 0
            {
                continue;
            }
            kept.push((candidate, profile, vec![label]));
            taken += 1;
        }
    }
    if kept.is_empty() {
        return Err(PlanError::NoRoute);
    }
    kept.truncate(MAX_ROUTES);
    let mut routes: Vec<PlannedRoute> = kept
        .iter()
        .map(|(path, profile, labels)| {
            assemble(
                model,
                path,
                *profile,
                labels.clone(),
                speed,
                origin_place,
                destination_place,
            )
        })
        .collect();
    // Primary (profile-labelled) routes first, then alternatives by duration.
    routes.sort_by(|a, b| {
        let primary = |r: &PlannedRoute| r.labels.iter().all(|l| l == "alternative");
        primary(a)
            .cmp(&primary(b))
            .then(a.duration_s.total_cmp(&b.duration_s))
    });
    for (i, route) in routes.iter_mut().enumerate() {
        route.id = format!("r{}", i + 1);
        route.rank = i + 1;
    }
    let mut notices = model.notices.clone();
    notices.push("Routes are screened from captured evidence, not certified accessible; verify before relying on them.".into());
    Ok(RouteResponse {
        levels: model.levels.clone(),
        georef: model.georef,
        origin: resolved(model, from, from_snap, origin_place),
        destination: resolved(model, to, to_snap, destination_place),
        routes,
        unreachable,
        notices,
    })
}

/// A compact description of a model's floors and connectors for level pickers.
pub fn levels_summary(model: &NavModel) -> Value {
    let connectors: Vec<Value> = model
        .edges
        .iter()
        .filter(|e| e.kind.is_connector() && e.id.ends_with('f'))
        .map(|e| {
            serde_json::json!({
                "id": e.connector.as_ref().map(|c| c.id.clone()).unwrap_or_else(|| e.id.clone()),
                "type": e.kind.as_str(),
                "source": e.connector.as_ref().map(|c| c.source).unwrap_or("graph"),
                "from_level_id": model.level_id(model.nodes[e.from].level),
                "to_level_id": model.level_id(model.nodes[e.to].level),
                "position_m": round_point(model.nodes[e.from].position),
            })
        })
        .collect();
    serde_json::json!({
        "levels": model.levels,
        "connectors": connectors,
        "node_count": model.nodes.len(),
        "georef": model.georef,
        "notices": model.notices,
    })
}

#[cfg(test)]
mod bench {
    use super::*;
    use crate::building_nav::{NavEdge, NavNode, levels, nearby};
    use std::time::Instant;

    /// A building-scale graph: `floors` × `side`² corridor junctions 2 m apart, with an elevator
    /// and a stair core linking every floor (Yen and nearby run over all of it).
    fn building(floors: usize, side: usize) -> NavModel {
        let mut model = NavModel::default();
        let index = |f: usize, x: usize, z: usize| f * side * side + z * side + x;
        for f in 0..floors {
            for z in 0..side {
                for x in 0..side {
                    model.nodes.push(NavNode {
                        id: format!("s:{f}-{x}-{z}"),
                        scan_id: "s".into(),
                        position: [2.0 * x as f64, 3.5 * f as f64, -2.0 * z as f64],
                        level: f,
                        kind: None,
                        label: None,
                    });
                }
            }
        }
        let push =
            |model: &mut NavModel, a: usize, b: usize, kind: EdgeKind, seconds: Option<f64>| {
                let (pa, pb) = (model.nodes[a].position, model.nodes[b].position);
                for (suffix, from, to, p, q) in [("f", a, b, pa, pb), ("r", b, a, pb, pa)] {
                    let id = format!("e{}{suffix}", model.edges.len() / 2);
                    model.edges.push(NavEdge {
                        id,
                        from,
                        to,
                        points: vec![p, q],
                        length_m: super::super::distance(p, q),
                        kind,
                        step_free: Some(kind != EdgeKind::Stairs),
                        width_m: Some(1.2),
                        slope: Some(0.0),
                        closed: false,
                        seconds,
                        hazards: vec![],
                        connector: None,
                    });
                }
            };
        for f in 0..floors {
            for z in 0..side {
                for x in 0..side {
                    if x + 1 < side {
                        push(
                            &mut model,
                            index(f, x, z),
                            index(f, x + 1, z),
                            EdgeKind::Surface,
                            None,
                        );
                    }
                    if z + 1 < side {
                        push(
                            &mut model,
                            index(f, x, z),
                            index(f, x, z + 1),
                            EdgeKind::Surface,
                            None,
                        );
                    }
                }
            }
            if f + 1 < floors {
                push(
                    &mut model,
                    index(f, 0, 0),
                    index(f + 1, 0, 0),
                    EdgeKind::Elevator,
                    Some(24.0),
                );
                push(
                    &mut model,
                    index(f, side - 1, 0),
                    index(f + 1, side - 1, 0),
                    EdgeKind::Stairs,
                    Some(12.0),
                );
            }
        }
        let heights: Vec<f64> = model.nodes.iter().map(|n| n.position[1]).collect();
        model.levels = levels::cluster(&heights);
        model.out = vec![Vec::new(); model.nodes.len()];
        for (i, e) in model.edges.iter().enumerate() {
            model.out[e.from].push(i);
        }
        for (i, n) in model.nodes.iter().enumerate() {
            model.node_index.insert(n.id.clone(), i);
        }
        model
    }

    fn time<T>(repeats: usize, mut body: impl FnMut() -> T) -> (f64, T) {
        let mut best = f64::INFINITY;
        let mut out = None;
        for _ in 0..repeats {
            let start = Instant::now();
            let value = body();
            best = best.min(start.elapsed().as_secs_f64());
            out = Some(value);
        }
        (best * 1000.0, out.unwrap())
    }

    #[test]
    #[ignore = "benchmark; run with --ignored --nocapture in release"]
    fn server_planner_timings() {
        for (floors, side) in [(1, 6), (1, 25), (3, 25), (5, 45)] {
            let model = building(floors, side);
            let far = format!("s:{}-{}-{}", floors - 1, side - 1, side - 1);
            let request: RouteRequest = serde_json::from_value(serde_json::json!({
                "from": {"node_id": format!("s:0-{}-{}", side / 2, side - 1)}, "to": {"node_id": far},
            }))
            .unwrap();
            let (plan_ms, response) = time(5, || plan(&model, &request).unwrap());
            let near: nearby::NearbyRequest = serde_json::from_value(serde_json::json!({
                "at": {"node_id": "s:0-0-0"}, "kinds": ["connector"], "radius_m": 5000
            }))
            .unwrap();
            let (nearby_ms, _) = time(5, || nearby::nearby(&model, &near).unwrap());
            let bytes = serde_json::to_vec(&response).unwrap().len();
            println!(
                "BENCH server · {floors} floor(s) × {side}² = {} nodes, {} edges · plan (fastest+accessible, alternatives) {plan_ms:.2} ms → {} routes, {:.0} KB · nearby {nearby_ms:.2} ms",
                model.nodes.len(),
                model.edges.len(),
                response.routes.len(),
                bytes as f64 / 1024.0
            );
        }
    }
}
