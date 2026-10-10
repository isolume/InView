use std::{
    fs,
    io::{Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

const TOKEN: &str = "startup-regression-token-0123456789";

struct Server(Child);

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn start(directory: &Path, address: SocketAddr) -> Server {
    let mut server = Server(
        Command::new(env!("CARGO_BIN_EXE_inview-backend"))
            .env("INVIEW_BIND", address.to_string())
            .env("INVIEW_API_TOKEN", TOKEN)
            .env("INVIEW_SCAN_DIR", directory.join("scans"))
            .env("INVIEW_STREAM_DIR", directory.join("streams"))
            .env("INVIEW_RECOGNITION", "off")
            .env_remove("INVIEW_DATABASE_URL")
            .env_remove("INVIEW_REQUIRE_TIMESCALE")
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        assert!(
            server.0.try_wait().unwrap().is_none(),
            "backend exited at startup"
        );
        if TcpStream::connect(address).is_ok() {
            return server;
        }
        assert!(Instant::now() < deadline, "backend did not start");
        thread::sleep(Duration::from_millis(20));
    }
}

fn request(address: SocketAddr, method: &str, path: &str, token: bool, body: &str) -> String {
    let mut stream = TcpStream::connect(address).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let authorization = if token {
        format!("Authorization: Bearer {TOKEN}\r\n")
    } else {
        String::new()
    };
    write!(stream, "{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n{authorization}Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()).unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    response
}

#[test]
fn executable_preserves_authentication_and_persistent_stores_across_restart() {
    let directory = std::env::temp_dir().join(format!("inview-startup-{}", uuid::Uuid::new_v4()));
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let server = start(&directory, address);
    assert!(request(address, "GET", "/health", false, "").starts_with("HTTP/1.1 401"));
    assert!(request(address, "GET", "/health", true, "").starts_with("HTTP/1.1 200"));
    assert!(
        request(
            address,
            "POST",
            "/scans",
            true,
            include_str!("../examples/scan.json")
        )
        .starts_with("HTTP/1.1 201")
    );
    assert!(
        request(
            address,
            "PUT",
            "/graphs/demo-building",
            true,
            include_str!("../examples/graph.json")
        )
        .starts_with("HTTP/1.1 200")
    );
    drop(server);

    let server = start(&directory, address);
    assert!(request(address, "GET", "/scans/demo-room", false, "").starts_with("HTTP/1.1 401"));
    let capture = request(address, "GET", "/scans/demo-room", true, "");
    assert!(capture.starts_with("HTTP/1.1 200"));
    let (_, body) = capture.split_once("\r\n\r\n").unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(body).unwrap(),
        serde_json::from_str::<serde_json::Value>(include_str!("../examples/scan.json")).unwrap()
    );
    assert!(request(address, "GET", "/graphs/demo-building", true, "").starts_with("HTTP/1.1 200"));
    drop(server);
    fs::remove_dir_all(directory).unwrap();
}
