//! "What's around me": places, signs and connectors near a point, ranked like a maps search.
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{
    EdgeKind, GeoReference, Level, NavModel, Poi, Vec3, horizontal_distance,
    paths::{self, Profile, Verdict},
    plan::{self, Endpoint, PlanError, ResolvedEndpoint},
    round_point, round3,
};

pub const DEFAULT_RADIUS_M: f64 = 200.0;
pub const MAX_RADIUS_M: f64 = 5000.0;
pub const DEFAULT_LIMIT: usize = 25;
pub const MAX_LIMIT: usize = 100;
/// A sign repeating a nearby place's name is the same thing.
const DUPLICATE_SIGN_M: f64 = 2.0;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Place,
    Sign,
    Connector,
    Door,
    Hazard,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NearbyRequest {
    pub at: Endpoint,
    /// Free text matched against names, sign text and categories ("mcdonalds", "restroom").
    #[serde(default)]
    pub query: Option<String>,
    /// Keep only these categories (exact, case-insensitive).
    #[serde(default)]
    pub categories: Vec<String>,
    #[serde(default = "default_kinds")]
    pub kinds: Vec<Kind>,
    #[serde(default = "default_radius")]
    pub radius_m: f64,
    #[serde(default = "default_limit")]
    pub limit: usize,
    #[serde(default)]
    pub same_level_only: bool,
    /// The viewer's facing, in the same reference as `bearing_deg`, for left/right/ahead hints.
    #[serde(default)]
    pub heading_degrees: Option<f64>,
    /// Pin a building map version (building scope only).
    #[serde(default)]
    pub version: Option<i32>,
    #[serde(default = "default_speed")]
    pub speed_mps: f64,
}

fn default_kinds() -> Vec<Kind> {
    vec![Kind::Place, Kind::Sign, Kind::Connector]
}
fn default_radius() -> f64 {
    DEFAULT_RADIUS_M
}
fn default_limit() -> usize {
    DEFAULT_LIMIT
}
fn default_speed() -> f64 {
    1.2
}

impl NearbyRequest {
    pub fn validate(&self) -> Result<(), String> {
        self.at.validate()?;
        if !self.radius_m.is_finite() || !(1.0..=MAX_RADIUS_M).contains(&self.radius_m) {
            return Err(format!("radius_m must be within 1–{MAX_RADIUS_M}."));
        }
        if !(1..=MAX_LIMIT).contains(&self.limit) {
            return Err(format!("limit must be within 1–{MAX_LIMIT}."));
        }
        if self.kinds.is_empty() {
            return Err("Ask for at least one kind: place, sign, connector, door, hazard.".into());
        }
        if self.query.as_ref().is_some_and(|q| q.len() > 120) {
            return Err("query is at most 120 characters.".into());
        }
        if self.categories.len() > 20 {
            return Err("At most 20 categories.".into());
        }
        if self.heading_degrees.is_some_and(|h| !h.is_finite()) {
            return Err("heading_degrees must be finite.".into());
        }
        if !self.speed_mps.is_finite() || !(0.2..=3.0).contains(&self.speed_mps) {
            return Err("speed_mps must be within 0.2–3.0.".into());
        }
        Ok(())
    }
}

#[derive(Debug, Serialize)]
pub struct NearbyResult {
    /// Unique within the response: `<kind>:<scan>:<source id>`.
    pub id: String,
    pub kind: Kind,
    pub category: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub scan_id: String,
    pub position_m: Vec3,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lon_lat: Option<[f64; 2]>,
    pub level_id: String,
    /// Floors up (+) or down (−) from the origin.
    pub level_delta: i64,
    /// Straight-line horizontal distance.
    pub distance_m: f64,
    pub reachable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub walking_distance_m: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub walking_duration_s: Option<f64>,
    /// Best step-free route's screening: accessible | unverified | not_accessible | none.
    pub accessible_route: &'static str,
    pub bearing_deg: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compass: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relative_direction: Option<&'static str>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub serves_level_ids: Vec<String>,
    /// Pass as `to` in a routes request.
    pub route_to: Value,
    pub refs: BTreeMap<String, String>,
    #[serde(skip_serializing_if = "Value::is_null")]
    pub detail: Value,
    #[serde(skip)]
    score: u8,
}

