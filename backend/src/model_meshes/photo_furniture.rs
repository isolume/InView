//! Quiet, photo-referenced furniture for the current lounge and balcony test area.
//! These are display templates, with simplified upholstery and no personal belongings.
use super::*;

const UPHOLSTERY: &str = "#c6cdd1";
const CUSHION: &str = "#d1d7db";
const FRAME: &str = "#bdc7cd";
const SILVER: &str = "#c5cfd5";
const TOP: &str = "#d7dde1";
const INSET: &str = "#b5c0c7";

/// Draw metric roundovers while placing components as fractions of the measured box.
fn soft_box(
    model: &mut ModelBuilder,
    name: &str,
    center: Vec3,
    size: Vec3,
    radius: f64,
    color: &str,
) {
    model.metric_rounded(
        name,
        center,
        std::array::from_fn(|axis| size[axis] * model.size[axis]),
        radius,
        color,
    );
}

pub(super) fn lounge_chair(model: &mut ModelBuilder) {
    soft_box(
        model,
        "lounge upholstered base",
        [0.0, -0.285, 0.0],
        [0.95, 0.31, 0.95],
        0.018,
        UPHOLSTERY,
    );
    soft_box(
        model,
        "lounge separate seat cushion",
        [0.0, -0.075, -0.065],
        [0.68, 0.14, 0.75],
        0.025,
        CUSHION,
    );
    for x in [-0.415, 0.415] {
        soft_box(
            model,
            &format!("lounge box arm {x}"),
            [x, -0.13, 0.0],
            [0.17, 0.60, 0.98],
            0.021,
            UPHOLSTERY,
        );
    }
    soft_box(
        model,
        "lounge padded reclined back",
        [0.0, 0.185, 0.325],
        [0.76, 0.61, 0.17],
        0.033,
        CUSHION,
    );
    let back = model.meshes.last_mut().expect("back was added");
    for vertex in &mut back.vertices {
        vertex[2] += (vertex[1] - 0.185) * 0.13;
    }
    for normal in &mut back.normals {
        normal[1] -= normal[2] * 0.13;
        *normal = normalized(*normal);
    }
    for x in [-0.398, 0.398] {
        for z in [-0.385, 0.385] {
            soft_box(
                model,
                &format!("lounge square foot {x} {z}"),
                [x, -0.465, z],
                [0.105, 0.07, 0.105],
                0.003,
                SILVER,
            );
        }
    }
}

pub(super) fn modular_sofa(model: &mut ModelBuilder) {
    // Each armless module has a straight inner join and a broad, rounded OUTER end.
    let left = d_module_outline();
    for (index, sign) in [1.0, -1.0].into_iter().enumerate() {
        let outline: Vec<_> = left
            .iter()
            .map(|p| [p[0] * sign * model.size[0], p[1] * model.size[2]])
            .collect();
        let height = model.size[1];
        model.metric_extruded(
            &format!("rounded outer module base {index}"),
            1,
            &outline,
            [-0.465 * height, -0.185 * height],
            0.012_f64.min(height * 0.02),
            UPHOLSTERY,
        );
        let seat_outline: Vec<_> = outline
            .iter()
            .map(|p| [p[0] * 0.988, p[1] * 0.986])
            .collect();
        model.metric_extruded(
            &format!("separate D seat cushion {index}"),
            1,
            &seat_outline,
            [-0.19 * height, -0.005 * height],
            0.018_f64.min(height * 0.03),
            CUSHION,
        );
        soft_box(
            model,
            &format!("modular thin back cushion {index}"),
            [-0.246 * sign, 0.25, 0.345],
            [0.475, 0.50, 0.17],
            0.037,
            CUSHION,
        );
        for x in [-0.395 * sign, -0.09 * sign] {
            for z in [-0.305, 0.305] {
                soft_box(
                    model,
                    &format!("module recessed foot {index} {x} {z}"),
                    [x, -0.4825, z],
                    [0.042, 0.035, 0.08],
                    0.003,
                    FRAME,
                );
            }
        }
    }
}

fn d_module_outline() -> Vec<[f64; 2]> {
    let mut result = vec![[-0.007, -0.46], [-0.265, -0.46]];
    for step in 1..=40 {
        let angle = -std::f64::consts::FRAC_PI_2 + step as f64 * std::f64::consts::PI / 40.0;
        result.push([-0.265 - 0.225 * angle.cos(), 0.46 * angle.sin()]);
    }
    result.push([-0.007, 0.46]);
    result
}

