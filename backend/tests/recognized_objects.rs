use inview_backend::{
    capture::{
        CameraCalibration, Confidence, Coordinates, DepthFrame, DepthImage, DetectedObject,
        ScanBundle,
    },
    geometry::{Bounds, Transform},
    recognized_objects::{
        Detection, ObjectFusion, RECOGNITION_CATEGORIES, canonical_category, merge_recognized,
        supported_category,
    },
    scene::{self, ProcessingOptions},
};

fn pose(x: f64, y: f64, z: f64) -> Transform {
    Transform([1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., x, y, z, 1.])
}

fn observation(
    id: usize,
    camera_x: f64,
    rectangles: &[(usize, usize)],
    category: &str,
) -> (DepthFrame, Vec<Detection>) {
    let shift = (camera_x * 40.).round() as isize;
    let mut depth = vec![None; 64 * 64];
    let mut detections = Vec::new();
    for &(start, end) in rectangles {
        let mut indices = Vec::new();
        for row in 16..36 {
            for original_col in start..end {
                let col = original_col as isize - shift;
                if !(0..64).contains(&col) {
                    continue;
                }
                let index = row * 64 + col as usize;
                depth[index] =
                    Some(2. + (original_col - start) as f64 * 0.008 + (row - 16) as f64 * 0.008);
                indices.push(index);
            }
        }
        detections.push(Detection {
            category: category.into(),
            score: 0.94,
            depth_indices: indices,
        });
    }
    (
        DepthFrame {
            id: format!("frame-{id}"),
            timestamp_seconds: id as f64 + 1.,
            pixel_orientation: "sensor_native".into(),
            map_from_camera: pose(camera_x, 1.5, 0.),
            camera: CameraCalibration {
                image_width: 128,
                image_height: 128,
                fx: 160.,
                fy: 160.,
                cx: 64.,
                cy: 64.,
            },
            depth: DepthImage {
                width: 64,
                height: 64,
                values_m: depth,
                confidence: Some(vec![2; 64 * 64]),
            },
            color_asset: None,
        },
        detections,
    )
}

fn bundle(objects: Vec<DetectedObject>) -> ScanBundle {
    ScanBundle {
        schema_version: 1,
        id: "recognized-test".into(),
        map_id: "map".into(),
        floor_id: "ground".into(),
        coordinates: Coordinates {
            units: "meters".into(),
            up_axis: "y".into(),
            handedness: "right".into(),
        },
        meshes: vec![],
        frames: vec![],
        objects,
        surfaces: vec![],
    }
}

#[test]
fn calibrated_lifting_preserves_camera_sign_and_corrected_rotation() {
    let (frame, detections) = observation(0, 0., &[(38, 56)], "plant");
    let mut fusion = ObjectFusion::default();
    fusion.integrate(&frame, &detections);
    let objects = fusion.finish();
    assert_eq!(objects.len(), 1);
    assert!(objects[0].map_from_object.0[12] > 0.);
    assert!(objects[0].map_from_object.0[14] < -2.);
    assert_eq!(objects[0].confidence, Confidence::Low);
    let mut rotated = frame.clone();
    rotated.map_from_camera = Transform([
        -1., 0., 0., 0., 0., 1., 0., 0., 0., 0., -1., 0., 4., 1.5, 5., 1.,
    ]);
    let mut fusion = ObjectFusion::default();
    fusion.integrate(&rotated, &detections);
    let object = fusion.finish().remove(0);
    assert!(object.map_from_object.0[12] < 4.);
    assert!(object.map_from_object.0[14] > 7.);
    object.map_from_object.validate().unwrap();
    let bounds =
        Bounds::from_points(&object.map_from_object.box_corners(object.dimensions_m)).unwrap();
    for &index in &detections[0].depth_indices {
        let point = rotated.point_in_map(index, rotated.depth.values_m[index].unwrap());
        for (axis, value) in point.iter().enumerate() {
            assert!(*value >= bounds.min[axis] - 1e-8 && *value <= bounds.max[axis] + 1e-8);
        }
    }
}

