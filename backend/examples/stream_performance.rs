//! Development benchmark; consumes only a supplied synthetic JPEG, never saved scans.
use std::{env, fs, io::Cursor, time::Instant};

use base64::{Engine, engine::general_purpose::STANDARD};
use inview_backend::streaming::StreamStore;
use serde_json::json;

fn main() {
    let arguments: Vec<_> = env::args().collect();
    let jpeg = fs::read(arguments.get(1).expect("synthetic JPEG path")).unwrap();
    let count: usize = arguments.get(2).map_or(120, |v| v.parse().unwrap());
    let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(&jpeg));
    decoder.read_info().unwrap();
    let info = decoder.info().unwrap();
    let color = STANDARD.encode(jpeg);
    let store = StreamStore::default();
    let id = "d66df66d-893a-47aa-bd0a-2df5b1b05c69";
    let pose = [
        1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
    ];
    store
        .create(
            json!({"schema_version":1,"id":id,"map_id":"synthetic","floor_id":"ground",
        "coordinates":{"units":"meters","up_axis":"y","handedness":"right"}}),
        )
        .unwrap();
    let started = Instant::now();
    for sequence in 0..count {
        store.append(id, sequence, json!({"sequence":sequence,"color_jpeg":color,
            "frame":{"id":format!("frame-{sequence}"),"timestamp_seconds":sequence as f64+1.,
                "pixel_orientation":"sensor_native","map_from_camera":pose,
                "camera":{"image_width":info.width,"image_height":info.height,
                    "fx":info.width as f64*0.75,"fy":info.width as f64*0.75,
                    "cx":(info.width as f64-1.)/2.,"cy":(info.height as f64-1.)/2.},
                "depth":{"width":256,"height":192,"values_m":vec![2.;256*192],"confidence":vec![2;256*192]}}})).unwrap();
    }
    println!(
        "frames={count} ingestion_seconds={:.3}",
        started.elapsed().as_secs_f64()
    );
    store.finish(id, count).unwrap();
    for pass in 0..2 {
        let started = Instant::now();
        let result = store.reconstruct(id).unwrap();
        let reconstruction_seconds = started.elapsed().as_secs_f64();
        let started = Instant::now();
        let encoded = serde_json::to_vec(&result).unwrap();
        println!(
            "pass={pass} reconstruction_seconds={reconstruction_seconds:.3} serialization_seconds={:.3} result_bytes={}",
            started.elapsed().as_secs_f64(),
            encoded.len()
        );
    }
    for pass in 0..2 {
        let started = Instant::now();
        let encoded = store.reconstruct_encoded(id, false).unwrap();
        println!(
            "http_pass={pass} result_seconds={:.3} result_bytes={}",
            started.elapsed().as_secs_f64(),
            encoded.len()
        );
    }
}