pub(super) fn drum_table(model: &mut ModelBuilder) {
    model.lathe(
        "soft barrel drum base",
        [0.0; 3],
        [0.5, 0.5],
        &[
            [0.0, -0.5],
            [0.90, -0.5],
            [0.967, -0.476],
            [0.995, -0.43],
            [0.995, 0.382],
            [0.98, 0.432],
            [0.94, 0.462],
            [0.0, 0.462],
        ],
        64,
        UPHOLSTERY,
    );
    model.lathe(
        "thin circular hard tabletop",
        [0.0; 3],
        [0.5, 0.5],
        &[
            [0.0, 0.46],
            [0.985, 0.46],
            [1.0, 0.475],
            [1.0, 0.49],
            [0.985, 0.5],
            [0.0, 0.5],
        ],
        64,
        TOP,
    );
}

pub(super) fn charging_stand(model: &mut ModelBuilder) {
    let outline = rounded_triangle();
    for (index, (bottom, top, scale)) in [
        (-0.50, -0.462, 1.0),
        (-0.075, -0.035, 0.95),
        (0.462, 0.50, 0.86),
    ]
    .into_iter()
    .enumerate()
    {
        let profile: Vec<_> = outline
            .iter()
            .map(|p| [p[0] * model.size[0] * scale, p[1] * model.size[2] * scale])
            .collect();
        model.metric_extruded(
            &format!("charging rounded triangular plate {index}"),
            1,
            &profile,
            [bottom * model.size[1], top * model.size[1]],
            0.004_f64.min(model.size[1] * 0.006),
            SILVER,
        );
    }
    for (level, lower, upper) in [(0, -0.463, -0.073), (1, -0.036, 0.464)] {
        for (column, (x, z)) in [(0.0, -0.265), (-0.238, 0.192), (0.238, 0.192)]
            .into_iter()
            .enumerate()
        {
            let width = 0.067_f64
                .min(model.size[0] * 0.115)
                .min(model.size[2] * 0.115);
            let radius = [width / model.size[0], width / model.size[2]];
            model.lathe(
                &format!("charging tapered silver column {level} {column}"),
                [x, 0.0, z],
                radius,
                &[[0.0, lower], [1.0, lower], [0.72, upper], [0.0, upper]],
                24,
                SILVER,
            );
            let front = z - radius[1] * 0.83;
            soft_box(
                model,
                &format!("charging subtle outlet panel {level} {column}"),
                [x, (lower + upper) / 2.0, front],
                [
                    width * 0.45 / model.size[0],
                    (upper - lower) * 0.42,
                    0.007_f64.min(model.size[2] * 0.014) / model.size[2],
                ],
                0.003,
                INSET,
            );
        }
    }
}

fn rounded_triangle() -> Vec<[f64; 2]> {
    let corners = [[0.0, -0.57], [0.57, 0.43], [-0.57, 0.43]];
    let mut result = Vec::new();
    for i in 0..3 {
        let corner = corners[i];
        let previous = corners[(i + 2) % 3];
        let next = corners[(i + 1) % 3];
        let a = [
            corner[0] * 0.65 + previous[0] * 0.35,
            corner[1] * 0.65 + previous[1] * 0.35,
        ];
        let b = [
            corner[0] * 0.65 + next[0] * 0.35,
            corner[1] * 0.65 + next[1] * 0.35,
        ];
        for station in 0..=12 {
            let t = station as f64 / 12.0;
            result.push(std::array::from_fn(|axis| {
                (1.0 - t).powi(2) * a[axis]
                    + 2.0 * (1.0 - t) * t * corner[axis]
                    + t.powi(2) * b[axis]
            }));
        }
    }
    result
}