#[test]
fn corrected_poses_merge_and_templates_require_independent_views_with_measured_bounds() {
    let (first, detections) = observation(0, 0., &[(24, 44)], "table");
    let mut fusion = ObjectFusion::default();
    fusion.integrate(&first, &detections);
    let mut stationary = first.clone();
    stationary.id = "stationary-frame".into();
    fusion.integrate(&stationary, &detections);
    assert_eq!(fusion.finish().len(), 1);
    assert_eq!(fusion.finish()[0].confidence, Confidence::Low);
    let (mut corrected, detections) = observation(1, 0.15, &[(24, 44)], "table");
    corrected.map_from_camera.0[12] += 2.;
    corrected.map_from_camera.0[12] -= 2.; // Pose-graph correction before fusion.
    fusion.integrate(&corrected, &detections);
    assert_eq!(fusion.finish().len(), 1);
    assert_eq!(fusion.finish()[0].confidence, Confidence::Medium);
    let (third, detections) = observation(2, 0.30, &[(24, 44)], "table");
    fusion.integrate(&third, &detections);
    assert_eq!(fusion.finish()[0].confidence, Confidence::High);
    let bundle = bundle(fusion.finish());
    bundle.validate().unwrap();
    let scene = scene::process(&bundle, ProcessingOptions::default()).unwrap();
    assert_ne!(scene.objects[0].model_key, "bounds_v1");
    assert_eq!(
        scene.objects[0].measured_dimensions_m,
        bundle.objects[0].dimensions_m
    );
    assert_eq!(
        scene.objects[0].map_from_object,
        bundle.objects[0].map_from_object
    );
    for mesh in &scene.objects[0].model_meshes {
        for vertex in &mesh.vertices {
            for (axis, value) in vertex.iter().enumerate() {
                assert!(value.abs() <= bundle.objects[0].dimensions_m[axis] / 2. + 1e-9);
            }
        }
    }
}

#[test]
fn adjacent_chairs_keep_separate_ids_when_detection_order_changes() {
    let (first, detections) = observation(0, 0., &[(8, 24), (40, 56)], "chair");
    let mut fusion = ObjectFusion::default();
    fusion.integrate(&first, &detections);
    let (second, mut detections) = observation(1, 0.15, &[(8, 24), (40, 56)], "chair");
    detections.reverse();
    fusion.integrate(&second, &detections);
    let objects = fusion.finish();
    assert_eq!(objects.len(), 2);
    assert_eq!(objects[0].id, "recognized-object-1");
    assert_eq!(objects[1].id, "recognized-object-2");
    assert!(objects[0].map_from_object.0[12] + 0.5 < objects[1].map_from_object.0[12]);
    bundle(objects).validate().unwrap();
}

#[test]
fn background_missing_and_low_confidence_depth_do_not_invent_volume() {
    let (mut frame, mut detections) = observation(0, 0., &[(20, 44)], "plant");
    for row in 16..24 {
        for col in 46..54 {
            let index = row * 64 + col;
            frame.depth.values_m[index] = Some(5.);
            detections[0].depth_indices.push(index);
        }
    }
    frame.depth.values_m[detections[0].depth_indices[50]] = Some(7.5);
    let mut fusion = ObjectFusion::default();
    fusion.integrate(&frame, &detections);
    let objects = fusion.finish();
    assert_eq!(objects.len(), 1);
    assert!(objects[0].map_from_object.0[14] > -2.5);
    assert!(objects[0].dimensions_m[2] < 0.7);
    for variant in 0..5 {
        let mut rejected = frame.clone();
        let mut detections = detections.clone();
        match variant {
            0 => rejected.depth.confidence = None,
            1 => rejected.depth.confidence = Some(vec![0; 64 * 64]),
            2 => {
                for &index in detections[0].depth_indices.iter().skip(23) {
                    rejected.depth.values_m[index] = None;
                }
            }
            3 => {
                for &index in &detections[0].depth_indices {
                    rejected.depth.values_m[index] = Some(9.);
                }
            }
            _ => detections[0].depth_indices.push(64 * 64 + 1),
        }
        let mut fusion = ObjectFusion::default();
        fusion.integrate(&rejected, &detections);
        assert!(fusion.finish().is_empty());
        assert_eq!(fusion.stats().detections_rejected, 1);
    }
}

