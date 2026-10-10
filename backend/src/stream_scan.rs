//! Turns a finished continuous-capture stream into an immutable `.inviewscan.tar` scan package, so
//! the scan store, Studio, building maps and the OpenCV worker pipeline treat streamed scans exactly
//! like uploaded packages.
//!
//! The package keeps the stream's evidence in the shared ARKit frame with loop-closure corrections
//! applied: a bounded, evenly spaced set of observations (upright RGB keyframe, float32 depth and
//! confidence sidecars, corrected pose, calibration, geographic/building environment sample), the
//! dense movement track (`camera-track.json`), the reconstructed capture (`capture.json`, RoomPlan
//! surfaces/objects and the fused depth mesh), and any whole-capture attachments the phone sent
//! (`roomplan.json`, `semantics.json`, `text-observations.json`).
use std::{collections::BTreeMap, io::Cursor};

use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    alignment::AlignmentResult,
    geometry::Transform,
    streaming::{StreamChunk, StreamError, StreamPose, StreamStore},
};

/// Observations kept in a package: enough to cover a long walk at a few metres apart while
/// staying far below the 256 MiB / 4096-file package limits (≈ 0.5 MiB and 3 files each).
pub const MAX_OBSERVATIONS: usize = 240;
const FLOAT32_DEPTH: u32 = 1_717_855_600; // CoreVideo kCVPixelFormatType_DepthFloat32
const JPEG_QUALITY: u8 = 88;

#[derive(Deserialize)]
struct CachedResult {
    capture: Value,
    alignment: AlignmentResult,
}

/// Evenly spaced sequence numbers, always including the first and last observation.
pub fn select(count: usize, limit: usize) -> Vec<usize> {
    if count <= limit {
        return (0..count).collect();
    }
    let mut picked: Vec<usize> = (0..limit)
        .map(|i| i * (count - 1) / (limit - 1).max(1))
        .collect();
    picked.dedup();
    picked
}

fn compose(left: Transform, right: Transform) -> Transform {
    let (a, b) = (left.0, right.0);
    let mut out = [0.0; 16];
    for column in 0..4 {
        for row in 0..4 {
            out[column * 4 + row] = (0..4).map(|k| a[k * 4 + row] * b[column * 4 + k]).sum();
        }
    }
    Transform(out)
}

/// Rotates a sensor-native (landscape) JPEG 90° clockwise into the upright orientation the iPhone
/// uses for keyframes, so every downstream consumer keeps one image convention: upright pixel
/// (px, py) of a W×H image is sensor-normalized (u, v) = (py / H, 1 − px / W).
pub fn upright_jpeg(sensor_jpeg: &[u8]) -> Result<(Vec<u8>, u16, u16), String> {
    let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(sensor_jpeg));
    let pixels = decoder
        .decode()
        .map_err(|e| format!("keyframe JPEG: {e}"))?;
    let info = decoder.info().ok_or("keyframe JPEG has no dimensions")?;
    let (width, height) = (info.width as usize, info.height as usize);
    let channels = match info.pixel_format {
        jpeg_decoder::PixelFormat::RGB24 => 3,
        jpeg_decoder::PixelFormat::L8 => 1,
        other => return Err(format!("unsupported keyframe pixel format {other:?}")),
    };
    if pixels.len() != width * height * channels {
        return Err("keyframe JPEG is truncated".into());
    }
    // Upright is H wide and W tall; upright(px, py) = sensor(x = py, y = H − 1 − px).
    let (out_w, out_h) = (height, width);
    let mut rotated = vec![0u8; pixels.len()];
    for py in 0..out_h {
        for px in 0..out_w {
            let (sx, sy) = (py, height - 1 - px);
            let src = (sy * width + sx) * channels;
            let dst = (py * out_w + px) * channels;
            rotated[dst..dst + channels].copy_from_slice(&pixels[src..src + channels]);
        }
    }
    let color = if channels == 3 {
        jpeg_encoder::ColorType::Rgb
    } else {
        jpeg_encoder::ColorType::Luma
    };
    let mut out = Vec::new();
    jpeg_encoder::Encoder::new(&mut out, JPEG_QUALITY)
        .encode(&rotated, out_w as u16, out_h as u16, color)
        .map_err(|e| format!("keyframe JPEG encode: {e}"))?;
    Ok((out, out_w as u16, out_h as u16))
}