pub(super) fn lectern(model: &mut ModelBuilder) {
    soft_box(
        model,
        "lectern square plinth",
        [0.0, -0.465, 0.03],
        [0.82, 0.07, 0.79],
        0.007,
        FRAME,
    );
    for x in [-0.1975, 0.1975] {
        soft_box(
            model,
            &format!("lectern front column stile {x}"),
            [x, -0.065, 0.035],
            [0.075, 0.75, 0.43],
            0.008,
            UPHOLSTERY,
        );
    }
    for y in [-0.4025, 0.2725] {
        soft_box(
            model,
            &format!("lectern column end rail {y}"),
            [0.0, y, 0.035],
            [0.47, 0.075, 0.43],
            0.007,
            UPHOLSTERY,
        );
    }
    soft_box(
        model,
        "lectern recessed front panel",
        [0.0, -0.065, -0.128],
        [0.327, 0.609, 0.035],
        0.004,
        INSET,
    );
    soft_box(
        model,
        "lectern rear column panel",
        [0.0, -0.065, 0.23],
        [0.33, 0.675, 0.04],
        0.005,
        UPHOLSTERY,
    );
    let profile: Vec<_> = [[0.29, -0.49], [0.40, 0.49], [0.465, 0.49], [0.355, -0.49]]
        .into_iter()
        .map(|p| [p[0] * model.size[1], p[1] * model.size[2]])
        .collect();
    model.metric_extruded(
        "lectern sloped reading shelf",
        0,
        &profile,
        [-0.5 * model.size[0], 0.5 * model.size[0]],
        0.006_f64.min(model.size[1] * 0.008),
        TOP,
    );
    let lip: Vec<_> = [[0.355, -0.49], [0.465, 0.49], [0.50, 0.49], [0.39, -0.49]]
        .into_iter()
        .map(|p| [p[0] * model.size[1], p[1] * model.size[2]])
        .collect();
    for sign in [-1.0, 1.0] {
        let limits = if sign < 0.0 {
            [-0.5, -0.475]
        } else {
            [0.475, 0.5]
        };
        model.metric_extruded(
            &format!("lectern shallow side lip {sign}"),
            0,
            &lip,
            limits.map(|value| value * model.size[0]),
            0.003_f64.min(model.size[1] * 0.004),
            UPHOLSTERY,
        );
    }
    soft_box(
        model,
        "lectern shallow front lip",
        [0.0, 0.38, -0.478],
        [0.98, 0.045, 0.025],
        0.004,
        UPHOLSTERY,
    );
}

pub(super) fn folding_table(model: &mut ModelBuilder) {
    soft_box(
        model,
        "folding thin rectangular tabletop",
        [0.0, 0.478, 0.0],
        [1.0, 0.044, 1.0],
        0.012,
        TOP,
    );
    let section = 0.025_f64
        .min(model.size[0] * 0.075)
        .min(model.size[1] * 0.035)
        .min(model.size[2] * 0.08);
    for x in [-0.35, 0.35] {
        for z in [-0.335, 0.335] {
            soft_box(
                model,
                &format!("folding slender trestle upright {x} {z}"),
                [x, -0.013, z],
                [section / model.size[0], 0.933, section / model.size[2]],
                section * 0.42,
                FRAME,
            );
        }
        soft_box(
            model,
            &format!("folding U frame foot {x}"),
            [x, -0.48, 0.0],
            [section / model.size[0], 0.04, 0.82],
            section * 0.42,
            FRAME,
        );
    }
    for z in [-0.335, 0.335] {
        soft_box(
            model,
            &format!("folding crossbar rail {z}"),
            [0.0, -0.105, z],
            [0.71, section / model.size[1], section / model.size[2]],
            section * 0.42,
            FRAME,
        );
    }
}

pub(super) fn sign_stand(model: &mut ModelBuilder) {
    model.lathe(
        "sign round pedestal",
        [0.0; 3],
        [0.43, 0.49],
        &[
            [0.0, -0.5],
            [0.92, -0.5],
            [1.0, -0.493],
            [1.0, -0.477],
            [0.12, -0.449],
            [0.0, -0.449],
        ],
        64,
        FRAME,
    );
    let radius = 0.018_f64
        .min(model.size[0] * 0.045)
        .min(model.size[2] * 0.055);
    model.lathe(
        "sign single slim post",
        [0.0; 3],
        [radius / model.size[0], radius / model.size[2]],
        &[[0.0, -0.46], [1.0, -0.46], [1.0, 0.20], [0.0, 0.20]],
        20,
        FRAME,
    );
    soft_box(
        model,
        "sign portrait frame",
        [0.0, 0.295, 0.0],
        [0.98, 0.41, 0.095],
        0.012,
        FRAME,
    );
    soft_box(
        model,
        "sign plain inset face",
        [0.0, 0.295, -0.047],
        [0.88, 0.371, 0.012],
        0.005,
        TOP,
    );
}

