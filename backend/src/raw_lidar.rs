//! Native ARKit depth and mesh evidence from the combined `.inviewscan.tar` package.
//! Current iPhone packages index exact binary sidecars in `package-manifest.json`; older ones
//! embed the same buffers as base64 in `raw-snapshot.json`. Both read original float32 buffers
//! with their *actual* row strides. Positions remain in the shared scan frame.
use std::{
    borrow::Cow,
    collections::{BTreeMap, HashSet},
};

use axum::{
    Json,
    body::Bytes,
    extract::{Path, Query, State},
    http::{StatusCode, header},
    response::IntoResponse,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};

use crate::{AppState, error::ApiError, geometry::Transform, scan_package, store::StoredScan};

const FLOAT32_DEPTH: u32 = 1_717_855_600; // CoreVideo kCVPixelFormatType_DepthFloat32 ('fdep')
const MAX_POINTS: usize = 150_000;
/// Continuous scans retain a bounded selection spanning the walk, including OCR keyframes.
const MAX_DEPTH_OBSERVATIONS: usize = crate::stream_scan::MAX_OBSERVATIONS;
const MAX_MESH_ANCHORS: usize = 2048;

type Assets = BTreeMap<String, Vec<u8>>;

/// Legacy `raw-snapshot.json` layout (camelCase, base64 buffers).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    #[serde(default)]
    depth_buffers: Vec<SnapshotDepth>,
    #[serde(default)]
    mesh_buffers: Vec<SnapshotMesh>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotDepth {
    id: String,
    width: usize,
    height: usize,
    bytes_per_row: usize,
    pixel_format: u32,
    depth: String,
    confidence_bytes_per_row: Option<usize>,
    confidence: Option<String>,
    smoothed_width: Option<usize>,
    smoothed_height: Option<usize>,
    smoothed_bytes_per_row: Option<usize>,
    smoothed_pixel_format: Option<u32>,
    smoothed_depth: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotMesh {
    id: String,
    map_from_anchor: Transform,
    vertices: String,
    vertex_offset: usize,
    vertex_stride: usize,
    vertex_count: usize,
    faces: String,
    bytes_per_index: usize,
    face_count: usize,
    indices_per_face: usize,
}

/// Calibrated pinhole camera and pose for one depth observation.
#[derive(Clone, Copy)]
struct Camera {
    map_from_camera: Transform,
    image_width: f64,
    image_height: f64,
    fx: f64,
    fy: f64,
    cx: f64,
    cy: f64,
}
struct Plane<'a> {
    width: usize,
    height: usize,
    bytes_per_row: usize,
    pixel_format: u32,
    bytes: Cow<'a, [u8]>,
}
struct DepthSource<'a> {
    id: String,
    camera: Camera,
    color_asset: Option<String>,
    depth: Plane<'a>,
    confidence: Option<(usize, Cow<'a, [u8]>)>,
    smoothed: Option<Plane<'a>>,
}
struct MeshSource<'a> {
    id: String,
    map_from_anchor: Transform,
    vertices: Cow<'a, [u8]>,
    vertex_offset: usize,
    vertex_stride: usize,
    vertex_count: usize,
    faces: Cow<'a, [u8]>,
    bytes_per_index: usize,
    face_count: usize,
    indices_per_face: usize,
}
struct NativeSources<'a> {
    format: &'static str,
    depth: Vec<DepthSource<'a>>,
    meshes: Vec<MeshSource<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MeshPreview {
    source: &'static str,
    /// `binary_sidecars` (manifest-indexed) or `legacy_raw_snapshot` (base64 JSON).
    package_format: &'static str,
    vertex_count: usize,
    triangle_count: usize,
    meshes: Vec<MeshAnchor>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MeshAnchor {
    source_id: String,
    vertices: Vec<[f32; 3]>,
    triangles: Vec<[u32; 3]>,
}
#[derive(Deserialize)]
pub struct PreviewQuery {
    mode: Option<String>,
    max_points: Option<usize>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Preview {
    source: &'static str,
    package_format: &'static str,
    mode: &'static str,
    point_count: usize,
    frames: Vec<PreviewFrame>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PreviewFrame {
    id: String,
    width: usize,
    height: usize,
    sample_stride: usize,
    used_smoothed: bool,
    confidence_available: bool,
    color_asset: Option<String>,
    /// World x/y/z in meters; u/v normalized *sensor-native*, not portrait JPEG orientation.
    points: Vec<[f32; 5]>,
}
fn error(code: &'static str, message: impl Into<String>, status: StatusCode) -> ApiError {
    ApiError::new(status, code, message)
}
fn check_plane(plane: &Plane, bytes_per_pixel: usize, format: Option<u32>) -> Result<(), String> {
    if format.is_some_and(|expected| plane.pixel_format != expected)
        || plane.width == 0
        || plane.height == 0
        || plane.width > 1024
        || plane.height > 1024
        || plane.bytes_per_row < plane.width * bytes_per_pixel
        || plane.bytes_per_row > 8192
    {
        return Err("Native depth layout or pixel format is unsupported.".into());
    }
    if plane.bytes.len() != plane.bytes_per_row * plane.height {
        return Err("Native depth row stride does not match the captured bytes.".into());
    }
    Ok(())
}

fn base64(encoded: &str, what: &str) -> Result<Cow<'static, [u8]>, String> {
    STANDARD
        .decode(encoded)
        .map(Cow::Owned)
        .map_err(|_| format!("Invalid native {what} bytes."))
}

fn sidecar<'a>(assets: &'a Assets, name: &str) -> Result<Cow<'a, [u8]>, String> {
    assets
        .get(name)
        .map(|bytes| Cow::Borrowed(bytes.as_slice()))
        .ok_or_else(|| format!("Native LiDAR sidecar {name} is missing."))
}