/// Builds the package bytes for a finished stream. Requires the reconstruction (loop-closure
/// alignment and capture) as cached JSON from `StreamStore::reconstruct_encoded`.
pub fn build_package(
    store: &StreamStore,
    id: &str,
    result_json: &[u8],
) -> Result<Vec<u8>, StreamError> {
    let cached: CachedResult = serde_json::from_slice(result_json)
        .map_err(|e| StreamError::Malformed(format!("stream result: {e}")))?;
    let alignment = cached.alignment;
    let attachments = store.assets(id)?;
    let mut files: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut observations = Vec::new();
    let mut track: Vec<StreamPose> = Vec::new();
    let mut unix_offset: Option<f64> = None;
    let mut picked = Vec::new();
    let count = store.summary(id)?.frame_count;
    let selected = select(count, MAX_OBSERVATIONS);
    let mut next = selected.iter().peekable();

    let (manifest, _) = store.for_each_chunk(id, |sequence, chunk: StreamChunk| {
        let correction = alignment.correction_for(chunk.frame.timestamp_seconds);
        let pose = compose(correction, chunk.frame.map_from_camera);
        // Movement: every recorded pose plus every keyframe pose, loop-corrected.
        for p in &chunk.poses {
            track.push(StreamPose { m: compose(alignment.correction_for(p.t), p.m), ..p.clone() });
        }
        track.push(StreamPose {
            t: chunk.frame.timestamp_seconds,
            m: pose,
            tracking: Some("normal".into()),
            mapping: None,
        });
        let recorded = chunk
            .environment
            .as_ref()
            .and_then(|e| e.get("recorded_at_unix_seconds"))
            .and_then(Value::as_f64);
        if unix_offset.is_none()
            && let Some(unix) = recorded
        {
            unix_offset = Some(unix - chunk.frame.timestamp_seconds);
        }
        if next.peek() != Some(&&sequence) {
            return Ok(());
        }
        next.next();
        let stem = format!("s{sequence:05}");
        let frame = &chunk.frame;
        let (width, height) = (frame.depth.width, frame.depth.height);
        let depth: Vec<u8> = frame
            .depth
            .values_m
            .iter()
            .flat_map(|v| (v.filter(|d| *d > 0.0 && d.is_finite()).unwrap_or(f64::NAN) as f32).to_le_bytes())
            .collect();
        files.insert(format!("{stem}.depth-f32le"), depth);
        let confidence_asset = frame.depth.confidence.as_ref().map(|values| {
            files.insert(format!("{stem}.confidence-u8"), values.clone());
            format!("{stem}.confidence-u8")
        });
        let jpeg = STANDARD
            .decode(&chunk.color_jpeg)
            .map_err(|_| StreamError::Malformed("stored color_jpeg is not base64".into()))?;
        let rgb_asset = match upright_jpeg(&jpeg) {
            Ok((upright, w, h)) => {
                files.insert(format!("{stem}.color.jpg"), upright);
                Some((format!("{stem}.color.jpg"), w, h))
            }
            Err(error) => {
                tracing::warn!(stream = id, sequence, %error, "Skipping unreadable keyframe colour");
                None
            }
        };
        let camera = &frame.camera;
        let mut raw_depth = json!({
            "raw_asset": format!("{stem}.depth-f32le"), "confidence_asset": confidence_asset,
            "smoothed_asset": null, "width": width, "height": height, "bytes_per_row": width * 4,
            "pixel_format": FLOAT32_DEPTH, "confidence_bytes_per_row": confidence_asset.as_ref().map(|_| width),
        });
        if let Some(environment) = &chunk.environment {
            raw_depth["environment"] = environment.clone();
        }
        observations.push(json!({
            "id": frame.id, "timestamp_seconds": frame.timestamp_seconds,
            "rgb_asset": rgb_asset.as_ref().map(|(name, _, _)| name.clone()),
            "rgb_image": rgb_asset.as_ref().map(|(_, w, h)| json!({
                "width": w, "height": h, "orientation": "upright_rotated_right_from_sensor"})),
            "map_from_camera": pose,
            "image": {"width": camera.image_width, "height": camera.image_height,
                      "fx": camera.fx, "fy": camera.fy, "cx": camera.cx, "cy": camera.cy},
            "raw_depth": raw_depth,
            "stream_sequence": sequence,
        }));
        picked.push(sequence);
        Ok(())
    })?;

    if observations.is_empty() {
        return Err(StreamError::Invalid(
            "The stream has no observations to package.".into(),
        ));
    }
    track.sort_by(|a, b| a.t.total_cmp(&b.t));
    track.dedup_by(|a, b| (a.t - b.t).abs() < 1e-6);
    let camera_track = attachments.get("camera-track.json").cloned().unwrap_or_else(|| {
        serde_json::to_vec(&json!({
            "schema_version": 1, "clock": "arkit_uptime_seconds",
            "unix_offset_seconds": unix_offset, "source": "stream_chunks_loop_corrected",
            "poses": track.iter().map(|p| json!({
                "t": p.t, "m": p.m, "tracking": p.tracking.clone().unwrap_or_else(|| "normal".into()),
                "mapping": p.mapping.clone().unwrap_or_else(|| "not_available".into()),
            })).collect::<Vec<_>>(),
        }))
        .expect("track JSON")
    });
    files.insert("camera-track.json".into(), camera_track);
    for (name, bytes) in attachments {
        if name != "camera-track.json" {
            files.insert(name, bytes);
        }
    }

    let mut capture = cached.capture;
    capture["id"] = json!(manifest.id);
    if let Some(metadata) = capture.get_mut("metadata").and_then(Value::as_object_mut) {
        metadata.insert("packaged_from_stream".into(), json!(true));
        metadata.insert("packaged_observations".into(), json!(picked.len()));
        metadata.insert("stream_frame_count".into(), json!(count));
    }
    files.insert(
        "capture.json".into(),
        serde_json::to_vec(&capture).map_err(|e| StreamError::Malformed(e.to_string()))?,
    );

    let role = |name: &str| match name {
        "capture.json" => "portable_capture",
        "roomplan.json" => "roomplan_original",
        "camera-track.json" => "camera_track",
        "semantics.json" => "capture_semantics",
        "text-observations.json" => "text_observations",
        n if n.ends_with(".color.jpg") => "rgb_keyframe",
        n if n.ends_with(".depth-f32le") => "raw_depth_float32",
        n if n.ends_with(".confidence-u8") => "depth_confidence",
        _ => "opaque_sidecar",
    };
    let media = |name: &str| {
        if name.ends_with(".json") {
            "application/json"
        } else if name.ends_with(".jpg") {
            "image/jpeg"
        } else {
            "application/octet-stream"
        }
    };
    let assets: Vec<Value> = files
        .iter()
        .map(|(name, bytes)| json!({"path": name, "role": role(name), "media_type": media(name), "bytes": bytes.len()}))
        .collect();
    let coordinates = &manifest.coordinates;
    let package_manifest = json!({
        "schema_version": 1, "capture_id": manifest.id, "map_id": manifest.map_id,
        "floor_id": manifest.floor_id,
        "coordinate_frame": {"units": coordinates.units, "up_axis": coordinates.up_axis,
                             "handedness": coordinates.handedness, "name": "shared_arkit_session"},
        "assets": assets, "observations": observations, "mesh_anchors": [],
        "source": {"kind": "continuous_stream", "stream_id": id, "frame_count": count,
                   "alignment_optimized": alignment.optimized},
    });
    files.insert(
        "package-manifest.json".into(),
        serde_json::to_vec(&package_manifest).map_err(|e| StreamError::Malformed(e.to_string()))?,
    );

    let mut tar = tar::Builder::new(Vec::new());
    for (name, bytes) in &files {
        let mut header = tar::Header::new_ustar();
        header.set_size(bytes.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        tar.append_data(
            &mut header,
            format!("{}/{name}", manifest.id),
            bytes.as_slice(),
        )
        .map_err(StreamError::Storage)?;
    }
    tar.into_inner().map_err(StreamError::Storage)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selection_keeps_both_ends_and_respects_the_limit() {
        assert_eq!(select(5, 10), vec![0, 1, 2, 3, 4]);
        let picked = select(1000, 240);
        assert_eq!(picked.len(), 240);
        assert_eq!((picked[0], *picked.last().unwrap()), (0, 999));
        assert!(picked.windows(2).all(|w| w[0] < w[1]));
    }

    #[test]
    fn upright_rotation_moves_pixels_clockwise() {
        // 4×2 sensor image; mark sensor pixel (x=3, y=0) (top-right) bright.
        let (w, h) = (4usize, 2usize);
        let mut pixels = vec![0u8; w * h * 3];
        pixels[3 * 3..3 * 3 + 3].copy_from_slice(&[250, 250, 250]);
        let mut sensor = Vec::new();
        jpeg_encoder::Encoder::new(&mut sensor, 100)
            .encode(&pixels, w as u16, h as u16, jpeg_encoder::ColorType::Rgb)
            .unwrap();
        let (upright, uw, uh) = upright_jpeg(&sensor).unwrap();
        assert_eq!((uw, uh), (2, 4));
        let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(&upright));
        let out = decoder.decode().unwrap();
        // Sensor (3, 0) maps to upright (px = H − 1 − 0 = 1, py = 3): the bottom-right pixel.
        let at = |px: usize, py: usize| out[(py * 2 + px) * 3] as i32;
        assert!(
            at(1, 3) > at(0, 0) + 100,
            "rotated bright pixel should be bottom-right"
        );
    }
}
