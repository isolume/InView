//! Floors from node heights in the building frame.
use super::Level;

/// Heights closer than this belong to one floor; real storeys are ≥ ~2.4 m apart, while a single
/// floor's nodes vary by a few centimetres (or tens of centimetres on ramps).
pub const LEVEL_GAP_M: f64 = 1.8;

/// Clusters heights into levels, lowest first (`L0`, `L1`, …), each at its median height.
pub fn cluster(heights: &[f64]) -> Vec<Level> {
    let mut sorted: Vec<f64> = heights.iter().copied().filter(|h| h.is_finite()).collect();
    sorted.sort_by(f64::total_cmp);
    let mut groups: Vec<Vec<f64>> = Vec::new();
    for h in sorted {
        match groups.last_mut() {
            Some(group) if h - group.last().copied().unwrap_or(h) < LEVEL_GAP_M => group.push(h),
            _ => groups.push(vec![h]),
        }
    }
    if groups.is_empty() {
        groups.push(vec![0.0]);
    }
    groups
        .into_iter()
        .enumerate()
        .map(|(index, group)| Level {
            id: format!("L{index}"),
            index,
            name: format!("Level {index}"),
            elevation_m: super::round3(group[group.len() / 2]),
        })
        .collect()
}

/// The level whose floor a point stands on: the highest floor at or below it (with a small
/// tolerance), so a sign mounted 2 m up stays on its own floor.
pub fn level_of(levels: &[Level], y: f64) -> usize {
    let mut chosen = 0;
    for (index, level) in levels.iter().enumerate() {
        if level.elevation_m <= y + 0.5 {
            chosen = index;
        }
    }
    chosen
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clusters_floors_and_assigns_mounted_points_to_their_own_floor() {
        let levels = cluster(&[0.02, -0.01, 0.0, 0.3, 3.6, 3.62, 7.2]);
        assert_eq!(levels.len(), 3);
        assert_eq!(levels[1].id, "L1");
        assert!((levels[1].elevation_m - 3.62).abs() < 0.03);
        assert_eq!(level_of(&levels, 2.0), 0); // A sign 2 m up on the ground floor.
        assert_eq!(level_of(&levels, 3.55), 1);
        assert_eq!(level_of(&levels, -0.4), 0);
        assert_eq!(cluster(&[]).len(), 1);
    }
}
