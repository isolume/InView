use serde::{Deserialize, Serialize};

pub type Vec3 = [f64; 3];

/// Column-major, right-handed map_from_local matrix. Scale belongs in dimensions.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
#[serde(transparent)]
pub struct Transform(pub [f64; 16]);

impl Transform {
    pub fn validate(&self) -> Result<(), String> {
        let m = self.0;
        if m.iter().any(|value| !value.is_finite()) {
            return Err("Transforms must be finite.".into());
        }
        let near = |a: f64, b: f64| (a - b).abs() <= 1e-4;
        if !near(m[3], 0.0) || !near(m[7], 0.0) || !near(m[11], 0.0) || !near(m[15], 1.0) {
            return Err("Transforms must be affine column-major matrices.".into());
        }
        let x = [m[0], m[1], m[2]];
        let y = [m[4], m[5], m[6]];
        let z = [m[8], m[9], m[10]];
        if !near(dot(x, x), 1.0)
            || !near(dot(y, y), 1.0)
            || !near(dot(z, z), 1.0)
            || !near(dot(x, y), 0.0)
            || !near(dot(x, z), 0.0)
            || !near(dot(y, z), 0.0)
            || !near(dot(cross(x, y), z), 1.0)
        {
            return Err("Transforms must be rigid rotations and translations, without scale, shear, or reflection.".into());
        }
        Ok(())
    }

    pub fn point(&self, p: Vec3) -> Vec3 {
        let m = self.0;
        [
            m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
            m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
            m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
        ]
    }

    pub fn box_corners(&self, dimensions: Vec3) -> [Vec3; 8] {
        std::array::from_fn(|index| {
            self.point(std::array::from_fn(|axis| {
                dimensions[axis] * if index & (1 << axis) == 0 { -0.5 } else { 0.5 }
            }))
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Bounds {
    pub min: Vec3,
    pub max: Vec3,
}

impl Bounds {
    pub fn from_points(points: &[Vec3]) -> Option<Self> {
        let &first = points.first()?;
        let mut bounds = Self {
            min: first,
            max: first,
        };
        for point in points {
            for (axis, value) in point.iter().enumerate() {
                bounds.min[axis] = bounds.min[axis].min(*value);
                bounds.max[axis] = bounds.max[axis].max(*value);
            }
        }
        Some(bounds)
    }
}

pub fn finite(point: Vec3) -> bool {
    point.iter().all(|v| v.is_finite())
}

fn dot(a: Vec3, b: Vec3) -> f64 {
    a.iter().zip(b).map(|(a, b)| a * b).sum()
}

fn cross(a: Vec3, b: Vec3) -> Vec3 {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
