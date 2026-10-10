use std::collections::HashSet;

use inview_backend::{
    capture::MeshCapture,
    display_mesh::{DisplayMeshOptions, simplify_display_mesh},
    geometry::Transform,
};

const IDENTITY: [f64; 16] = [
    1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
];

fn grid(size: usize, hole: Option<(usize, usize)>, overlapping: bool) -> MeshCapture {
    let vertices = (0..size)
        .flat_map(|row| (0..size).map(move |col| [col as f64 * 0.05, row as f64 * 0.05, 0.]))
        .collect();
    let mut triangles = Vec::new();
    for row in 0..size - 1 {
        for col in 0..size - 1 {
            if hole.is_some_and(|(a, b)| row >= a && row < b && col >= a && col < b) {
                continue;
            }
            let a = row * size + col;
            triangles.extend([[a, a + size, a + 1], [a + 1, a + size, a + size + 1]]);
            if overlapping {
                triangles.extend([[a, a + size + 1, a + 1], [a, a + size, a + size + 1]]);
            }
        }
    }
    MeshCapture {
        id: "measured-display".into(),
        map_from_anchor: Transform(IDENTITY),
        vertices,
        triangles,
        classifications: None,
    }
}

fn options(target: usize) -> DisplayMeshOptions {
    DisplayMeshOptions {
        target_triangles: target,
        ..Default::default()
    }
}

fn covers_xy(mesh: &MeshCapture, point: [f64; 2]) -> bool {
    mesh.triangles.iter().any(|face| {
        let points = face.map(|index| mesh.vertices[index]);
        let signs = std::array::from_fn::<_, 3, _>(|i| {
            let (a, b) = (points[i], points[(i + 1) % 3]);
            (b[0] - a[0]) * (point[1] - a[1]) - (b[1] - a[1]) * (point[0] - a[0])
        });
        signs.iter().all(|v| *v >= -1e-10) || signs.iter().all(|v| *v <= 1e-10)
    })
}

#[test]
fn dense_planar_surface_reduces_while_preserving_measurements_and_coverage() {
    let original = grid(121, None, false);
    let source: HashSet<_> = original
        .vertices
        .iter()
        .map(|point| point.map(f64::to_bits))
        .collect();
    let (display, report) = simplify_display_mesh(original.clone(), options(2_000)).unwrap();
    assert!(display.triangles.len() < original.triangles.len() / 5);
    assert!(display.vertices.len() < original.vertices.len() / 5);
    assert_eq!(display.id, original.id);
    assert_eq!(display.map_from_anchor.0, original.map_from_anchor.0);
    assert!(
        display
            .vertices
            .iter()
            .all(|point| source.contains(&point.map(f64::to_bits)))
    );
    assert!(
        display
            .vertices
            .iter()
            .flatten()
            .all(|value| value.is_finite())
    );
    assert!(report.estimated_error_meters <= report.error_limit_meters);
    for point in [[0.025, 0.025], [3., 3.], [5.975, 5.975]] {
        assert!(covers_xy(&display, point), "{point:?}");
    }
    let used: HashSet<_> = display.triangles.iter().flatten().copied().collect();
    assert_eq!(used.len(), display.vertices.len());
}

#[test]
fn confidence_hole_and_large_opening_remain_unfilled() {
    let original = grid(121, Some((40, 80)), true);
    let (display, report) = simplify_display_mesh(original.clone(), options(2_000)).unwrap();
    assert!(display.triangles.len() < original.triangles.len() / 5);
    assert!(report.estimated_error_meters <= 0.20);
    for x in [2.25, 3., 3.75] {
        for y in [2.25, 3., 3.75] {
            assert!(!covers_xy(&display, [x, y]), "hole filled at{x},{y}");
        }
    }
    for point in [[1., 3.], [5., 3.], [3., 1.], [3., 5.]] {
        assert!(
            covers_xy(&display, point),
            "surrounding surface lost:{point:?}"
        );
    }
}

#[test]
fn disconnected_distant_regions_and_small_island_are_all_retained() {
    let mut original = grid(61, None, false);
    let remote = grid(61, None, false);
    let offset = original.vertices.len();
    original.vertices.extend(
        remote
            .vertices
            .iter()
            .map(|point| [point[0] + 100., point[1], point[2]]),
    );
    original.triangles.extend(
        remote
            .triangles
            .iter()
            .map(|face| face.map(|index| index + offset)),
    );
    let island = original.vertices.len();
    original
        .vertices
        .extend([[400., 0., 0.], [400.1, 0., 0.], [400., 0.1, 0.]]);
    original.triangles.push([island, island + 1, island + 2]);
    let (display, report) = simplify_display_mesh(original, options(1_000)).unwrap();
    assert_eq!(report.preserved_component_count, 3);
    for region in [0., 100., 400.] {
        assert!(
            display.triangles.iter().any(|face| face
                .iter()
                .all(|index| (region..region + 3.1).contains(&display.vertices[*index][0]))),
            "missing region{region}"
        );
    }
    assert!(display.triangles.iter().all(|face| {
        let xs = face.map(|index| display.vertices[index][0]);
        xs.iter().copied().fold(f64::NEG_INFINITY, f64::max)
            - xs.iter().copied().fold(f64::INFINITY, f64::min)
            < 4.
    }));
}

#[test]
fn nonmanifold_overlap_uses_spatial_cleanup_and_is_deterministic() {
    let mut original = grid(101, None, true);
    // Independent depth observations leave sub-decimeter disagreement after
    // welding. This stops strict QEM while spatial cleanup can reduce the noise.
    for (index, vertex) in original.vertices.iter_mut().enumerate() {
        vertex[2] = if (index / 101 + index % 101) % 2 == 0 {
            0.06
        } else {
            -0.06
        };
    }
    let (first, first_report) = simplify_display_mesh(original.clone(), options(1_000)).unwrap();
    let (second, second_report) = simplify_display_mesh(original.clone(), options(1_000)).unwrap();
    assert!(first_report.spatial_cleanup_used);
    assert!(first.triangles.len() < original.triangles.len() / 5);
    assert_eq!(
        serde_json::to_value(first).unwrap(),
        serde_json::to_value(second).unwrap()
    );
    assert_eq!(
        serde_json::to_value(first_report).unwrap(),
        serde_json::to_value(second_report).unwrap()
    );
}

#[test]
fn small_mesh_and_classified_geometry_remain_exactly_unchanged() {
    let small = grid(4, None, false);
    let (display, report) =
        simplify_display_mesh(small.clone(), DisplayMeshOptions::default()).unwrap();
    assert_eq!(
        serde_json::to_value(display).unwrap(),
        serde_json::to_value(small).unwrap()
    );
    assert_eq!(report.method, "unchanged");
    let mut classified = grid(21, None, false);
    classified.classifications = Some(vec!["floor".into(); classified.triangles.len()]);
    let (display, _) = simplify_display_mesh(classified.clone(), options(10)).unwrap();
    assert_eq!(
        serde_json::to_value(display).unwrap(),
        serde_json::to_value(classified).unwrap()
    );
}

#[test]
fn invalid_indices_and_nonfinite_coordinates_never_reach_native_simplifier() {
    let mut invalid = grid(4, None, false);
    invalid.triangles[0][0] = invalid.vertices.len();
    assert!(simplify_display_mesh(invalid, options(1)).is_err());
    let mut nonfinite = grid(4, None, false);
    nonfinite.vertices[0][0] = f64::NAN;
    assert!(simplify_display_mesh(nonfinite, options(1)).is_err());
}