#[derive(Debug, Serialize)]
pub struct NearbyResponse {
    pub levels: Vec<Level>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub georef: Option<GeoReference>,
    pub origin: ResolvedEndpoint,
    /// `true_north` with a geographic reference, else the map frame's −Z axis.
    pub bearing_reference: &'static str,
    pub results: Vec<NearbyResult>,
    /// Matches before `limit` was applied.
    pub total_matches: usize,
    pub notices: Vec<String>,
}

/// Lowercase alphanumerics; apostrophes vanish ("McDonald's" → "mcdonalds"), other marks split words.
pub fn normalize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if c.is_alphanumeric() {
            out.extend(c.to_lowercase());
        } else if !matches!(c, '\'' | '’' | '`') && !out.ends_with(' ') {
            out.push(' ');
        }
    }
    out.trim().to_owned()
}

/// Everyday words for the worker's place and sign categories.
fn synonyms(category: &str) -> &'static str {
    match category {
        "restroom" | "toilet" | "bathroom" => "restroom bathroom toilet washroom wc",
        "elevator" => "elevator lift",
        "stairs" => "stairs stairway staircase steps",
        "escalator" => "escalator moving stairs",
        "exit" | "emergency_exit" => "exit way out",
        "entrance" => "entrance entry way in door",
        "food" | "restaurant" | "cafe" => "food restaurant cafe eat dining",
        "information" | "info" => "information info help desk",
        _ => "",
    }
}

/// A room number read from its door plate: "204" and "room 204" find Room 204 even when the
/// place's name is a department rather than the number.
fn room_score(query: &str, detail: &Value) -> u8 {
    let Some(number) = detail.get("room_number").and_then(Value::as_str).map(normalize) else {
        return 0;
    };
    if number.is_empty() {
        return 0;
    }
    if query == number || query.split(' ').any(|token| token == number) {
        4
    } else if number.starts_with(query) {
        3
    } else {
        0
    }
}

/// 0 = no match; higher is a better name match.
fn score(query: &str, name: Option<&str>, category: &str) -> u8 {
    let name = name.map(normalize).unwrap_or_default();
    let compact = |s: &str| s.replace(' ', "");
    if !name.is_empty() && (name == query || compact(&name) == compact(query)) {
        return 4;
    }
    if !name.is_empty() && (name.starts_with(query) || compact(&name).starts_with(&compact(query)))
    {
        return 3;
    }
    let haystack = format!("{name} {} {}", normalize(category), synonyms(category));
    let squashed = compact(&haystack);
    if query
        .split(' ')
        .all(|token| haystack.contains(token) || squashed.contains(token))
    {
        return if name.contains(query) { 2 } else { 1 };
    }
    0
}

/// Clockwise degrees from the map frame's −Z, the forward axis of every scan frame.
fn frame_bearing(from: Vec3, to: Vec3) -> f64 {
    let degrees = (to[0] - from[0]).atan2(-(to[2] - from[2])).to_degrees();
    degrees.rem_euclid(360.0)
}

fn compass(bearing: f64) -> &'static str {
    const POINTS: [&str; 8] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
    POINTS[(((bearing + 22.5).rem_euclid(360.0)) / 45.0) as usize % 8]
}

fn relative(bearing: f64, heading: f64) -> &'static str {
    match (bearing - heading).rem_euclid(360.0) {
        a if !(30.0..=330.0).contains(&a) => "ahead",
        a if a < 150.0 => "right",
        a if a <= 210.0 => "behind",
        _ => "left",
    }
}

