//! A local HTTP server for the avatar sources (no network in tests): it
//! answers each request with what `route` returns and records the requests.

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

/// One request the stub received.
#[derive(Debug, Clone)]
pub struct Request {
    /// Path and query, as sent (`/gravatar/abc?s=80&d=404`).
    pub target: String,
    /// Header lines, names lowercased (`authorization: Bearer x`).
    pub headers: Vec<String>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        let prefix = format!("{}:", name.to_ascii_lowercase());
        self.headers
            .iter()
            .find_map(|line| line.strip_prefix(&prefix))
            .map(str::trim)
    }

    pub fn path(&self) -> &str {
        self.target.split('?').next().unwrap_or(&self.target)
    }
}

/// What to answer.
pub struct Reply {
    pub status: u16,
    pub content_type: &'static str,
    pub body: Vec<u8>,
}

impl Reply {
    pub fn png(body: &[u8]) -> Self {
        Self {
            status: 200,
            content_type: "image/png",
            body: body.to_vec(),
        }
    }

    pub fn json(text: &str) -> Self {
        Self {
            status: 200,
            content_type: "application/json",
            body: text.as_bytes().to_vec(),
        }
    }

    pub fn status(status: u16) -> Self {
        Self {
            status,
            content_type: "text/plain",
            body: b"stub".to_vec(),
        }
    }
}

type Route = dyn Fn(&Request, &str) -> Reply + Send + Sync;

pub struct HttpStub {
    base: String,
    requests: Arc<Mutex<Vec<Request>>>,
}

impl HttpStub {
    /// Serves until the test ends. `route` gets the request and the stub's
    /// base URL (to answer URLs that point back at it).
    pub fn start(route: impl Fn(&Request, &str) -> Reply + Send + Sync + 'static) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind stub");
        let base = format!("http://{}", listener.local_addr().expect("stub address"));
        let requests: Arc<Mutex<Vec<Request>>> = Arc::default();
        let route: Arc<Route> = Arc::new(route);
        let (seen, url) = (Arc::clone(&requests), base.clone());
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let (seen, route, url) = (Arc::clone(&seen), Arc::clone(&route), url.clone());
                thread::spawn(move || serve(stream, &seen, &*route, &url));
            }
        });
        Self { base, requests }
    }

    pub fn base(&self) -> &str {
        &self.base
    }

    pub fn requests(&self) -> Vec<Request> {
        self.requests.lock().expect("requests").clone()
    }

    /// The paths requested, in order.
    pub fn paths(&self) -> Vec<String> {
        self.requests()
            .iter()
            .map(|r| r.path().to_string())
            .collect()
    }
}

fn serve(stream: TcpStream, seen: &Mutex<Vec<Request>>, route: &Route, base: &str) {
    let mut reader = BufReader::new(match stream.try_clone() {
        Ok(stream) => stream,
        Err(_) => return,
    });
    let mut line = String::new();
    if reader.read_line(&mut line).is_err() {
        return;
    }
    let target = line.split_whitespace().nth(1).unwrap_or("/").to_string();
    let mut headers = Vec::new();
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim().is_empty() {
            break;
        }
        let header = header.trim_end().to_string();
        let lowered = match header.split_once(':') {
            Some((name, value)) => format!("{}:{value}", name.to_ascii_lowercase()),
            None => header,
        };
        headers.push(lowered);
    }
    let request = Request { target, headers };
    seen.lock().expect("requests").push(request.clone());
    let reply = route(&request, base);
    let mut stream = stream;
    let head = format!(
        "HTTP/1.1 {} Stub\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        reply.status,
        reply.content_type,
        reply.body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(&reply.body);
    let _ = stream.flush();
}
