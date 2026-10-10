//! Conservative, measured object envelopes from segmentation masks and calibrated depth.
//! Capture poses must already include reconstruction corrections. Category labels never supply
//! dimensions, hidden surfaces, or navigation clearance.
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};

use serde::{Deserialize, Serialize};

use crate::{
    capture::{Confidence, DepthFrame, DetectedObject},
    geometry::{Bounds, Transform, Vec3, finite},
};

pub const RECOGNITION_CATEGORIES: &[&str] = &[
    "chair",
    "sofa",
    "table",
    "round_table",
    "bench",
    "storage",
    "bed",
    "sink",
    "plant",
    "rug",
    "lectern",
    "waste_bin",
    "sign_stand",
    "charging_stand",
    "railing",
    "ottoman",
    "open_bin",
    "square_planter",
    "floor_sign",
];
const MIN_SAMPLES: usize = 24;
const MAX_MASK_SAMPLES: usize = 2048;
const MAX_OBSERVATION_POINTS: usize = 512;
const MAX_TRACK_POINTS: usize = 1024;
const MAX_VIEWPOINTS: usize = 16;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Detection {
    pub category: String,
    pub score: f64,
    pub depth_indices: Vec<usize>,
}

pub fn canonical_category(category: &str) -> Option<&'static str> {
    match category
        .trim()
        .to_ascii_lowercase()
        .replace([' ', '-'], "_")
        .as_str()
    {
        "chair" | "armchair" | "lounge_chair" | "lounge_chair_v1" => Some("chair"),
        "sofa" | "loveseat" | "modular_sofa" | "modular_sofa_v1" => Some("sofa"),
        "table" | "dining_table" | "desk" | "folding_table" | "folding_table_v1" => Some("table"),
        "drum_table" | "round_table" | "drum_table_v1" => Some("round_table"),
        "rug" | "carpet" => Some("rug"),
        "bench" | "bench_v1" => Some("bench"),
        "cabinet" | "storage" | "shelf" | "bookshelf" => Some("storage"),
        "bed" => Some("bed"),
        "sink" => Some("sink"),
        "plant" | "potted_plant" => Some("plant"),
        "lectern" | "lectern_v1" | "podium" => Some("lectern"),
        "waste_bin" | "waste_bin_v1" | "trash_bin" | "trash_can" => Some("waste_bin"),
        "sign_stand" | "sign_stand_v1" => Some("sign_stand"),
        "charging_stand" | "charging_stand_v1" => Some("charging_stand"),
        "railing" | "railing_v1" => Some("railing"),
        "ottoman" => Some("ottoman"),
        "open_bin" | "open_bin_v1" => Some("open_bin"),
        "square_planter" | "square_planter_v1" => Some("square_planter"),
        "floor_sign" | "floor_sign_v1" | "caution_sign" => Some("floor_sign"),
        _ => None,
    }
}