#[derive(Clone, Copy, PartialEq, PartialOrd)]
enum Screen {
    Accessible,
    Unverified,
    NotAccessible,
}

/// Screening of the best step-free path to every node (doors on the way count).
fn screens(model: &NavModel, tree: &paths::Tree) -> Vec<Option<Screen>> {
    let door = |node: usize| match model.doors.get(&node).map(|d| d.accessible) {
        Some(Some(false)) => Screen::NotAccessible,
        Some(None) => Screen::Unverified,
        _ => Screen::Accessible,
    };
    let mut out = vec![None; model.nodes.len()];
    for &node in &tree.order {
        out[node] = Some(match tree.previous[node] {
            None => door(node),
            Some(e) => {
                let edge = &model.edges[e];
                let parent = out[edge.from].unwrap_or(Screen::Accessible);
                let step = match paths::accessible_verdict(model, edge) {
                    Verdict::Pass => Screen::Accessible,
                    Verdict::Unknown(_) => Screen::Unverified,
                    Verdict::Fail(_) => Screen::NotAccessible,
                };
                [parent, step, door(node)]
                    .into_iter()
                    .fold(Screen::Accessible, |a, b| if b > a { b } else { a })
            }
        });
    }
    out
}

struct Candidate<'m> {
    kind: Kind,
    poi: Option<&'m Poi>,
    scan_id: String,
    source_id: String,
    category: String,
    name: Option<String>,
    position: Vec3,
    level: usize,
    refs: BTreeMap<String, String>,
    serves: Vec<usize>,
    detail: Value,
}

fn from_poi<'m>(kind: Kind, poi: &'m Poi, key: &str) -> Candidate<'m> {
    let mut refs = BTreeMap::new();
    refs.insert(key.to_owned(), poi.id.clone());
    refs.insert("scan_id".into(), poi.scan_id.clone());
    Candidate {
        kind,
        poi: Some(poi),
        scan_id: poi.scan_id.clone(),
        source_id: poi.id.clone(),
        category: poi.category.clone(),
        name: poi.name.clone(),
        position: poi.position,
        level: poi.level,
        refs,
        serves: Vec::new(),
        detail: poi.detail.clone(),
    }
}

/// Levels each place-backed connector links, keyed by (scan, place id).
fn served_levels(model: &NavModel) -> BTreeMap<(String, String), Vec<usize>> {
    let mut served: BTreeMap<(String, String), Vec<usize>> = BTreeMap::new();
    for edge in model.edges.iter().filter(|e| e.kind.is_connector()) {
        let Some(info) = &edge.connector else {
            continue;
        };
        let scans: Vec<&String> = info
            .refs
            .iter()
            .filter(|(k, _)| k.ends_with("scan_id"))
            .map(|(_, v)| v)
            .collect();
        for place in info
            .refs
            .iter()
            .filter(|(k, _)| k.ends_with("place_id"))
            .map(|(_, v)| v)
        {
            for scan in &scans {
                let levels = served.entry(((*scan).clone(), place.clone())).or_default();
                for level in [model.nodes[edge.from].level, model.nodes[edge.to].level] {
                    if !levels.contains(&level) {
                        levels.push(level);
                    }
                }
            }
        }
    }
    for levels in served.values_mut() {
        levels.sort_unstable();
    }
    served
}

