use std::io::Read;

use axum::{
    Router,
    body::{Body, to_bytes},
    http::{HeaderMap, Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use inview_backend::{AppState, app};
use serde_json::{Value, json};
use tower::ServiceExt;

const ID: &str = "fe9d26ee-790a-411e-b2c4-541be6c42eb4";
const IDENTITY: [f64; 16] = [
    1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
];

fn finished_stream() -> Router {
    let state = AppState::default();
    state
        .streams
        .create(
            json!({"schema_version":1,"id":ID,"map_id":"synthetic","floor_id":"ground",
        "coordinates":{"units":"meters","up_axis":"y","handedness":"right"}}),
        )
        .unwrap();
    state
        .streams
        .append(
            ID,
            0,
            json!({"sequence":0,
        "color_jpeg":STANDARD.encode(include_bytes!("fixtures/stream-color.jpg")),
        "frame":{"id":"frame-0","timestamp_seconds":1.,"pixel_orientation":"sensor_native",
            "map_from_camera":IDENTITY,
            "camera":{"image_width":4,"image_height":4,"fx":20.,"fy":20.,"cx":1.5,"cy":1.5},
            "depth":{"width":4,"height":4,"values_m":vec![2.;16],"confidence":vec![2;16]}}}),
        )
        .unwrap();
    state.streams.finish(ID, 1).unwrap();
    app(state)
}

async fn response(
    router: &Router,
    path: &str,
    accept_encoding: &[&str],
) -> (StatusCode, HeaderMap, Vec<u8>) {
    let mut request = Request::builder().uri(path);
    for encoding in accept_encoding {
        request = request.header("accept-encoding", *encoding);
    }
    let response = router
        .clone()
        .oneshot(request.body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap()
        .to_vec();
    (status, headers, bytes)
}

#[tokio::test]
async fn gzip_result_and_scene_are_smaller_and_decode_to_exact_original_json() {
    let router = finished_stream();
    for endpoint in ["result", "scene"] {
        let path = format!("/streams/{ID}/{endpoint}");
        let (status, plain_headers, plain) = response(&router, &path, &[]).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(plain_headers["content-type"], "application/json");
        assert_eq!(plain_headers["vary"], "Accept-Encoding");
        assert!(!plain_headers.contains_key("content-encoding"));
        let (status, headers, compressed) = response(&router, &path, &["br, gzip, deflate"]).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(headers["content-type"], "application/json");
        assert_eq!(headers["content-encoding"], "gzip");
        assert_eq!(headers["vary"], "Accept-Encoding");
        assert!(compressed.len() < plain.len());
        let mut decoded = Vec::new();
        flate2::read::GzDecoder::new(compressed.as_slice())
            .read_to_end(&mut decoded)
            .unwrap();
        assert_eq!(decoded, plain);
        assert!(serde_json::from_slice::<Value>(&decoded).is_ok());
        // Compression never replaces the durable ordinary-JSON result cache.
        assert_eq!(response(&router, &path, &[]).await.2, plain);
    }
}

#[tokio::test]
async fn encoding_quality_wildcards_refusal_and_multiple_headers_are_respected() {
    let router = finished_stream();
    let path = format!("/streams/{ID}/result");
    for (encodings, gzip) in [
        (vec!["GZip"], true),
        (vec!["gzip;q=0.5, identity;q=1"], true),
        (vec!["gzip;q=0"], false),
        (vec!["gzip;q=0, *;q=1"], false),
        (vec!["gzip;q=1, *;q=0"], true),
        (vec!["br, *;q=0.7"], true),
        (vec!["*;q=0"], false),
        (vec!["br"], false),
        (vec!["identity"], false),
        (vec!["gzip;q=2"], false),
        (vec!["gzip;q=invalid"], false),
        (vec!["gzip;q"], false),
        (vec!["gzip;q=NaN"], false),
        (vec!["br", "gzip"], true),
        (vec!["gzip;q=0", "gzip;q=1"], false),
    ] {
        let (status, headers, bytes) = response(&router, &path, &encodings).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            headers.contains_key("content-encoding"),
            gzip,
            "{encodings:?}"
        );
        if !gzip {
            assert!(serde_json::from_slice::<Value>(&bytes).is_ok());
        }
    }
}

#[tokio::test]
async fn other_stream_endpoints_and_errors_remain_plain_json() {
    let router = finished_stream();
    let (status, headers, bytes) = response(&router, &format!("/streams/{ID}"), &["gzip"]).await;
    assert_eq!(status, StatusCode::OK);
    assert!(!headers.contains_key("content-encoding"));
    assert_eq!(
        serde_json::from_slice::<Value>(&bytes).unwrap()["finished"],
        true
    );
    let (status, headers, bytes) = response(
        &router,
        "/streams/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/result",
        &["gzip"],
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(!headers.contains_key("content-encoding"));
    assert_eq!(
        serde_json::from_slice::<Value>(&bytes).unwrap()["error"]["code"],
        "stream_not_found"
    );
}
