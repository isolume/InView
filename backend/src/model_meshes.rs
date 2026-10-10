//! Curated, deterministic display models. Navigation uses the captured obstacle, not these
//! templates. Each template is centered, y up, front at -z, and bounded by its source box.
use serde::Serialize;

use crate::geometry::Vec3;

mod photo_furniture;

/// Choose a photographed display silhouette without changing the measured obstacle.
/// Explicit labels remain available for objects whose coarse capture category is ambiguous.
pub fn photo_model_key(category: &str, size: Vec3) -> Option<&'static str> {
    let category = category.trim().to_ascii_lowercase();
    match category.as_str() {
        "chair" | "armchair" | "lounge_chair" | "lounge_chair_v1" => Some("lounge_chair_v1"),
        "sofa" if size[1] <= 0.6 && size[0] / size[2] >= 2.8 => Some("bench_v1"),
        "sofa" | "loveseat" | "modular_sofa" | "modular_sofa_v1" => Some("modular_sofa_v1"),
        "table" if size[1] <= 0.62 && (0.8..=1.25).contains(&(size[0] / size[2])) => {
            Some("drum_table_v1")
        }
        "table" | "folding_table" | "folding_table_v1" => Some("folding_table_v1"),
        "drum_table" | "round_table" | "ottoman" | "drum_table_v1" => Some("drum_table_v1"),
        "charging_stand" | "charging_stand_v1" => Some("charging_stand_v1"),
        "lectern" | "podium" | "lectern_v1" => Some("lectern_v1"),
        "sign_stand" | "sign_stand_v1" => Some("sign_stand_v1"),
        "waste_bin" | "trash_bin" | "waste_bin_v1" => Some("waste_bin_v1"),
        "open_bin" | "open_bin_v1" => Some("open_bin_v1"),
        "bench" | "bench_v1" => Some("bench_v1"),
        "square_planter" | "square_planter_v1" => Some("square_planter_v1"),
        "railing" | "railing_v1" => Some("railing_v1"),
        "floor_sign" | "caution_sign" | "floor_sign_v1" => Some("floor_sign_v1"),
        _ => None,
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct ModelMesh {
    pub name: String,
    pub vertices: Vec<Vec3>,
    pub normals: Vec<Vec3>,
    /// Counterclockwise winding viewed from outside the component.
    pub triangles: Vec<[usize; 3]>,
    pub color: String,
}

/// Build only the requested supplied category, using positive, finite measured dimensions.
/// Rounded profiles, bowed panels, and inflated cushions supply a deliberate silhouette;
/// geometry is not inferred from a raw scan and unknown objects keep measured envelopes.
pub fn furniture_meshes(key: &str, size: Vec3) -> Vec<ModelMesh> {
    // Very extreme envelopes cannot represent centimeter detail reliably. Use a
    // proportional display template in those cases; measured obstacles stay untouched.
    let smallest = size.into_iter().fold(f64::INFINITY, f64::min);
    let largest = size.into_iter().fold(0.0, f64::max);
    let catalog_size = if smallest < 1e-6 || largest > 1e6 || smallest / largest < 1e-8 {
        [1.0; 3]
    } else {
        size
    };
    let mut model = ModelBuilder::new(catalog_size);
    match key {
        "lounge_chair_v1" => photo_furniture::lounge_chair(&mut model),
        "modular_sofa_v1" => photo_furniture::modular_sofa(&mut model),
        "drum_table_v1" => photo_furniture::drum_table(&mut model),
        "charging_stand_v1" => photo_furniture::charging_stand(&mut model),
        "lectern_v1" => photo_furniture::lectern(&mut model),
        "folding_table_v1" => photo_furniture::folding_table(&mut model),
        "sign_stand_v1" => photo_furniture::sign_stand(&mut model),
        "waste_bin_v1" => photo_furniture::waste_bin(&mut model),
        "open_bin_v1" => photo_furniture::open_bin(&mut model),
        "bench_v1" => photo_furniture::bench(&mut model),
        "square_planter_v1" => photo_furniture::square_planter(&mut model),
        "railing_v1" => photo_furniture::railing(&mut model),
        "floor_sign_v1" => photo_furniture::floor_sign(&mut model),
        "chair_v2" | "chair_v1" => chair(&mut model),
        "sofa_v2" | "sofa_v1" => sofa(&mut model),
        "table_v2" | "table_v1" => table(&mut model),
        "storage_v2" => storage(&mut model),
        "bed_v2" => bed(&mut model),
        "sink_v2" => sink(&mut model),
        "plant_v2" => plant(&mut model),
        "rug_v2" => rug(&mut model),
        _ => model.rounded(
            "measured unknown object",
            [0.0; 3],
            [1.0; 3],
            0.018,
            "#cbd4da",
        ),
    }
    for mesh in &mut model.meshes {
        for vertex in &mut mesh.vertices {
            for axis in 0..3 {
                vertex[axis] *= size[axis];
            }
        }
        for normal in &mut mesh.normals {
            // Inverse-transpose nonuniform scale using relative ratios, avoiding overflow.
            let scale = (0..3)
                .filter(|&axis| normal[axis] != 0.0)
                .map(|axis| size[axis])
                .fold(f64::INFINITY, f64::min);
            *normal = normalized(std::array::from_fn(|axis| {
                if normal[axis] == 0.0 {
                    0.0
                } else {
                    normal[axis] * (scale / size[axis])
                }
            }));
        }
    }
    model.meshes
}

fn chair(model: &mut ModelBuilder) {
    let [width, height, depth] = model.size;
    let pad_height = 0.052_f64.min(height * 0.072);
    let frame_height = 0.028_f64.min(height * 0.043);
    let seat_top = -0.002 * height;
    let pad_center = (seat_top - pad_height / 2.0) / height;
    let frame_center = (seat_top - pad_height - frame_height / 2.0 + frame_height * 0.10) / height;
    model.metric_rounded(
        "plywood seat frame",
        [0.0, frame_center, -0.065],
        [width * 0.89, frame_height, depth * 0.79],
        0.028,
        "#cbd4da",
    );
    model.metric_rounded(
        "thin upholstered seat pad",
        [0.0, pad_center, -0.065],
        [width * 0.86, pad_height, depth * 0.75],
        0.014,
        "#dbe2e5",
    );
    model.bowed_panel(
        "bent plywood back",
        [0.84, 0.022_f64.min(depth * 0.034) / depth],
        [0.047, 0.491],
        [0.35, 0.090],
        "#cbd4da",
    );
    let section = 0.046_f64.min(width * 0.12).min(depth * 0.12);
    let leg_top = (seat_top - pad_height - frame_height * 0.6) / height;
    for x in [-0.305_f64, 0.305] {
        for z in [-0.27_f64, 0.265] {
            let bottom = [x + x.signum() * 0.052, -0.5, z + z.signum() * 0.064];
            model.metric_leg(
                &format!("splayed hardwood leg {x} {z}"),
                bottom,
                [x, leg_top, z],
                [section * 0.77; 2],
                [section; 2],
                "#bcc8cf",
            );
        }
        model.metric_leg(
            &format!("back support {x}"),
            [x, leg_top, 0.265],
            [x, 0.155, 0.267],
            [section * 0.72; 2],
            [section * 0.64; 2],
            "#bcc8cf",
        );
    }
}

fn sofa(model: &mut ModelBuilder) {
    let [width, height, depth] = model.size;
    let arm_width = 0.115_f64.min(width * 0.085);
    let edge_margin = width * 0.005;
    let arm_x = (width / 2.0 - arm_width / 2.0 - edge_margin) / width;
    let base_height = 0.175_f64.min(height * 0.22);
    let base_center = -0.27 * height;
    let base_bottom = base_center - base_height / 2.0;
    let base_top = base_center + base_height / 2.0;
    let foot_section = 0.061_f64.min(width * 0.075).min(depth * 0.09);
    for x in [-0.40_f64, 0.40] {
        for z in [-0.30_f64, 0.30] {
            model.metric_leg(
                &format!("recessed oak foot {x} {z}"),
                [x + x.signum() * 0.009, -0.5, z + z.signum() * 0.012],
                [x, (base_bottom + 0.009_f64.min(height * 0.01)) / height, z],
                [foot_section * 0.85; 2],
                [foot_section; 2],
                "#bbc6cd",
            );
        }
    }
    model.metric_rounded(
        "architectural upholstered base",
        [0.0, -0.27, 0.0],
        [width * 0.98, base_height, depth * 0.92],
        0.018,
        "#ccd4d8",
    );
    let back_depth = 0.124_f64.min(depth * 0.17);
    let back_front = depth * 0.478 - back_depth;
    model.metric_rounded(
        "straight upholstered back frame",
        [0.0, 0.14, (depth * 0.478 - back_depth / 2.0) / depth],
        [width * 0.96, height * 0.68, back_depth],
        0.018,
        "#ccd4d8",
    );
    for x in [-arm_x, arm_x] {
        model.metric_rounded(
            &format!("clean sofa arm {x}"),
            [x, -0.095, -0.0175],
            [arm_width, 0.46_f64.min(height * 0.54), depth * 0.935],
            0.021,
            "#ccd4d8",
        );
    }
    let inner_width = width - 2.0 * (arm_width + edge_margin);
    let gap = 0.013_f64.min(width * 0.008);
    let cushion_width = (inner_width - gap * 2.0) / 3.0;
    let seat_height = 0.112_f64.min(height * 0.14);
    let seat_center = (base_top + seat_height / 2.0 - 0.008_f64.min(height * 0.01)) / height;
    let seat_depth = depth * 0.735;
    let seat_z = -0.0425;
    let back_pad_depth = 0.086_f64.min(depth * 0.13);
    for index in 0..3 {
        let x = (index as f64 - 1.0) * (cushion_width + gap) / width;
        model.metric_rounded(
            &format!("aligned seat cushion {index}"),
            [x, seat_center, seat_z],
            [cushion_width, seat_height, seat_depth],
            0.016,
            "#d5dde0",
        );
        model.metric_rounded(
            &format!("aligned back cushion {index}"),
            [
                x,
                0.165,
                (back_front - back_pad_depth / 2.0 + depth * 0.005) / depth,
            ],
            [cushion_width, height * 0.50, back_pad_depth],
            0.014,
            "#d5dde0",
        );
    }
}

fn table(model: &mut ModelBuilder) {
    let [width, height, depth] = model.size;
    let thickness = 0.044_f64.min(height * 0.13);
    let top = height / 2.0;
    let corner = 0.038_f64.min(width * 0.08).min(depth * 0.08);
    let outline = rounded_rectangle(width / 2.0, depth / 2.0, corner, 14);
    model.metric_extruded(
        "tabletop slab",
        1,
        &outline,
        [top - thickness, top],
        0.003_f64.min(thickness * 0.12),
        "#dbe2e5",
    );
    let section = 0.066_f64.min(width * 0.10).min(depth * 0.14);
    let leg_top = (top - thickness + 0.004_f64.min(height * 0.01)) / height;
    for x in [-0.36_f64, 0.36] {
        for z in [-0.34_f64, 0.34] {
            model.metric_leg(
                &format!("square tapered leg {x} {z}"),
                [x + x.signum() * 0.009, -0.5, z + z.signum() * 0.009],
                [x, leg_top, z],
                [section * 0.82; 2],
                [section; 2],
                "#c4d0d6",
            );
        }
    }
}

fn storage(model: &mut ModelBuilder) {
    model.rounded(
        "console carcass",
        [0.0, 0.072, 0.004],
        [0.962, 0.793, 0.945],
        0.016,
        "#ccd5da",
    );
    let outline = rounded_rectangle(0.5, 0.5, 0.045, 3);
    model.extruded(
        "oak console top",
        1,
        &outline,
        [0.446, 0.5],
        0.013,
        "#d5dde0",
    );
    for x in [-0.235_f64, 0.235] {
        model.rounded(
            &format!("inset cabinet door {x}"),
            [x, 0.065, -0.477],
            [0.455, 0.692, 0.034],
            0.008,
            "#d0d8dd",
        );
    }
    for x in [-0.355_f64, 0.355] {
        for z in [-0.30_f64, 0.30] {
            model.leg(
                &format!("console oak foot {x} {z}"),
                [x + x.signum() * 0.012, -0.5, z + z.signum() * 0.014],
                [x, -0.316, z],
                [0.061, 0.07],
                [0.083, 0.09],
                "#bbc6cd",
            );
        }
    }
}

fn bed(model: &mut ModelBuilder) {
    model.rounded(
        "bed platform",
        [0.0, -0.255, -0.035],
        [0.95, 0.155, 0.915],
        0.035,
        "#c4cfd5",
    );
    model.inflated(
        "mattress",
        [0.0, -0.112, -0.035],
        [0.946, 0.18, 0.91],
        6.0,
        "#dce3e6",
    );
    model.rounded(
        "upholstered headboard",
        [0.0, 0.15, 0.43],
        [0.98, 0.70, 0.14],
        0.035,
        "#ccd5da",
    );
    model.inflated(
        "folded duvet",
        [0.0, -0.002, -0.194],
        [0.925, 0.075, 0.575],
        5.0,
        "#d2dbe0",
    );
    for x in [-0.225, 0.225] {
        model.inflated(
            &format!("linen pillow {x}"),
            [x, 0.012, 0.228],
            [0.428, 0.132, 0.237],
            3.4,
            "#e0e6e9",
        );
    }
    for x in [-0.37, 0.37] {
        for z in [-0.33, 0.33] {
            model.leg(
                &format!("bed foot {x} {z}"),
                [x, -0.5, z],
                [x, -0.30, z],
                [0.076, 0.076],
                [0.089, 0.089],
                "#bbc6cd",
            );
        }
    }
}

fn sink(model: &mut ModelBuilder) {
    model.rounded(
        "vanity cabinet",
        [0.0, -0.12, 0.035],
        [0.90, 0.76, 0.85],
        0.015,
        "#cdd6db",
    );
    model.rounded(
        "vanity inset door",
        [0.0, -0.115, -0.411],
        [0.80, 0.63, 0.035],
        0.009,
        "#d3dce0",
    );
    // The ceramic bowl has a real recessed inner surface, not a painted rectangle.
    let bowl = [
        [0.0, 0.18],
        [0.22, 0.18],
        [0.69, 0.225],
        [1.0, 0.415],
        [1.0, 0.48],
        [0.875, 0.48],
        [0.87, 0.418],
        [0.59, 0.276],
        [0.16, 0.234],
        [0.0, 0.234],
    ];
    model.lathe(
        "recessed ceramic basin",
        [0.0, 0.0, -0.055],
        [0.425, 0.36],
        &bowl,
        24,
        "#e0e6e9",
    );
    model.rounded(
        "tap pedestal",
        [0.0, 0.305, 0.40],
        [0.041, 0.29, 0.041],
        0.008,
        "#bbc6cd",
    );
    model.rounded(
        "tap spout",
        [0.0, 0.43, 0.346],
        [0.041, 0.032, 0.147],
        0.008,
        "#c3cfd5",
    );
}

fn plant(model: &mut ModelBuilder) {
    let pot_profile = [
        [0.225, -0.5],
        [0.259, -0.484],
        [0.34, -0.208],
        [0.34, -0.185],
        [0.304, -0.185],
        [0.297, -0.22],
        [0.20, -0.46],
        [0.0, -0.46],
        [0.0, -0.5],
    ];
    model.lathe(
        "stoneware planter",
        [0.0; 3],
        [1.0, 1.0],
        &pot_profile,
        20,
        "#ccd5da",
    );
    let soil = [
        [0.0, -0.226],
        [0.294, -0.226],
        [0.294, -0.217],
        [0.0, -0.217],
    ];
    model.lathe("soil", [0.0; 3], [1.0, 1.0], &soil, 20, "#bac7ce");
    model.branch(
        "main woody stem",
        [0.0, -0.219, 0.0],
        [0.0, 0.365, 0.0],
        0.015,
        "#b7c4cb",
    );
    let leaves = [
        ([-0.045, -0.13, 0.0], [-0.37, 0.03, -0.07], 0.15),
        ([0.015, -0.08, 0.0], [0.38, 0.11, 0.055], 0.16),
        ([0.0, 0.00, -0.01], [0.10, 0.14, -0.395], 0.17),
        ([0.0, 0.075, 0.01], [-0.095, 0.23, 0.38], 0.17),
        ([-0.01, 0.145, 0.0], [-0.355, 0.31, 0.015], 0.155),
        ([0.01, 0.22, 0.0], [0.345, 0.365, -0.085], 0.15),
        ([0.0, 0.285, 0.0], [-0.085, 0.473, -0.22], 0.13),
        ([0.0, 0.325, 0.0], [0.09, 0.47, 0.205], 0.125),
    ];
    for (index, (root, tip, width)) in leaves.into_iter().enumerate() {
        let stalk_end = mix(root, tip, 0.35);
        model.branch(
            &format!("leaf stalk {index}"),
            root,
            stalk_end,
            0.008,
            "#b7c4cb",
        );
        model.leaf(
            &format!("sculpted leaf {index}"),
            mix(root, tip, 0.17),
            tip,
            width,
            "#c3cdd2",
        );
    }
}

fn rug(model: &mut ModelBuilder) {
    let perimeter = rounded_rectangle(0.5, 0.5, 0.018, 3);
    model.extruded("plain rug", 1, &perimeter, [-0.5, 0.5], 0.012, "#d5dce0");
}

struct ModelBuilder {
    meshes: Vec<ModelMesh>,
    size: Vec3,
}

impl ModelBuilder {
    fn new(size: Vec3) -> Self {
        Self {
            meshes: Vec::new(),
            size,
        }
    }

    fn metric_rounded(
        &mut self,
        name: &str,
        center: Vec3,
        dimensions: Vec3,
        radius: f64,
        color: &str,
    ) {
        let physical_center = std::array::from_fn(|axis| center[axis] * self.size[axis]);
        self.rounded(name, physical_center, dimensions, radius, color);
        normalize_metric_mesh(
            self.meshes.last_mut().expect("metric mesh was added"),
            self.size,
        );
    }

    fn metric_leg(
        &mut self,
        name: &str,
        bottom: Vec3,
        top: Vec3,
        bottom_size: [f64; 2],
        top_size: [f64; 2],
        color: &str,
    ) {
        let physical = |point: Vec3| std::array::from_fn(|axis| point[axis] * self.size[axis]);
        self.leg(
            name,
            physical(bottom),
            physical(top),
            bottom_size,
            top_size,
            color,
        );
        normalize_metric_mesh(
            self.meshes.last_mut().expect("metric mesh was added"),
            self.size,
        );
    }

    fn metric_extruded(
        &mut self,
        name: &str,
        axis: usize,
        profile: &[[f64; 2]],
        limits: [f64; 2],
        bevel: f64,
        color: &str,
    ) {
        self.extruded(name, axis, profile, limits, bevel, color);
        normalize_metric_mesh(
            self.meshes.last_mut().expect("metric mesh was added"),
            self.size,
        );
    }

    fn rounded(&mut self, name: &str, center: Vec3, dimensions: Vec3, radius: f64, color: &str) {
        let half = dimensions.map(|dimension| dimension / 2.0);
        let radius = radius.min(half.into_iter().fold(f64::INFINITY, f64::min) * 0.85);
        let core = half.map(|extent| extent - radius);
        let mut mesh = empty_mesh(name, color);
        for face_axis in 0..3 {
            let u_axis = (face_axis + 1) % 3;
            let v_axis = (face_axis + 2) % 3;
            let us = bevel_knots(half[u_axis], radius);
            let vs = bevel_knots(half[v_axis], radius);
            for side in [-1.0, 1.0] {
                let start = mesh.vertices.len();
                for &v in &vs {
                    for &u in &us {
                        let mut point = [0.0; 3];
                        point[face_axis] = half[face_axis] * side;
                        point[u_axis] = u;
                        point[v_axis] = v;
                        let anchor =
                            std::array::from_fn(|axis| point[axis].clamp(-core[axis], core[axis]));
                        let normal = normalized(subtract(point, anchor));
                        mesh.vertices.push(std::array::from_fn(|axis| {
                            center[axis] + anchor[axis] + normal[axis] * radius
                        }));
                        mesh.normals.push(normal);
                    }
                }
                grid_faces(&mut mesh, start, us.len(), vs.len());
            }
        }
        self.meshes.push(mesh);
    }

    /// A superellipsoid supplies gently inflated cushions with curved broad faces.
    fn inflated(
        &mut self,
        name: &str,
        center: Vec3,
        dimensions: Vec3,
        power: f64,
        color: &str,
    ) -> &mut ModelMesh {
        let half = dimensions.map(|dimension| dimension / 2.0);
        let knots = [-1.0, -0.76, -0.42, 0.0, 0.42, 0.76, 1.0];
        let mut mesh = empty_mesh(name, color);
        for face_axis in 0..3 {
            let u_axis = (face_axis + 1) % 3;
            let v_axis = (face_axis + 2) % 3;
            for side in [-1.0, 1.0] {
                let start = mesh.vertices.len();
                for &v in &knots {
                    for &u in &knots {
                        let mut point: Vec3 = [0.0; 3];
                        point[face_axis] = side;
                        point[u_axis] = u;
                        point[v_axis] = v;
                        let divisor = point
                            .iter()
                            .map(|value| value.abs().powf(power))
                            .sum::<f64>()
                            .powf(1.0 / power);
                        point = point.map(|value| value / divisor);
                        mesh.vertices.push(std::array::from_fn(|axis| {
                            center[axis] + point[axis] * half[axis]
                        }));
                        mesh.normals.push(normalized(std::array::from_fn(|axis| {
                            point[axis].signum() * point[axis].abs().powf(power - 1.0) / half[axis]
                        })));
                    }
                }
                grid_faces(&mut mesh, start, knots.len(), knots.len());
            }
        }
        self.meshes.push(mesh);
        self.meshes.last_mut().expect("mesh was added")
    }

    /// Bevel a deliberately drawn convex profile, extruded along the selected axis.
    fn extruded(
        &mut self,
        name: &str,
        axis: usize,
        profile: &[[f64; 2]],
        limits: [f64; 2],
        bevel: f64,
        color: &str,
    ) {
        let [lower, upper] = limits;
        let (u_axis, v_axis) = match axis {
            0 => (1, 2),
            1 => (0, 2),
            _ => (0, 1),
        };
        let mut profile = profile.to_vec();
        if signed_area(&profile) < 0.0 {
            profile.reverse();
        }
        let center: [f64; 2] = std::array::from_fn(|component| {
            profile.iter().map(|point| point[component]).sum::<f64>() / profile.len() as f64
        });
        let bevel = bevel.min((upper - lower) * 0.43);
        let max_radius = profile
            .iter()
            .map(|point| ((point[0] - center[0]).powi(2) + (point[1] - center[1]).powi(2)).sqrt())
            .fold(0.0, f64::max);
        let inset_scale = 1.0 - bevel / max_radius;
        let rings: Vec<Vec<Vec3>> = [
            (lower, inset_scale),
            (lower + bevel, 1.0),
            (upper - bevel, 1.0),
            (upper, inset_scale),
        ]
        .into_iter()
        .map(|(height, scale)| {
            profile
                .iter()
                .map(|point| {
                    let mut vertex = [0.0; 3];
                    vertex[axis] = height;
                    vertex[u_axis] = center[0] + (point[0] - center[0]) * scale;
                    vertex[v_axis] = center[1] + (point[1] - center[1]) * scale;
                    vertex
                })
                .collect()
        })
        .collect();
        let mut mesh = empty_mesh(name, color);
        for ring in 0..rings.len() - 1 {
            for index in 0..profile.len() {
                let next = (index + 1) % profile.len();
                let edge = [
                    profile[next][0] - profile[index][0],
                    profile[next][1] - profile[index][1],
                ];
                let mut outward = [0.0; 3];
                outward[u_axis] = edge[1];
                outward[v_axis] = -edge[0];
                if ring == 0 {
                    outward[axis] = -bevel;
                }
                if ring == 2 {
                    outward[axis] = bevel;
                }
                quad(
                    &mut mesh,
                    [
                        rings[ring][index],
                        rings[ring][next],
                        rings[ring + 1][next],
                        rings[ring + 1][index],
                    ],
                    outward,
                );
            }
        }
        for (ring, side) in [(0, -1.0), (3, 1.0)] {
            let mut cap_center = [0.0; 3];
            cap_center[axis] = if side < 0.0 { lower } else { upper };
            cap_center[u_axis] = center[0];
            cap_center[v_axis] = center[1];
            let mut normal = [0.0; 3];
            normal[axis] = side;
            for index in 0..profile.len() {
                triangle(
                    &mut mesh,
                    [
                        cap_center,
                        rings[ring][index],
                        rings[ring][(index + 1) % profile.len()],
                    ],
                    normal,
                );
            }
        }
        self.meshes.push(mesh);
    }

    fn bowed_panel(
        &mut self,
        name: &str,
        dimensions: [f64; 2],
        height: [f64; 2],
        depth: [f64; 2],
        color: &str,
    ) {
        let [width, thickness] = dimensions;
        let [bottom, top] = height;
        let [rear, bow] = depth;
        let radius_x = (0.024 / self.size[0]).min(width * 0.08);
        let radius_y = (0.024 / self.size[1]).min((top - bottom) * 0.09);
        let mut mesh = empty_mesh(name, color);
        let fractions: Vec<f64> = (0..=64)
            .map(|station| station as f64 / 32.0 - 1.0)
            .collect();
        let rings: Vec<[Vec3; 4]> = fractions
            .iter()
            .map(|&fraction| {
                let x = fraction * width / 2.0;
                let z = rear - bow * fraction.powi(2);
                let edge_distance = width / 2.0 - x.abs();
                let corner = if edge_distance < radius_x {
                    radius_y
                        * (1.0
                            - (1.0 - ((radius_x - edge_distance) / radius_x).powi(2))
                                .max(0.0)
                                .sqrt())
                } else {
                    0.0
                };
                [
                    [x, bottom + corner, z - thickness / 2.0],
                    [x, top - corner, z - thickness / 2.0],
                    [x, top - corner, z + thickness / 2.0],
                    [x, bottom + corner, z + thickness / 2.0],
                ]
            })
            .collect();
        for segment in 0..rings.len() - 1 {
            let slopes = [fractions[segment], fractions[segment + 1]]
                .map(|fraction| -4.0 * bow * fraction / width);
            smooth_quad(
                &mut mesh,
                [
                    rings[segment][0],
                    rings[segment + 1][0],
                    rings[segment + 1][1],
                    rings[segment][1],
                ],
                [
                    normalized([slopes[0], 0.0, -1.0]),
                    normalized([slopes[1], 0.0, -1.0]),
                    normalized([slopes[1], 0.0, -1.0]),
                    normalized([slopes[0], 0.0, -1.0]),
                ],
            );
            smooth_quad(
                &mut mesh,
                [
                    rings[segment][2],
                    rings[segment + 1][2],
                    rings[segment + 1][3],
                    rings[segment][3],
                ],
                [
                    normalized([-slopes[0], 0.0, 1.0]),
                    normalized([-slopes[1], 0.0, 1.0]),
                    normalized([-slopes[1], 0.0, 1.0]),
                    normalized([-slopes[0], 0.0, 1.0]),
                ],
            );
            quad(
                &mut mesh,
                [
                    rings[segment][1],
                    rings[segment + 1][1],
                    rings[segment + 1][2],
                    rings[segment][2],
                ],
                [0.0, 1.0, 0.0],
            );
            quad(
                &mut mesh,
                [
                    rings[segment][3],
                    rings[segment + 1][3],
                    rings[segment + 1][0],
                    rings[segment][0],
                ],
                [0.0, -1.0, 0.0],
            );
        }
        quad(&mut mesh, rings[0], [-1.0, 0.0, 0.0]);
        quad(
            &mut mesh,
            *rings.last().expect("panel rings"),
            [1.0, 0.0, 0.0],
        );
        self.meshes.push(mesh);
    }

    fn leg(
        &mut self,
        name: &str,
        bottom: Vec3,
        top: Vec3,
        bottom_size: [f64; 2],
        top_size: [f64; 2],
        color: &str,
    ) {
        let bottom_ring = rounded_rectangle(
            bottom_size[0] / 2.0,
            bottom_size[1] / 2.0,
            bottom_size[0].min(bottom_size[1]) * 0.10,
            2,
        )
        .into_iter()
        .map(|point| [bottom[0] + point[0], bottom[1], bottom[2] + point[1]])
        .collect::<Vec<_>>();
        let top_ring = rounded_rectangle(
            top_size[0] / 2.0,
            top_size[1] / 2.0,
            top_size[0].min(top_size[1]) * 0.10,
            2,
        )
        .into_iter()
        .map(|point| [top[0] + point[0], top[1], top[2] + point[1]])
        .collect::<Vec<_>>();
        let mut mesh = empty_mesh(name, color);
        for index in 0..bottom_ring.len() {
            let next = (index + 1) % bottom_ring.len();
            let midpoint = mix(bottom_ring[index], bottom_ring[next], 0.5);
            let outward = [midpoint[0] - bottom[0], 0.0, midpoint[2] - bottom[2]];
            quad(
                &mut mesh,
                [
                    bottom_ring[index],
                    bottom_ring[next],
                    top_ring[next],
                    top_ring[index],
                ],
                outward,
            );
        }
        for (ring, center, normal) in [
            (bottom_ring, bottom, [0.0, -1.0, 0.0]),
            (top_ring, top, [0.0, 1.0, 0.0]),
        ] {
            for index in 0..ring.len() {
                triangle(
                    &mut mesh,
                    [center, ring[index], ring[(index + 1) % ring.len()]],
                    normal,
                );
            }
        }
        self.meshes.push(mesh);
    }

    /// Revolve a closed radial/y profile, including optional poles, for pots and hollow bowls.
    fn lathe(
        &mut self,
        name: &str,
        center: Vec3,
        radii: [f64; 2],
        profile: &[[f64; 2]],
        segments: usize,
        color: &str,
    ) {
        let mut profile = profile.to_vec();
        if signed_area(&profile) < 0.0 {
            profile.reverse();
        }
        let mut mesh = empty_mesh(name, color);
        for edge in 0..profile.len() {
            let a = profile[edge];
            let b = profile[(edge + 1) % profile.len()];
            for segment in 0..segments {
                let angles = [segment as f64, (segment + 1) as f64]
                    .map(|step| step * std::f64::consts::TAU / segments as f64);
                let point = |profile: [f64; 2], angle: f64| {
                    [
                        center[0] + profile[0] * radii[0] * angle.cos(),
                        center[1] + profile[1],
                        center[2] + profile[0] * radii[1] * angle.sin(),
                    ]
                };
                let angle = (angles[0] + angles[1]) / 2.0;
                let outward = [
                    (b[1] - a[1]) * angle.cos() / radii[0],
                    a[0] - b[0],
                    (b[1] - a[1]) * angle.sin() / radii[1],
                ];
                quad(
                    &mut mesh,
                    [
                        point(a, angles[0]),
                        point(a, angles[1]),
                        point(b, angles[1]),
                        point(b, angles[0]),
                    ],
                    outward,
                );
            }
        }
        self.meshes.push(mesh);
    }

    fn branch(&mut self, name: &str, start: Vec3, end: Vec3, radius: f64, color: &str) {
        let delta = subtract(end, start);
        let length = dot(delta, delta).sqrt();
        let profile = [
            [0.0, -length / 2.0],
            [radius, -length / 2.0],
            [radius * 0.65, length / 2.0],
            [0.0, length / 2.0],
        ];
        let center = mix(start, end, 0.5);
        let index = self.meshes.len();
        self.lathe(name, [0.0; 3], [1.0, 1.0], &profile, 8, color);
        // Local lathe y becomes the branch direction.
        let direction = normalized(delta);
        let reference = if direction[1].abs() < 0.9 {
            [0.0, 1.0, 0.0]
        } else {
            [0.0, 0.0, 1.0]
        };
        let right = normalized(cross(direction, reference));
        let back = cross(right, direction);
        orient(&mut self.meshes[index], center, [right, direction, back]);
    }

    fn leaf(&mut self, name: &str, start: Vec3, end: Vec3, width: f64, color: &str) {
        let delta = subtract(end, start);
        let length = dot(delta, delta).sqrt();
        let mesh = self.inflated(name, [0.0; 3], [width, 0.035, length], 2.0, color);
        let direction = normalized(delta);
        let right = normalized(cross(direction, [0.0, 1.0, 0.0]));
        let up = cross(direction, right);
        orient(mesh, mix(start, end, 0.5), [right, up, direction]);
        // Small foliage reads as deliberate facets at map scale; face normals also
        // remain faithful to its triangular surface after extreme envelope scaling.
        faceted(mesh);
    }
}

fn faceted(mesh: &mut ModelMesh) {
    let mut result = empty_mesh(&mesh.name, &mesh.color);
    for indices in &mesh.triangles {
        let points = indices.map(|index| mesh.vertices[index]);
        let normal = cross(
            subtract(points[1], points[0]),
            subtract(points[2], points[0]),
        );
        triangle(&mut result, points, normal);
    }
    *mesh = result;
}

fn normalize_metric_mesh(mesh: &mut ModelMesh, size: Vec3) {
    for vertex in &mut mesh.vertices {
        for axis in 0..3 {
            vertex[axis] /= size[axis];
        }
    }
    for normal in &mut mesh.normals {
        let scale = (0..3)
            .filter(|&axis| normal[axis] != 0.0)
            .map(|axis| size[axis])
            .fold(0.0, f64::max);
        *normal = normalized(std::array::from_fn(|axis| {
            normal[axis] * (size[axis] / scale)
        }));
    }
}

fn smooth_quad(mesh: &mut ModelMesh, points: [Vec3; 4], normals: [Vec3; 4]) {
    let start = mesh.vertices.len();
    mesh.vertices.extend(points);
    mesh.normals.extend(normals);
    push_outward(mesh, [start, start + 1, start + 2]);
    push_outward(mesh, [start, start + 2, start + 3]);
}

fn rounded_rectangle(half_x: f64, half_z: f64, radius: f64, subdivisions: usize) -> Vec<[f64; 2]> {
    let mut points = Vec::new();
    for quadrant in 0..4 {
        let corner = [
            if quadrant == 0 || quadrant == 3 {
                1.0
            } else {
                -1.0
            },
            if quadrant < 2 { 1.0 } else { -1.0 },
        ];
        for segment in 0..=subdivisions {
            let theta = quadrant as f64 * std::f64::consts::FRAC_PI_2
                + segment as f64 * std::f64::consts::FRAC_PI_2 / subdivisions as f64;
            points.push([
                corner[0] * (half_x - radius) + theta.cos() * radius,
                corner[1] * (half_z - radius) + theta.sin() * radius,
            ]);
        }
    }
    points
}

fn orient(mesh: &mut ModelMesh, center: Vec3, basis: [Vec3; 3]) {
    for vertex in &mut mesh.vertices {
        *vertex = std::array::from_fn(|axis| {
            center[axis]
                + (0..3)
                    .map(|component| basis[component][axis] * vertex[component])
                    .sum::<f64>()
        });
    }
    for normal in &mut mesh.normals {
        *normal = std::array::from_fn(|axis| {
            (0..3)
                .map(|component| basis[component][axis] * normal[component])
                .sum::<f64>()
        });
    }
}
fn signed_area(profile: &[[f64; 2]]) -> f64 {
    (0..profile.len())
        .map(|i| {
            let next = profile[(i + 1) % profile.len()];
            profile[i][0] * next[1] - next[0] * profile[i][1]
        })
        .sum::<f64>()
        / 2.0
}
fn bevel_knots(half: f64, radius: f64) -> [f64; 12] {
    [
        -half,
        -half + radius * 0.15,
        -half + radius * 0.35,
        -half + radius * 0.57,
        -half + radius * 0.78,
        -half + radius,
        half - radius,
        half - radius * 0.78,
        half - radius * 0.57,
        half - radius * 0.35,
        half - radius * 0.15,
        half,
    ]
}
fn empty_mesh(name: &str, color: &str) -> ModelMesh {
    ModelMesh {
        name: name.to_owned(),
        vertices: Vec::new(),
        normals: Vec::new(),
        triangles: Vec::new(),
        color: color.to_owned(),
    }
}
fn grid_faces(mesh: &mut ModelMesh, start: usize, width: usize, height: usize) {
    for v in 0..height - 1 {
        for u in 0..width - 1 {
            let a = start + v * width + u;
            let b = a + 1;
            let c = a + width;
            let d = c + 1;
            push_outward(mesh, [a, b, d]);
            push_outward(mesh, [a, d, c]);
        }
    }
}
fn push_outward(mesh: &mut ModelMesh, mut triangle: [usize; 3]) {
    let [a, b, c] = triangle.map(|index| mesh.vertices[index]);
    let normal = cross(subtract(b, a), subtract(c, a));
    let expected = std::array::from_fn(|axis| {
        triangle
            .iter()
            .map(|&index| mesh.normals[index][axis])
            .sum()
    });
    if dot(normal, expected) < 0.0 {
        triangle.swap(1, 2);
    }
    mesh.triangles.push(triangle);
}
fn quad(mesh: &mut ModelMesh, points: [Vec3; 4], outward: Vec3) {
    triangle(mesh, [points[0], points[1], points[2]], outward);
    triangle(mesh, [points[0], points[2], points[3]], outward);
}
fn triangle(mesh: &mut ModelMesh, mut points: [Vec3; 3], outward: Vec3) {
    let mut normal = cross(
        subtract(points[1], points[0]),
        subtract(points[2], points[0]),
    );
    if dot(normal, normal) < 1e-30 {
        return;
    }
    if dot(normal, outward) < 0.0 {
        points.swap(1, 2);
        normal = normal.map(|value| -value);
    }
    normal = normalized(normal);
    let start = mesh.vertices.len();
    mesh.vertices.extend(points);
    mesh.normals.extend([normal; 3]);
    mesh.triangles.push([start, start + 1, start + 2]);
}
fn mix(a: Vec3, b: Vec3, t: f64) -> Vec3 {
    std::array::from_fn(|axis| a[axis] + (b[axis] - a[axis]) * t)
}
fn subtract(a: Vec3, b: Vec3) -> Vec3 {
    std::array::from_fn(|axis| a[axis] - b[axis])
}
fn dot(a: Vec3, b: Vec3) -> f64 {
    (0..3).map(|axis| a[axis] * b[axis]).sum()
}
fn cross(a: Vec3, b: Vec3) -> Vec3 {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn normalized(vector: Vec3) -> Vec3 {
    let max = vector.into_iter().map(f64::abs).fold(0.0, f64::max);
    let scaled = vector.map(|value| value / max);
    let length = dot(scaled, scaled).sqrt();
    scaled.map(|value| value / length)
}