fn portable_camera(scan: &StoredScan, id: &str) -> Option<(Camera, Option<String>)> {
    scan.bundle.frames.iter().find(|f| f.id == id).map(|f| {
        (
            Camera {
                map_from_camera: f.map_from_camera,
                image_width: f.camera.image_width as f64,
                image_height: f.camera.image_height as f64,
                fx: f.camera.fx,
                fy: f.camera.fy,
                cx: f.camera.cx,
                cy: f.camera.cy,
            },
            f.color_asset.clone(),
        )
    })
}

/// Prefer manifest-indexed binary sidecars; fall back to the base64 snapshot of older packages.
fn native_sources(scan: &StoredScan) -> Result<NativeSources<'_>, String> {
    let assets = scan
        .package_assets
        .as_ref()
        .ok_or("This scan has no native LiDAR package.")?;
    let manifest = scan
        .package_manifest
        .as_ref()
        .map(scan_package::parse_manifest)
        .transpose()?;
    if let Some(manifest) = manifest.filter(|m| {
        !m.mesh_anchors.is_empty() || m.observations.iter().any(|o| o.raw_depth.is_some())
    }) {
        return sidecar_sources(scan, assets, manifest);
    }
    let bytes = assets
        .get("raw-snapshot.json")
        .ok_or("This scan has no native LiDAR snapshot.")?;
    let snapshot: Snapshot =
        serde_json::from_slice(bytes).map_err(|_| "Native LiDAR snapshot is invalid.")?;
    let mut depth = Vec::with_capacity(snapshot.depth_buffers.len());
    for native in snapshot.depth_buffers {
        let (camera, color_asset) = portable_camera(scan, &native.id)
            .ok_or("Native depth refers to an unknown capture frame.")?;
        let smoothed = match native.smoothed_depth {
            Some(encoded) => Some(Plane {
                width: native
                    .smoothed_width
                    .ok_or("Missing smoothed depth width.")?,
                height: native
                    .smoothed_height
                    .ok_or("Missing smoothed depth height.")?,
                bytes_per_row: native
                    .smoothed_bytes_per_row
                    .ok_or("Missing smoothed depth stride.")?,
                pixel_format: native
                    .smoothed_pixel_format
                    .ok_or("Missing smoothed depth format.")?,
                bytes: base64(&encoded, "smoothed depth")?,
            }),
            None => None,
        };
        let confidence = match native.confidence {
            Some(encoded) => Some((
                native
                    .confidence_bytes_per_row
                    .ok_or("Missing native confidence stride.")?,
                base64(&encoded, "confidence")?,
            )),
            None => None,
        };
        depth.push(DepthSource {
            id: native.id,
            camera,
            color_asset,
            depth: Plane {
                width: native.width,
                height: native.height,
                bytes_per_row: native.bytes_per_row,
                pixel_format: native.pixel_format,
                bytes: base64(&native.depth, "depth")?,
            },
            confidence,
            smoothed,
        });
    }
    let mut meshes = Vec::with_capacity(snapshot.mesh_buffers.len());
    for mesh in snapshot.mesh_buffers {
        meshes.push(MeshSource {
            vertices: base64(&mesh.vertices, "mesh vertex")?,
            faces: base64(&mesh.faces, "mesh index")?,
            id: mesh.id,
            map_from_anchor: mesh.map_from_anchor,
            vertex_offset: mesh.vertex_offset,
            vertex_stride: mesh.vertex_stride,
            vertex_count: mesh.vertex_count,
            bytes_per_index: mesh.bytes_per_index,
            face_count: mesh.face_count,
            indices_per_face: mesh.indices_per_face,
        });
    }
    Ok(NativeSources {
        format: "legacy_raw_snapshot",
        depth,
        meshes,
    })
}

