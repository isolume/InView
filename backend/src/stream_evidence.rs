//! Derive aligned spatial sidecars without rewriting the received evidence.
//!
//! Loop correction varies with observation time. A feature may be transformed only using its
//! recorded time, a matching timestamped stream feature, or one correction shared by the entire
//! capture. Unknown provenance is omitted from the derived spatial product, never guessed.
use std::collections::BTreeMap;

use serde_json::{Value, json};

use crate::{alignment::AlignmentResult, geometry::Transform, map_frame::IDENTITY};

#[derive(Clone, Copy)]
pub(crate) struct FeatureCorrection {
    pub correction: Transform,
    pub timestamp: f64,
}

pub(crate) fn compose(left: Transform, right: Transform) -> Transform {
    let mut out = [0.; 16];
    for column in 0..4 {
        for row in 0..4 {
            out[column * 4 + row] = (0..4)
                .map(|k| left.0[k * 4 + row] * right.0[column * 4 + k])
                .sum();
        }
    }
    Transform(out)
}

fn same(a: Transform, b: Transform) -> bool {
    a.0.iter().zip(b.0).all(|(a, b)| (a - b).abs() < 1e-8)
}

fn vector(value: &Value) -> Option<[f64; 3]> {
    let values: Vec<f64> = if let Some(array) = value.as_array() {
        array
            .iter()
            .take(3)
            .map(Value::as_f64)
            .collect::<Option<_>>()?
    } else {
        ["x", "y", "z"]
            .iter()
            .map(|key| value.get(key)?.as_f64())
            .collect::<Option<_>>()?
    };
    let result: [f64; 3] = values.try_into().ok()?;
    result.iter().all(|n| n.is_finite()).then_some(result)
}

fn matrix(value: &Value) -> Option<Transform> {
    let value = value
        .get("columns")
        .or_else(|| value.get("matrix"))
        .unwrap_or(value);
    let values = value.as_array()?;
    let flat: Vec<f64> = if values.len() == 16 {
        values.iter().map(Value::as_f64).collect::<Option<_>>()?
    } else if values.len() == 4 {
        let mut result = Vec::with_capacity(16);
        for column in values {
            if let Some(column) = column.as_array().filter(|c| c.len() == 4) {
                result.extend(
                    column
                        .iter()
                        .map(Value::as_f64)
                        .collect::<Option<Vec<_>>>()?,
                );
            } else {
                for key in ["x", "y", "z", "w"] {
                    result.push(column.get(key)?.as_f64()?);
                }
            }
        }
        result
    } else {
        return None;
    };
    let transform = Transform(flat.try_into().ok()?);
    transform.validate().ok()?;
    Some(transform)
}

pub(crate) struct Corrector<'a> {
    alignment: &'a AlignmentResult,
    features: &'a BTreeMap<String, FeatureCorrection>,
    uniform: Option<Transform>,
    pub omitted: usize,
}

impl<'a> Corrector<'a> {
    pub fn new(
        alignment: &'a AlignmentResult,
        features: &'a BTreeMap<String, FeatureCorrection>,
    ) -> Self {
        let uniform = if !alignment.optimized {
            Some(IDENTITY)
        } else {
            alignment
                .frames
                .first()
                .map(|frame| alignment.correction_for(frame.timestamp_seconds))
                .filter(|first| {
                    alignment.frames.iter().all(|frame| {
                        same(*first, alignment.correction_for(frame.timestamp_seconds))
                    })
                })
        };
        Self {
            alignment,
            features,
            uniform,
            omitted: 0,
        }
    }

    fn recorded(&self, value: &Value) -> Option<FeatureCorrection> {
        if let Some(t) = value.get("timestamp_seconds").and_then(Value::as_f64)
            && t.is_finite()
            && t >= 0.
            && self
                .alignment
                .frames
                .first()
                .is_some_and(|f| t >= f.timestamp_seconds)
            && self
                .alignment
                .frames
                .last()
                .is_some_and(|f| t <= f.timestamp_seconds)
        {
            return Some(FeatureCorrection {
                correction: self.alignment.correction_for(t),
                timestamp: t,
            });
        }
        let id = value
            .get("identifier")
            .or_else(|| value.get("id"))
            .and_then(Value::as_str)?;
        self.features.get(&id.to_ascii_lowercase()).copied()
    }

    fn correction(&self, value: &Value) -> Option<Transform> {
        self.recorded(value).map(|f| f.correction).or(self.uniform)
    }

    fn point(&self, value: &mut Value, key: &str, correction: Transform) -> bool {
        let Some(point) = value.get(key).and_then(vector) else {
            return false;
        };
        value[key] = json!(correction.point(point));
        true
    }

