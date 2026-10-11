//! Profile-aware shortest paths and distinct alternatives (Yen's k-shortest loopless paths).
use std::{
    cmp::Ordering,
    collections::{BinaryHeap, HashSet},
};

use serde::{Deserialize, Serialize};

use super::{EdgeKind, NavEdge, NavModel, RAMP_MAX_SLOPE, ROUTE_MIN_CLEAR_M};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum Profile {
    /// Shortest time for someone walking; only closed connections are avoided.
    Fastest,
    /// Step-free, ≥ 0.915 m clear, slope ≤ 1:12. Unknown values are allowed but marked unverified.
    Accessible,
    /// Walkable, but avoids hazards and narrow passages where it can.
    LowVision,
}

impl Profile {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Fastest => "fastest",
            Self::Accessible => "accessible",
            Self::LowVision => "low_vision",
        }
    }
}

/// Whether one edge meets the accessible-route criteria.
#[derive(Clone, Debug, PartialEq)]
pub enum Verdict {
    Pass,
    Unknown(&'static str),
    Fail(&'static str),
}

/// Accessible-route screening for one edge, never assuming unknown values are fine.
pub fn accessible_verdict(model: &NavModel, edge: &NavEdge) -> Verdict {
    if edge.closed {
        return Verdict::Fail("closed");
    }
    match edge.kind {
        EdgeKind::Stairs => return Verdict::Fail("stairs"),
        EdgeKind::Escalator => return Verdict::Fail("escalator"),
        EdgeKind::Elevator => {
            return Verdict::Unknown("elevator door width and controls unverified");
        }
        EdgeKind::Seam => return Verdict::Unknown("join between scans is unverified"),
        EdgeKind::Ramp if edge.slope.is_none() => {
            return Verdict::Unknown("ramp slope and width unverified");
        }
        EdgeKind::Ramp => {}
        EdgeKind::Surface => {}
    }
    if edge.step_free == Some(false) {
        return Verdict::Fail("step or level change");
    }
    if edge.width_m.is_some_and(|w| w < ROUTE_MIN_CLEAR_M) {
        return Verdict::Fail("clear width below 0.915 m");
    }
    if edge.slope.is_some_and(|s| s > RAMP_MAX_SLOPE) {
        return Verdict::Fail("slope steeper than 1:12");
    }
    if edge.step_free.is_none() {
        return Verdict::Unknown("step-free unverified");
    }
    if edge.width_m.is_none() {
        return Verdict::Unknown("clear width unknown");
    }
    let rise = (model.nodes[edge.from].position[1] - model.nodes[edge.to].position[1]).abs();
    if edge.slope.is_none() && rise > 0.1 {
        return Verdict::Unknown("slope unknown on a sloped connection");
    }
    Verdict::Pass
}

/// Travel time of an edge in seconds for a walking speed.
pub fn seconds(edge: &NavEdge, speed_mps: f64) -> f64 {
    edge.seconds.unwrap_or(edge.length_m / speed_mps)
}

/// Search cost (seconds with preference penalties), or None when the profile can't use the edge.
pub fn cost(model: &NavModel, edge: &NavEdge, profile: Profile, speed_mps: f64) -> Option<f64> {
    if edge.closed {
        return None;
    }
    let base = seconds(edge, speed_mps);
    match profile {
        Profile::Fastest => Some(base),
        Profile::Accessible => match accessible_verdict(model, edge) {
            Verdict::Fail(_) => None,
            // Prefer verified connections when both exist.
            Verdict::Unknown(_) => Some(base * 1.5 + 2.0),
            Verdict::Pass => Some(base),
        },
        Profile::LowVision => {
            let narrow = edge.width_m.is_some_and(|w| w < ROUTE_MIN_CLEAR_M);
            let penalty = 1.0
                + 0.6 * edge.hazards.len() as f64
                + if narrow { 0.5 } else { 0.0 }
                + if edge.kind == EdgeKind::Escalator {
                    1.0
                } else {
                    0.0
                };
            Some(base * penalty)
        }
    }
}

#[derive(Clone, Debug)]
pub struct Path {
    pub nodes: Vec<usize>,
    pub edges: Vec<usize>,
    pub cost: f64,
}

#[derive(PartialEq)]
struct Item(f64, usize);
impl Eq for Item {}
impl Ord for Item {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .0
            .total_cmp(&self.0)
            .then_with(|| other.1.cmp(&self.1))
    }
}
impl PartialOrd for Item {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// Dijkstra with banned nodes/edges (for Yen's spur searches).
pub fn shortest(
    model: &NavModel,
    from: usize,
    to: usize,
    weight: &dyn Fn(usize) -> Option<f64>,
    banned_nodes: &HashSet<usize>,
    banned_edges: &HashSet<usize>,
) -> Option<Path> {
    let n = model.nodes.len();
    let mut best = vec![f64::INFINITY; n];
    let mut previous: Vec<Option<usize>> = vec![None; n];
    let mut queue = BinaryHeap::new();
    best[from] = 0.0;
    queue.push(Item(0.0, from));
    while let Some(Item(cost, node)) = queue.pop() {
        if cost > best[node] {
            continue;
        }
        if node == to {
            break;
        }
        for &e in &model.out[node] {
            if banned_edges.contains(&e) {
                continue;
            }
            let edge = &model.edges[e];
            if banned_nodes.contains(&edge.to) {
                continue;
            }
            let Some(w) = weight(e) else { continue };
            let next = cost + w;
            if next < best[edge.to] {
                best[edge.to] = next;
                previous[edge.to] = Some(e);
                queue.push(Item(next, edge.to));
            }
        }
    }
    if !best[to].is_finite() {
        return None;
    }
    let mut edges = Vec::new();
    let mut node = to;
    while node != from {
        let e = previous[node]?;
        edges.push(e);
        node = model.edges[e].from;
    }
    edges.reverse();
    let mut nodes = vec![from];
    nodes.extend(edges.iter().map(|&e| model.edges[e].to));
    Some(Path {
        nodes,
        edges,
        cost: best[to],
    })
}

/// Shortest-path tree from one node: search cost plus walked meters and travel seconds along it.
pub struct Tree {
    pub cost: Vec<f64>,
    pub length_m: Vec<f64>,
    pub seconds: Vec<f64>,
    pub previous: Vec<Option<usize>>,
    /// Nodes in the order they were settled (every node after its predecessor).
    pub order: Vec<usize>,
}

/// Meters a person walks along an edge; riding a lift or escalator adds none.
pub fn walked_m(edge: &NavEdge) -> f64 {
    match edge.kind {
        EdgeKind::Elevator | EdgeKind::Escalator => 0.0,
        _ => edge.length_m,
    }
}

pub fn tree(
    model: &NavModel,
    from: usize,
    weight: &dyn Fn(usize) -> Option<f64>,
    speed_mps: f64,
) -> Tree {
    let n = model.nodes.len();
    let mut tree = Tree {
        cost: vec![f64::INFINITY; n],
        length_m: vec![f64::INFINITY; n],
        seconds: vec![f64::INFINITY; n],
        previous: vec![None; n],
        order: Vec::new(),
    };
    let mut settled = vec![false; n];
    let mut queue = BinaryHeap::new();
    tree.cost[from] = 0.0;
    tree.length_m[from] = 0.0;
    tree.seconds[from] = 0.0;
    queue.push(Item(0.0, from));
    while let Some(Item(cost, node)) = queue.pop() {
        if settled[node] || cost > tree.cost[node] {
            continue;
        }
        settled[node] = true;
        tree.order.push(node);
        for &e in &model.out[node] {
            let edge = &model.edges[e];
            let Some(w) = weight(e) else { continue };
            let next = cost + w;
            if next < tree.cost[edge.to] {
                tree.cost[edge.to] = next;
                tree.length_m[edge.to] = tree.length_m[node] + walked_m(edge);
                tree.seconds[edge.to] = tree.seconds[node] + seconds(edge, speed_mps);
                tree.previous[edge.to] = Some(e);
                queue.push(Item(next, edge.to));
            }
        }
    }
    tree
}

/// Up to `k` loopless paths in increasing cost (Yen's algorithm).
pub fn k_shortest(
    model: &NavModel,
    from: usize,
    to: usize,
    k: usize,
    weight: &dyn Fn(usize) -> Option<f64>,
) -> Vec<Path> {
    let none = HashSet::new();
    let Some(first) = shortest(model, from, to, weight, &none, &none) else {
        return vec![];
    };
    let mut accepted = vec![first];
    let mut candidates: Vec<Path> = Vec::new();
    while accepted.len() < k {
        let last = accepted.last().unwrap().clone();
        for i in 0..last.nodes.len().saturating_sub(1) {
            let spur = last.nodes[i];
            let root_nodes = &last.nodes[..=i];
            let root_edges = &last.edges[..i];
            let mut banned_edges = HashSet::new();
            for path in &accepted {
                if path.nodes.len() > i && path.nodes[..=i] == *root_nodes {
                    banned_edges.insert(path.edges[i]);
                }
            }
            let banned_nodes: HashSet<usize> = root_nodes[..i].iter().copied().collect();
            let Some(tail) = shortest(model, spur, to, weight, &banned_nodes, &banned_edges) else {
                continue;
            };
            let root_cost: f64 = root_edges.iter().filter_map(|&e| weight(e)).sum();
            let mut nodes = root_nodes.to_vec();
            nodes.extend_from_slice(&tail.nodes[1..]);
            let mut edges = root_edges.to_vec();
            edges.extend_from_slice(&tail.edges);
            let candidate = Path {
                nodes,
                edges,
                cost: root_cost + tail.cost,
            };
            if !candidates
                .iter()
                .chain(&accepted)
                .any(|p| p.edges == candidate.edges)
            {
                candidates.push(candidate);
            }
        }
        let Some(best) = candidates
            .iter()
            .enumerate()
            .min_by(|a, b| a.1.cost.total_cmp(&b.1.cost))
            .map(|(i, _)| i)
        else {
            break;
        };
        accepted.push(candidates.swap_remove(best));
    }
    accepted
}

/// Graphs above this size use penalty alternatives: Yen's spur searches grow with path length × k.
pub const YEN_MAX_NODES: usize = 1500;
/// Cost multiplier for edges an earlier alternative already uses.
const ALTERNATIVE_PENALTY: f64 = 1.6;

/// Up to `k` distinct paths by re-searching with the edges of earlier paths made costlier
/// (k Dijkstra runs, independent of path length). Costs are reported with the true weights.
pub fn penalty_alternatives(
    model: &NavModel,
    from: usize,
    to: usize,
    k: usize,
    weight: &dyn Fn(usize) -> Option<f64>,
) -> Vec<Path> {
    let none = HashSet::new();
    let key = |e: usize| {
        let edge = &model.edges[e];
        (edge.from.min(edge.to), edge.from.max(edge.to))
    };
    let mut used: std::collections::HashMap<(usize, usize), u32> = std::collections::HashMap::new();
    let mut found: Vec<Path> = Vec::new();
    for _ in 0..k.max(1) * 2 {
        if found.len() >= k {
            break;
        }
        let penalized = |e: usize| {
            let times = used.get(&key(e)).copied().unwrap_or(0);
            weight(e).map(|w| w * ALTERNATIVE_PENALTY.powi(times as i32))
        };
        let Some(mut path) = shortest(model, from, to, &penalized, &none, &none) else {
            break;
        };
        for &e in &path.edges {
            *used.entry(key(e)).or_default() += 1;
        }
        if found.iter().any(|p| p.edges == path.edges) {
            continue;
        }
        path.cost = path.edges.iter().filter_map(|&e| weight(e)).sum();
        found.push(path);
    }
    found.sort_by(|a, b| a.cost.total_cmp(&b.cost));
    found
}

/// Distinct candidate paths: exact Yen on ordinary graphs, penalty alternatives on huge ones.
pub fn alternatives(
    model: &NavModel,
    from: usize,
    to: usize,
    k: usize,
    weight: &dyn Fn(usize) -> Option<f64>,
) -> Vec<Path> {
    if model.nodes.len() > YEN_MAX_NODES {
        penalty_alternatives(model, from, to, k, weight)
    } else {
        k_shortest(model, from, to, k, weight)
    }
}

/// Fraction of `candidate`'s length shared with `other` (undirected edge identity).
pub fn overlap(model: &NavModel, candidate: &Path, other: &Path) -> f64 {
    let key = |e: usize| {
        let edge = &model.edges[e];
        (edge.from.min(edge.to), edge.from.max(edge.to))
    };
    let theirs: HashSet<_> = other.edges.iter().map(|&e| key(e)).collect();
    let weight = |e: usize| model.edges[e].length_m.max(0.01);
    let total: f64 = candidate.edges.iter().map(|&e| weight(e)).sum();
    let shared: f64 = candidate
        .edges
        .iter()
        .filter(|&&e| theirs.contains(&key(e)))
        .map(|&e| weight(e))
        .sum();
    if total <= 0.0 { 1.0 } else { shared / total }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::building_nav::{NavEdge, NavNode};

    fn grid() -> NavModel {
        // 0 —1.0— 1 —1.0— 3, 0 —2.5— 2 —2.5— 3, and 1 —2.0— 2.
        let mut model = NavModel::default();
        for (i, p) in [
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [1.0, 0.0, 2.0],
            [2.0, 0.0, 0.0],
        ]
        .into_iter()
        .enumerate()
        {
            model.nodes.push(NavNode {
                id: i.to_string(),
                scan_id: "s".into(),
                position: p,
                level: 0,
                kind: None,
                label: None,
            });
        }
        let mut add = |from: usize, to: usize, length: f64| {
            for (a, b) in [(from, to), (to, from)] {
                model.edges.push(NavEdge {
                    id: format!("{a}-{b}"),
                    from: a,
                    to: b,
                    points: vec![],
                    length_m: length,
                    kind: EdgeKind::Surface,
                    step_free: Some(true),
                    width_m: Some(1.2),
                    slope: None,
                    closed: false,
                    seconds: None,
                    hazards: vec![],
                    connector: None,
                });
            }
        };
        add(0, 1, 1.0);
        add(1, 3, 1.0);
        add(0, 2, 2.5);
        add(2, 3, 2.5);
        add(1, 2, 2.0);
        model.out = vec![Vec::new(); 4];
        for (i, e) in model.edges.iter().enumerate() {
            model.out[e.from].push(i);
        }
        model
    }

    #[test]
    fn yen_returns_loopless_paths_in_cost_order() {
        let model = grid();
        let weight = |e: usize| Some(model.edges[e].length_m);
        let paths = k_shortest(&model, 0, 3, 3, &weight);
        assert_eq!(paths.len(), 3);
        assert_eq!(paths[0].nodes, vec![0, 1, 3]);
        assert!(paths.windows(2).all(|w| w[0].cost <= w[1].cost));
        for path in &paths {
            let unique: HashSet<_> = path.nodes.iter().collect();
            assert_eq!(unique.len(), path.nodes.len(), "loop in {:?}", path.nodes);
        }
        assert!(overlap(&model, &paths[0], &paths[0]) > 0.99);
        assert!(overlap(&model, &paths[1], &paths[0]) < 1.0);
    }

    #[test]
    fn penalty_alternatives_start_with_the_shortest_and_stay_distinct() {
        let model = grid();
        let weight = |e: usize| Some(model.edges[e].length_m);
        let paths = penalty_alternatives(&model, 0, 3, 3, &weight);
        assert_eq!(paths[0].nodes, vec![0, 1, 3]);
        assert!((paths[0].cost - 2.0).abs() < 1e-9);
        assert!(paths.len() >= 2);
        for (i, a) in paths.iter().enumerate() {
            assert!(paths[i + 1..].iter().all(|b| b.edges != a.edges));
        }
    }

    #[test]
    fn accessible_profile_fails_stairs_and_flags_unknowns() {
        let mut model = grid();
        model.edges[0].kind = EdgeKind::Stairs;
        assert_eq!(
            accessible_verdict(&model, &model.edges[0]),
            Verdict::Fail("stairs")
        );
        assert!(cost(&model, &model.edges[0], Profile::Accessible, 1.0).is_none());
        model.edges[2].width_m = None;
        assert_eq!(
            accessible_verdict(&model, &model.edges[2]),
            Verdict::Unknown("clear width unknown")
        );
        model.edges[4].width_m = Some(0.7);
        assert!(matches!(
            accessible_verdict(&model, &model.edges[4]),
            Verdict::Fail(_)
        ));
        assert_eq!(accessible_verdict(&model, &model.edges[6]), Verdict::Pass);
    }
}
