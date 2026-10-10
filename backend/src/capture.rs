use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::geometry::{Transform, Vec3, finite};

/// Portable interchange draft, not Apple's native CapturedRoom Codable layout.
/// The store retains the original JSON including fields this projection does not use.
#[derive(Clone, Debug, Deserialize)]
pub struct ScanBundle {
    pub schema_version: u32,
    pub id: String,
    pub map_id: String,
    pub floor_id: String,
    pub coordinates: Coordinates,
    #[serde(default)]
    pub meshes: Vec<MeshCapture>,
    #[serde(default)]
    pub frames: Vec<DepthFrame>,
    #[serde(default)]
    pub objects: Vec<DetectedObject>,
    #[serde(default)]
    pub surfaces: Vec<CapturedSurface>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Coordinates {
    pub units: String,
    pub up_axis: String,
    pub handedness: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct MeshCapture {
    pub id: String,
    pub map_from_anchor: Transform,
    pub vertices: Vec<Vec3>,
    pub triangles: Vec<[usize; 3]>,
    #[serde(default)]
    pub classifications: Option<Vec<String>>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Confidence {
    #[default]
    Unknown,
    Low,
    Medium,
    High,
}

#[derive(Clone, Debug, Deserialize)]
pub struct DetectedObject {
    pub id: String,
    pub category: String,
    #[serde(default)]
    pub confidence: Confidence,
    pub map_from_object: Transform,
    /// Local centered bounds, not display-model dimensions inferred from a category.
    pub dimensions_m: Vec3,
}

#[derive(Clone, Debug, Deserialize)]
pub struct CapturedSurface {
    pub id: String,
    pub kind: String,
    pub map_from_surface: Transform,
    /// Local centered bounds; one axis may be zero for a measured planar surface.
    pub dimensions_m: Vec3,
    /// Optional measured outline in surface-local coordinates, without a repeated closing vertex.
    #[serde(default)]
    pub polygon_corners: Option<Vec<Vec3>>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct DepthFrame {
    pub id: String,
    pub timestamp_seconds: f64,
    pub pixel_orientation: String,
    pub map_from_camera: Transform,
    pub camera: CameraCalibration,
    pub depth: DepthImage,
    /// Opaque identifier only; no server-side download or image decoding.
    #[serde(default)]
    pub color_asset: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct CameraCalibration {
    pub image_width: usize,
    pub image_height: usize,
    pub fx: f64,
    pub fy: f64,
    pub cx: f64,
    pub cy: f64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct DepthImage {
    pub width: usize,
    pub height: usize,
    /// Row-major meters. Null or zero is a missing sample.
    pub values_m: Vec<Option<f64>>,
    /// ARKit confidence: 0 low, 1 medium, 2 high. Omitted means unknown.
    #[serde(default)]
    pub confidence: Option<Vec<u8>>,
}

impl ScanBundle {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != 1 {
            return Err("Only draft scan schema_version 1 is supported.".into());
        }
        nonempty(&self.id)?;
        nonempty(&self.map_id)?;
        nonempty(&self.floor_id)?;
        if self.coordinates.units != "meters"
            || self.coordinates.up_axis != "y"
            || self.coordinates.handedness != "right"
        {
            return Err(
                "Export capture coordinates in meters with right-handed, y-up axes.".into(),
            );
        }
        if self.meshes.is_empty()
            && self.frames.is_empty()
            && self.objects.is_empty()
            && self.surfaces.is_empty()
        {
            return Err("A scan needs mesh, depth, objects, or shell surfaces.".into());
        }
        unique_ids(self.meshes.iter().map(|mesh| mesh.id.as_str()))?;
        unique_ids(self.frames.iter().map(|frame| frame.id.as_str()))?;
        unique_ids(self.objects.iter().map(|object| object.id.as_str()))?;
        unique_ids(self.surfaces.iter().map(|surface| surface.id.as_str()))?;
        for mesh in &self.meshes {
            mesh.map_from_anchor.validate()?;
            if mesh.vertices.is_empty()
                || mesh
                    .vertices
                    .iter()
                    .any(|p| !finite(*p) || !finite(mesh.map_from_anchor.point(*p)))
            {
                return Err(format!("Mesh {} needs finite vertices.", mesh.id));
            }
            if mesh.triangles.iter().any(|triangle| {
                triangle.iter().any(|&index| index >= mesh.vertices.len())
                    || triangle[0] == triangle[1]
                    || triangle[0] == triangle[2]
                    || triangle[1] == triangle[2]
            }) {
                return Err(format!("Mesh {} has invalid triangle indices.", mesh.id));
            }
            if mesh
                .classifications
                .as_ref()
                .is_some_and(|classes| classes.len() != mesh.triangles.len())
            {
                return Err(format!(
                    "Mesh {} needs one classification per triangle.",
                    mesh.id
                ));
            }
        }
        for object in &self.objects {
            nonempty(&object.category)?;
            object.map_from_object.validate()?;
            if !finite(object.dimensions_m)
                || object.dimensions_m.iter().any(|v| *v <= 0.0)
                || object
                    .map_from_object
                    .box_corners(object.dimensions_m)
                    .iter()
                    .any(|p| !finite(*p))
            {
                return Err(format!(
                    "Object {} needs positive finite dimensions.",
                    object.id
                ));
            }
        }
        for surface in &self.surfaces {
            nonempty(&surface.kind)?;
            surface.map_from_surface.validate()?;
            if !finite(surface.dimensions_m)
                || surface.dimensions_m.iter().any(|v| *v < 0.0)
                || surface.dimensions_m.iter().filter(|v| **v > 0.0).count() < 2
                || surface
                    .map_from_surface
                    .box_corners(surface.dimensions_m)
                    .iter()
                    .any(|p| !finite(*p))
            {
                return Err(format!(
                    "Surface {} needs finite planar or box dimensions.",
                    surface.id
                ));
            }
            if let Some(polygon) = &surface.polygon_corners
                && (!valid_surface_polygon(polygon)
                    || polygon
                        .iter()
                        .any(|point| !finite(surface.map_from_surface.point(*point))))
            {
                return Err(format!("Surface {} has an invalid outline.", surface.id));
            }
        }
        for frame in &self.frames {
            frame.validate()?;
        }
        Ok(())
    }
}

fn valid_surface_polygon(corners: &[Vec3]) -> bool {
    if !(3..=128).contains(&corners.len()) || corners.iter().any(|point| !finite(*point)) {
        return false;
    }
    // Newell area in the original local plane, translated to avoid numerical cancellation.
    let origin = corners[0];
    let mut twice_area = [0.0_f64; 3];
    for index in 0..corners.len() {
        let a: Vec3 = std::array::from_fn(|axis| corners[index][axis] - origin[axis]);
        let b: Vec3 =
            std::array::from_fn(|axis| corners[(index + 1) % corners.len()][axis] - origin[axis]);
        twice_area[0] += a[1] * b[2] - a[2] * b[1];
        twice_area[1] += a[2] * b[0] - a[0] * b[2];
        twice_area[2] += a[0] * b[1] - a[1] * b[0];
    }
    twice_area.iter().all(|value| value.is_finite())
        && twice_area.iter().map(|value| value * value).sum::<f64>() > 4e-12
}

impl DepthFrame {
    fn validate(&self) -> Result<(), String> {
        self.map_from_camera.validate()?;
        if !self.timestamp_seconds.is_finite() || self.timestamp_seconds < 0.0 {
            return Err("Frame timestamps must be finite nonnegative seconds.".into());
        }
        if self.pixel_orientation != "sensor_native" {
            return Err(
                "Export depth and camera calibration in sensor_native pixel orientation.".into(),
            );
        }
        let camera = &self.camera;
        if camera.image_width == 0
            || camera.image_height == 0
            || ![camera.fx, camera.fy, camera.cx, camera.cy]
                .iter()
                .all(|v| v.is_finite())
            || camera.fx <= 0.0
            || camera.fy <= 0.0
        {
            return Err("Frames need valid image dimensions and camera intrinsics.".into());
        }
        let count = self
            .depth
            .width
            .checked_mul(self.depth.height)
            .filter(|&count| count > 0)
            .ok_or("Depth dimensions are invalid.")?;
        if camera.image_width as u128 * self.depth.height as u128
            != camera.image_height as u128 * self.depth.width as u128
        {
            return Err("Depth must cover the full camera image with the same aspect ratio; cropped buffers need an exporter adapter.".into());
        }
        if count != self.depth.values_m.len()
            || self
                .depth
                .values_m
                .iter()
                .flatten()
                .any(|v| !v.is_finite() || *v < 0.0)
        {
            return Err(
                "Depth samples must match the image size and be finite nonnegative meters.".into(),
            );
        }
        if self
            .depth
            .confidence
            .as_ref()
            .is_some_and(|values| values.len() != count || values.iter().any(|v| *v > 2))
        {
            return Err("Depth confidence must match the image size and use 0, 1, or 2.".into());
        }
        for (index, depth) in self.depth.values_m.iter().enumerate() {
            if let Some(depth) = depth.filter(|value| *value > 0.0)
                && !finite(self.point_in_map(index, depth))
            {
                return Err("Depth and calibration produce nonfinite map positions.".into());
            }
        }
        Ok(())
    }

    pub fn point_in_map(&self, index: usize, depth: f64) -> Vec3 {
        let camera = &self.camera;
        let u =
            (index % self.depth.width) as f64 * camera.image_width as f64 / self.depth.width as f64;
        let v = (index / self.depth.width) as f64 * camera.image_height as f64
            / self.depth.height as f64;
        // Sensor image: x right, y down. ARKit camera: x right, y up, looks along -z.
        self.map_from_camera.point([
            (u - camera.cx) * depth / camera.fx,
            -(v - camera.cy) * depth / camera.fy,
            -depth,
        ])
    }
}

fn unique_ids<'a>(ids: impl Iterator<Item = &'a str>) -> Result<(), String> {
    let mut seen = HashSet::new();
    for id in ids {
        nonempty(id)?;
        if !seen.insert(id) {
            return Err(format!("Duplicate capture id: {id}."));
        }
    }
    Ok(())
}

fn nonempty(value: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        Err("Capture identifiers and categories must not be empty.".into())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod surface_polygon_tests {
    use super::*;
    use serde_json::json;

    fn surface_bundle() -> ScanBundle {
        serde_json::from_value(json!({
            "schema_version": 1, "id": "scan", "map_id": "building", "floor_id": "ground",
            "coordinates": {"units": "meters", "up_axis": "y", "handedness": "right"},
            "surfaces": [{
                "id": "floor", "kind": "floor", "dimensions_m": [6, 4, 0],
                "map_from_surface": [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 8, -1.2, 3, 1]
            }]
        }))
        .unwrap()
    }

    #[test]
    fn legacy_surface_has_no_polygon() {
        let bundle = surface_bundle();
        assert!(bundle.surfaces[0].polygon_corners.is_none());
        bundle.validate().unwrap();
    }

    #[test]
    fn concave_surface_polygons_accept_native_xy_and_xz_planes() {
        let xy = vec![
            [-3.0, -2.0, 0.0],
            [3.0, -2.0, 0.0],
            [3.0, 0.0, 0.0],
            [0.0, 0.0, 0.0],
            [0.0, 2.0, 0.0],
            [-3.0, 2.0, 0.0],
        ];
        let mut bundle = surface_bundle();
        bundle.surfaces[0].polygon_corners = Some(xy.clone());
        bundle.validate().unwrap();
        bundle.surfaces[0].polygon_corners = Some(xy.iter().map(|p| [p[0], 0.0, p[1]]).collect());
        bundle.validate().unwrap();
    }

    #[test]
    fn surface_polygons_reject_invalid_geometry_and_vertex_limits() {
        let mut bundle = surface_bundle();
        for outline in [
            vec![],
            vec![[0.0; 3]; 2],
            vec![[0.0; 3], [1.0, 0.0, 0.0], [2.0, 0.0, 0.0]],
            vec![[0.0; 3], [1.0, 0.0, 0.0], [0.0, f64::NAN, 0.0]],
            vec![[0.0; 3], [1.0, 0.0, 0.0], [0.0, f64::INFINITY, 0.0]],
            vec![[0.0; 3]; 129],
        ] {
            bundle.surfaces[0].polygon_corners = Some(outline);
            assert!(bundle.validate().is_err());
        }
        let circle = (0..128)
            .map(|index| {
                let angle = index as f64 * std::f64::consts::TAU / 128.0;
                [angle.cos(), angle.sin(), 0.0]
            })
            .collect();
        bundle.surfaces[0].polygon_corners = Some(circle);
        bundle.validate().unwrap();
    }

    #[test]
    fn surface_polygon_decode_rejects_non_xyz_vertex_arrays() {
        let value = json!({
            "id": "floor", "kind": "floor", "dimensions_m": [6, 4, 0],
            "map_from_surface": [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 8, -1.2, 3, 1],
            "polygon_corners": [[0, 0], [1, 0], [0, 1]]
        });
        assert!(serde_json::from_value::<CapturedSurface>(value).is_err());
    }
}