pub fn supported_category(category: &str) -> bool {
    canonical_category(category).is_some()
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct ObjectFusionStats {
    pub frames_processed: usize,
    pub detections_seen: usize,
    pub detections_rejected: usize,
    pub tracks: usize,
    pub multi_view_confirmed: usize,
    pub retained_points: usize,
}

#[derive(Default)]
pub struct ObjectFusion {
    tracks: Vec<Track>,
    stats: ObjectFusionStats,
    last_frame_id: Option<String>,
}

struct Track {
    id: usize,
    category: String,
    points: Vec<Vec3>,
    fit: Fit,
    views: Vec<View>,
    last_frame_id: String,
}

struct View {
    camera: Vec3,
    score: f64,
    purity: f64,
    high_depth_fraction: f64,
}

struct Observation {
    category: String,
    score: f64,
    points: Vec<Vec3>,
    fit: Fit,
    purity: f64,
    high_depth_fraction: f64,
}

#[derive(Clone)]
struct Fit {
    transform: Transform,
    dimensions: Vec3,
    bounds: Bounds,
    oriented: bool,
}

impl ObjectFusion {
    /// One-to-one assignment in each frame prevents nearby same-category detections from being
    /// merged. New tracks require measured depth; building object count is not artificially capped.
    pub fn integrate(&mut self, frame: &DepthFrame, detections: &[Detection]) {
        if self.last_frame_id.as_deref() == Some(&frame.id) {
            return;
        }
        self.last_frame_id = Some(frame.id.clone());
        self.stats.frames_processed += 1;
        self.stats.detections_seen += detections.len();
        if frame.validate().is_err() || frame.depth.confidence.is_none() {
            self.stats.detections_rejected += detections.len();
            return;
        }
        let mut observations: Vec<_> = detections
            .iter()
            .filter_map(|detection| {
                let observation = lift(frame, detection);
                if observation.is_none() {
                    self.stats.detections_rejected += 1;
                }
                observation
            })
            .collect();
        // Remove duplicate masks in the same image, without joining separate adjacent objects.
        observations.sort_by(|a, b| b.score.total_cmp(&a.score));
        let mut unique: Vec<Observation> = Vec::new();
        for observation in observations {
            if unique.iter().any(|other| {
                iou(other.fit.bounds, observation.fit.bounds) > 0.85
                    && support_overlap(&other.points, &observation.points) > 0.8
            }) {
                self.stats.detections_rejected += 1;
            } else {
                unique.push(observation);
            }
        }
        unique.sort_by(|a, b| {
            a.category.cmp(&b.category).then_with(|| {
                for axis in 0..3 {
                    let order =
                        a.fit.transform.0[12 + axis].total_cmp(&b.fit.transform.0[12 + axis]);
                    if !order.is_eq() {
                        return order;
                    }
                }
                std::cmp::Ordering::Equal
            })
        });
        let mut candidates = Vec::new();
        for (observation_index, observation) in unique.iter().enumerate() {
            for (track_index, track) in self.tracks.iter().enumerate() {
                if track.category == observation.category
                    && let Some(score) = association(
                        &track.fit,
                        &track.points,
                        &observation.fit,
                        &observation.points,
                    )
                {
                    candidates.push((score, track_index, observation_index));
                }
            }
        }
        candidates.sort_by(|a, b| {
            b.0.total_cmp(&a.0)
                .then_with(|| a.1.cmp(&b.1))
                .then_with(|| a.2.cmp(&b.2))
        });
        let mut assigned_tracks = BTreeSet::new();
        let mut assigned_observations = BTreeMap::new();
        for (_, track, observation) in candidates {
            if !assigned_tracks.contains(&track)
                && !assigned_observations.contains_key(&observation)
            {
                assigned_tracks.insert(track);
                assigned_observations.insert(observation, track);
            }
        }
        let camera = [
            frame.map_from_camera.0[12],
            frame.map_from_camera.0[13],
            frame.map_from_camera.0[14],
        ];
        for (index, observation) in unique.into_iter().enumerate() {
            if let Some(&track_index) = assigned_observations.get(&index) {
                let track = &mut self.tracks[track_index];
                if track.last_frame_id == frame.id {
                    continue;
                }
                track.last_frame_id = frame.id.clone();
                track.points.extend(observation.points.iter().copied());
                track.points = compact_points(std::mem::take(&mut track.points), MAX_TRACK_POINTS);
                // Observations are already depth-clustered and robustly trimmed. Repeated views
                // add measured extents, instead of guessing an unseen object back from a category.
                if let Some(fit) = fit(&track.points, &track.category) {
                    track.fit = fit;
                }
                add_view(track, camera, &observation);
            } else {
                let mut track = Track {
                    id: self.tracks.len() + 1,
                    category: observation.category.clone(),
                    points: observation.points.clone(),
                    fit: observation.fit.clone(),
                    views: Vec::new(),
                    last_frame_id: frame.id.clone(),
                };
                add_view(&mut track, camera, &observation);
                self.tracks.push(track);
            }
        }
    }

    pub fn finish(&self) -> Vec<DetectedObject> {
        self.tracks
            .iter()
            .map(|track| DetectedObject {
                id: format!("recognized-object-{}", track.id),
                category: track.category.clone(),
                confidence: confidence(track),
                map_from_object: track.fit.transform,
                dimensions_m: track.fit.dimensions,
            })
            .collect()
    }

    pub fn stats(&self) -> ObjectFusionStats {
        let mut stats = self.stats.clone();
        stats.tracks = self.tracks.len();
        stats.multi_view_confirmed = self
            .tracks
            .iter()
            .filter(|track| confidence(track) >= Confidence::Medium)
            .count();
        stats.retained_points = self.tracks.iter().map(|track| track.points.len()).sum();
        stats
    }
}

fn add_view(track: &mut Track, camera: Vec3, observation: &Observation) {
    if track.views.len() >= MAX_VIEWPOINTS {
        return;
    }
    let center = [
        track.fit.transform.0[12],
        track.fit.transform.0[13],
        track.fit.transform.0[14],
    ];
    let independent = track.views.iter().all(|view| {
        let baseline = distance(camera, view.camera);
        let a = sub(camera, center);
        let b = sub(view.camera, center);
        let denominator = length(a) * length(b);
        let angle = if denominator > 1e-8 {
            (dot(a, b) / denominator).clamp(-1.0, 1.0).acos()
        } else {
            0.0
        };
        baseline >= 0.12 || (baseline >= 0.08 && angle >= 0.26)
    });
    if independent {
        track.views.push(View {
            camera,
            score: observation.score,
            purity: observation.purity,
            high_depth_fraction: observation.high_depth_fraction,
        });
    } else if let Some(view) = track
        .views
        .iter_mut()
        .min_by(|a, b| distance(camera, a.camera).total_cmp(&distance(camera, b.camera)))
    {
        // Better quality at the same viewpoint improves evidence without inventing another view.
        if observation.score > view.score {
            view.score = observation.score;
            view.purity = observation.purity;
            view.high_depth_fraction = observation.high_depth_fraction;
        }
    }
}

fn confidence(track: &Track) -> Confidence {
    let strong: Vec<_> = track
        .views
        .iter()
        .filter(|view| view.score >= 0.65 && view.purity >= 0.75)
        .collect();
    if strong.len() < 2
        || !track.fit.oriented
        || track
            .fit
            .dimensions
            .iter()
            .any(|dimension| *dimension < 0.05)
    {
        return Confidence::Low;
    }
    if strong.len() >= 3
        && strong
            .iter()
            .all(|view| view.score >= 0.8 && view.high_depth_fraction >= 0.7)
    {
        Confidence::High
    } else {
        Confidence::Medium
    }
}

#[derive(Clone)]
struct Sample {
    index: usize,
    depth: f64,
    point: Vec3,
    confidence: u8,
}

fn lift(frame: &DepthFrame, detection: &Detection) -> Option<Observation> {
    let category = canonical_category(&detection.category)?;
    if !detection.score.is_finite()
        || !(0.45..=1.0).contains(&detection.score)
        || detection.depth_indices.len() > MAX_MASK_SAMPLES
    {
        return None;
    }
    let confidence = frame.depth.confidence.as_ref()?;
    let indices: BTreeSet<_> = detection.depth_indices.iter().copied().collect();
    if indices.len() != detection.depth_indices.len() {
        return None;
    }
    let mut samples = Vec::new();
    for index in indices {
        let depth = *frame.depth.values_m.get(index)?;
        let confidence = *confidence.get(index)?;
        let Some(depth) = depth.filter(|depth| (0.15..=8.0).contains(depth)) else {
            continue;
        };
        if confidence < 1 {
            continue;
        }
        let point = frame.point_in_map(index, depth);
        if finite(point) {
            samples.push(Sample {
                index,
                depth,
                point,
                confidence,
            });
        }
    }
    if samples.len() < MIN_SAMPLES {
        return None;
    }
    let valid_count = samples.len();
    samples = largest_cluster(frame, samples);
    if samples.len() < MIN_SAMPLES {
        return None;
    }
    let purity = samples.len() as f64 / valid_count as f64;
    let mut centers = [0.0; 3];
    let mut spreads = [0.0; 3];
    for axis in 0..3 {
        let values: Vec<_> = samples.iter().map(|sample| sample.point[axis]).collect();
        centers[axis] = median(values.clone());
        spreads[axis] = (6.0
            * median(
                values
                    .into_iter()
                    .map(|value| (value - centers[axis]).abs())
                    .collect(),
            ))
        .max(0.10);
    }
    samples.retain(|sample| {
        (0..3).all(|axis| (sample.point[axis] - centers[axis]).abs() <= spreads[axis])
    });
    if samples.len() < MIN_SAMPLES {
        return None;
    }
    let high_depth_fraction = samples
        .iter()
        .filter(|sample| sample.confidence == 2)
        .count() as f64
        / samples.len() as f64;
    let points = compact_points(
        samples.into_iter().map(|sample| sample.point).collect(),
        MAX_OBSERVATION_POINTS,
    );
    let fit = fit(&points, category)?;
    Some(Observation {
        category: category.into(),
        score: detection.score,
        points,
        fit,
        purity,
        high_depth_fraction,
    })
}

fn largest_cluster(frame: &DepthFrame, samples: Vec<Sample>) -> Vec<Sample> {
    let width = frame.depth.width;
    let min_row = samples
        .iter()
        .map(|sample| sample.index / width)
        .min()
        .unwrap();
    let max_row = samples
        .iter()
        .map(|sample| sample.index / width)
        .max()
        .unwrap();
    let min_col = samples
        .iter()
        .map(|sample| sample.index % width)
        .min()
        .unwrap();
    let max_col = samples
        .iter()
        .map(|sample| sample.index % width)
        .max()
        .unwrap();
    // Mask indices may be uniformly sampled by the recognition worker. Adapt connectivity to
    // that density; requiring immediate pixel neighbors would discard large sparse masks.
    let area = (max_row - min_row + 1) * (max_col - min_col + 1);
    let radius = ((area as f64 / samples.len() as f64).sqrt().ceil() as usize * 2).clamp(1, 24);
    let mut bins: HashMap<(usize, usize), Vec<usize>> = HashMap::new();
    for (index, sample) in samples.iter().enumerate() {
        bins.entry((sample.index / width / radius, sample.index % width / radius))
            .or_default()
            .push(index);
    }
    let mut visited = vec![false; samples.len()];
    let mut largest = Vec::new();
    for start in 0..samples.len() {
        if visited[start] {
            continue;
        }
        visited[start] = true;
        let mut queue = VecDeque::from([start]);
        let mut component = Vec::new();
        while let Some(index) = queue.pop_front() {
            component.push(index);
            let sample = &samples[index];
            let row = sample.index / width;
            let col = sample.index % width;
            let bin = (row / radius, col / radius);
            for row_bin in bin.0.saturating_sub(1)..=bin.0 + 1 {
                for col_bin in bin.1.saturating_sub(1)..=bin.1 + 1 {
                    let Some(neighbors) = bins.get(&(row_bin, col_bin)) else {
                        continue;
                    };
                    for &next in neighbors {
                        if visited[next] {
                            continue;
                        }
                        let other = &samples[next];
                        if row.abs_diff(other.index / width) > radius
                            || col.abs_diff(other.index % width) > radius
                        {
                            continue;
                        }
                        let depth = sample.depth.min(other.depth);
                        let pixel_m = depth
                            * (frame.camera.image_width as f64
                                / frame.depth.width as f64
                                / frame.camera.fx)
                                .max(
                                    frame.camera.image_height as f64
                                        / frame.depth.height as f64
                                        / frame.camera.fy,
                                );
                        if (sample.depth - other.depth).abs() <= 0.12 + 0.035 * depth
                            && distance(sample.point, other.point)
                                <= 0.06 + 1.8 * pixel_m * radius as f64
                        {
                            visited[next] = true;
                            queue.push_back(next);
                        }
                    }
                }
            }
        }
        if component.len() > largest.len() {
            largest = component;
        }
    }
    largest.sort_unstable();
    largest
        .into_iter()
        .map(|index| samples[index].clone())
        .collect()
}

fn fit(points: &[Vec3], category: &str) -> Option<Fit> {
    if points.len() < MIN_SAMPLES {
        return None;
    }
    let bounds = Bounds::from_points(points)?;
    let mean_x = points.iter().map(|point| point[0]).sum::<f64>() / points.len() as f64;
    let mean_z = points.iter().map(|point| point[2]).sum::<f64>() / points.len() as f64;
    let xx = points
        .iter()
        .map(|point| (point[0] - mean_x).powi(2))
        .sum::<f64>();
    let zz = points
        .iter()
        .map(|point| (point[2] - mean_z).powi(2))
        .sum::<f64>();
    let xz = points
        .iter()
        .map(|point| (point[0] - mean_x) * (point[2] - mean_z))
        .sum::<f64>();
    let trace = xx + zz;
    if trace <= 1e-10 {
        return None;
    }
    let anisotropy = ((xx - zz).powi(2) + 4.0 * xz * xz).sqrt() / trace;
    let angle = if anisotropy >= 0.15 {
        0.5 * (2.0 * xz).atan2(xx - zz)
    } else {
        0.0
    };
    let mut x = [angle.cos(), 0.0, angle.sin()];
    let mut z = [-angle.sin(), 0.0, angle.cos()];
    let mut oriented = anisotropy >= 0.15
        || matches!(
            category,
            "plant"
                | "waste_bin"
                | "open_bin"
                | "table"
                | "round_table"
                | "ottoman"
                | "square_planter"
                | "rug"
        );
    if matches!(category, "chair" | "sofa") {
        // PCA alone cannot tell a chair's front from its back. Require a measured tall-end
        // profile along one axis before choosing an oriented chair/sofa template.
        let a = tall_end(points, x);
        let b = tall_end(points, z);
        if a.0.max(b.0) >= 0.15 {
            let (axis, sign) = if a.0 > b.0 { (x, a.1) } else { (z, b.1) };
            z = axis.map(|value| value * sign);
            x = [z[2], 0.0, -z[0]];
            oriented = true;
        } else {
            oriented = false;
        }
    }
    let mut min = [f64::INFINITY; 3];
    let mut max = [f64::NEG_INFINITY; 3];
    for point in points {
        let local = [dot(*point, x), point[1], dot(*point, z)];
        for axis in 0..3 {
            min[axis] = min[axis].min(local[axis]);
            max[axis] = max[axis].max(local[axis]);
        }
    }
    let dimensions = std::array::from_fn(|axis| max[axis] - min[axis]);
    if !finite(dimensions) || dimensions.iter().any(|dimension| *dimension <= 0.001) {
        return None;
    }
    let local_center: Vec3 = std::array::from_fn(|axis| (max[axis] + min[axis]) / 2.0);
    let center = [
        x[0] * local_center[0] + z[0] * local_center[2],
        local_center[1],
        x[2] * local_center[0] + z[2] * local_center[2],
    ];
    let transform = Transform([
        x[0], 0.0, x[2], 0.0, 0.0, 1.0, 0.0, 0.0, z[0], 0.0, z[2], 0.0, center[0], center[1],
        center[2], 1.0,
    ]);
    if transform.validate().is_err() {
        return None;
    }
    Some(Fit {
        transform,
        dimensions,
        bounds,
        oriented,
    })
}

fn tall_end(points: &[Vec3], axis: Vec3) -> (f64, f64) {
    let mut projections: Vec<_> = points.iter().map(|point| dot(*point, axis)).collect();
    projections.sort_by(f64::total_cmp);
    let low = projections[projections.len() / 4];
    let high = projections[projections.len() * 3 / 4];
    if high - low < 0.10 {
        return (0.0, 1.0);
    }
    let lower: Vec<_> = points
        .iter()
        .filter(|point| dot(**point, axis) <= low)
        .map(|point| point[1])
        .collect();
    let upper: Vec<_> = points
        .iter()
        .filter(|point| dot(**point, axis) >= high)
        .map(|point| point[1])
        .collect();
    let lower = percentile(lower, 0.85);
    let upper = percentile(upper, 0.85);
    (
        (upper - lower).abs(),
        if upper >= lower { 1.0 } else { -1.0 },
    )
}

fn compact_points(points: Vec<Vec3>, maximum: usize) -> Vec<Vec3> {
    let mut cells = BTreeMap::new();
    for point in &points {
        cells
            .entry(point.map(|value| (value / 0.015).floor() as i64))
            .or_insert(*point);
    }
    let mut values: Vec<_> = cells.into_values().collect();
    // Voxel representatives alone can lose a measured boundary. Protect directional extrema.
    for x in -1..=1 {
        for y in -1..=1 {
            for z in -1..=1 {
                if x == 0 && y == 0 && z == 0 {
                    continue;
                }
                let direction = [x as f64, y as f64, z as f64];
                if let Some(point) = points
                    .iter()
                    .max_by(|a, b| dot(**a, direction).total_cmp(&dot(**b, direction)))
                {
                    values.push(*point);
                }
            }
        }
    }
    values.sort_by(|a, b| {
        a[0].total_cmp(&b[0])
            .then_with(|| a[1].total_cmp(&b[1]))
            .then_with(|| a[2].total_cmp(&b[2]))
    });
    values.dedup();
    if values.len() <= maximum {
        return values;
    }
    let mut keep = BTreeSet::new();
    for x in -1..=1 {
        for y in -1..=1 {
            for z in -1..=1 {
                if x == 0 && y == 0 && z == 0 {
                    continue;
                }
                let direction = [x as f64, y as f64, z as f64];
                if let Some((index, _)) = values
                    .iter()
                    .enumerate()
                    .max_by(|a, b| dot(*a.1, direction).total_cmp(&dot(*b.1, direction)))
                {
                    keep.insert(index);
                }
            }
        }
    }
    let remaining = maximum - keep.len();
    for step in 0..remaining {
        keep.insert(step * (values.len() - 1) / remaining.max(1));
    }
    for index in 0..values.len() {
        if keep.len() == maximum {
            break;
        }
        keep.insert(index);
    }
    keep.into_iter().map(|index| values[index]).collect()
}

fn association(a: &Fit, a_points: &[Vec3], b: &Fit, b_points: &[Vec3]) -> Option<f64> {
    let center_a = [a.transform.0[12], a.transform.0[13], a.transform.0[14]];
    let center_b = [b.transform.0[12], b.transform.0[13], b.transform.0[14]];
    let separation = distance(center_a, center_b);
    let radius = (0.4 * length(a.dimensions).max(length(b.dimensions))).clamp(0.15, 0.85);
    if separation > radius || overlap_axis(a.bounds, b.bounds, 1, 0.04) < 0.35 {
        return None;
    }
    let overlap = support_overlap(a_points, b_points).max(support_overlap(b_points, a_points));
    let box_overlap = iou(a.bounds, b.bounds);
    if overlap < 0.2 && box_overlap < 0.45 {
        return None;
    }
    Some(2.0 * overlap + box_overlap + 1.0 - separation / radius)
}

fn support_overlap(a: &[Vec3], b: &[Vec3]) -> f64 {
    let count = b.len().min(64);
    if count == 0 || a.is_empty() {
        return 0.0;
    }
    let matches = (0..count)
        .filter(|index| {
            let point = b[index * b.len() / count];
            a.iter()
                .any(|other| squared_distance(point, *other) <= 0.10_f64.powi(2))
        })
        .count();
    matches as f64 / count as f64
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct RecognitionMergeStats {
    pub labeled_existing: usize,
    pub added: usize,
    pub withheld_ambiguous: usize,
    /// Unconfirmed labels keep their original measured depth geometry in the reconstruction.
    pub unconfirmed_in_mesh: usize,
    /// Labels can name raw bounds without asserting an incompatible display orientation.
    pub withheld_orientation: usize,
}

/// Recognition may name an existing measured obstacle but cannot resize or replace it.
/// Ambiguous overlap is withheld rather than turning one raw cluster into duplicate templates.
pub fn merge_recognized(
    mut existing: Vec<DetectedObject>,
    recognized: Vec<DetectedObject>,
) -> (Vec<DetectedObject>, RecognitionMergeStats) {
    let mut stats = RecognitionMergeStats::default();
    let mut existing_bounds: Vec<_> = existing.iter().map(object_bounds).collect();
    let recognized_bounds: Vec<_> = recognized.iter().map(object_bounds).collect();
    // A classifier can alternate labels for the same physical support across views. Do not
    // display both catalog models, or choose one without stable category evidence.
    let mut conflicting = BTreeSet::new();
    for (left, object) in recognized.iter().enumerate() {
        if object.confidence < Confidence::Medium {
            continue;
        }
        for (right, other) in recognized.iter().enumerate().skip(left + 1) {
            if other.confidence < Confidence::Medium || object.category == other.category {
                continue;
            }
            if let (Some(a), Some(b)) = (recognized_bounds[left], recognized_bounds[right])
                && iou(a, b) >= 0.7
            {
                conflicting.insert(left);
                conflicting.insert(right);
            }
        }
    }
    let mut candidates = Vec::new();
    for (new_index, object) in recognized.iter().enumerate() {
        if object.confidence < Confidence::Medium || conflicting.contains(&new_index) {
            continue;
        }
        let Some(new_bounds) = recognized_bounds[new_index] else {
            continue;
        };
        for (old_index, old) in existing.iter().enumerate() {
            let Some(old_bounds) = existing_bounds[old_index] else {
                continue;
            };
            if old.category == "unclassified_obstacle"
                && strong_envelope_match(old_bounds, new_bounds)
            {
                candidates.push((old_index, new_index));
            }
        }
    }
    let mut consumed = BTreeSet::new();
    for &(old_index, new_index) in &candidates {
        if candidates
            .iter()
            .filter(|(old, _)| *old == old_index)
            .count()
            != 1
            || candidates
                .iter()
                .filter(|(_, new)| *new == new_index)
                .count()
                != 1
        {
            continue;
        }
        existing[old_index].category = recognized[new_index].category.clone();
        existing[old_index].confidence = if rotations_agree(
            existing[old_index].map_from_object,
            recognized[new_index].map_from_object,
        ) {
            recognized[new_index].confidence
        } else {
            stats.withheld_orientation += 1;
            Confidence::Low
        };
        consumed.insert(new_index);
        stats.labeled_existing += 1;
    }
    let mut used_ids: BTreeSet<_> = existing.iter().map(|object| object.id.clone()).collect();
    let mut replacement_id = 1;
    for (index, mut object) in recognized.into_iter().enumerate() {
        if consumed.contains(&index) {
            continue;
        }
        if object.confidence < Confidence::Medium {
            stats.unconfirmed_in_mesh += 1;
            continue;
        }
        if conflicting.contains(&index) {
            stats.withheld_ambiguous += 1;
            continue;
        }
        let Some(bounds) = recognized_bounds[index] else {
            stats.withheld_ambiguous += 1;
            continue;
        };
        let overlaps_existing = existing_bounds.iter().flatten().any(|old| {
            let overlap = intersection_volume(*old, bounds);
            overlap / volume(*old).min(volume(bounds)).max(1e-9) >= 0.25
        });
        if overlaps_existing {
            stats.withheld_ambiguous += 1;
        } else {
            if used_ids.contains(&object.id) {
                loop {
                    let candidate = format!("recognized-object-{replacement_id}");
                    replacement_id += 1;
                    if !used_ids.contains(&candidate) {
                        object.id = candidate;
                        break;
                    }
                }
            }
            used_ids.insert(object.id.clone());
            existing_bounds.push(Some(bounds));
            existing.push(object);
            stats.added += 1;
        }
    }
    (existing, stats)
}

fn object_bounds(object: &DetectedObject) -> Option<Bounds> {
    if object.map_from_object.validate().is_err()
        || !finite(object.dimensions_m)
        || object
            .dimensions_m
            .iter()
            .any(|dimension| *dimension <= 0.0)
    {
        return None;
    }
    Bounds::from_points(&object.map_from_object.box_corners(object.dimensions_m))
}

fn rotations_agree(a: Transform, b: Transform) -> bool {
    // The trace of R_a^T R_b gives the full proper-rotation angle. Using its sign, rather
    // than unsigned principal axes, also rejects a chair facing the opposite direction.
    let trace: f64 = (0..3)
        .map(|column| {
            (0..3)
                .map(|row| a.0[column * 4 + row] * b.0[column * 4 + row])
                .sum::<f64>()
        })
        .sum();
    ((trace - 1.0) / 2.0).clamp(-1.0, 1.0).acos() <= 15_f64.to_radians()
}
fn strong_envelope_match(a: Bounds, b: Bounds) -> bool {
    let intersection = intersection_volume(a, b);
    iou(a, b) >= 0.55
        && intersection / volume(a).max(1e-9) >= 0.65
        && intersection / volume(b).max(1e-9) >= 0.65
}
fn volume(bounds: Bounds) -> f64 {
    (0..3)
        .map(|axis| (bounds.max[axis] - bounds.min[axis]).max(0.0))
        .product()
}
fn intersection_volume(a: Bounds, b: Bounds) -> f64 {
    (0..3)
        .map(|axis| (a.max[axis].min(b.max[axis]) - a.min[axis].max(b.min[axis])).max(0.0))
        .product()
}
fn iou(a: Bounds, b: Bounds) -> f64 {
    let intersection = intersection_volume(a, b);
    intersection / (volume(a) + volume(b) - intersection).max(1e-9)
}
fn overlap_axis(a: Bounds, b: Bounds, axis: usize, padding: f64) -> f64 {
    let overlap = (a.max[axis].min(b.max[axis]) - a.min[axis].max(b.min[axis]) + padding).max(0.0);
    overlap
        / (a.max[axis] - a.min[axis])
            .min(b.max[axis] - b.min[axis])
            .max(1e-9)
}
fn sub(a: Vec3, b: Vec3) -> Vec3 {
    std::array::from_fn(|axis| a[axis] - b[axis])
}
fn dot(a: Vec3, b: Vec3) -> f64 {
    (0..3).map(|axis| a[axis] * b[axis]).sum()
}
fn length(a: Vec3) -> f64 {
    dot(a, a).sqrt()
}
fn squared_distance(a: Vec3, b: Vec3) -> f64 {
    dot(sub(a, b), sub(a, b))
}
fn distance(a: Vec3, b: Vec3) -> f64 {
    squared_distance(a, b).sqrt()
}
fn median(values: Vec<f64>) -> f64 {
    percentile(values, 0.5)
}
fn percentile(mut values: Vec<f64>, fraction: f64) -> f64 {
    values.sort_by(f64::total_cmp);
    values[((values.len() - 1) as f64 * fraction).round() as usize]
}