pub(super) fn waste_bin(model: &mut ModelBuilder) {
    model.lathe(
        "waste cylindrical hollow body",
        [0.0; 3],
        [0.5, 0.5],
        &[
            [0.0, -0.5],
            [0.94, -0.5],
            [1.0, -0.477],
            [1.0, 0.12],
            [0.91, 0.12],
            [0.91, -0.44],
            [0.0, -0.44],
        ],
        64,
        UPHOLSTERY,
    );
    // A hollow curved hood with a real front aperture. No full cylinder fills the opening.
    hood_with_opening(model);
    soft_box(
        model,
        "waste opening recessed inner panel",
        [0.0, 0.26, -0.316],
        [0.60, 0.18, 0.025],
        0.009,
        INSET,
    );
}

fn hood_with_opening(model: &mut ModelBuilder) {
    let outer = [
        [1.0, 0.12],
        [1.0, 0.17],
        [0.99, 0.355],
        [0.96, 0.397],
        [0.86, 0.45],
        [0.65, 0.482],
        [0.38, 0.497],
        [0.0, 0.5],
    ];
    let inner = [
        [0.935, 0.12],
        [0.935, 0.17],
        [0.925, 0.355],
        [0.90, 0.382],
        [0.80, 0.432],
        [0.60, 0.462],
        [0.34, 0.475],
        [0.0, 0.482],
    ];
    let segments = 64;
    let point = |p: [f64; 2], index: usize| {
        let angle = index as f64 * std::f64::consts::TAU / segments as f64;
        [p[0] * 0.5 * angle.cos(), p[1], p[0] * 0.5 * angle.sin()]
    };
    let omitted = |row: usize, segment: usize| row == 1 && (40..56).contains(&segment);
    let mut mesh = empty_mesh("waste domed hood with inset aperture", UPHOLSTERY);
    for row in 0..outer.len() - 1 {
        for segment in 0..segments {
            if omitted(row, segment) {
                continue;
            }
            let next = segment + 1;
            let angle = (segment as f64 + 0.5) * std::f64::consts::TAU / segments as f64;
            let outward = [angle.cos(), 0.7, angle.sin()];
            quad(
                &mut mesh,
                [
                    point(outer[row], segment),
                    point(outer[row], next),
                    point(outer[row + 1], next),
                    point(outer[row + 1], segment),
                ],
                outward,
            );
            quad(
                &mut mesh,
                [
                    point(inner[row], segment),
                    point(inner[row], next),
                    point(inner[row + 1], next),
                    point(inner[row + 1], segment),
                ],
                outward.map(|v| -v),
            );
            if row == 0 || omitted(row - 1, segment) {
                quad(
                    &mut mesh,
                    [
                        point(outer[row], segment),
                        point(outer[row], next),
                        point(inner[row], next),
                        point(inner[row], segment),
                    ],
                    [0.0, -1.0, 0.0],
                );
            }
            if row + 1 == outer.len() - 1 || omitted(row + 1, segment) {
                quad(
                    &mut mesh,
                    [
                        point(outer[row + 1], segment),
                        point(outer[row + 1], next),
                        point(inner[row + 1], next),
                        point(inner[row + 1], segment),
                    ],
                    [0.0, 1.0, 0.0],
                );
            }
            for (edge, neighbor, sign) in [
                (segment, (segment + segments - 1) % segments, -1.0),
                (next, next % segments, 1.0),
            ] {
                if omitted(row, neighbor) {
                    let theta = edge as f64 * std::f64::consts::TAU / segments as f64;
                    quad(
                        &mut mesh,
                        [
                            point(outer[row], edge),
                            point(outer[row + 1], edge),
                            point(inner[row + 1], edge),
                            point(inner[row], edge),
                        ],
                        [-theta.sin() * sign, 0.0, theta.cos() * sign],
                    );
                }
            }
        }
    }
    model.meshes.push(mesh);
}

pub(super) fn open_bin(model: &mut ModelBuilder) {
    square_vessel(
        model,
        "open tapered rectangular wastebasket",
        [0.5, 0.5],
        &[
            [0.0, -0.5],
            [0.73, -0.5],
            [1.0, 0.5],
            [0.89, 0.5],
            [0.64, -0.42],
            [0.0, -0.42],
        ],
        UPHOLSTERY,
    );
}