fn sidecar_sources<'a>(
    scan: &'a StoredScan,
    assets: &'a Assets,
    manifest: scan_package::PackageManifest,
) -> Result<NativeSources<'a>, String> {
    let mut depth = Vec::new();
    for observation in manifest.observations {
        let Some(native) = observation.raw_depth else {
            continue;
        };
        let portable = portable_camera(scan, &observation.id);
        let camera = match (observation.map_from_camera, observation.image) {
            (Some(map_from_camera), Some(image)) => Camera {
                map_from_camera,
                image_width: image.width as f64,
                image_height: image.height as f64,
                fx: image.fx,
                fy: image.fy,
                cx: image.cx,
                cy: image.cy,
            },
            _ => portable
                .as_ref()
                .map(|(camera, _)| *camera)
                .ok_or("Native depth has no calibrated camera pose.")?,
        };
        let smoothed = match &native.smoothed_asset {
            Some(name) => Some(Plane {
                width: native
                    .smoothed_width
                    .ok_or("Missing smoothed depth width.")?,
                height: native
                    .smoothed_height
                    .ok_or("Missing smoothed depth height.")?,
                bytes_per_row: native
                    .smoothed_bytes_per_row
                    .ok_or("Missing smoothed depth stride.")?,
                pixel_format: native
                    .smoothed_pixel_format
                    .ok_or("Missing smoothed depth format.")?,
                bytes: sidecar(assets, name)?,
            }),
            None => None,
        };
        let confidence = match &native.confidence_asset {
            Some(name) => Some((
                native
                    .confidence_bytes_per_row
                    .ok_or("Missing native confidence stride.")?,
                sidecar(assets, name)?,
            )),
            None => None,
        };
        depth.push(DepthSource {
            color_asset: observation
                .rgb_asset
                .or_else(|| portable.and_then(|(_, color)| color)),
            id: observation.id,
            camera,
            depth: Plane {
                width: native.width,
                height: native.height,
                bytes_per_row: native.bytes_per_row,
                pixel_format: native.pixel_format,
                bytes: sidecar(assets, &native.raw_asset)?,
            },
            confidence,
            smoothed,
        });
    }
    let mut meshes = Vec::with_capacity(manifest.mesh_anchors.len());
    for mesh in manifest.mesh_anchors {
        meshes.push(MeshSource {
            vertices: sidecar(assets, &mesh.vertices_asset)?,
            faces: sidecar(assets, &mesh.faces_asset)?,
            id: mesh.id,
            map_from_anchor: mesh.map_from_anchor,
            vertex_offset: mesh.vertex_offset,
            vertex_stride: mesh.vertex_stride,
            vertex_count: mesh.vertex_count,
            bytes_per_index: mesh.bytes_per_index,
            face_count: mesh.face_count,
            indices_per_face: mesh.indices_per_face,
        });
    }
    Ok(NativeSources {
        format: "binary_sidecars",
        depth,
        meshes,
    })
}

