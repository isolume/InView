//! Local development profiling. Prints geometry counts/timings, never source coordinates.
use inview_backend::capture::ScanBundle;
use inview_backend::display_mesh::{DisplayMeshOptions, simplify_display_mesh};
use meshopt::SimplifyOptions;
use serde::Deserialize;
use std::{collections::HashMap, env, fs, time::Instant};

#[derive(Deserialize)]
struct Input {
    capture: ScanBundle,
}

fn main() {
    let input: Input =
        serde_json::from_slice(&fs::read(env::args().nth(1).expect("result JSON path")).unwrap())
            .unwrap();
    let mesh = &input.capture.meshes[0];
    let vertices: Vec<[f32; 3]> = mesh
        .vertices
        .iter()
        .map(|point| point.map(|v| v as f32))
        .collect();
    let indices: Vec<u32> = mesh
        .triangles
        .iter()
        .flatten()
        .map(|index| u32::try_from(*index).unwrap())
        .collect();
    let scale = meshopt::simplify_scale_decoder(&vertices);
    let mut edges = HashMap::new();
    for face in &mesh.triangles {
        for i in 0..3 {
            let (a, b) = (face[i], face[(i + 1) % 3]);
            *edges.entry((a.min(b), a.max(b))).or_insert(0u32) += 1;
        }
    }
    let mut locks = vec![false; vertices.len()];
    let mut borders = 0;
    for ((a, b), count) in edges {
        if count == 1 {
            locks[a] = true;
            locks[b] = true;
            borders += 1;
        }
    }
    println!(
        "source_vertices={} source_triangles={} boundary_edges={} boundary_vertices={}",
        vertices.len(),
        indices.len() / 3,
        borders,
        locks.iter().filter(|v| **v).count()
    );
    for (name, options) in [
        ("strict", SimplifyOptions::ErrorAbsolute),
        (
            "strict_locked_borders",
            SimplifyOptions::ErrorAbsolute | SimplifyOptions::LockBorder,
        ),
    ] {
        let started = Instant::now();
        let mut error = 0.;
        let result = meshopt::simplify_decoder(
            &indices,
            &vertices,
            150_000,
            0.05,
            options,
            Some(&mut error),
        );
        println!(
            "method={name} triangles={} seconds={:.3} error_meters={error}",
            result.len() / 3,
            started.elapsed().as_secs_f64()
        );
    }
    for (name, vertex_locks) in [
        ("cluster", vec![false; vertices.len()]),
        ("cluster_locked_borders", locks),
    ] {
        let started = Instant::now();
        let mut error = 0.;
        let result = meshopt::simplify_sloppy_with_locks_decoder(
            &indices,
            &vertices,
            &vertex_locks,
            150_000,
            0.05 / scale,
            Some(&mut error),
        );
        println!(
            "method={name} triangles={} seconds={:.3} error_meters={}",
            result.len() / 3,
            started.elapsed().as_secs_f64(),
            error * scale
        );
    }
    for tolerance in [0.1, 0.15, 0.2] {
        let started = Instant::now();
        let mut error = 0.;
        let result = meshopt::simplify_decoder(
            &indices,
            &vertices,
            150_000,
            tolerance,
            SimplifyOptions::ErrorAbsolute,
            Some(&mut error),
        );
        println!(
            "method=strict_tolerance tolerance={tolerance} triangles={} seconds={:.3} error_meters={error}",
            result.len() / 3,
            started.elapsed().as_secs_f64()
        );
    }
    for cluster_error in [0.05, 0.1, 0.15, 0.2] {
        let started = Instant::now();
        let mut error = 0.;
        let clustered = meshopt::simplify_sloppy_decoder(
            &indices,
            &vertices,
            150_000,
            cluster_error / scale,
            Some(&mut error),
        );
        let mut strict_error = 0.;
        let result = meshopt::simplify_decoder(
            &clustered,
            &vertices,
            150_000,
            0.05,
            SimplifyOptions::ErrorAbsolute,
            Some(&mut strict_error),
        );
        println!(
            "method=cluster_then_strict clustering_tolerance={cluster_error} triangles={} seconds={:.3} error_meters={}",
            result.len() / 3,
            started.elapsed().as_secs_f64(),
            error * scale + strict_error
        );
    }
    for error_limit in [0.1, 0.15, 0.2] {
        let started = Instant::now();
        let (_, report) = simplify_display_mesh(
            mesh.clone(),
            DisplayMeshOptions {
                max_error_meters: error_limit,
                ..Default::default()
            },
        )
        .unwrap();
        println!(
            "protected_display_seconds={:.3} report={}",
            started.elapsed().as_secs_f64(),
            serde_json::to_string(&report).unwrap()
        );
    }
}