fn candidates<'m>(model: &'m NavModel, kinds: &[Kind]) -> Vec<Candidate<'m>> {
    let mut out = Vec::new();
    if kinds.contains(&Kind::Place) {
        let served = served_levels(model);
        for place in &model.places {
            let mut candidate = from_poi(Kind::Place, place, "place_id");
            candidate.serves = served
                .get(&(place.scan_id.clone(), place.id.clone()))
                .cloned()
                .unwrap_or_default();
            out.push(candidate);
        }
    }
    if kinds.contains(&Kind::Sign) {
        for sign in &model.signs {
            let duplicate = sign.name.as_deref().map(normalize).is_some_and(|text| {
                model.places.iter().any(|p| {
                    p.level == sign.level
                        && p.name.as_deref().map(normalize).as_deref() == Some(text.as_str())
                        && horizontal_distance(p.position, sign.position) <= DUPLICATE_SIGN_M
                })
            });
            if !(duplicate && kinds.contains(&Kind::Place)) {
                out.push(from_poi(Kind::Sign, sign, "sign_id"));
            }
        }
    }
    if kinds.contains(&Kind::Hazard) {
        out.extend(
            model
                .hazards
                .iter()
                .map(|h| from_poi(Kind::Hazard, h, "hazard_id")),
        );
    }
    if kinds.contains(&Kind::Door) {
        let mut doors: Vec<_> = model.doors.values().collect();
        doors.sort_by(|a, b| (&a.scan_id, &a.id).cmp(&(&b.scan_id, &b.id)));
        out.extend(
            doors
                .into_iter()
                .map(|d| from_poi(Kind::Door, d, "door_id")),
        );
    }
    if kinds.contains(&Kind::Connector) {
        // Connectors evidenced by a place are already listed through that place.
        let mut ends: BTreeMap<(String, usize), Candidate> = BTreeMap::new();
        for edge in model.edges.iter().filter(|e| e.kind.is_connector()) {
            let info = edge.connector.as_ref();
            let place_backed = info.is_some_and(|c| c.refs.keys().any(|k| k.ends_with("place_id")));
            if place_backed && kinds.contains(&Kind::Place) {
                continue;
            }
            let id = info
                .map(|c| c.id.clone())
                .unwrap_or_else(|| edge.id.trim_end_matches(['f', 'r']).to_owned());
            let node = &model.nodes[edge.from];
            let other = model.nodes[edge.to].level;
            let entry = ends.entry((id.clone(), edge.from)).or_insert_with(|| {
                let mut refs = info.map(|c| c.refs.clone()).unwrap_or_default();
                refs.insert("connector_id".into(), id.clone());
                Candidate {
                    kind: Kind::Connector,
                    poi: None,
                    scan_id: node.scan_id.clone(),
                    source_id: format!("{id}@{}", node.id),
                    category: edge.kind.as_str().to_owned(),
                    name: info.and_then(|c| c.name.clone()),
                    position: node.position,
                    level: node.level,
                    refs,
                    serves: vec![node.level],
                    detail: json!({"source": info.map(|c| c.source).unwrap_or("graph"), "step_free": edge.kind != EdgeKind::Stairs && edge.kind != EdgeKind::Escalator}),
                }
            });
            if !entry.serves.contains(&other) {
                entry.serves.push(other);
                entry.serves.sort_unstable();
            }
        }
        out.extend(ends.into_values());
    }
    out
}