    /// Derive one native component. polygonCorners remains surface-local and does not change.
    fn native_component(&mut self, mut value: Value) -> Option<Value> {
        let correction = self.correction(&value);
        let transform = value.get("transform").and_then(matrix);
        let (Some(correction), Some(transform)) = (correction, transform) else {
            self.omitted += 1;
            return None;
        };
        value["transform"] = json!(compose(correction, transform));
        if let Some(evidence) = self.recorded(&value) {
            value["alignment_timestamp_seconds"] = json!(evidence.timestamp);
        }
        Some(value)
    }

    fn room_correction(&self, room: &Value, native: bool) -> Option<Transform> {
        if let Some(correction) = self.uniform {
            return Some(correction);
        }
        if let Some(recorded) = self.recorded(room) {
            return Some(recorded.correction);
        }
        let keys: &[&str] = if native {
            &["walls", "doors", "openings", "windows", "floors", "objects"]
        } else {
            &["surfaces"]
        };
        let corrections: Vec<_> = keys
            .iter()
            .flat_map(|key| {
                room.get(key)
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
            })
            .map(|item| self.recorded(item).map(|f| f.correction))
            .collect::<Option<_>>()?;
        corrections
            .first()
            .copied()
            .filter(|first| corrections.iter().all(|other| same(*first, *other)))
    }

    fn sections(&mut self, room: &mut Value, correction: Option<Transform>) {
        let Some(sections) = room.get_mut("sections").and_then(Value::as_array_mut) else {
            return;
        };
        sections.retain_mut(|section| {
            let correction = self.correction(section).or(correction);
            let keep = correction.is_some_and(|c| self.point(section, "center", c));
            if !keep {
                self.omitted += 1;
            }
            keep
        });
    }

    pub fn roomplan(&mut self, mut value: Value) -> Value {
        if !self.alignment.optimized {
            return value;
        }
        if let Some(rooms) = value.as_array_mut() {
            for room in rooms {
                *room = self.roomplan(room.take());
            }
            return value;
        }
        if !value.is_object() {
            self.omitted += 1;
            return json!([]);
        }
        if let Some(rooms) = value.get_mut("rooms").and_then(Value::as_array_mut) {
            for room in rooms {
                *room = self.roomplan(room.take());
            }
        }
        let correction = self.room_correction(&value, true);
        self.sections(&mut value, correction);
        for key in ["walls", "doors", "openings", "windows", "floors", "objects"] {
            if let Some(items) = value.get_mut(key).and_then(Value::as_array_mut) {
                *items = std::mem::take(items)
                    .into_iter()
                    .filter_map(|item| self.native_component(item))
                    .collect();
            }
        }
        value
    }

    pub fn semantics(&mut self, mut value: Value) -> Value {
        if !self.alignment.optimized || !value.is_object() {
            return value;
        }
        if let Some(points) = value.get_mut("access_points").and_then(Value::as_array_mut) {
            points.retain_mut(|point| {
                let keep = self
                    .correction(point)
                    .is_some_and(|c| self.point(point, "position", c));
                if !keep {
                    self.omitted += 1;
                }
                keep
            });
        }
        if let Some(rooms) = value
            .get_mut("roomplan")
            .and_then(|r| r.get_mut("rooms"))
            .and_then(Value::as_array_mut)
        {
            for room in rooms {
                let correction = self.room_correction(room, false);
                self.sections(room, correction);
                if let Some(surfaces) = room.get_mut("surfaces").and_then(Value::as_array_mut) {
                    surfaces.retain_mut(|surface| {
                        let correction = self.correction(surface);
                        let transform = surface.get("map_from_surface").and_then(matrix);
                        let (Some(correction), Some(transform)) = (correction, transform) else {
                            self.omitted += 1;
                            return false;
                        };
                        surface["map_from_surface"] = json!(compose(correction, transform));
                        if let Some(corners) = surface
                            .get_mut("polygon_corners_m")
                            .and_then(Value::as_array_mut)
                        {
                            *corners = std::mem::take(corners)
                                .into_iter()
                                .filter_map(|corner| {
                                    vector(&corner).map(|p| json!(correction.point(p)))
                                })
                                .collect();
                        }
                        true
                    });
                }
            }
        }
        // A single geographic heading/floor plane cannot represent a time-varying 3D correction.
        // Calibrated per-observation geo samples remain in the manifest for the georef stage.
        value
            .as_object_mut()
            .unwrap()
            .remove("geographic_reference");
        value.as_object_mut().unwrap().remove("floor_y");
        if let Some(stairs) = value
            .get_mut("stairs_footprints")
            .and_then(Value::as_array_mut)
        {
            self.omitted += stairs.len();
            stairs.clear(); // No capture-time provenance exists for the 2D rectangles.
        }
        value["coordinate_frame"] = json!("shared_arkit_session");
        value["coordinate_derivation"] =
            json!({"method": "recorded_stream_alignment", "source_asset": "source-semantics.json"});
        value
    }

