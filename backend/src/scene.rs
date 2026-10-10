use serde::{Deserialize, Serialize};

use crate::{
    capture::{Confidence, Coordinates, ScanBundle},
    geometry::{Bounds, Transform, Vec3, finite},
    model_meshes::{ModelMesh, furniture_meshes, photo_model_key},
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct ProcessingOptions {
    pub minimum_object_confidence: Confidence,
    /// None explicitly allows samples with unknown confidence; default requires medium.
    pub minimum_depth_confidence: Option<u8>,
    pub max_points: usize,
}

impl Default for ProcessingOptions {
    fn default() -> Self {
        Self {
            minimum_object_confidence: Confidence::Medium,
            minimum_depth_confidence: Some(1),
            max_points: 20_000,
        }
    }
}

impl ProcessingOptions {
    pub fn validate(&self) -> Result<(), String> {
        if self.minimum_depth_confidence.is_some_and(|value| value > 2) {
            return Err("minimum_depth_confidence must be 0, 1, 2, or null.".into());
        }
        if self.max_points == 0 || self.max_points > 100_000 {
            return Err("max_points must be between 1 and 100000.".into());
        }
        Ok(())
    }
}

#[derive(Debug, Serialize)]
pub struct Scene {
    pub schema_version: u32,
    pub processing_version: u32,
    pub source_scan_id: String,
    pub map_id: String,
    pub floor_id: String,
    pub coordinates: Coordinates,
    pub options: ProcessingOptions,
    pub objects: Vec<SceneObject>,
    pub surfaces: Vec<SceneSurface>,
    pub meshes: Vec<SceneMesh>,
    pub point_cloud: Vec<CloudPoint>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct SceneObject {
    pub source_id: String,
    pub source_category: String,
    pub source_confidence: Confidence,
    pub model_key: &'static str,
    pub map_from_object: Transform,
    pub measured_dimensions_m: Vec3,
    /// Source-oriented box is retained separately from the stylized model's parts.
    pub obstacle_corners: [Vec3; 8],
    pub obstacle_bounds: Bounds,
    pub parts: Vec<ModelPart>,
    /// Sculpted display geometry in object-local meters; measured bounds remain separate.
    pub model_meshes: Vec<ModelMesh>,
}

#[derive(Debug, Serialize)]
pub struct ModelPart {
    /// Cuboid center and dimensions in the object's local coordinates.
    pub center: Vec3,
    pub dimensions_m: Vec3,
    pub color: &'static str,
}

#[derive(Debug, Serialize)]
pub struct SceneSurface {
    pub source_id: String,
    pub kind: String,
    pub map_from_surface: Transform,
    pub measured_dimensions_m: Vec3,
    /// Thin display thickness for zero-thickness source surfaces, never navigation data.
    pub render_dimensions_m: Vec3,
    pub color: &'static str,
    /// Captured surface-local outline, unchanged by display styling.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub polygon_corners: Option<Vec<Vec3>>,
}

#[derive(Debug, Serialize)]
pub struct SceneMesh {
    pub source_id: String,
    /// Normalized into this scene's map frame, without smoothing or geometry removal.
    pub vertices: Vec<Vec3>,
    pub triangles: Vec<[usize; 3]>,
    pub classifications: Option<Vec<String>>,
}

#[derive(Debug, Serialize)]
pub struct CloudPoint {
    pub source_frame_id: String,
    pub position: Vec3,
    pub confidence: Option<u8>,
}

/// Deterministic first pass: placement and depth unprojection, not learned recognition.
pub fn process(bundle: &ScanBundle, options: ProcessingOptions) -> Result<Scene, String> {
    bundle.validate()?;
    options.validate()?;
    let mut warnings = Vec::new();
    if bundle.objects.is_empty() {
        warnings.push(
            "No object labels were supplied; furniture recognition is not implemented yet.".into(),
        );
    }
    let objects: Vec<_> = bundle
        .objects
        .iter()
        .map(|object| {
            let category = object.category.trim().to_ascii_lowercase();
            let model_key = if object.confidence >= options.minimum_object_confidence {
                photo_model_key(&category, object.dimensions_m).unwrap_or_else(|| {
                    match category.as_str() {
                        "storage" | "cabinet" => "storage_v2",
                        "bed" => "bed_v2",
                        "sink" => "sink_v2",
                        "plant" => "plant_v2",
                        "rug" => "rug_v2",
                        _ => "bounds_v1",
                    }
                })
            } else {
                "bounds_v1"
            };
            let corners = object.map_from_object.box_corners(object.dimensions_m);
            SceneObject {
                source_id: object.id.clone(),
                source_category: object.category.clone(),
                source_confidence: object.confidence,
                model_key,
                map_from_object: object.map_from_object,
                measured_dimensions_m: object.dimensions_m,
                obstacle_bounds: Bounds::from_points(&corners).expect("eight corners"),
                obstacle_corners: corners,
                parts: model_parts(model_key, object.dimensions_m),
                model_meshes: furniture_meshes(model_key, object.dimensions_m),
            }
        })
        .collect();
    if objects.iter().any(|object| object.model_key == "bounds_v1") {
        warnings.push("Some objects use their measured boxes because their type or confidence is unsupported.".into());
    }
    let surfaces = bundle
        .surfaces
        .iter()
        .map(|surface| SceneSurface {
            source_id: surface.id.clone(),
            kind: surface.kind.clone(),
            map_from_surface: surface.map_from_surface,
            measured_dimensions_m: surface.dimensions_m,
            render_dimensions_m: surface
                .dimensions_m
                .map(|v| if v == 0.0 { 0.025 } else { v }),
            color: if surface.kind == "floor" {
                "#e8e4dc"
            } else {
                "#f4f1eb"
            },
            polygon_corners: surface.polygon_corners.clone(),
        })
        .collect();
    let meshes = bundle
        .meshes
        .iter()
        .map(|mesh| SceneMesh {
            source_id: mesh.id.clone(),
            vertices: mesh
                .vertices
                .iter()
                .map(|p| mesh.map_from_anchor.point(*p))
                .collect(),
            triangles: mesh.triangles.clone(),
            classifications: mesh.classifications.clone(),
        })
        .collect();

    // Uniformly sample across all supplied frames rather than filling the cap with frame one.
    let total_samples = bundle.frames.iter().try_fold(0usize, |count, frame| {
        count
            .checked_add(frame.depth.values_m.len())
            .ok_or("Too many depth samples.")
    })?;
    let stride = total_samples.div_ceil(options.max_points).max(1);
    let mut sample_index = 0usize;
    let mut point_cloud = Vec::new();
    let mut missing_confidence = false;
    for frame in &bundle.frames {
        if frame.depth.confidence.is_none() && options.minimum_depth_confidence.is_some() {
            missing_confidence = true;
        }
        for (index, &depth) in frame.depth.values_m.iter().enumerate() {
            let take = sample_index.is_multiple_of(stride);
            sample_index += 1;
            if !take {
                continue;
            }
            let Some(depth) = depth.filter(|value| *value > 0.0) else {
                continue;
            };
            let confidence = frame.depth.confidence.as_ref().map(|values| values[index]);
            if let Some(minimum) = options.minimum_depth_confidence
                && !confidence.is_some_and(|value| value >= minimum)
            {
                continue;
            }
            let position = frame.point_in_map(index, depth);
            if !finite(position) {
                return Err("Depth and calibration produce nonfinite map positions.".into());
            }
            point_cloud.push(CloudPoint {
                source_frame_id: frame.id.clone(),
                position,
                confidence,
            });
        }
    }
    if missing_confidence {
        warnings.push(
            "Depth frames without confidence were excluded by the selected confidence requirement."
                .into(),
        );
    }
    Ok(Scene {
        schema_version: 1,
        processing_version: 3,
        source_scan_id: bundle.id.clone(),
        map_id: bundle.map_id.clone(),
        floor_id: bundle.floor_id.clone(),
        coordinates: bundle.coordinates.clone(),
        options,
        objects,
        surfaces,
        meshes,
        point_cloud,
        warnings,
    })
}

fn model_parts(key: &str, size: Vec3) -> Vec<ModelPart> {
    let mut parts = Vec::new();
    let mut add = |center: Vec3, dimensions: Vec3, color| {
        parts.push(ModelPart {
            center: std::array::from_fn(|axis| center[axis] * size[axis]),
            dimensions_m: std::array::from_fn(|axis| dimensions[axis] * size[axis]),
            color,
        });
    };
    match key {
        "chair_v1" | "chair_v2" => {
            add([0.0, -0.02, 0.0], [1.0, 0.13, 0.95], "#b6c6c3");
            add([0.0, 0.225, 0.425], [1.0, 0.55, 0.15], "#b6c6c3");
            for x in [-0.4, 0.4] {
                for z in [-0.375, 0.375] {
                    add([x, -0.26, z], [0.1, 0.48, 0.1], "#687a76");
                }
            }
        }
        "sofa_v1" | "sofa_v2" => {
            add([0.0, -0.25, 0.0], [1.0, 0.28, 1.0], "#b6c6c3");
            add([0.0, -0.02, -0.08], [0.74, 0.18, 0.73], "#cbd7d3");
            add([0.0, 0.24, 0.4], [1.0, 0.52, 0.2], "#b6c6c3");
            for x in [-0.435, 0.435] {
                add([x, 0.01, -0.06], [0.13, 0.45, 0.88], "#b6c6c3");
            }
            add([0.0, -0.44, 0.0], [0.85, 0.12, 0.8], "#687a76");
        }
        "table_v1" | "table_v2" => {
            add([0.0, 0.45, 0.0], [1.0, 0.1, 1.0], "#c9b99d");
            for x in [-0.4, 0.4] {
                for z in [-0.4, 0.4] {
                    add([x, -0.05, z], [0.1, 0.9, 0.1], "#998970");
                }
            }
        }
        _ => add([0.0; 3], [1.0; 3], "#d3b58b"),
    }
    parts
}

#[cfg(test)]
mod surface_polygon_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn processing_preserves_measured_concave_outline_and_local_pose() {
        let outline = json!([
            [-3, -2, 0],
            [3, -2, 0],
            [3, 0, 0],
            [0, 0, 0],
            [0, 2, 0],
            [-3, 2, 0]
        ]);
        let value = json!({
            "schema_version": 1, "id": "scan", "map_id": "building", "floor_id": "ground",
            "coordinates": {"units": "meters", "up_axis": "y", "handedness": "right"},
            "surfaces": [{
                "id": "floor", "kind": "floor", "dimensions_m": [6, 4, 0],
                "map_from_surface": [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 8, -1.2, 3, 1],
                "polygon_corners": outline
            }]
        });
        let bundle: ScanBundle = serde_json::from_value(value).unwrap();
        let scene = process(&bundle, ProcessingOptions::default()).unwrap();
        assert_eq!(
            scene.surfaces[0].polygon_corners,
            bundle.surfaces[0].polygon_corners
        );
        assert_eq!(
            scene.surfaces[0].map_from_surface,
            bundle.surfaces[0].map_from_surface
        );
        assert_eq!(scene.surfaces[0].measured_dimensions_m, [6.0, 4.0, 0.0]);
        assert_eq!(scene.surfaces[0].render_dimensions_m, [6.0, 4.0, 0.025]);
        let output = serde_json::to_value(&scene).unwrap();
        let decoded: Vec<Vec3> =
            serde_json::from_value(output["surfaces"][0]["polygon_corners"].clone()).unwrap();
        assert_eq!(Some(decoded), bundle.surfaces[0].polygon_corners);
    }

    #[test]
    fn legacy_scene_omits_missing_surface_outline() {
        let bundle: ScanBundle = serde_json::from_value(json!({
            "schema_version": 1, "id": "scan", "map_id": "building", "floor_id": "ground",
            "coordinates": {"units": "meters", "up_axis": "y", "handedness": "right"},
            "surfaces": [{
                "id": "floor", "kind": "floor", "dimensions_m": [6, 0, 4],
                "map_from_surface": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
            }]
        }))
        .unwrap();
        let scene = process(&bundle, ProcessingOptions::default()).unwrap();
        let output = serde_json::to_value(&scene).unwrap();
        assert!(output["surfaces"][0].get("polygon_corners").is_none());
    }
}