pub fn nearby(model: &NavModel, request: &NearbyRequest) -> Result<NearbyResponse, PlanError> {
    request.validate().map_err(PlanError::Invalid)?;
    let mut far_origin = None;
    let (origin_node, snapped, origin_place) = match plan::resolve(model, &request.at, "at") {
        Ok(found) => found,
        // A phone position may be outside the walked graph (e.g. before tracking settles):
        // search from the closest walkable spot on that floor instead of failing.
        Err(PlanError::EndpointNotFound(_)) if request.at.position_m.is_some() => {
            let position = request.at.position_m.unwrap_or_default();
            let level = match &request.at.level_id {
                Some(id) => model
                    .level_by_id(id)
                    .ok_or_else(|| PlanError::Invalid(format!("Unknown level {id}.")))?,
                None => super::levels::level_of(&model.levels, position[1]),
            };
            let (node, distance) = model
                .nodes
                .iter()
                .enumerate()
                .filter(|(_, n)| n.level == level)
                .map(|(i, n)| (i, horizontal_distance(n.position, position)))
                .min_by(|a, b| a.1.total_cmp(&b.1))
                .ok_or(PlanError::EndpointNotFound("at"))?;
            far_origin = Some(distance);
            (node, distance, None)
        }
        Err(error) => return Err(error),
    };
    // Straight-line distances and bearings are measured from where the person is, not the node.
    let origin = request
        .at
        .position_m
        .unwrap_or(model.nodes[origin_node].position);
    let origin_level = model.nodes[origin_node].level;
    let speed = request.speed_mps;
    let walking = paths::tree(
        model,
        origin_node,
        &|e| paths::cost(model, &model.edges[e], Profile::Fastest, speed),
        speed,
    );
    let step_free = paths::tree(
        model,
        origin_node,
        &|e| paths::cost(model, &model.edges[e], Profile::Accessible, speed),
        speed,
    );
    let screened = screens(model, &step_free);
    let query = request
        .query
        .as_deref()
        .map(normalize)
        .filter(|q| !q.is_empty());
    let categories: Vec<String> = request
        .categories
        .iter()
        .map(|c| c.to_lowercase())
        .collect();
    let georef = model.georef;

    let mut results = Vec::new();
    for candidate in candidates(model, &request.kinds) {
        if origin_place.is_some_and(|o| candidate.poi.is_some_and(|p| std::ptr::eq(o, p))) {
            continue;
        }
        if request.same_level_only
            && candidate.level != origin_level
            && !(candidate.kind == Kind::Connector && candidate.serves.contains(&origin_level))
        {
            continue;
        }
        if !categories.is_empty() && !categories.contains(&candidate.category.to_lowercase()) {
            continue;
        }
        let score = match &query {
            Some(q) => match score(q, candidate.name.as_deref(), &candidate.category)
                .max(room_score(q, &candidate.detail))
            {
                0 => continue,
                s => s,
            },
            None => 0,
        };
        // A connector end on the origin's floor is where the person would board it.
        let level = if candidate.serves.contains(&origin_level) && candidate.kind == Kind::Connector
        {
            origin_level
        } else {
            candidate.level
        };
        let target = plan::nearest(model, candidate.position, candidate.level);
        let walk = target.filter(|(n, _)| walking.cost[*n].is_finite());
        let distance = horizontal_distance(origin, candidate.position);
        let walking_distance = walk.map(|(n, d)| walking.length_m[n] + d + snapped);
        if walking_distance.unwrap_or(distance) > request.radius_m {
            continue;
        }
        let accessible_route = match target.and_then(|(n, _)| screened[n]) {
            Some(Screen::Accessible) => "accessible",
            Some(Screen::Unverified) => "unverified",
            Some(Screen::NotAccessible) => "not_accessible",
            None => "none",
        };
        let raw_bearing = frame_bearing(origin, candidate.position);
        let bearing = georef.map_or(raw_bearing, |g| {
            (raw_bearing + g.heading_degrees).rem_euclid(360.0)
        });
        let route_to = match (candidate.kind, target) {
            (Kind::Place, _) => json!({"place_id": candidate.source_id}),
            (_, Some((n, _))) => json!({"node_id": model.nodes[n].id}),
            _ => {
                json!({"position_m": round_point(candidate.position), "level_id": model.level_id(candidate.level)})
            }
        };
        let kind_name = serde_json::to_value(candidate.kind)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default();
        results.push(NearbyResult {
            id: format!("{kind_name}:{}:{}", candidate.scan_id, candidate.source_id),
            kind: candidate.kind,
            category: candidate.category,
            name: candidate.name,
            scan_id: candidate.scan_id,
            position_m: round_point(candidate.position),
            lon_lat: georef.and_then(|g| g.lon_lat(candidate.position[0], candidate.position[2])),
            level_id: model.level_id(level).to_owned(),
            level_delta: level as i64 - origin_level as i64,
            distance_m: round3(distance),
            reachable: walk.is_some(),
            walking_distance_m: walking_distance.map(round3),
            walking_duration_s: walk
                .map(|(n, d)| round3(walking.seconds[n] + (d + snapped) / speed)),
            accessible_route,
            bearing_deg: round3(bearing),
            compass: georef.map(|_| compass(bearing)),
            relative_direction: request.heading_degrees.map(|h| relative(bearing, h)),
            serves_level_ids: candidate
                .serves
                .iter()
                .map(|&l| model.level_id(l).to_owned())
                .collect(),
            route_to,
            refs: candidate.refs,
            detail: candidate.detail,
            score,
        });
    }
    // Best name match first, then what is closest to walk to; unreachable last.
    results.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then(a.reachable.cmp(&b.reachable).reverse())
            .then(
                a.walking_distance_m
                    .unwrap_or(a.distance_m)
                    .total_cmp(&b.walking_distance_m.unwrap_or(b.distance_m)),
            )
            .then(a.id.cmp(&b.id))
    });
    let total_matches = results.len();
    results.truncate(request.limit);
    let mut notices = model.notices.clone();
    if let Some(distance) = far_origin {
        notices.push(format!(
            "Your position is {distance:.0} m from the mapped paths; walking distances start from the closest mapped spot."
        ));
    }
    if results.iter().any(|r| !r.reachable) {
        notices.push("Some results are not connected to your position in the captured map; distances for them are straight-line.".into());
    }
    Ok(NearbyResponse {
        levels: model.levels.clone(),
        georef,
        origin: plan::resolved(model, origin_node, snapped, origin_place),
        bearing_reference: if georef.is_some() {
            "true_north"
        } else {
            "frame_minus_z"
        },
        results,
        total_matches,
        notices,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalization_and_scoring_match_everyday_queries() {
        assert_eq!(normalize("McDonald's — Food Court"), "mcdonalds food court");
        let q = normalize("mcdonalds");
        assert_eq!(score(&q, Some("McDonald's"), "restaurant"), 4);
        assert_eq!(
            score(&normalize("mc donalds"), Some("McDonald's"), "restaurant"),
            4
        );
        assert_eq!(
            score(&normalize("mcd"), Some("McDonald's"), "restaurant"),
            3
        );
        assert_eq!(
            score(&normalize("bathroom"), Some("Restrooms"), "restroom"),
            1
        );
        assert_eq!(score(&normalize("lift"), None, "elevator"), 1);
        assert_eq!(
            score(&normalize("pizza"), Some("McDonald's"), "restaurant"),
            0
        );
    }

    #[test]
    fn room_numbers_from_door_plates_are_searchable() {
        let detail = json!({"room_number": "204A"});
        assert_eq!(room_score(&normalize("204A"), &detail), 4);
        assert_eq!(room_score(&normalize("Room 204a"), &detail), 4);
        assert_eq!(room_score(&normalize("204"), &detail), 3);
        assert_eq!(room_score(&normalize("205"), &detail), 0);
        assert_eq!(room_score(&normalize("204"), &json!({"room_number": null})), 0);
    }

    #[test]
    fn bearings_follow_the_frame_and_compass() {
        assert!((frame_bearing([0.0; 3], [0.0, 0.0, -1.0]) - 0.0).abs() < 1e-9);
        assert!((frame_bearing([0.0; 3], [1.0, 0.0, 0.0]) - 90.0).abs() < 1e-9);
        assert!((frame_bearing([0.0; 3], [0.0, 0.0, 1.0]) - 180.0).abs() < 1e-9);
        assert_eq!(compass(44.0), "NE");
        assert_eq!(compass(350.0), "N");
        assert_eq!(relative(95.0, 0.0), "right");
        assert_eq!(relative(10.0, 350.0), "ahead");
        assert_eq!(relative(260.0, 0.0), "left");
        assert_eq!(relative(180.0, 0.0), "behind");
    }
}
