use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use inview_backend::{AppState, app};
use serde_json::{Value, json};
use tower::ServiceExt;

fn fixture(stride: usize, native_mesh: bool) -> Vec<u8> {
    let mut source: Value =
        serde_json::from_slice(include_bytes!("../examples/scan.json")).unwrap();
    source["frames"][0]["color_asset"] = json!("depth-frame-001.color.jpg");
    if native_mesh {
        source["meshes"] = json!([]);
    }
    let mut buffer = vec![0; stride * 2];
    for (y, row) in [[1., 0., 2.], [1.5, 2., 2.5]].into_iter().enumerate() {
        for (x, depth) in row.into_iter().enumerate() {
            if y * stride + x * 4 + 4 <= buffer.len() {
                buffer[y * stride + x * 4..y * stride + x * 4 + 4]
                    .copy_from_slice(&f32::to_le_bytes(depth));
            }
        }
    }
    let smooth = [1.5_f32, 1.5, 1.5, 1.5, 1.5, 1.5]
        .into_iter()
        .flat_map(f32::to_le_bytes)
        .collect::<Vec<_>>();
    let mut native = json!({"depthBuffers":[{
        "id":"depth-frame-001", "width":3,"height":2,"bytesPerRow":stride,
        "pixelFormat":1717855600u32,"depth":STANDARD.encode(buffer),
        "confidenceBytesPerRow":4,"confidence":STANDARD.encode([2,0,1,0,2,2,2,0]),
        "smoothedWidth":3,"smoothedHeight":2,"smoothedBytesPerRow":12,
        "smoothedPixelFormat":1717855600u32,"smoothedDepth":STANDARD.encode(smooth)
    }]});
    if native_mesh {
        let positions = [0., 0., 0., 1., 0., 0., 0., 0., 1.]
            .into_iter()
            .flat_map(f32::to_le_bytes)
            .collect::<Vec<_>>();
        let indices = [0_u16, 1, 2]
            .into_iter()
            .flat_map(u16::to_le_bytes)
            .collect::<Vec<_>>();
        native["meshBuffers"] = json!([{
            "id":"raw-anchor", "mapFromAnchor":[1,0,0,0,0,1,0,0,0,0,1,0,2,0,3,1],
            "vertices":STANDARD.encode(positions), "vertexOffset":0,"vertexStride":12,"vertexCount":3,
            "faces":STANDARD.encode(indices),"bytesPerIndex":2,"faceCount":1,"indicesPerFace":3
        }]);
    }
    let mut tar = tar::Builder::new(Vec::new());
    for (name, bytes) in [
        ("capture.json", serde_json::to_vec(&source).unwrap()),
        ("raw-snapshot.json", serde_json::to_vec(&native).unwrap()),
        ("depth-frame-001.color.jpg", vec![0xff, 0xd8, 0xff, 0xd9]),
    ] {
        let mut header = tar::Header::new_ustar();
        header.set_size(bytes.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        tar.append_data(&mut header, format!("demo-room/{name}"), bytes.as_slice())
            .unwrap();
    }
    tar.into_inner().unwrap()
}
async fn call(router: &Router, path: &str, method: &str, data: Vec<u8>) -> (StatusCode, Vec<u8>) {
    let response = router
        .clone()
        .oneshot(
            Request::builder()
                .uri(path)
                .method(method)
                .body(Body::from(data))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    (
        status,
        to_bytes(response.into_body(), 20_000_000)
            .await
            .unwrap()
            .to_vec(),
    )
}

#[tokio::test]
async fn native_depth_respects_row_padding_confidence_and_camera_frame() {
    let router = app(AppState::default());
    assert_eq!(
        call(&router, "/scan-packages", "POST", fixture(16, false))
            .await
            .0,
        StatusCode::CREATED
    );
    let (status, bytes) = call(
        &router,
        "/scans/demo-room/raw-preview?mode=raw&max_points=1000",
        "GET",
        vec![],
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let raw: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(raw["source"], "native_arkit_depth");
    assert_eq!(raw["pointCount"], 5);
    assert_eq!(raw["frames"][0]["usedSmoothed"], false);
    assert_eq!(raw["frames"][0]["width"], 3);
    assert_eq!(raw["frames"][0]["height"], 2);
    assert_eq!(raw["frames"][0]["sampleStride"], 1);
    assert_eq!(raw["frames"][0]["colorAsset"], "depth-frame-001.color.jpg");
    assert_eq!(raw["frames"][0]["points"][0][0], -0.25);
    assert!((raw["frames"][0]["points"][0][2].as_f64().unwrap() - 0.8).abs() < 1e-5);
    let (status, bytes) = call(
        &router,
        "/scans/demo-room/raw-preview?mode=smoothed&max_points=1000",
        "GET",
        vec![],
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let smooth: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(smooth["frames"][0]["usedSmoothed"], true);
    assert_eq!(smooth["pointCount"], 5);
    assert!((smooth["frames"][0]["points"][0][2].as_f64().unwrap() - 0.3).abs() < 1e-5);
    assert_eq!(
        call(
            &router,
            "/scans/demo-room/color/depth-frame-001.color.jpg",
            "GET",
            vec![]
        )
        .await
        .1,
        [0xff, 0xd8, 0xff, 0xd9]
    );
    assert_eq!(
        call(&router, "/scans/demo-room/color/unknown.jpg", "GET", vec![])
            .await
            .0,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn native_mesh_restores_portable_omission_in_shared_arkit_frame() {
    let router = app(AppState::default());
    assert_eq!(
        call(&router, "/scan-packages", "POST", fixture(16, true))
            .await
            .0,
        StatusCode::CREATED
    );
    let (status, bytes) = call(&router, "/scans/demo-room/native-mesh", "GET", vec![]).await;
    assert_eq!(status, StatusCode::OK);
    let mesh: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(mesh["source"], "native_arkit_mesh");
    assert_eq!(mesh["vertexCount"], 3);
    assert_eq!(mesh["triangleCount"], 1);
    assert_eq!(mesh["meshes"][0]["vertices"][1], json!([3., 0., 3.]));
    assert_eq!(mesh["meshes"][0]["triangles"][0], json!([0, 1, 2]));
    let (_, scene_bytes) = call(&router, "/scans/demo-room/scene", "GET", vec![]).await;
    let scene: Value = serde_json::from_slice(&scene_bytes).unwrap();
    assert_eq!(scene["meshes"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn invalid_native_stride_is_rejected_without_reading_past_buffer() {
    let router = app(AppState::default());
    assert_eq!(
        call(&router, "/scan-packages", "POST", fixture(8, false))
            .await
            .0,
        StatusCode::CREATED
    );
    let (status, _) = call(
        &router,
        "/scans/demo-room/raw-preview?mode=raw",
        "GET",
        vec![],
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
}
