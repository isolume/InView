//! Local X/Z meters ↔ WGS84, numerically identical to the app's `BuildingMapReference`
//! (Packages/AccessCore/.../BuildingMapReference.swift): heading is clockwise from true north to
//! the frame's −Z axis, with a Web-Mercator projection scale-corrected at the origin.
use super::GeoReference;

const EARTH_RADIUS: f64 = 6_378_137.0;
const MAXIMUM_LATITUDE: f64 = 85.051_128_78;

fn projected_y(latitude: f64) -> f64 {
    EARTH_RADIUS
        * (std::f64::consts::FRAC_PI_4 + latitude.to_radians() / 2.0)
            .tan()
            .ln()
}

fn wrapped_degrees(degrees: f64) -> f64 {
    let value = degrees % 360.0;
    if value >= 180.0 {
        value - 360.0
    } else if value < -180.0 {
        value + 360.0
    } else {
        value
    }
}

impl GeoReference {
    pub fn is_valid(&self) -> bool {
        self.latitude.is_finite()
            && self.latitude.abs() < MAXIMUM_LATITUDE
            && self.longitude.is_finite()
            && (-180.0..=180.0).contains(&self.longitude)
            && self.heading_degrees.is_finite()
    }

    fn heading_radians(&self) -> f64 {
        (self.heading_degrees % 360.0).to_radians()
    }

    /// `[longitude, latitude]` (GeoJSON order) for local `(x, z)`.
    pub fn lon_lat(&self, x: f64, z: f64) -> Option<[f64; 2]> {
        if !self.is_valid() || !x.is_finite() || !z.is_finite() {
            return None;
        }
        let angle = self.heading_radians();
        let east = x * angle.cos() - z * angle.sin();
        let north = -x * angle.sin() - z * angle.cos();
        let scale = self.latitude.to_radians().cos();
        let y = projected_y(self.latitude) + north / scale;
        if !y.is_finite() || y.abs() >= projected_y(MAXIMUM_LATITUDE) {
            return None;
        }
        let latitude = (y / EARTH_RADIUS).sinh().atan().to_degrees();
        let longitude =
            wrapped_degrees(self.longitude + (east / scale / EARTH_RADIUS).to_degrees());
        Some([longitude, latitude])
    }

    /// Local `(x, z)` for a coordinate (inverse of `lon_lat`).
    pub fn local(&self, latitude: f64, longitude: f64) -> Option<[f64; 2]> {
        if !self.is_valid()
            || !latitude.is_finite()
            || latitude.abs() >= MAXIMUM_LATITUDE
            || !longitude.is_finite()
        {
            return None;
        }
        let scale = self.latitude.to_radians().cos();
        let east = wrapped_degrees(longitude - self.longitude).to_radians() * EARTH_RADIUS * scale;
        let north = (projected_y(latitude) - projected_y(self.latitude)) * scale;
        let angle = self.heading_radians();
        Some([
            east * angle.cos() - north * angle.sin(),
            -east * angle.sin() - north * angle.cos(),
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reference(heading: f64) -> GeoReference {
        GeoReference {
            latitude: 37.33285,
            longitude: -122.00537,
            heading_degrees: heading,
        }
    }

    #[test]
    fn north_is_minus_z_at_zero_heading_and_east_is_plus_x() {
        let r = reference(0.0);
        let [lon, lat] = r.lon_lat(0.0, -100.0).unwrap();
        assert!(lat > r.latitude && (lon - r.longitude).abs() < 1e-9);
        let [lon, lat] = r.lon_lat(100.0, 0.0).unwrap();
        assert!(lon > r.longitude && (lat - r.latitude).abs() < 1e-9);
        // 100 m of latitude is ≈ 0.000899°.
        let [_, lat] = r.lon_lat(0.0, -100.0).unwrap();
        assert!((lat - r.latitude - 0.000_899).abs() < 2e-6);
    }

    #[test]
    fn round_trips_at_any_heading() {
        for heading in [0.0, 37.5, 90.0, 213.0, -45.0] {
            let r = reference(heading);
            let [lon, lat] = r.lon_lat(12.5, -40.25).unwrap();
            let [x, z] = r.local(lat, lon).unwrap();
            assert!(
                (x - 12.5).abs() < 1e-6 && (z + 40.25).abs() < 1e-6,
                "{heading}: {x} {z}"
            );
        }
    }
}