fn square_vessel(
    model: &mut ModelBuilder,
    name: &str,
    radii: [f64; 2],
    profile: &[[f64; 2]],
    color: &str,
) {
    let outline = rounded_rectangle(radii[0], radii[1], radii[0].min(radii[1]) * 0.10, 5);
    let mut profile = profile.to_vec();
    if signed_area(&profile) < 0.0 {
        profile.reverse();
    }
    let point =
        |p: [f64; 2], index: usize| [outline[index][0] * p[0], p[1], outline[index][1] * p[0]];
    let mut mesh = empty_mesh(name, color);
    for edge in 0..profile.len() {
        let a = profile[edge];
        let b = profile[(edge + 1) % profile.len()];
        for index in 0..outline.len() {
            let next = (index + 1) % outline.len();
            let midpoint = [
                outline[index][0] + outline[next][0],
                outline[index][1] + outline[next][1],
            ];
            let outward = [
                (b[1] - a[1]) * midpoint[0],
                a[0] - b[0],
                (b[1] - a[1]) * midpoint[1],
            ];
            quad(
                &mut mesh,
                [
                    point(a, index),
                    point(a, next),
                    point(b, next),
                    point(b, index),
                ],
                outward,
            );
        }
    }
    model.meshes.push(mesh);
}

pub(super) fn bench(model: &mut ModelBuilder) {
    for (index, x) in [-0.328, 0.0, 0.328].into_iter().enumerate() {
        soft_box(
            model,
            &format!("bench separate upholstered pad {index}"),
            [x, 0.41, 0.0],
            [0.318, 0.18, 0.98],
            0.016,
            CUSHION,
        );
    }
    let section = 0.047_f64
        .min(model.size[0] * 0.06)
        .min(model.size[1] * 0.105)
        .min(model.size[2] * 0.10);
    for z in [-0.377, 0.377] {
        soft_box(
            model,
            &format!("bench narrow longitudinal rail {z}"),
            [0.0, 0.28, z],
            [0.98, 0.08, section / model.size[2]],
            0.005,
            FRAME,
        );
    }
    for x in [-0.465, 0.0, 0.465] {
        for z in [-0.377, 0.377] {
            soft_box(
                model,
                &format!("bench square leg {x} {z}"),
                [x, -0.10, z],
                [section / model.size[0], 0.80, section / model.size[2]],
                0.004,
                FRAME,
            );
        }
        soft_box(
            model,
            &format!("bench transverse support {x}"),
            [x, 0.275, 0.0],
            [section / model.size[0], 0.075, 0.81],
            0.004,
            FRAME,
        );
    }
}

pub(super) fn square_planter(model: &mut ModelBuilder) {
    square_vessel(
        model,
        "tall tapered square planter",
        [0.325, 0.325],
        &[
            [0.0, -0.5],
            [0.78, -0.5],
            [1.0, 0.17],
            [0.925, 0.17],
            [0.72, -0.45],
            [0.0, -0.45],
        ],
        UPHOLSTERY,
    );
    soft_box(
        model,
        "planter recessed soil",
        [0.0, 0.133, 0.0],
        [0.595, 0.018, 0.595],
        0.006,
        INSET,
    );
    for index in 0..16 {
        let angle = index as f64 * std::f64::consts::TAU / 16.0;
        let rise = if index % 3 == 0 {
            0.325
        } else {
            0.245 + (index % 4) as f64 * 0.017
        };
        let reach = if index % 3 == 0 { 0.29 } else { 0.405 };
        drooping_leaf(
            model,
            &format!("planter broad drooping leaf {index}"),
            angle,
            rise,
            reach,
            0.115 + (index % 3) as f64 * 0.013,
        );
    }
}