    pub fn track(&mut self, mut value: Value) -> Option<Value> {
        if value.get("schema_version").and_then(Value::as_u64) != Some(1)
            || value.get("clock").and_then(Value::as_str) != Some("arkit_uptime_seconds")
        {
            self.omitted += 1;
            return None;
        }
        let poses = value.get_mut("poses")?.as_array_mut()?;
        poses.retain_mut(|pose| {
            let time = pose
                .get("t")
                .and_then(Value::as_f64)
                .filter(|t| t.is_finite() && *t >= 0.);
            let transform = pose.get("m").and_then(matrix);
            let (Some(time), Some(transform)) = (time, transform) else {
                self.omitted += 1;
                return false;
            };
            pose["m"] = json!(compose(self.alignment.correction_for(time), transform));
            true
        });
        value["source"] = json!("received_track_loop_corrected");
        Some(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::alignment::AlignedFrame;

    fn translation(x: f64) -> Transform {
        let mut t = IDENTITY;
        t.0[12] = x;
        t
    }
    fn alignment() -> AlignmentResult {
        AlignmentResult {
            reference_frame: "original_arkit_session".into(),
            optimized: true,
            frames: [0., 2.]
                .into_iter()
                .map(|t| AlignedFrame {
                    frame_id: t.to_string(),
                    timestamp_seconds: t,
                    original_map_from_camera: IDENTITY,
                    optimized_map_from_camera: translation(t / 4.),
                })
                .collect(),
            constraints: vec![],
            initial_cost: 1.,
            final_cost: 0.,
        }
    }

    #[test]
    fn only_recorded_points_and_matched_roomplan_features_enter_corrected_sidecars() {
        let a = alignment();
        let features = BTreeMap::from([(
            "door-a".into(),
            FeatureCorrection {
                correction: translation(0.5),
                timestamp: 2.,
            },
        )]);
        let mut corrector = Corrector::new(&a, &features);
        let semantics = corrector.semantics(json!({"access_points":[
            {"id":"manual", "position":[1.,0.,0.]},
            {"id":"observed", "timestamp_seconds":2., "position":[1.,0.,0.], "requires_assistance":true}],
            "roomplan":{"rooms":[{"surfaces":[{"id":"DOOR-A", "map_from_surface":IDENTITY,
            "polygon_corners_m":[[0.,0.,0.],[1.,0.,0.]]}]}]}}));
        assert_eq!(semantics["access_points"].as_array().unwrap().len(), 1);
        assert_eq!(semantics["access_points"][0]["position"][0], 1.5);
        assert_eq!(semantics["access_points"][0]["requires_assistance"], true);
        assert_eq!(
            semantics["roomplan"]["rooms"][0]["surfaces"][0]["polygon_corners_m"][0][0],
            0.5
        );
        let native = corrector.roomplan(
            json!([{"doors":[{"identifier":"DOOR-A", "transform":IDENTITY,
            "polygonCorners":[[0.,0.,0.],[1.,0.,0.]], "category":{"door":{"isOpen":true}}}],
            "sections":[{"center":[1.,0.,0.], "label":"lobby"}]}]),
        );
        assert_eq!(native[0]["doors"][0]["transform"][12], 0.5);
        assert_eq!(native[0]["doors"][0]["polygonCorners"][0][0], 0.);
        assert_eq!(native[0]["sections"][0]["center"][0], 1.5);
        assert_eq!(corrector.omitted, 1);
    }

    #[test]
    fn supplied_camera_track_uses_each_pose_time() {
        let a = alignment();
        let features = BTreeMap::new();
        let mut corrector = Corrector::new(&a, &features);
        let track = corrector.track(json!({"schema_version":1,"clock":"arkit_uptime_seconds","unix_offset_seconds":1000.,
            "poses":[{"t":0.,"m":IDENTITY},{"t":1.,"m":IDENTITY},{"t":2.,"m":IDENTITY}]})).unwrap();
        assert_eq!(track["poses"][0]["m"][12], 0.);
        assert_eq!(track["poses"][1]["m"][12], 0.25);
        assert_eq!(track["poses"][2]["m"][12], 0.5);
        assert_eq!(track["unix_offset_seconds"], 1000.);
    }
}