#[test]
fn sparse_mask_clouds_are_bounded_and_outputs_deterministic() {
    let (mut frame, mut detections) = observation(0, 0., &[(12, 52)], "plant");
    detections[0]
        .depth_indices
        .retain(|index| index % 3 == 0 && (index / 64) % 2 == 0);
    let mut a = ObjectFusion::default();
    let mut b = ObjectFusion::default();
    for index in 0..80 {
        frame.id = format!("sparse-{index}");
        frame.timestamp_seconds = index as f64;
        frame.map_from_camera.0[12] = (index % 8) as f64 * 0.002;
        a.integrate(&frame, &detections);
        b.integrate(&frame, &detections);
    }
    assert_eq!(a.finish().len(), 1);
    assert_eq!(
        serde_json::to_value(a.finish()).unwrap(),
        serde_json::to_value(b.finish()).unwrap()
    );
    assert!(a.stats().retained_points <= 1024);
    assert_eq!(a.finish()[0].confidence, Confidence::Low);
}

#[test]
fn naming_raw_obstacles_retains_exact_navigation_envelopes_and_withholds_ambiguous_matches() {
    let raw = DetectedObject {
        id: "raw-obstacle".into(),
        category: "unclassified_obstacle".into(),
        confidence: Confidence::Unknown,
        map_from_object: pose(1., 0.5, 2.),
        dimensions_m: [0.6, 1., 0.5],
    };
    let recognized = DetectedObject {
        id: "recognized-object-1".into(),
        category: "chair".into(),
        confidence: Confidence::Medium,
        map_from_object: pose(1.01, 0.5, 2.01),
        dimensions_m: [0.58, 0.98, 0.48],
    };
    let (merged, stats) = merge_recognized(vec![raw.clone()], vec![recognized.clone()]);
    assert_eq!(merged.len(), 1);
    assert_eq!(merged[0].id, raw.id);
    assert_eq!(merged[0].map_from_object, raw.map_from_object);
    assert_eq!(merged[0].dimensions_m, raw.dimensions_m);
    assert_eq!(merged[0].category, "chair");
    assert_eq!(merged[0].confidence, Confidence::Medium);
    assert_eq!(stats.labeled_existing, 1);
    let mut second = recognized.clone();
    second.id = "recognized-object-2".into();
    second.map_from_object.0[12] -= 0.04;
    let (ambiguous, stats) = merge_recognized(vec![raw.clone()], vec![recognized, second]);
    assert_eq!(ambiguous.len(), 1);
    assert_eq!(ambiguous[0].category, "unclassified_obstacle");
    assert_eq!(ambiguous[0].map_from_object, raw.map_from_object);
    assert_eq!(stats.withheld_ambiguous, 2);
}

#[test]
fn catalog_and_detection_json_match_the_worker() {
    for category in RECOGNITION_CATEGORIES {
        assert!(supported_category(category));
    }
    assert_eq!(canonical_category("cabinet"), Some("storage"));
    assert_eq!(canonical_category("round_table"), Some("round_table"));
    assert_eq!(canonical_category("rug"), Some("rug"));
    assert!(!supported_category("person"));
    let detection = Detection {
        category: "plant".into(),
        score: 0.9,
        depth_indices: vec![1, 2, 3],
    };
    let restored: Detection =
        serde_json::from_value(serde_json::to_value(detection).unwrap()).unwrap();
    assert_eq!(restored.depth_indices, [1, 2, 3]);
}

#[test]
fn only_confirmed_recognition_adds_objects_and_uncertainty_remains_in_measured_mesh() {
    let raw = DetectedObject {
        id: "raw-obstacle".into(),
        category: "unclassified_obstacle".into(),
        confidence: Confidence::Unknown,
        map_from_object: pose(0., 0.5, 0.),
        dimensions_m: [0.5, 1., 0.5],
    };
    let low = DetectedObject {
        id: "recognized-object-1".into(),
        category: "chair".into(),
        confidence: Confidence::Low,
        map_from_object: pose(4., 0.5, 0.),
        dimensions_m: [0.5, 1., 0.5],
    };
    let mut confirmed = low.clone();
    confirmed.id = "recognized-object-2".into();
    confirmed.confidence = Confidence::Medium;
    confirmed.map_from_object.0[12] = 6.;
    let (merged, stats) = merge_recognized(vec![raw.clone()], vec![low, confirmed]);
    assert_eq!(merged.len(), 2);
    assert_eq!(
        serde_json::to_value(&merged[0]).unwrap(),
        serde_json::to_value(&raw).unwrap()
    );
    assert_eq!(merged[1].id, "recognized-object-2");
    assert_eq!(stats.added, 1);
    assert_eq!(stats.unconfirmed_in_mesh, 1);
}