fn drooping_leaf(
    model: &mut ModelBuilder,
    name: &str,
    angle: f64,
    rise: f64,
    reach: f64,
    width: f64,
) {
    let direction = [angle.cos(), 0.0, angle.sin()];
    let side = [-angle.sin(), 0.0, angle.cos()];
    let station = |t: f64| {
        [
            direction[0] * (0.028 + reach * t),
            0.172 + rise * (std::f64::consts::PI * t).sin() - 0.075 * t,
            direction[2] * (0.028 + reach * t),
        ]
    };
    let rings: Vec<_> = (0..=18)
        .map(|index| {
            let t = index as f64 / 18.0;
            let center = station(t);
            let tangent = normalized(subtract(
                station((t + 0.001).min(1.001)),
                station((t - 0.001).max(-0.001)),
            ));
            let up = normalized(cross(tangent, side));
            let half_width = width * (0.06 + (std::f64::consts::PI * t).sin().powf(0.7)) / 2.0;
            let thickness = 0.006 * (0.18 + (std::f64::consts::PI * t).sin());
            let ring: Vec<Vec3> = (0..8)
                .map(|edge| {
                    let theta = edge as f64 * std::f64::consts::TAU / 8.0;
                    std::array::from_fn(|axis| {
                        center[axis]
                            + side[axis] * half_width * theta.cos()
                            + up[axis] * thickness * theta.sin()
                    })
                })
                .collect();
            (center, ring)
        })
        .collect();
    let mut mesh = empty_mesh(name, CUSHION);
    for row in 0..rings.len() - 1 {
        for edge in 0..8 {
            let next = (edge + 1) % 8;
            let outward = subtract(
                mix(rings[row].1[edge], rings[row].1[next], 0.5),
                rings[row].0,
            );
            quad(
                &mut mesh,
                [
                    rings[row].1[edge],
                    rings[row].1[next],
                    rings[row + 1].1[next],
                    rings[row + 1].1[edge],
                ],
                outward,
            );
        }
    }
    for (index, normal) in [
        (0, subtract(station(0.0), station(0.001))),
        (rings.len() - 1, subtract(station(1.0), station(0.999))),
    ] {
        for edge in 0..8 {
            triangle(
                &mut mesh,
                [
                    rings[index].0,
                    rings[index].1[edge],
                    rings[index].1[(edge + 1) % 8],
                ],
                normal,
            );
        }
    }
    model.meshes.push(mesh);
}

pub(super) fn railing(model: &mut ModelBuilder) {
    let section = 0.032_f64
        .min(model.size[0] * 0.03)
        .min(model.size[2] * 0.27);
    for x in [-0.475, -0.158, 0.158, 0.475] {
        soft_box(
            model,
            &format!("balcony slender vertical post {x}"),
            [x, -0.025, 0.0],
            [section / model.size[0], 0.95, section / model.size[2]],
            0.006,
            FRAME,
        );
    }
    for (index, y) in [-0.355, -0.225, -0.095, 0.035, 0.165, 0.295, 0.425]
        .into_iter()
        .enumerate()
    {
        soft_box(
            model,
            &format!("balcony thin horizontal rail {index}"),
            [0.0, y, 0.0],
            [
                0.985,
                section * 0.65 / model.size[1],
                section * 0.65 / model.size[2],
            ],
            0.005,
            FRAME,
        );
    }
    let radius = 0.026_f64
        .min(model.size[1] * 0.023)
        .min(model.size[2] * 0.47);
    let start = [
        -0.5 * model.size[0] + radius,
        0.5 * model.size[1] - radius,
        0.0,
    ];
    let end = [
        0.5 * model.size[0] - radius,
        0.5 * model.size[1] - radius,
        0.0,
    ];
    model.branch(
        "balcony rounded continuous handrail",
        start,
        end,
        radius,
        SILVER,
    );
    normalize_metric_mesh(
        model.meshes.last_mut().expect("handrail was added"),
        model.size,
    );
}

pub(super) fn floor_sign(model: &mut ModelBuilder) {
    let size = model.size;
    for sign in [-1.0, 1.0] {
        let side_profile = |bottom: f64, top: f64| {
            let z = |y: f64| sign * (0.252 - y * 0.46);
            [
                [bottom, z(bottom) - 0.015],
                [top, z(top) - 0.015],
                [top, z(top) + 0.015],
                [bottom, z(bottom) + 0.015],
            ]
            .map(|p| [p[0] * size[1], p[1] * size[2]])
        };
        model.metric_extruded(
            &format!("floor sign sloping panel {sign}"),
            0,
            &side_profile(-0.49, 0.34),
            [-0.46 * model.size[0], 0.46 * model.size[0]],
            0.004_f64.min(model.size[1] * 0.006),
            UPHOLSTERY,
        );
        for x in [-0.31, 0.31] {
            model.metric_extruded(
                &format!("floor sign handle side {sign} {x}"),
                0,
                &side_profile(0.34, 0.465),
                [(x - 0.15) * model.size[0], (x + 0.15) * model.size[0]],
                0.003_f64.min(model.size[1] * 0.004),
                UPHOLSTERY,
            );
        }
        model.metric_extruded(
            &format!("floor sign carry handle bar {sign}"),
            0,
            &side_profile(0.425, 0.465),
            [-0.46 * model.size[0], 0.46 * model.size[0]],
            0.003_f64.min(model.size[1] * 0.004),
            UPHOLSTERY,
        );
    }
    soft_box(
        model,
        "floor sign rounded top hinge",
        [0.0, 0.48, 0.034],
        [0.96, 0.04, 0.13],
        0.006,
        FRAME,
    );
}
