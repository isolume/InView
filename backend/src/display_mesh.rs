//! Display-only reduction. Navigation surfaces, obstacle measurements and raw capture
//! observations must remain separate from this approximate rendering mesh.
use std::collections::{BTreeMap, HashMap};

use meshopt::SimplifyOptions;
use serde::Serialize;

use crate::capture::MeshCapture;

#[derive(Clone, Copy, Debug)]
pub struct DisplayMeshOptions {
    /// A soft rendering target, never a scan acceptance limit.
    pub target_triangles: usize,
    /// Maximum combined estimated simplification error, in the mesh's meter units.
    pub max_error_meters: f32,
}
impl Default for DisplayMeshOptions {
    fn default() -> Self {
        Self {
            target_triangles: 50_000,
            max_error_meters: 0.20,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct DisplayMeshReport {
    pub source_vertex_count: usize,
    pub source_triangle_count: usize,
    pub display_vertex_count: usize,
    pub display_triangle_count: usize,
    pub target_triangle_count: usize,
    pub error_limit_meters: f32,
    pub estimated_error_meters: f32,
    pub preserved_component_count: usize,
    pub protected_boundary_vertex_count: usize,
    pub spatial_cleanup_used: bool,
    pub method: &'static str,
}

/// Prefer topology-preserving QEM. Overlapping depth observations often create
/// nonmanifold edges that prevent QEM from making useful progress; in that case
/// try spatial cleanup followed by QEM, using the smallest useful cleanup scale.
/// Each connected region is processed separately and retained, large closed border
/// loops are protected, and output positions are exact original measured values.
/// The error is a rendering estimate, not an accessibility/clearance guarantee.
pub fn simplify_display_mesh(
    mesh: MeshCapture,
    options: DisplayMeshOptions,
) -> Result<(MeshCapture, DisplayMeshReport), String> {
    if options.target_triangles == 0
        || !options.max_error_meters.is_finite()
        || options.max_error_meters <= 0.
    {
        return Err(
            "Display simplification needs a positive target and finite meter error.".into(),
        );
    }
    if mesh
        .vertices
        .iter()
        .flatten()
        .any(|value| !value.is_finite())
        || mesh
            .triangles
            .iter()
            .flatten()
            .any(|index| *index >= mesh.vertices.len())
    {
        return Err(
            "Display simplification needs finite vertices and valid triangle indices.".into(),
        );
    }
    let mut report = DisplayMeshReport {
        source_vertex_count: mesh.vertices.len(),
        source_triangle_count: mesh.triangles.len(),
        display_vertex_count: mesh.vertices.len(),
        display_triangle_count: mesh.triangles.len(),
        target_triangle_count: options.target_triangles,
        error_limit_meters: options.max_error_meters,
        estimated_error_meters: 0.,
        preserved_component_count: 0,
        protected_boundary_vertex_count: 0,
        spatial_cleanup_used: false,
        method: "unchanged",
    };
    // Per-face classes cannot be assigned to new QEM triangles without a separate
    // semantic remapping step. The fused continuous mesh has no such classifications.
    if mesh.triangles.len() <= options.target_triangles
        || mesh.classifications.is_some()
        || mesh.vertices.len() > u32::MAX as usize
    {
        return Ok((mesh, report));
    }
    let components = connected_components(&mesh);
    let mut vertices = Vec::new();
    let mut triangles = Vec::new();
    for face_ids in components.values() {
        let mut source_vertices = Vec::new();
        let mut lookup = HashMap::new();
        let mut indices = Vec::with_capacity(face_ids.len() * 3);
        for &face_id in face_ids {
            for &source_id in &mesh.triangles[face_id] {
                let local = *lookup.entry(source_id).or_insert_with(|| {
                    let local = source_vertices.len() as u32;
                    source_vertices.push(source_id);
                    local
                });
                indices.push(local);
            }
        }
        // Translate only the temporary float analysis coordinates, avoiding precision
        // loss far from the map origin. Returned positions retain the original f64s.
        let origin = mesh.vertices[source_vertices[0]];
        let positions: Vec<[f32; 3]> = source_vertices
            .iter()
            .map(|&index| {
                std::array::from_fn(|axis| (mesh.vertices[index][axis] - origin[axis]) as f32)
            })
            .collect();
        let target = ((face_ids.len() as f64 * options.target_triangles as f64
            / mesh.triangles.len() as f64)
            .round() as usize)
            .max(4)
            .min(face_ids.len());
        let (reduced, error, cleanup, border_locks) =
            if positions.iter().flatten().all(|value| value.is_finite()) {
                simplify_component(&indices, &positions, target, options.max_error_meters)
            } else {
                (indices.clone(), 0., false, 0)
            };
        report.estimated_error_meters = report.estimated_error_meters.max(error);
        report.spatial_cleanup_used |= cleanup;
        report.protected_boundary_vertex_count += border_locks;
        report.preserved_component_count += 1;
        // Compact referenced vertices deterministically, without averaging or moving them.
        let mut remap = vec![usize::MAX; source_vertices.len()];
        for face in reduced.chunks_exact(3) {
            let triangle = std::array::from_fn(|axis| {
                let local = face[axis] as usize;
                if remap[local] == usize::MAX {
                    remap[local] = vertices.len();
                    vertices.push(mesh.vertices[source_vertices[local]]);
                }
                remap[local]
            });
            triangles.push(triangle);
        }
    }
    report.display_vertex_count = vertices.len();
    report.display_triangle_count = triangles.len();
    report.method = if report.spatial_cleanup_used {
        "meshoptimizer_spatial_cleanup_qem"
    } else {
        "meshoptimizer_qem"
    };
    Ok((
        MeshCapture {
            id: mesh.id,
            map_from_anchor: mesh.map_from_anchor,
            vertices,
            triangles,
            classifications: mesh.classifications,
        },
        report,
    ))
}

fn simplify_component(
    indices: &[u32],
    positions: &[[f32; 3]],
    target: usize,
    limit: f32,
) -> (Vec<u32>, f32, bool, usize) {
    if indices.len() / 3 <= target {
        return (indices.to_vec(), 0., false, 0);
    }
    let (locks, border_count) = important_border_locks(indices, positions);
    let mut error = 0.;
    let mut best = meshopt::simplify_with_locks_decoder(
        indices,
        positions,
        &locks,
        target * 3,
        limit.min(0.05),
        SimplifyOptions::ErrorAbsolute,
        Some(&mut error),
    );
    if best.is_empty() {
        best = indices.to_vec();
        error = 0.;
    }
    let mut cleanup = false;
    if best.len() / 3 <= target {
        return (best, error, cleanup, border_count);
    }
    let scale = meshopt::simplify_scale_decoder(positions);
    if !scale.is_finite() || scale <= 0. {
        return (best, error, cleanup, border_count);
    }
    for fraction in [0.25, 0.5, 0.75, 1.] {
        let mut cluster_error = 0.;
        let clustered = meshopt::simplify_sloppy_with_locks_decoder(
            indices,
            positions,
            &locks,
            target * 3,
            limit * fraction / scale,
            Some(&mut cluster_error),
        );
        cluster_error *= scale;
        if clustered.is_empty() || !cluster_error.is_finite() || cluster_error >= limit {
            continue;
        }
        let mut qem_error = 0.;
        let candidate = meshopt::simplify_with_locks_decoder(
            &clustered,
            positions,
            &locks,
            target.min(clustered.len() / 3) * 3,
            (limit - cluster_error).min(0.05),
            SimplifyOptions::ErrorAbsolute,
            Some(&mut qem_error),
        );
        let combined_error = cluster_error + qem_error;
        if !candidate.is_empty() && candidate.len() < best.len() && combined_error <= limit {
            best = candidate;
            error = combined_error;
            cleanup = true;
        }
        // Accept a small overshoot rather than using more approximation for an exact budget.
        if best.len() / 3 <= target.saturating_mul(5) / 4 {
            break;
        }
    }
    (best, error, cleanup, border_count)
}

fn connected_components(mesh: &MeshCapture) -> BTreeMap<usize, Vec<usize>> {
    let mut parents: Vec<usize> = (0..mesh.vertices.len()).collect();
    for face in &mesh.triangles {
        for &index in &face[1..] {
            let a = find_root(&mut parents, face[0]);
            let b = find_root(&mut parents, index);
            parents[a.max(b)] = a.min(b);
        }
    }
    let mut components = BTreeMap::<usize, Vec<usize>>::new();
    for (index, face) in mesh.triangles.iter().enumerate() {
        components
            .entry(find_root(&mut parents, face[0]))
            .or_default()
            .push(index);
    }
    components
}

fn find_root(parents: &mut [usize], mut index: usize) -> usize {
    while parents[index] != index {
        parents[index] = parents[parents[index]];
        index = parents[index];
    }
    index
}

/// Protect complete, substantial opening/outline loops, not every tiny jagged
/// border caused by partial overlapping depth triangles. Branching/ambiguous border
/// fragments remain subject to the stated display tolerance. Extent anchors retain
/// each region's outer reach even when its border is fragmented.
fn important_border_locks(indices: &[u32], positions: &[[f32; 3]]) -> (Vec<bool>, usize) {
    let mut edges = HashMap::<[u32; 2], u32>::new();
    for face in indices.chunks_exact(3) {
        for i in 0..3 {
            let (a, b) = (face[i], face[(i + 1) % 3]);
            *edges.entry([a.min(b), a.max(b)]).or_default() += 1;
        }
    }
    let mut neighbors = vec![[u32::MAX; 2]; positions.len()];
    let mut degree = vec![0usize; positions.len()];
    for (edge, count) in edges {
        if count != 1 {
            continue;
        }
        for (a, b) in [(edge[0], edge[1]), (edge[1], edge[0])] {
            let a = a as usize;
            if degree[a] < 2 {
                neighbors[a][degree[a]] = b;
            }
            degree[a] += 1;
        }
    }
    let mut locks = vec![false; positions.len()];
    let mut visited = vec![false; positions.len()];
    for start in 0..positions.len() {
        if visited[start] || degree[start] != 2 {
            continue;
        }
        let mut path = Vec::new();
        let (mut previous, mut current) = (usize::MAX, start);
        let mut closed = false;
        while degree[current] == 2 && !visited[current] {
            visited[current] = true;
            path.push(current);
            let next = neighbors[current]
                .iter()
                .copied()
                .filter(|v| *v as usize != previous)
                .min()
                .unwrap() as usize;
            previous = current;
            current = next;
            if current == start {
                closed = true;
                break;
            }
        }
        if !closed || path.len() < 3 {
            continue;
        }
        let mut minimum = [f32::INFINITY; 3];
        let mut maximum = [f32::NEG_INFINITY; 3];
        let mut perimeter = 0f32;
        for (index, &vertex) in path.iter().enumerate() {
            for axis in 0..3 {
                minimum[axis] = minimum[axis].min(positions[vertex][axis]);
                maximum[axis] = maximum[axis].max(positions[vertex][axis]);
            }
            let next = path[(index + 1) % path.len()];
            perimeter += (0..3)
                .map(|axis| (positions[vertex][axis] - positions[next][axis]).powi(2))
                .sum::<f32>()
                .sqrt();
        }
        if perimeter >= 1.0 && (0..3).any(|axis| maximum[axis] - minimum[axis] >= 0.3) {
            for vertex in path {
                locks[vertex] = true;
            }
        }
    }
    let border_count = locks.iter().filter(|v| **v).count();
    for axis in 0..3 {
        let mut min = 0;
        let mut max = 0;
        for index in 1..positions.len() {
            if positions[index][axis] < positions[min][axis] {
                min = index;
            }
            if positions[index][axis] > positions[max][axis] {
                max = index;
            }
        }
        locks[min] = true;
        locks[max] = true;
    }
    for &index in &indices[..3] {
        locks[index as usize] = true;
    }
    (locks, border_count)
}