fn point_cloud(
    sources: NativeSources,
    mode: &str,
    budget: usize,
    assets: &Assets,
) -> Result<Preview, String> {
    if sources.depth.is_empty() {
        return Err("This package has no native depth observations.".into());
    }
    if sources.depth.len() > MAX_DEPTH_OBSERVATIONS {
        return Err("Too many native depth buffers.".into());
    }
    let total = sources
        .depth
        .iter()
        .try_fold(0usize, |sum, f| {
            let plane = f.smoothed.as_ref().unwrap_or(&f.depth);
            sum.checked_add(plane.width.checked_mul(plane.height)?)
        })
        .ok_or("Native depth dimensions overflow.")?;
    let step = ((total as f64 / budget as f64).sqrt().ceil() as usize).max(1);
    let mut output = Vec::new();
    let mut point_count = 0;
    for native in sources.depth {
        check_plane(&native.depth, 4, Some(FLOAT32_DEPTH))?;
        if let Some(plane) = &native.smoothed {
            check_plane(plane, 4, Some(FLOAT32_DEPTH))?;
        }
        if let Some((row, conf)) = &native.confidence
            && (*row < native.depth.width || *row > 8192 || conf.len() != row * native.depth.height)
        {
            return Err("Invalid native confidence layout.".into());
        }
        let smooth = mode == "smoothed" && native.smoothed.is_some();
        let plane = if smooth {
            native.smoothed.as_ref().unwrap()
        } else {
            &native.depth
        };
        let (width, height, stride) = (plane.width, plane.height, plane.bytes_per_row);
        let camera = native.camera;
        let mut points = Vec::new();
        for y in (0..height).step_by(step) {
            for x in (0..width).step_by(step) {
                if let Some((row, conf)) = &native.confidence {
                    let cx = x * native.depth.width / width;
                    let cy = y * native.depth.height / height;
                    if conf[cy * row + cx] == 0 {
                        continue;
                    }
                }
                let offset = y * stride + x * 4;
                let d = f32::from_le_bytes(plane.bytes[offset..offset + 4].try_into().unwrap());
                if !d.is_finite() || !(0.1..=30.).contains(&d) {
                    continue;
                }
                let u = (x as f64 + 0.5) / width as f64;
                let v = (y as f64 + 0.5) / height as f64;
                let image_u = u * camera.image_width;
                let image_v = v * camera.image_height;
                let local = [
                    (image_u - camera.cx) * d as f64 / camera.fx,
                    -(image_v - camera.cy) * d as f64 / camera.fy,
                    -(d as f64),
                ];
                let world = camera.map_from_camera.point(local);
                if world
                    .iter()
                    .all(|value| value.is_finite() && value.abs() < 100_000.)
                {
                    points.push([
                        world[0] as f32,
                        world[1] as f32,
                        world[2] as f32,
                        u as f32,
                        v as f32,
                    ]);
                }
            }
        }
        point_count += points.len();
        let color_asset = native
            .color_asset
            .filter(|name| name.ends_with(".color.jpg") && assets.contains_key(name));
        output.push(PreviewFrame {
            id: native.id,
            width,
            height,
            sample_stride: step,
            used_smoothed: smooth,
            confidence_available: native.confidence.is_some(),
            color_asset,
            points,
        });
    }
    Ok(Preview {
        source: "native_arkit_depth",
        package_format: sources.format,
        mode: if mode == "smoothed" {
            "smoothed"
        } else {
            "raw"
        },
        point_count,
        frames: output,
    })
}

