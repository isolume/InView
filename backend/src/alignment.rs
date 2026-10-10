//! Bounded, evidence-driven alignment in the original ARKit session gauge.
//!
//! Depth samples are camera-local (ARKit's forward direction is negative Z).
//! No coordinate-axis conversion is performed here. Odometry alone never changes
//! a pose: only a verified RGB/depth revisit enables graph optimization.

use crate::geometry::{Transform, Vec3};
use nalgebra::{DMatrix, DVector, Matrix3, Rotation3, UnitQuaternion, Vector3};
use serde::{Deserialize, Serialize};

const MAX_FRAMES: usize = 64;
const MAX_POINTS: usize = 512;
const MAX_REGISTRATIONS: usize = 24;
const MIN_POINTS: usize = 40;
// A small angular error displaces typical room samples two meters away. Using
// that lever arm keeps angular odometry informative while distributing drift.
const ROTATION_SCALE: f64 = 2.0;
const MAX_CAMERA_TRANSLATION_CORRECTION: f64 = 0.75;
const ODOMETRY_ROTATION_NOISE: f64 = std::f64::consts::PI / 180.0;

#[derive(Clone, Debug)]
pub struct AlignmentFrame {
    pub id: String,
    pub timestamp_seconds: f64,
    pub pose: Transform,
    pub points: Vec<Vec3>,
    /// Spatial RGB thumbnail, normalized to [0, 1], in a consistent layout.
    pub visual_signature: Vec<f64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AlignedFrame {
    pub frame_id: String,
    pub timestamp_seconds: f64,
    pub original_map_from_camera: Transform,
    pub optimized_map_from_camera: Transform,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConstraintDiagnostic {
    pub source_frame_id: String,
    pub target_frame_id: String,
    pub accepted: bool,
    pub reason: String,
    pub visual_distance: f64,
    pub overlap: f64,
    pub residual_meters: Option<f64>,
    pub measured_target_from_source: Option<Transform>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AlignmentResult {
    pub reference_frame: String,
    pub optimized: bool,
    pub frames: Vec<AlignedFrame>,
    pub constraints: Vec<ConstraintDiagnostic>,
    pub initial_cost: f64,
    pub final_cost: f64,
}

impl AlignmentResult {
    /// A rigid map-space correction, interpolated between retained keyframes.
    /// Applying this to the original pose corrects unsampled stream frames too.
    pub fn correction_for(&self, timestamp_seconds: f64) -> Transform {
        if !self.optimized || self.frames.is_empty() || !timestamp_seconds.is_finite() {
            return Rigid::identity().transform();
        }
        let correction = |frame: &AlignedFrame| {
            if frame.optimized_map_from_camera == frame.original_map_from_camera {
                return Rigid::identity();
            }
            Rigid::from(frame.optimized_map_from_camera)
                .compose(&Rigid::from(frame.original_map_from_camera).inverse())
        };
        let upper = self
            .frames
            .partition_point(|f| f.timestamp_seconds < timestamp_seconds);
        if upper == 0 {
            return correction(&self.frames[0]).transform();
        }
        if upper == self.frames.len() {
            return correction(self.frames.last().unwrap()).transform();
        }
        let a = &self.frames[upper - 1];
        let b = &self.frames[upper];
        let t = ((timestamp_seconds - a.timestamp_seconds)
            / (b.timestamp_seconds - a.timestamp_seconds))
            .clamp(0.0, 1.0);
        let ca = correction(a);
        let cb = correction(b);
        Rigid {
            rotation: ca.rotation.slerp(&cb.rotation, t),
            translation: ca.translation * (1.0 - t) + cb.translation * t,
        }
        .transform()
    }
}

#[derive(Clone, Debug)]
struct Rigid {
    rotation: UnitQuaternion<f64>,
    translation: Vector3<f64>,
}

impl Rigid {
    fn identity() -> Self {
        Self {
            rotation: UnitQuaternion::identity(),
            translation: Vector3::zeros(),
        }
    }

    fn from(t: Transform) -> Self {
        let m = t.0;
        Self {
            rotation: UnitQuaternion::from_rotation_matrix(&Rotation3::from_matrix_unchecked(
                Matrix3::new(m[0], m[4], m[8], m[1], m[5], m[9], m[2], m[6], m[10]),
            )),
            translation: Vector3::new(m[12], m[13], m[14]),
        }
    }

    fn transform(&self) -> Transform {
        let r = self.rotation.to_rotation_matrix();
        let r = r.matrix();
        Transform([
            r[(0, 0)],
            r[(1, 0)],
            r[(2, 0)],
            0.0,
            r[(0, 1)],
            r[(1, 1)],
            r[(2, 1)],
            0.0,
            r[(0, 2)],
            r[(1, 2)],
            r[(2, 2)],
            0.0,
            self.translation.x,
            self.translation.y,
            self.translation.z,
            1.0,
        ])
    }

    fn compose(&self, other: &Self) -> Self {
        Self {
            rotation: self.rotation * other.rotation,
            translation: self.rotation * other.translation + self.translation,
        }
    }

    fn inverse(&self) -> Self {
        let rotation = self.rotation.inverse();
        Self {
            rotation,
            translation: rotation * -self.translation,
        }
    }

    fn point(&self, p: Vector3<f64>) -> Vector3<f64> {
        self.rotation * p + self.translation
    }

    fn perturb(&self, delta: &[f64]) -> Self {
        // Right-local SE(3) increment. The rotation and translation are both
        // variables; graph fitting never substitutes a position-only update.
        self.compose(&Self {
            rotation: UnitQuaternion::from_scaled_axis(Vector3::new(delta[3], delta[4], delta[5])),
            translation: Vector3::new(delta[0], delta[1], delta[2]),
        })
    }
}

#[derive(Clone)]
struct Edge {
    i: usize,
    j: usize,
    measured: Rigid,
    is_loop: bool,
    diagnostic: Option<usize>,
}

struct Registration {
    measured: Rigid,
    overlap: f64,
    residual: f64,
}

pub fn align(frames: &[AlignmentFrame]) -> Result<AlignmentResult, String> {
    if frames.len() > MAX_FRAMES {
        return Err(format!(
            "Alignment accepts at most {MAX_FRAMES} retained keyframes."
        ));
    }
    for (index, frame) in frames.iter().enumerate() {
        frame.pose.validate()?;
        if frame.id.is_empty()
            || !frame.timestamp_seconds.is_finite()
            || (index > 0 && frame.timestamp_seconds <= frames[index - 1].timestamp_seconds)
            || frames[..index]
                .iter()
                .any(|previous| previous.id == frame.id)
        {
            return Err(
                "Alignment keyframes need unique IDs and increasing finite timestamps.".into(),
            );
        }
        if frame.points.len() > MAX_POINTS
            || frame.points.iter().flatten().any(|x| !x.is_finite())
            || frame.visual_signature.len() > 4096
            || frame
                .visual_signature
                .iter()
                .any(|x| !x.is_finite() || !(0.0..=1.0).contains(x))
        {
            return Err("Alignment samples must be finite, bounded camera points and normalized RGB thumbnails.".into());
        }
    }
    let original: Vec<_> = frames.iter().map(|f| Rigid::from(f.pose)).collect();
    let clouds: Vec<Vec<Vector3<f64>>> = frames
        .iter()
        .map(|f| f.points.iter().map(|p| Vector3::from(*p)).collect())
        .collect();
    let mut result = AlignmentResult {
        reference_frame: "original_arkit_session".into(),
        optimized: false,
        frames: frames
            .iter()
            .map(|f| AlignedFrame {
                frame_id: f.id.clone(),
                timestamp_seconds: f.timestamp_seconds,
                original_map_from_camera: f.pose,
                optimized_map_from_camera: f.pose,
            })
            .collect(),
        constraints: Vec::new(),
        initial_cost: 0.0,
        final_cost: 0.0,
    };
    let mut edges: Vec<_> = (1..frames.len())
        .map(|j| Edge {
            i: j - 1,
            j,
            measured: original[j - 1].inverse().compose(&original[j]),
            is_loop: false,
            diagnostic: None,
        })
        .collect();
    let mut candidates = Vec::new();
    for j in 4..frames.len() {
        let mut query_candidates: Vec<(usize, usize, f64)> = (0..j - 3)
            .filter(|&i| {
                frames[j].timestamp_seconds - frames[i].timestamp_seconds >= 4.0
                    && (original[j].translation - original[i].translation).norm() <= 3.0
            })
            .filter_map(|i| {
                visual_distance(&frames[i].visual_signature, &frames[j].visual_signature)
                    .filter(|&distance| distance <= 0.12)
                    .map(|distance| (i, j, distance))
            })
            .collect();
        query_candidates.sort_by(|a, b| a.2.total_cmp(&b.2).then_with(|| a.0.cmp(&b.0)));
        candidates.extend(query_candidates.into_iter().take(2));
    }
    // Rank over the entire scan before spending the registration budget. Early
    // ambiguous views cannot consume every attempt before the final revisit.
    candidates.sort_by(|a, b| {
        a.2.total_cmp(&b.2).then_with(|| {
            let span_a = frames[a.1].timestamp_seconds - frames[a.0].timestamp_seconds;
            let span_b = frames[b.1].timestamp_seconds - frames[b.0].timestamp_seconds;
            span_b.total_cmp(&span_a)
        })
    });
    for (i, j, visual_distance) in candidates.into_iter().take(MAX_REGISTRATIONS) {
        let seed = original[i].inverse().compose(&original[j]);
        let registration = register(&clouds[j], &clouds[i], &seed);
        let diagnostic = result.constraints.len();
        let mut report = ConstraintDiagnostic {
            source_frame_id: frames[j].id.clone(),
            target_frame_id: frames[i].id.clone(),
            accepted: false,
            reason: String::new(),
            visual_distance,
            overlap: 0.0,
            residual_meters: None,
            measured_target_from_source: None,
        };
        match registration {
            Ok(registration) => {
                report.accepted = true;
                report.reason = "verified_rgb_depth_loop".into();
                report.overlap = registration.overlap;
                report.residual_meters = Some(registration.residual);
                report.measured_target_from_source = Some(registration.measured.transform());
                edges.push(Edge {
                    i,
                    j,
                    measured: registration.measured,
                    is_loop: true,
                    diagnostic: Some(diagnostic),
                });
            }
            Err(reason) => report.reason = reason.into(),
        }
        result.constraints.push(report);
    }
    if !edges.iter().any(|e| e.is_loop) {
        return Ok(result);
    }
    // Measured evidence remains a verified loop when there is no drift to fix.
    // Retain the original poses byte-for-byte rather than inventing a failure
    // or a successful change from floating-point registration noise.
    let original_cost = cost(&original, &edges);
    if original_cost <= 1e-10 {
        result.initial_cost = original_cost;
        result.final_cost = original_cost;
        for report in &mut result.constraints {
            if report.accepted {
                report.reason = "verified_loop_already_aligned".into();
            }
        }
        return Ok(result);
    }

    // A robust graph fit can reject a measured match that contradicts the
    // retained trajectory. Refit after rejecting those loops, never commit a
    // graph whose odometry strain or remaining loop residual is excessive.
    let mut fitted = original.clone();
    for _ in 0..3 {
        fitted = optimize(&original, &edges);
        let rejected: Vec<_> = edges
            .iter()
            .filter(|edge| edge.is_loop && residual(edge, &fitted).norm() > 0.20)
            .filter_map(|edge| edge.diagnostic)
            .collect();
        if rejected.is_empty() {
            break;
        }
        for diagnostic in &rejected {
            result.constraints[*diagnostic].accepted = false;
            result.constraints[*diagnostic].reason = "pose_graph_inconsistent".into();
        }
        edges.retain(|e| !e.diagnostic.is_some_and(|d| rejected.contains(&d)));
        if !edges.iter().any(|e| e.is_loop) {
            return Ok(result);
        }
    }
    result.initial_cost = cost(&original, &edges);
    result.final_cost = cost(&fitted, &edges);
    let bounded = edges.iter().all(|e| {
        e.is_loop || {
            let r = residual(e, &fitted);
            // Repeated, richly textured alcoves can satisfy geometric matching.
            // A loop may distribute small drift, but must not erase a meaningful
            // fraction of measured movement by spreading it along many edges.
            let translation_limit = 0.025 + 0.15 * e.measured.translation.norm();
            let rotation_limit = ODOMETRY_ROTATION_NOISE + 0.15 * e.measured.rotation.angle();
            r.fixed_rows::<3>(0).norm() <= translation_limit
                && r.fixed_rows::<3>(3).norm() <= rotation_limit * ROTATION_SCALE
        }
    }) && fitted.iter().zip(&original).all(|(new, old)| {
        // Pose proximity can discover candidates out to three meters, but a
        // visual/depth match alone cannot authorize a large map deformation.
        (new.translation - old.translation).norm() <= MAX_CAMERA_TRANSLATION_CORRECTION
            && (old.rotation.inverse() * new.rotation).angle() <= 0.45
    });
    if !bounded
        || !result.final_cost.is_finite()
        || result.final_cost >= result.initial_cost - 1e-10
    {
        for report in &mut result.constraints {
            if report.accepted {
                report.accepted = false;
                report.reason = "pose_graph_correction_rejected".into();
            }
        }
        result.final_cost = result.initial_cost;
        return Ok(result);
    }
    result.optimized = true;
    for (frame, pose) in result.frames.iter_mut().zip(&fitted) {
        frame.optimized_map_from_camera = pose.transform();
    }
    // Preserve the anchor byte for byte, including its original numeric form.
    result.frames[0].optimized_map_from_camera = frames[0].pose;
    Ok(result)
}

fn visual_distance(a: &[f64], b: &[f64]) -> Option<f64> {
    if a.len() != b.len() || a.len() < 48 || !a.len().is_multiple_of(3) {
        return None;
    }
    let variance = |values: &[f64]| {
        let mut means = [0.0; 3];
        for (index, value) in values.iter().enumerate() {
            means[index % 3] += value / (values.len() / 3) as f64;
        }
        values
            .iter()
            .enumerate()
            .map(|(index, x)| (x - means[index % 3]).powi(2))
            .sum::<f64>()
            / values.len() as f64
    };
    // Blank/single-color frames provide no place evidence.
    if variance(a) < 0.005 || variance(b) < 0.005 {
        return None;
    }
    Some((a.iter().zip(b).map(|(a, b)| (a - b).powi(2)).sum::<f64>() / a.len() as f64).sqrt())
}

fn centroid(points: &[Vector3<f64>]) -> Vector3<f64> {
    points
        .iter()
        .fold(Vector3::zeros(), |sum, point| sum + point)
        / points.len() as f64
}

fn nondegenerate(points: &[Vector3<f64>]) -> bool {
    if points.len() < MIN_POINTS {
        return false;
    }
    let center = centroid(points);
    let covariance = points.iter().fold(Matrix3::zeros(), |sum, point| {
        let d = point - center;
        sum + d * d.transpose()
    }) / points.len() as f64;
    let values = covariance.symmetric_eigen().eigenvalues;
    let smallest = values.min();
    let largest = values.max();
    // Require relief in all three directions. A single wall/flat corridor has
    // insufficient geometric evidence to establish an unambiguous revisit.
    largest > 0.015
        && smallest > 0.0025
        && smallest / largest > 0.012
        && normal_direction_coverage(points)
}

fn normal_direction_coverage(points: &[Vector3<f64>]) -> bool {
    // Floor and parallel walls have full-rank point covariance, but cannot
    // observe translation along the corridor. Local PCA normals provide the
    // missing directional test. Weight smooth neighborhoods above corners.
    let mut information = Matrix3::<f64>::zeros();
    let mut count = 0;
    for point in points {
        let mut neighbors: Vec<_> = points
            .iter()
            .map(|q| ((point - q).norm_squared(), *q))
            .collect();
        if neighbors.len() > 12 {
            neighbors.select_nth_unstable_by(11, |a, b| a.0.total_cmp(&b.0));
            neighbors.truncate(12);
        }
        let center =
            neighbors.iter().fold(Vector3::zeros(), |sum, p| sum + p.1) / neighbors.len() as f64;
        let covariance = neighbors.iter().fold(Matrix3::zeros(), |sum, p| {
            let d = p.1 - center;
            sum + d * d.transpose()
        });
        let eigen = covariance.symmetric_eigen();
        let mut order = [0, 1, 2];
        order.sort_by(|&a, &b| eigen.eigenvalues[a].total_cmp(&eigen.eigenvalues[b]));
        let middle = eigen.eigenvalues[order[1]];
        if middle <= 1e-8 {
            continue;
        }
        let normal = eigen.eigenvectors.column(order[0]);
        let weight = (1.0 - (eigen.eigenvalues[order[0]] / middle).clamp(0.0, 1.0)).powi(2);
        information += normal * normal.transpose() * weight;
        count += 1;
    }
    let values = information.symmetric_eigen().eigenvalues;
    count >= MIN_POINTS && values.max() > 1.0 && values.min() / values.max() > 0.025
}

fn nearest(point: Vector3<f64>, cloud: &[Vector3<f64>]) -> (usize, f64) {
    cloud
        .iter()
        .enumerate()
        .map(|(i, q)| (i, (point - q).norm_squared()))
        .min_by(|a, b| a.1.total_cmp(&b.1))
        .unwrap()
}

fn register(
    source: &[Vector3<f64>],
    target: &[Vector3<f64>],
    seed: &Rigid,
) -> Result<Registration, &'static str> {
    if source.len() < MIN_POINTS || target.len() < MIN_POINTS {
        return Err("insufficient_depth_samples");
    }
    if !nondegenerate(source) || !nondegenerate(target) {
        return Err("ambiguous_planar_or_linear_geometry");
    }
    // Centroid translation is measured from depth, and helps recover accumulated
    // translation drift. Both seeds preserve the supplied rotation initially.
    let centered = Rigid {
        rotation: seed.rotation,
        translation: centroid(target) - seed.rotation * centroid(source),
    };
    let mut best: Option<Registration> = None;
    for initial in [seed.clone(), centered] {
        let pose = icp(source, target, initial);
        let delta = seed.inverse().compose(&pose);
        if delta.translation.norm() > 3.2 || delta.rotation.angle() > 0.45 {
            continue;
        }
        let mut matched = Vec::new();
        let mut used = vec![false; target.len()];
        let mut error = 0.0;
        let mut forward = 0;
        for point in source {
            let (index, distance) = nearest(pose.point(*point), target);
            if distance <= 0.10f64.powi(2) {
                forward += 1;
                error += distance;
                if !used[index] {
                    matched.push(target[index]);
                    used[index] = true;
                }
            }
        }
        let inverse = pose.inverse();
        let mut reverse = 0;
        for point in target {
            let (_, distance) = nearest(inverse.point(*point), source);
            if distance <= 0.10f64.powi(2) {
                reverse += 1;
                error += distance;
            }
        }
        let overlap = (forward as f64 / source.len() as f64)
            .min(reverse as f64 / target.len() as f64)
            .min(matched.len() as f64 / target.len() as f64);
        let count = forward + reverse;
        let residual = if count == 0 {
            f64::INFINITY
        } else {
            (error / count as f64).sqrt()
        };
        if overlap >= 0.60
            && residual <= 0.055
            && nondegenerate(&matched)
            && best
                .as_ref()
                .is_none_or(|previous| residual < previous.residual)
        {
            best = Some(Registration {
                measured: pose,
                overlap,
                residual,
            });
        }
    }
    best.ok_or("depth_registration_failed_verification")
}

fn icp(source: &[Vector3<f64>], target: &[Vector3<f64>], mut pose: Rigid) -> Rigid {
    for _ in 0..24 {
        let mut pairs: Vec<_> = source
            .iter()
            .filter_map(|point| {
                let moved = pose.point(*point);
                let (index, distance) = nearest(moved, target);
                (distance <= 0.8f64.powi(2)).then_some((moved, target[index], distance))
            })
            .collect();
        if pairs.len() < MIN_POINTS {
            break;
        }
        pairs.sort_by(|a, b| a.2.total_cmp(&b.2));
        // Trim occlusions and objects that changed between observations.
        pairs.truncate((pairs.len() * 85 / 100).max(MIN_POINTS));
        let a = pairs.iter().fold(Vector3::zeros(), |sum, p| sum + p.0) / pairs.len() as f64;
        let b = pairs.iter().fold(Vector3::zeros(), |sum, p| sum + p.1) / pairs.len() as f64;
        let covariance = pairs.iter().fold(Matrix3::zeros(), |sum, p| {
            sum + (p.0 - a) * (p.1 - b).transpose()
        });
        let svd = covariance.svd(true, true);
        let u = svd.u.unwrap();
        let v = svd.v_t.unwrap().transpose();
        let mut reflection = Matrix3::identity();
        reflection[(2, 2)] = if (v * u.transpose()).determinant() < 0.0 {
            -1.0
        } else {
            1.0
        };
        let rotation = UnitQuaternion::from_rotation_matrix(&Rotation3::from_matrix_unchecked(
            v * reflection * u.transpose(),
        ));
        let delta = Rigid {
            rotation,
            translation: b - rotation * a,
        };
        pose = delta.compose(&pose);
        if delta.translation.norm() < 1e-5 && delta.rotation.angle() < 1e-5 {
            break;
        }
    }
    pose
}

fn residual(edge: &Edge, poses: &[Rigid]) -> nalgebra::SVector<f64, 6> {
    let error = edge
        .measured
        .inverse()
        .compose(&poses[edge.i].inverse().compose(&poses[edge.j]));
    let rotation = error.rotation.scaled_axis() * ROTATION_SCALE;
    nalgebra::SVector::<f64, 6>::new(
        error.translation.x,
        error.translation.y,
        error.translation.z,
        rotation.x,
        rotation.y,
        rotation.z,
    )
}

fn edge_weight(edge: &Edge, residual_norm: f64) -> f64 {
    if edge.is_loop {
        8.0 * (0.12 / residual_norm.max(0.12))
    } else {
        1.0
    }
}

fn cost(poses: &[Rigid], edges: &[Edge]) -> f64 {
    edges
        .iter()
        .map(|edge| {
            let norm = residual(edge, poses).norm();
            if edge.is_loop {
                8.0 * if norm <= 0.12 {
                    0.5 * norm * norm
                } else {
                    0.12 * (norm - 0.06)
                }
            } else {
                0.5 * norm * norm
            }
        })
        .sum()
}

fn optimize(original: &[Rigid], edges: &[Edge]) -> Vec<Rigid> {
    let mut poses = original.to_vec();
    let dimension = (poses.len() - 1) * 6;
    // Finite-difference block Jacobians, IRLS Huber weights for loops, and a
    // damped dense Gauss-Newton solve. Max 64 frames bounds the dense system.
    for _ in 0..16 {
        let mut normal = DMatrix::<f64>::zeros(dimension, dimension);
        let mut gradient = DVector::<f64>::zeros(dimension);
        for edge in edges {
            let r = residual(edge, &poses);
            let weight = edge_weight(edge, r.norm());
            let mut blocks = Vec::new();
            for node in [edge.i, edge.j] {
                if node == 0 {
                    continue;
                }
                let mut jacobian = nalgebra::SMatrix::<f64, 6, 6>::zeros();
                let saved = poses[node].clone();
                for axis in 0..6 {
                    let mut delta = [0.0; 6];
                    delta[axis] = 1e-6;
                    poses[node] = saved.perturb(&delta);
                    jacobian.set_column(axis, &((residual(edge, &poses) - r) / 1e-6));
                }
                poses[node] = saved;
                blocks.push(((node - 1) * 6, jacobian));
            }
            for (offset, j) in &blocks {
                let g = j.transpose() * r * weight;
                for a in 0..6 {
                    gradient[*offset + a] += g[a];
                }
                for (other_offset, other_j) in &blocks {
                    let h = j.transpose() * other_j * weight;
                    for a in 0..6 {
                        for b in 0..6 {
                            normal[(*offset + a, *other_offset + b)] += h[(a, b)];
                        }
                    }
                }
            }
        }
        for diagonal in 0..dimension {
            normal[(diagonal, diagonal)] += 1e-5;
        }
        let Some(cholesky) = normal.cholesky() else {
            break;
        };
        let step = cholesky.solve(&(-gradient));
        if step.iter().any(|x| !x.is_finite()) || step.norm() < 1e-7 {
            break;
        }
        let old_cost = cost(&poses, edges);
        let mut updated = None;
        for scale in [1.0, 0.5, 0.25, 0.125] {
            let mut trial = poses.clone();
            for (node, pose) in trial.iter_mut().enumerate().skip(1) {
                let delta: Vec<_> = step
                    .rows((node - 1) * 6, 6)
                    .iter()
                    .map(|x| x * scale)
                    .collect();
                *pose = pose.perturb(&delta);
            }
            if cost(&trial, edges) < old_cost {
                updated = Some(trial);
                break;
            }
        }
        let Some(next) = updated else {
            break;
        };
        poses = next;
    }
    poses
}

#[cfg(test)]
mod tests {
    use super::*;

    fn textured_signature() -> Vec<f64> {
        (0..192)
            .map(|i| ((i * 47 + 19) % 193) as f64 / 193.0)
            .collect()
    }

    fn cloud() -> Vec<Vec3> {
        // An asymmetric depth-rich room fragment. Reproducible pseudo-random
        // positions avoid the repeated nearest-neighbor minima of a grid.
        let mut state = 42_u64;
        let mut random = || {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
            ((state >> 32) as u32) as f64 / u32::MAX as f64
        };
        (0..180)
            .map(|_| {
                [
                    random() * 2.5 - 1.2,
                    random() * 1.7 - 0.8,
                    -1.0 - random() * 2.0,
                ]
            })
            .collect()
    }

    fn pose(x: f64, yaw: f64) -> Transform {
        Rigid {
            rotation: UnitQuaternion::from_scaled_axis(Vector3::new(0.0, yaw, 0.0)),
            translation: Vector3::new(x, 0.0, 0.0),
        }
        .transform()
    }

    fn loop_frames() -> Vec<AlignmentFrame> {
        let geometry = cloud();
        (0..9)
            .map(|i| {
                let true_x = if i <= 4 {
                    i as f64 * 0.7
                } else {
                    (8 - i) as f64 * 0.7
                };
                let signature = if i == 0 || i == 8 {
                    textured_signature()
                } else {
                    vec![0.4; 192]
                };
                AlignmentFrame {
                    id: format!("f{i}"),
                    timestamp_seconds: i as f64,
                    pose: pose(true_x + i as f64 * 0.055, i as f64 * 0.013),
                    points: if i == 0 || i == 8 {
                        geometry.clone()
                    } else {
                        Vec::new()
                    },
                    visual_signature: signature,
                }
            })
            .collect()
    }

    #[test]
    fn verified_loop_corrects_translation_and_rotation_drift_and_keeps_anchor() {
        let frames = loop_frames();
        let result = align(&frames).unwrap();
        assert!(result.optimized, "{:?}", result.constraints);
        assert!(
            result
                .constraints
                .iter()
                .any(|c| c.accepted && c.overlap > 0.95)
        );
        assert!(result.final_cost < result.initial_cost * 0.1);
        assert_eq!(result.frames[0].optimized_map_from_camera, frames[0].pose);
        let last = Rigid::from(result.frames.last().unwrap().optimized_map_from_camera);
        assert!(last.translation.norm() < 0.04, "{:?}", last.translation);
        assert!(last.rotation.angle() < 0.015, "{}", last.rotation.angle());
        for f in &result.frames {
            f.optimized_map_from_camera.validate().unwrap();
        }
        let correction = result.correction_for(7.5);
        correction.validate().unwrap();
        assert!(Rigid::from(correction).translation.norm() > 0.1);
    }

    #[test]
    fn no_loop_preserves_every_original_pose() {
        let frames: Vec<_> = (0..12)
            .map(|i| AlignmentFrame {
                id: i.to_string(),
                timestamp_seconds: i as f64,
                pose: pose(i as f64, 0.0),
                points: cloud(),
                visual_signature: textured_signature(),
            })
            .collect();
        let result = align(&frames).unwrap();
        assert!(!result.optimized);
        assert!(result.constraints.is_empty());
        for (output, input) in result.frames.iter().zip(frames) {
            assert_eq!(
                output.original_map_from_camera,
                output.optimized_map_from_camera
            );
            assert_eq!(output.optimized_map_from_camera, input.pose);
        }
    }

    #[test]
    fn wall_only_revisit_is_rejected() {
        let mut frames = loop_frames();
        let planar: Vec<Vec3> = (0..100)
            .map(|i| [(i % 10) as f64 * 0.12, (i / 10) as f64 * 0.15, -2.0])
            .collect();
        frames[0].points = planar.clone();
        frames[8].points = planar;
        let result = align(&frames).unwrap();
        assert!(!result.optimized);
        assert_eq!(
            result.constraints[0].reason,
            "ambiguous_planar_or_linear_geometry"
        );
    }

    #[test]
    fn parallel_walls_and_floor_corridor_is_directionally_ambiguous() {
        let mut corridor = Vec::new();
        for z in 0..14 {
            for n in 0..12 {
                let depth = -1.0 - z as f64 * 0.30;
                corridor.push([-1.0, n as f64 * 0.18, depth]);
                corridor.push([1.0, n as f64 * 0.18, depth]);
                corridor.push([-1.0 + n as f64 * 2.0 / 11.0, 0.0, depth]);
            }
        }
        let mut frames = loop_frames();
        frames[0].points = corridor.clone();
        frames[8].points = corridor;
        let result = align(&frames).unwrap();
        assert!(!result.optimized, "{:?}", result.constraints);
        assert_eq!(
            result.constraints[0].reason,
            "ambiguous_planar_or_linear_geometry"
        );
    }

    #[test]
    fn blank_visual_revisit_is_not_place_evidence() {
        let mut frames = loop_frames();
        for signature in [vec![0.4; 192], [0.1, 0.5, 0.9].repeat(64)] {
            frames[0].visual_signature = signature.clone();
            frames[8].visual_signature = signature;
            let result = align(&frames).unwrap();
            assert!(!result.optimized);
            assert!(result.constraints.is_empty());
        }
    }

    #[test]
    fn verified_loop_without_drift_preserves_poses_and_reports_evidence() {
        let mut frames = loop_frames();
        frames[8].pose = frames[0].pose;
        let result = align(&frames).unwrap();
        assert!(!result.optimized);
        assert!(
            result
                .constraints
                .iter()
                .any(|c| c.accepted && c.reason == "verified_loop_already_aligned")
        );
        assert!(
            result
                .frames
                .iter()
                .all(|f| f.original_map_from_camera == f.optimized_map_from_camera)
        );
    }

    #[test]
    fn bounded_registration_budget_includes_final_revisit() {
        let geometry = cloud();
        let planar: Vec<_> = (0..100)
            .map(|i| [(i % 10) as f64 * 0.12, (i / 10) as f64 * 0.15, -2.0])
            .collect();
        let frames: Vec<_> = (0..64)
            .map(|i| {
                let actual_x = if i <= 31 {
                    i as f64 * 0.2
                } else {
                    (63 - i) as f64 * 0.2
                };
                AlignmentFrame {
                    id: format!("f{i}"),
                    timestamp_seconds: i as f64,
                    pose: pose(actual_x + i as f64 * 0.004, i as f64 * 0.001),
                    points: if i == 0 || i == 63 {
                        geometry.clone()
                    } else {
                        planar.clone()
                    },
                    visual_signature: textured_signature(),
                }
            })
            .collect();
        let result = align(&frames).unwrap();
        assert!(result.optimized, "{:?}", result.constraints);
        assert!(
            result
                .constraints
                .iter()
                .any(|c| c.source_frame_id == "f63" && c.target_frame_id == "f0" && c.accepted)
        );
        assert!(result.constraints.len() <= MAX_REGISTRATIONS);
    }

    #[test]
    fn same_rgb_but_incompatible_depth_does_not_change_map() {
        let mut frames = loop_frames();
        frames[8].points = cloud()
            .iter()
            .map(|p| [p[0] * 2.0, p[1] * 0.6, p[2] * 1.7])
            .collect();
        let result = align(&frames).unwrap();
        assert!(!result.optimized, "{:?}", result.constraints);
        assert!(result.constraints.iter().all(|c| !c.accepted));
        assert!(
            result
                .frames
                .iter()
                .all(|f| f.original_map_from_camera == f.optimized_map_from_camera)
        );
    }

    #[test]
    fn matching_rich_alcoves_cannot_collapse_monotonic_forward_traversal() {
        // Exact reviewer fixture: matching appearances and observable geometry
        // at different places must not defeat the original measured movement.
        let geometry = cloud();
        let signature = textured_signature();
        // The short traversal is under the camera correction cap, so its
        // rejection also exercises relative edge strain independently.
        for step in [0.04, 0.2] {
            let frames: Vec<_> = (0..12)
                .map(|i| AlignmentFrame {
                    id: format!("f{i}"),
                    timestamp_seconds: i as f64,
                    pose: pose(i as f64 * step, 0.0),
                    points: if i == 0 || i == 11 {
                        geometry.clone()
                    } else {
                        Vec::new()
                    },
                    visual_signature: if i == 0 || i == 11 {
                        signature.clone()
                    } else {
                        vec![0.4; 192]
                    },
                })
                .collect();
            let result = align(&frames).unwrap();
            assert!(!result.optimized);
            assert_eq!(result.constraints.len(), 1);
            assert!(!result.constraints[0].accepted);
            assert_eq!(
                result.constraints[0].reason,
                "pose_graph_correction_rejected"
            );
            assert!(result.constraints[0].overlap > 0.95);
            assert!(result.constraints[0].residual_meters.unwrap() < 1e-5);
            assert_eq!(result.initial_cost, result.final_cost);
            assert!(
                result
                    .frames
                    .iter()
                    .all(|frame| frame.original_map_from_camera == frame.optimized_map_from_camera)
            );
            assert_eq!(result.frames[0].optimized_map_from_camera, frames[0].pose);
            assert_eq!(
                result.frames[11].optimized_map_from_camera.0[12],
                11.0 * step
            );
        }
    }

    #[test]
    fn six_dof_registration_recovers_arbitrary_rigid_motion_without_reflection() {
        let target: Vec<_> = cloud().into_iter().map(Vector3::from).collect();
        let measured = Rigid {
            rotation: UnitQuaternion::from_scaled_axis(Vector3::new(0.08, -0.10, 0.07)),
            translation: Vector3::new(0.20, -0.08, 0.12),
        };
        let source: Vec<_> = target
            .iter()
            .map(|p| measured.inverse().point(*p))
            .collect();
        let registration = register(&source, &target, &Rigid::identity()).unwrap();
        let error = measured.inverse().compose(&registration.measured);
        assert!(error.translation.norm() < 1e-5);
        assert!(error.rotation.angle() < 1e-5);
        assert!(
            (registration
                .measured
                .rotation
                .to_rotation_matrix()
                .matrix()
                .determinant()
                - 1.0)
                .abs()
                < 1e-10
        );
    }

    #[test]
    fn contradictory_loop_edge_is_robustly_downweighted() {
        let original: Vec<_> = (0..9)
            .map(|i| Rigid::from(pose(i as f64 * 0.5, 0.0)))
            .collect();
        let mut edges: Vec<_> = (1..original.len())
            .map(|j| Edge {
                i: j - 1,
                j,
                measured: original[j - 1].inverse().compose(&original[j]),
                is_loop: false,
                diagnostic: None,
            })
            .collect();
        // Several consistent measured loops and one very large contradictory
        // match test graph robustness separately from the registration gates.
        for (j, original_pose) in original.iter().enumerate().skip(4) {
            edges.push(Edge {
                i: 0,
                j,
                measured: original_pose.clone(),
                is_loop: true,
                diagnostic: None,
            });
        }
        edges.push(Edge {
            i: 0,
            j: 8,
            measured: Rigid::from(pose(-12.0, 1.2)),
            is_loop: true,
            diagnostic: None,
        });
        let fitted = optimize(&original, &edges);
        assert_eq!(fitted[0].transform(), original[0].transform());
        assert!((fitted[8].translation - original[8].translation).norm() < 0.15);
        assert!(fitted[8].rotation.angle() < 0.1);
        assert!(residual(edges.last().unwrap(), &fitted).norm() > 10.0);
    }

    #[test]
    fn invalid_and_unbounded_input_is_rejected() {
        let mut frames = loop_frames();
        frames[1].timestamp_seconds = frames[0].timestamp_seconds;
        assert!(align(&frames).is_err());
        frames[1].timestamp_seconds = 1.0;
        frames[1].points = vec![[0.0, 0.0, -1.0]; MAX_POINTS + 1];
        assert!(align(&frames).is_err());
    }
}