#[test]
fn raw_navigation_envelopes_cannot_inherit_a_mismatched_chair_template_orientation() {
    let raw = DetectedObject {
        id: "raw-chair-bounds".into(),
        category: "unclassified_obstacle".into(),
        confidence: Confidence::Unknown,
        map_from_object: pose(1., 0.5, 2.),
        dimensions_m: [0.6, 1., 0.5],
    };
    for reversed in [false, true] {
        let mut recognized = raw.clone();
        recognized.id = "recognized-object-1".into();
        recognized.category = "chair".into();
        recognized.confidence = Confidence::High;
        if reversed {
            recognized.map_from_object = Transform([
                -1., 0., 0., 0., 0., 1., 0., 0., 0., 0., -1., 0., 1., 0.5, 2., 1.,
            ]);
        } else {
            recognized.map_from_object = Transform([
                0., 0., 1., 0., 0., 1., 0., 0., -1., 0., 0., 0., 1., 0.5, 2., 1.,
            ]);
            recognized.dimensions_m = [0.5, 1., 0.6];
        }
        let (merged, stats) = merge_recognized(vec![raw.clone()], vec![recognized]);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].id, raw.id);
        assert_eq!(merged[0].map_from_object, raw.map_from_object);
        assert_eq!(merged[0].dimensions_m, raw.dimensions_m);
        assert_eq!(merged[0].category, "chair");
        assert_eq!(merged[0].confidence, Confidence::Low);
        assert_eq!(stats.withheld_orientation, 1);
        let scene = scene::process(&bundle(merged), ProcessingOptions::default()).unwrap();
        assert_eq!(scene.objects[0].model_key, "bounds_v1");
    }
}

#[test]
fn alternating_categories_for_one_physical_object_do_not_create_duplicate_templates() {
    for categories in [["table", "round_table"], ["plant", "square_planter"]] {
        let mut fusion = ObjectFusion::default();
        for index in 0..4 {
            let (frame, detections) = observation(
                index,
                index as f64 * 0.15,
                &[(24, 44)],
                categories[index % 2],
            );
            fusion.integrate(&frame, &detections);
        }
        let recognized = fusion.finish();
        assert_eq!(recognized.len(), 2);
        assert!(
            recognized
                .iter()
                .all(|object| object.confidence >= Confidence::Medium)
        );
        let (merged, stats) = merge_recognized(vec![], recognized.clone());
        assert!(
            merged.is_empty(),
            "conflicting labels keep measured mesh as fallback"
        );
        assert_eq!(stats.withheld_ambiguous, 2);

        let mut raw = recognized[0].clone();
        raw.id = "raw-object".into();
        raw.category = "unclassified_obstacle".into();
        raw.confidence = Confidence::Unknown;
        let (merged, stats) = merge_recognized(vec![raw.clone()], recognized);
        assert_eq!(merged.len(), 1);
        assert_eq!(
            serde_json::to_value(&merged[0]).unwrap(),
            serde_json::to_value(raw).unwrap()
        );
        assert_eq!(stats.withheld_ambiguous, 2);
    }
}

#[test]
fn generated_ids_reserve_existing_source_ids_and_new_objects_reserve_their_bounds() {
    let raw = DetectedObject {
        id: "recognized-object-1".into(),
        category: "unclassified_obstacle".into(),
        confidence: Confidence::Unknown,
        map_from_object: pose(0., 0.5, 0.),
        dimensions_m: [0.5, 1., 0.5],
    };
    let mut recognized = raw.clone();
    recognized.map_from_object.0[12] = 4.;
    recognized.category = "plant".into();
    recognized.confidence = Confidence::Medium;
    let mut duplicate = recognized.clone();
    duplicate.id = "recognized-object-3".into();
    let input = vec![recognized, duplicate];
    let (merged, stats) = merge_recognized(vec![raw.clone()], input.clone());
    assert_eq!(merged.len(), 2);
    assert_eq!(merged[0].id, raw.id);
    assert_eq!(merged[0].map_from_object, raw.map_from_object);
    assert_eq!(merged[0].dimensions_m, raw.dimensions_m);
    assert_eq!(merged[1].id, "recognized-object-2");
    assert_eq!(stats.added, 1);
    assert_eq!(stats.withheld_ambiguous, 1);
    bundle(merged.clone()).validate().unwrap();
    assert_eq!(
        serde_json::to_value(merged).unwrap(),
        serde_json::to_value(merge_recognized(vec![raw], input).0).unwrap()
    );
}
