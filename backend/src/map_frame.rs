//! ARKit scan-local → stable building-local, meters, Y up. Never derive alignment from GPS.
use serde::{Deserialize, Serialize};

use crate::geometry::{Transform, Vec3, finite};

pub const IDENTITY: Transform = Transform([
    1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
]);

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ControlPoint {
    pub scan: Vec3,
    pub building: Vec3,
}

#[derive(Debug, Clone)]
pub struct Fit {
    pub transform: Transform,
    pub rms_m: Option<f64>,
    pub max_error_m: Option<f64>,
}

pub fn fit_points(pairs: &[ControlPoint]) -> Result<Fit, String> {
    if !(2..=32).contains(&pairs.len())
        || pairs.iter().any(|p| {
            !finite(p.scan)
                || !finite(p.building)
                || p.scan
                    .iter()
                    .chain(p.building.iter())
                    .any(|v| v.abs() > 10_000.)
        })
    {
        return Err("Provide 2–32 finite matching points in meters.".into());
    }
    let n = pairs.len() as f64;
    let mut s = [0.; 3];
    let mut b = [0.; 3];
    for p in pairs {
        for k in 0..3 {
            s[k] += p.scan[k] / n;
            b[k] += p.building[k] / n;
        }
    }
    let mut dot = 0.;
    let mut cross = 0.;
    let mut scan_extent: f64 = 0.;
    let mut building_extent: f64 = 0.;
    for p in pairs {
        let (sx, sz) = (p.scan[0] - s[0], p.scan[2] - s[2]);
        let (bx, bz) = (p.building[0] - b[0], p.building[2] - b[2]);
        scan_extent = scan_extent.max(sx.hypot(sz));
        building_extent = building_extent.max(bx.hypot(bz));
        dot += sx * bx + sz * bz;
        cross += sx * bz - sz * bx;
    }
    if scan_extent < 0.15 || building_extent < 0.15 || dot.hypot(cross) < 1e-8 {
        return Err(
            "Control points must be distinct and spread horizontally across the scan.".into(),
        );
    }
    let theta = cross.atan2(dot);
    let (c, sin) = (theta.cos(), theta.sin());
    // XZ yaw: x' = c*x - sin*z, z' = sin*x + c*z.
    let transform = Transform([
        c,
        0.,
        sin,
        0.,
        0.,
        1.,
        0.,
        0.,
        -sin,
        0.,
        c,
        0.,
        b[0] - c * s[0] + sin * s[2],
        b[1] - s[1],
        b[2] - sin * s[0] - c * s[2],
        1.,
    ]);
    let mut squared = 0.;
    let mut maximum: f64 = 0.;
    for p in pairs {
        let q = transform.point(p.scan);
        let error = ((q[0] - p.building[0]).powi(2)
            + (q[1] - p.building[1]).powi(2)
            + (q[2] - p.building[2]).powi(2))
        .sqrt();
        squared += error * error;
        maximum = maximum.max(error);
    }
    let rms = (squared / n).sqrt();
    if rms > 0.35 || maximum > 0.60 {
        return Err(format!(
            "Control points disagree (RMS {rms:.2} m, worst {maximum:.2} m)."
        ));
    }
    Ok(Fit {
        transform,
        rms_m: Some(rms),
        max_error_m: Some(maximum),
    })
}

pub fn fit_marker(
    building_from_marker: Transform,
    scan_from_marker: Transform,
) -> Result<Fit, String> {
    building_from_marker.validate()?;
    scan_from_marker.validate()?;
    if building_from_marker
        .0
        .iter()
        .chain(scan_from_marker.0.iter())
        .any(|v| v.abs() > 100_000.)
    {
        return Err("Marker coordinates exceed 100 km from the scan origin.".into());
    }
    let m = scan_from_marker.0;
    let mut inverse = IDENTITY.0;
    for row in 0..3 {
        for column in 0..3 {
            inverse[column * 4 + row] = m[row * 4 + column];
        }
    }
    for row in 0..3 {
        inverse[12 + row] = -(0..3)
            .map(|k| inverse[k * 4 + row] * m[12 + k])
            .sum::<f64>();
    }
    let a = building_from_marker.0;
    let mut out = [0.; 16];
    for col in 0..4 {
        for row in 0..4 {
            out[col * 4 + row] = (0..4).map(|k| a[k * 4 + row] * inverse[col * 4 + k]).sum();
        }
    }
    let transform = Transform(out);
    transform.validate()?;
    Ok(Fit {
        transform,
        rms_m: None,
        max_error_m: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn yaw_translation_and_rejects_bad_fit() {
        let pairs = [
            ControlPoint {
                scan: [0., 0., 0.],
                building: [10., 2., 20.],
            },
            ControlPoint {
                scan: [1., 0., 0.],
                building: [10., 2., 21.],
            },
            ControlPoint {
                scan: [0., 0., 1.],
                building: [9., 2., 20.],
            },
        ];
        let fit = fit_points(&pairs).unwrap();
        assert!(fit.rms_m.unwrap() < 1e-8);
        let actual = fit.transform.point([1., 0., 0.]);
        assert!((actual[2] - 21.).abs() < 1e-8);
        let mut invalid = pairs.to_vec();
        invalid[2].building = [0., 2., 0.];
        assert!(fit_points(&invalid).is_err());
    }

    #[test]
    fn marker_composition_rejects_nonrigid() {
        let mut s = IDENTITY;
        s.0[12] = 1.;
        s.0[14] = 2.;
        let mut b = IDENTITY;
        b.0[12] = 6.;
        b.0[14] = 9.;
        assert_eq!(
            fit_marker(b, s).unwrap().transform.point([0., 0., 0.]),
            [5., 0., 7.]
        );
        s.0[0] = 2.;
        assert!(fit_marker(b, s).is_err());
    }
}