fn reconstruct_mesh(sources: NativeSources) -> Result<MeshPreview, String> {
    if sources.meshes.len() > MAX_MESH_ANCHORS {
        return Err("Too many native mesh anchors.".into());
    }
    let mut meshes = Vec::new();
    let (mut vertex_count, mut triangle_count) = (0usize, 0usize);
    let mut ids = HashSet::new();
    for anchor in sources.meshes {
        if !ids.insert(anchor.id.clone()) {
            return Err("Duplicate native mesh anchor.".into());
        }
        if anchor.vertex_count == 0 || anchor.face_count == 0 {
            continue;
        }
        vertex_count = vertex_count
            .checked_add(anchor.vertex_count)
            .ok_or("Native mesh vertex count overflow.")?;
        triangle_count = triangle_count
            .checked_add(anchor.face_count)
            .ok_or("Native mesh face count overflow.")?;
        if vertex_count > 2_000_000 || triangle_count > 3_600_000 {
            return Err("Native mesh exceeds the bounded review preview.".into());
        }
        anchor.map_from_anchor.validate()?;
        if anchor.vertex_stride < 12
            || anchor.vertex_stride > 256
            || anchor.indices_per_face != 3
            || !matches!(anchor.bytes_per_index, 2 | 4)
        {
            return Err("Unsupported native mesh layout.".into());
        }
        let (vertices, faces) = (&anchor.vertices, &anchor.faces);
        let vertex_end = (anchor.vertex_count - 1)
            .checked_mul(anchor.vertex_stride)
            .and_then(|n| n.checked_add(anchor.vertex_offset))
            .and_then(|n| n.checked_add(12))
            .ok_or("Native mesh vertex offset overflow.")?;
        let face_end = anchor
            .face_count
            .checked_mul(3)
            .and_then(|n| n.checked_mul(anchor.bytes_per_index))
            .ok_or("Native mesh index offset overflow.")?;
        if vertex_end > vertices.len() || face_end > faces.len() {
            return Err("Native mesh buffers are truncated.".into());
        }
        let mut points = Vec::with_capacity(anchor.vertex_count);
        for index in 0..anchor.vertex_count {
            let offset = anchor.vertex_offset + index * anchor.vertex_stride;
            let p = [0, 4, 8].map(|delta| {
                f32::from_le_bytes(
                    vertices[offset + delta..offset + delta + 4]
                        .try_into()
                        .unwrap(),
                )
            });
            if !p.iter().all(|n| n.is_finite()) {
                return Err("Native mesh contains invalid vertices.".into());
            }
            let world = anchor.map_from_anchor.point(p.map(f64::from));
            if !world.iter().all(|n| n.is_finite() && n.abs() < 100_000.) {
                return Err("Native mesh exceeds the local frame.".into());
            }
            points.push(world.map(|n| n as f32));
        }
        let mut triangles = Vec::with_capacity(anchor.face_count);
        for face in 0..anchor.face_count {
            let indices = [0, 1, 2].map(|corner| {
                let at = (face * 3 + corner) * anchor.bytes_per_index;
                if anchor.bytes_per_index == 2 {
                    u16::from_le_bytes(faces[at..at + 2].try_into().unwrap()) as u32
                } else {
                    u32::from_le_bytes(faces[at..at + 4].try_into().unwrap())
                }
            });
            if indices.iter().any(|&n| n as usize >= points.len())
                || indices[0] == indices[1]
                || indices[1] == indices[2]
                || indices[0] == indices[2]
            {
                return Err("Native mesh contains invalid triangle indices.".into());
            }
            triangles.push(indices);
        }
        meshes.push(MeshAnchor {
            source_id: anchor.id,
            vertices: points,
            triangles,
        });
    }
    if meshes.is_empty() {
        return Err("This package has no native mesh anchors.".into());
    }
    Ok(MeshPreview {
        source: "native_arkit_mesh",
        package_format: sources.format,
        vertex_count,
        triangle_count,
        meshes,
    })
}

