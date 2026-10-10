//! Export the same deterministic photo furniture meshes used by the app.
use inview_backend::model_meshes::{ModelMesh, furniture_meshes};
use serde::Serialize;

#[derive(Serialize)]
struct Catalogue {
    version: u32,
    models: Vec<Model>,
}

#[derive(Serialize)]
struct Model {
    id: &'static str,
    key: &'static str,
    title: &'static str,
    dimensions_m: [f64; 3],
    reference_photos: Vec<&'static str>,
    meshes: Vec<ModelMesh>,
}

fn main() {
    let definitions = [
        (
            "lounge-chair",
            "lounge_chair_v1",
            "Lounge chair",
            [0.90, 0.90, 0.87],
            vec![
                "IMG_5415.HEIC",
                "IMG_5417.HEIC",
                "IMG_5419.HEIC",
                "IMG_5423.HEIC",
            ],
        ),
        (
            "modular-sofa",
            "modular_sofa_v1",
            "Modular sofa",
            [2.20, 0.80, 0.83],
            vec!["IMG_5417.HEIC", "IMG_5423.HEIC"],
        ),
        (
            "large-drum-table",
            "drum_table_v1",
            "Large drum table",
            [1.05, 0.43, 1.05],
            vec!["IMG_5419.HEIC"],
        ),
        (
            "small-drum-table",
            "drum_table_v1",
            "Small drum table",
            [0.54, 0.46, 0.54],
            vec!["IMG_5420.HEIC"],
        ),
        (
            "charging-stand",
            "charging_stand_v1",
            "Charging stand",
            [0.39, 0.77, 0.36],
            vec!["IMG_5415.HEIC", "IMG_5419.HEIC"],
        ),
        (
            "lectern",
            "lectern_v1",
            "Lectern",
            [0.60, 1.25, 0.48],
            vec!["IMG_5420.HEIC"],
        ),
        (
            "folding-table",
            "folding_table_v1",
            "Folding table",
            [1.22, 0.74, 0.61],
            vec!["IMG_5423.HEIC"],
        ),
        (
            "sign-stand",
            "sign_stand_v1",
            "Sign stand",
            [0.34, 1.55, 0.34],
            vec!["IMG_5421.HEIC", "IMG_5422.HEIC"],
        ),
        (
            "waste-bin",
            "waste_bin_v1",
            "Waste bin",
            [0.43, 0.95, 0.43],
            vec!["IMG_5423.HEIC"],
        ),
        (
            "open-bin",
            "open_bin_v1",
            "Open bin",
            [0.28, 0.38, 0.23],
            vec!["IMG_5421.HEIC", "IMG_5422.HEIC"],
        ),
        (
            "bench",
            "bench_v1",
            "Balcony bench",
            [2.05, 0.48, 0.53],
            vec!["IMG_5426.HEIC"],
        ),
        (
            "square-planter",
            "square_planter_v1",
            "Square planter",
            [0.72, 1.25, 0.72],
            vec!["IMG_5426.HEIC"],
        ),
        (
            "balcony-railing",
            "railing_v1",
            "Balcony railing",
            [2.40, 1.05, 0.11],
            vec!["IMG_5424.HEIC", "IMG_5425.HEIC"],
        ),
        (
            "floor-sign",
            "floor_sign_v1",
            "Floor sign",
            [0.30, 0.63, 0.42],
            vec!["IMG_5426.HEIC"],
        ),
    ];
    let models = definitions
        .into_iter()
        .map(|(id, key, title, dimensions_m, reference_photos)| Model {
            id,
            key,
            title,
            dimensions_m,
            reference_photos,
            meshes: furniture_meshes(key, dimensions_m),
        })
        .collect();
    println!(
        "{}",
        serde_json::to_string(&Catalogue { version: 1, models })
            .expect("serialize furniture catalogue")
    );
}
