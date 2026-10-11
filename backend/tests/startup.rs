//! Exercise the actual executable so configured stores and credentials cannot be shadowed.
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    path::PathBuf,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

const TOKEN: &str = "executable-test-processing-token-at-least-32-characters";

struct Server {
    child: Child,
    address: SocketAddr,
}
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
struct Directory(PathBuf);
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn command(directory: &Directory, address: &str) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_inview-backend"));
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("INVIEW_") {
            command.env_remove(key);
        }
    }
    command
        .current_dir(&directory.0)
        .env("INVIEW_BIND", address)
        .env("INVIEW_RECOGNITION", "off")
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

fn start(directory: &Directory) -> Server {
    let socket = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = socket.local_addr().unwrap();
    drop(socket);
    let child = command(directory, &address.to_string())
        .env("INVIEW_API_TOKEN", TOKEN)
        .env("INVIEW_SCAN_DIR", directory.0.join("configured-scans"))
        .env("INVIEW_STREAM_DIR", directory.0.join("configured-streams"))
        .env("INVIEW_PRODUCT_DIR", directory.0.join("configured-product"))
        .spawn()
        .unwrap();
    let mut server = Server { child, address };
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        assert!(
            server.child.try_wait().unwrap().is_none(),
            "backend exited before listening"
        );
        if TcpStream::connect(address).is_ok() {
            return server;
        }
        assert!(Instant::now() < deadline, "backend did not listen");
        thread::sleep(Duration::from_millis(25));
    }
}

fn request(
    server: &Server,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (u16, Value) {
    let body = body.map_or(String::new(), |value| value.to_string());
    let auth = token.map_or(String::new(), |token| {
        format!("Authorization: Bearer {token}\r\n")
    });
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n{auth}Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
        body.len()
    );
    let mut socket = TcpStream::connect(server.address).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    socket.write_all(request.as_bytes()).unwrap();
    let mut response = String::new();
    socket.read_to_string(&mut response).unwrap();
    let (headers, body) = response.split_once("\r\n\r\n").unwrap();
    let status = headers.split_whitespace().nth(1).unwrap().parse().unwrap();
    (status, serde_json::from_str(body).unwrap())
}

#[test]
fn configured_executable_enforces_auth_and_reopens_all_persistent_stores() {
    let directory =
        Directory(std::env::temp_dir().join(format!("inview-startup-{}", uuid::Uuid::new_v4())));
    std::fs::create_dir_all(&directory.0).unwrap();
    let server = start(&directory);
    for path in ["/health", "/scans", "/graphs", "/api/buildings"] {
        assert_eq!(request(&server, "GET", path, None, None).0, 401);
    }
    assert_eq!(request(&server, "GET", "/health", Some(TOKEN), None).0, 200);
    let scan: Value = serde_json::from_str(include_str!("../examples/scan.json")).unwrap();
    let graph: Value = serde_json::from_str(include_str!("../examples/graph.json")).unwrap();
    assert_eq!(
        request(&server, "POST", "/scans", Some(TOKEN), Some(scan.clone())).0,
        201
    );
    assert_eq!(
        request(
            &server,
            "PUT",
            "/graphs/demo-building",
            Some(TOKEN),
            Some(graph.clone())
        )
        .0,
        200
    );
    let (status, account) = request(
        &server,
        "POST",
        "/api/accounts/register",
        None,
        Some(json!({"email":"restart@example.test","password":"a durable test password"})),
    );
    assert_eq!(status, 201);
    let stored_graph = request(&server, "GET", "/graphs/demo-building", Some(TOKEN), None).1;
    assert_eq!(
        request(&server, "GET", "/graphs/demo-building", None, None).0,
        404
    );
    drop(server);
    assert!(directory.0.join("configured-scans").exists());
    assert!(directory.0.join("configured-streams").exists());
    assert!(directory.0.join("configured-product/product.json").exists());
    assert!(!directory.0.join("data").exists());
    let restarted = start(&directory);
    assert_eq!(
        request(&restarted, "GET", "/scans/demo-room", Some(TOKEN), None).1,
        scan
    );
    assert_eq!(
        request(
            &restarted,
            "GET",
            "/graphs/demo-building",
            Some(TOKEN),
            None
        )
        .1,
        stored_graph
    );
    assert_eq!(
        request(
            &restarted,
            "GET",
            "/api/accounts/me",
            account["token"].as_str(),
            None
        )
        .0,
        200
    );
    for path in ["/scans", "/scans/demo-room"] {
        assert_eq!(request(&restarted, "GET", path, None, None).0, 401);
    }
}

#[test]
fn executable_rejects_unsafe_or_incomplete_configuration_before_startup() {
    let directory = Directory(
        std::env::temp_dir().join(format!("inview-invalid-startup-{}", uuid::Uuid::new_v4())),
    );
    std::fs::create_dir_all(&directory.0).unwrap();
    assert!(!command(&directory, "0.0.0.0:0").status().unwrap().success());
    assert!(
        !command(&directory, "127.0.0.1:0")
            .env("INVIEW_API_TOKEN", "short")
            .status()
            .unwrap()
            .success()
    );
    assert!(
        !command(&directory, "127.0.0.1:0")
            .env("INVIEW_REQUIRE_TIMESCALE", "1")
            .status()
            .unwrap()
            .success()
    );
}