/// Native ARKit mesh vertices in the shared scan frame, when the package carries a usable mesh.
pub(crate) fn native_mesh_vertices(scan: &StoredScan) -> Option<Vec<[f32; 3]>> {
    let mesh = reconstruct_mesh(native_sources(scan).ok()?).ok()?;
    Some(mesh.meshes.into_iter().flat_map(|m| m.vertices).collect())
}

fn task_failed(error: tokio::task::JoinError, what: &str) -> ApiError {
    tracing::error!(%error, "Native {what} processing task failed");
    ApiError::new(
        StatusCode::INTERNAL_SERVER_ERROR,
        "processing_failed",
        format!("Native {what} could not be processed."),
    )
}

async fn scan(state: &AppState, id: &str) -> Result<std::sync::Arc<StoredScan>, ApiError> {
    state
        .scans
        .get(id)
        .await
        .ok_or_else(|| error("scan_not_found", "Scan not found.", StatusCode::NOT_FOUND))
}

pub async fn native_mesh(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<impl Serialize>, ApiError> {
    let scan = scan(&state, &id).await?;
    let result = tokio::task::spawn_blocking(move || reconstruct_mesh(native_sources(&scan)?))
        .await
        .map_err(|e| task_failed(e, "mesh"))?;
    result.map(Json).map_err(|message| {
        error(
            "native_mesh_unavailable",
            message,
            StatusCode::UNPROCESSABLE_ENTITY,
        )
    })
}

pub async fn preview(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<PreviewQuery>,
) -> Result<Json<Preview>, ApiError> {
    let mode = query.mode.as_deref().unwrap_or("smoothed");
    if !matches!(mode, "smoothed" | "raw")
        || !(1_000..=MAX_POINTS).contains(&query.max_points.unwrap_or(80_000))
    {
        return Err(ApiError::invalid(
            "mode must be smoothed/raw and max_points must be 1000–150000.",
        ));
    }
    let scan = scan(&state, &id).await?;
    let mode = mode.to_owned();
    let budget = query.max_points.unwrap_or(80_000);
    let result = tokio::task::spawn_blocking(move || {
        let assets = scan
            .package_assets
            .as_ref()
            .ok_or("This scan has no native LiDAR package.")?;
        point_cloud(native_sources(&scan)?, &mode, budget, assets)
    })
    .await
    .map_err(|e| task_failed(e, "depth"))?;
    result.map(Json).map_err(|message| {
        error(
            "raw_preview_unavailable",
            message,
            StatusCode::UNPROCESSABLE_ENTITY,
        )
    })
}

/// Only RGB keyframes indexed by the portable capture or the package manifest are served.
fn indexed_color(scan: &StoredScan, filename: &str) -> bool {
    filename.ends_with(".color.jpg")
        && (scan
            .bundle
            .frames
            .iter()
            .any(|f| f.color_asset.as_deref() == Some(filename))
            || scan
                .package_manifest
                .as_ref()
                .and_then(|m| m.get("observations"))
                .and_then(|o| o.as_array())
                .is_some_and(|observations| {
                    observations
                        .iter()
                        .any(|o| o.get("rgb_asset").and_then(|v| v.as_str()) == Some(filename))
                }))
}

pub async fn color_asset(
    State(state): State<AppState>,
    Path((id, filename)): Path<(String, String)>,
) -> Result<impl IntoResponse, ApiError> {
    let scan = scan(&state, &id).await?;
    let missing = || {
        error(
            "asset_not_found",
            "Color asset not found.",
            StatusCode::NOT_FOUND,
        )
    };
    if !indexed_color(&scan, &filename) {
        return Err(missing());
    }
    let bytes = scan
        .package_assets
        .as_ref()
        .and_then(|files| files.get(&filename))
        .ok_or_else(missing)?;
    if bytes.len() > 8 * 1024 * 1024 {
        return Err(ApiError::invalid(
            "Color keyframe exceeds the preview limit.",
        ));
    }
    Ok((
        [
            (header::CONTENT_TYPE, "image/jpeg"),
            (header::CACHE_CONTROL, "private, no-store"),
        ],
        Bytes::copy_from_slice(bytes),
    ))
}
