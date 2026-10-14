use std::time::Duration;

use super::exchange::{USER_AGENT, is_text};
use super::*;
use crate::*;

use std::io::{Read, Write};
use std::net::TcpListener;

/// Serves one canned response and returns the raw request it received.
fn serve_once(response: &'static str) -> (String, std::thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/echo", listener.local_addr().unwrap());
    let handle = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buf = [0u8; 4096];
        let n = stream.read(&mut buf).unwrap();
        stream.write_all(response.as_bytes()).unwrap();
        String::from_utf8_lossy(&buf[..n]).into_owned()
    });
    (url, handle)
}

#[tokio::test]
async fn sends_request_and_reads_response() {
    let (url, server) = serve_once(
        "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}",
    );

    let mut req = Request::new("post", url);
    req.headers.push(Header {
        name: "X-Test".into(),
        value: "yes".into(),
    });
    req.body = Some("hello".into());

    let resp = send(req).await.unwrap();
    assert_eq!(resp.status, 201);
    assert_eq!(resp.status_text, "Created");
    assert_eq!(resp.body, "{\"ok\":true}");
    assert_eq!(resp.size_bytes, 11);
    assert!(resp.headers.iter().any(|h| h.name == "content-type"));

    let raw = server.join().unwrap();
    assert!(raw.starts_with("POST /echo HTTP/1.1"));
    assert!(raw.to_lowercase().contains("x-test: yes"));
    assert!(raw.ends_with("hello"));
}

/// The header lines of a raw request, lower-cased and sorted.
fn header_lines(raw: &str) -> Vec<String> {
    let head = raw.split("\r\n\r\n").next().unwrap();
    let mut lines: Vec<String> = head.lines().skip(1).map(str::to_lowercase).collect();
    lines.sort();
    lines
}

#[tokio::test]
async fn records_the_headers_that_were_sent() {
    let (url, server) =
        serve_once("HTTP/1.1 200 OK\r\nSet-Cookie: seen=1\r\nContent-Length: 0\r\n\r\n");
    let mut request = Request::new("POST", &url);
    request.add_header("X-Test", "yes");
    request.add_header("Cookie", "own=1");
    request.body = Some("hello".into());
    let host = url.trim_start_matches("http://").trim_end_matches("/echo");
    let mut jar = vec![Cookie {
        name: "stored".into(),
        value: "2".into(),
        domain: "127.0.0.1".into(),
        path: "/".into(),
        expires: None,
        secure: false,
        http_only: false,
        host_only: true,
    }];

    let (_, exchanges) = send_logged(
        request,
        &SendOptions::default(),
        &mut jar,
        &Watch::default(),
    )
    .await
    .unwrap();
    let mut recorded: Vec<String> = exchanges[0]
        .request
        .headers
        .iter()
        .map(|h| format!("{}: {}", h.name, h.value).to_lowercase())
        .collect();
    recorded.sort();
    // What the exchange says was sent is what the server received.
    assert_eq!(recorded, header_lines(&server.join().unwrap()));
    assert_eq!(
        recorded,
        [
            "accept-encoding: zstd,gzip,deflate,br".to_string(),
            "accept: */*".to_string(),
            "content-length: 5".to_string(),
            "cookie: own=1; stored=2".to_string(),
            format!("host: {host}"),
            format!("user-agent: {}", USER_AGENT.to_lowercase()),
            "x-test: yes".to_string(),
        ]
    );
    // The jar still learns what the server set.
    assert!(jar.iter().any(|c| c.name == "seen"));
}

#[tokio::test]
async fn reuses_the_connection_between_sends() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    listener.set_nonblocking(true).unwrap();
    // Answers every request on every connection, counting connections.
    let connections = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counter = connections.clone();
    let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stop = done.clone();
    let server = std::thread::spawn(move || {
        use std::sync::atomic::Ordering::SeqCst;
        let mut streams = Vec::new();
        while !stop.load(SeqCst) {
            if let Ok((stream, _)) = listener.accept() {
                stream.set_nonblocking(true).unwrap();
                counter.fetch_add(1, SeqCst);
                streams.push(stream);
            }
            for stream in &mut streams {
                let mut buf = [0u8; 4096];
                if matches!(stream.read(&mut buf), Ok(n) if n > 0) {
                    stream
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                        .unwrap();
                }
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    });

    for _ in 0..3 {
        assert_eq!(send(Request::new("GET", &url)).await.unwrap().body, "ok");
    }
    done.store(true, std::sync::atomic::Ordering::SeqCst);
    server.join().unwrap();
    assert_eq!(connections.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[tokio::test]
async fn keeps_binary_bodies_as_bytes() {
    // A PNG signature is not valid UTF-8.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/logo.png", listener.local_addr().unwrap());
    let png: &[u8] = &[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0xff, 0x00];
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buf = [0u8; 4096];
        let _ = stream.read(&mut buf).unwrap();
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 10\r\n\r\n")
            .unwrap();
        stream.write_all(png).unwrap();
    });
    let response = send(Request::new("GET", url)).await.unwrap();
    assert_eq!(response.bytes.as_deref(), Some(png));
    assert_eq!((response.body.as_str(), response.size_bytes), ("", 10));

    // Text in another encoding is still treated as text.
    assert!(is_text("text/plain; charset=latin1"));
    assert!(is_text("application/problem+json"));
    assert!(!is_text("image/png"));
}

#[tokio::test]
async fn rejects_bad_input() {
    let err = send(Request::new("GET", "not a url")).await.unwrap_err();
    assert!(matches!(err, Error::InvalidUrl { .. }));

    let err = send(Request::new("BAD METHOD", "http://localhost"))
        .await
        .unwrap_err();
    assert!(matches!(err, Error::InvalidMethod(_)));

    let err = send_with(
        &Request::new("GET", "{{base}}/x"),
        &[],
        &SendOptions::default(),
        &[],
    )
    .await
    .unwrap_err();
    assert!(matches!(err, Error::UnresolvedVariables(v) if v == ["base"]));

    let err = send_with(
        &Request::new("GET", "http://{{host}}/x"),
        &[],
        &SendOptions::default(),
        &[],
    )
    .await
    .unwrap_err();
    assert!(matches!(err, Error::UnresolvedVariables(v) if v == ["host"]));
}

#[tokio::test]
async fn sends_with_variables() {
    let (url, server) = serve_once("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
    let mut req = Request::new("GET", "{{base}}?q={{nope}}");
    req.add_header("X-Token", "{{token}}");
    req.add_header("X-Missing", "{{nope}}");

    let vars = [Variable::new("base", url), Variable::new("token", "t1")];
    let sent = send_with(&req, &vars, &SendOptions::default(), &[])
        .await
        .unwrap();
    assert_eq!(sent.response.status, 200);
    assert_eq!(sent.unresolved, ["nope"]);
    assert!(
        server
            .join()
            .unwrap()
            .to_lowercase()
            .contains("x-token: t1")
    );
}

/// Serves the responses in order, one connection each, and returns the
/// raw requests it received.
fn serve(responses: Vec<String>) -> (String, std::thread::JoinHandle<Vec<String>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/echo", listener.local_addr().unwrap());
    let handle = std::thread::spawn(move || {
        let mut seen = Vec::new();
        for response in responses {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 8192];
            let n = stream.read(&mut buf).unwrap();
            stream.write_all(response.as_bytes()).unwrap();
            seen.push(String::from_utf8_lossy(&buf[..n]).into_owned());
        }
        seen
    });
    (url, handle)
}

fn reply(status: &str, headers: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {status}\r\n{headers}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

#[tokio::test]
async fn auth_resolves_variables_and_signs_the_request() {
    let (url, server) = serve(vec![reply("200 OK", "", "")]);
    let mut request = Request::new("GET", url);
    request.auth = Some(Auth::new(
        AuthKind::Basic,
        &[("username", "{{user}}"), ("password", "{{missing}}")],
    ));
    let sent = send_with(
        &request,
        &[Variable::new("user", "bob")],
        &SendOptions::default(),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(sent.unresolved, ["missing"]);
    // base64("bob:{{missing}}")
    assert!(server.join().unwrap()[0].contains("authorization: Basic Ym9iOnt7bWlzc2luZ319"));
}

#[tokio::test]
async fn digest_answers_the_challenge() {
    let challenge = "WWW-Authenticate: Digest realm=\"r\", nonce=\"abc\", qop=\"auth\"\r\n";
    let (url, server) = serve(vec![
        reply("401 Unauthorized", challenge, "no"),
        reply("200 OK", "", "yes"),
    ]);
    let mut request = Request::new("GET", format!("{url}?a=1"));
    request.auth = Some(Auth::new(
        AuthKind::Digest,
        &[("username", "u"), ("password", "p")],
    ));
    let response = send(request).await.unwrap();
    assert_eq!(response.status, 200);
    assert_eq!(response.body, "yes");

    let seen = server.join().unwrap();
    assert!(!seen[0].to_lowercase().contains("authorization:"));
    let second = &seen[1];
    assert!(
        second.contains("Digest username=\"u\", realm=\"r\", nonce=\"abc\", uri=\"/echo?a=1\"")
    );
    assert!(second.contains("qop=auth, nc=00000001"));

    // Without a challenge the first response is simply returned.
    let (url, server) = serve(vec![reply("403 Forbidden", "", "")]);
    let mut request = Request::new("GET", url);
    request.auth = Some(Auth::new(AuthKind::Digest, &[("username", "u")]));
    assert_eq!(send(request).await.unwrap().status, 403);
    server.join().unwrap();
}

#[tokio::test]
async fn oauth2_fetches_a_token_once_and_reuses_it() {
    let token = r#"{"access_token":"tok-1","token_type":"bearer","expires_in":3600}"#;
    let (url, server) = serve(vec![
        reply("200 OK", "Content-Type: application/json\r\n", token),
        reply("200 OK", "", ""),
        reply("200 OK", "", ""),
    ]);
    let mut request = Request::new("GET", url.clone());
    request.auth = Some(Auth::new(
        AuthKind::OAuth2,
        &[
            ("accessTokenUrl", &url),
            ("clientId", "id"),
            ("clientSecret", "secret"),
            ("scope", "read write"),
        ],
    ));
    assert_eq!(send(request.clone()).await.unwrap().status, 200);
    assert_eq!(send(request).await.unwrap().status, 200);

    let seen = server.join().unwrap();
    assert!(seen[0].starts_with("POST /echo"));
    assert!(seen[0].contains("authorization: Basic aWQ6c2VjcmV0"));
    assert!(seen[0].ends_with("grant_type=client_credentials&scope=read+write"));
    assert!(seen[1].contains("authorization: Bearer tok-1"));
    assert!(
        seen[2].contains("authorization: Bearer tok-1"),
        "second send used the cache"
    );

    // A failed token request is reported with the server's reason.
    let (url, server) = serve(vec![reply(
        "400 Bad Request",
        "",
        r#"{"error":"invalid_client","error_description":"unknown client"}"#,
    )]);
    let mut request = Request::new("GET", url.clone());
    request.auth = Some(Auth::new(
        AuthKind::OAuth2,
        &[("accessTokenUrl", &url), ("clientId", "nope")],
    ));
    let err = send(request).await.unwrap_err().to_string();
    assert!(err.contains("unknown client"), "{err}");
    server.join().unwrap();
}

#[tokio::test]
async fn ntlm_completes_the_handshake_on_one_connection() {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    use ntlmclient::{ChallengeMessage, Flags, Message};

    let challenge = Message::Challenge(ChallengeMessage {
        target_name: "DOMAIN".into(),
        flags: Flags::NEGOTIATE_UNICODE | Flags::NEGOTIATE_NTLM,
        challenge: [1, 2, 3, 4, 5, 6, 7, 8],
        context: (0, 0),
        target_information: Vec::new(),
        os_version: Default::default(),
    });
    let challenge = STANDARD.encode(challenge.to_bytes().unwrap());

    // One accepted connection only: the handshake fails if it is not reused.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/echo", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut seen = Vec::new();
        let replies = [
            format!(
                "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Negotiate\r\nWWW-Authenticate: NTLM {challenge}\r\nContent-Length: 0\r\n\r\n"
            ),
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".to_string(),
        ];
        for reply in replies {
            let mut buf = [0u8; 8192];
            let n = stream.read(&mut buf).unwrap();
            seen.push(String::from_utf8_lossy(&buf[..n]).into_owned());
            stream.write_all(reply.as_bytes()).unwrap();
        }
        seen
    });

    let mut request = Request::new("GET", url);
    request.auth = Some(Auth::new(
        AuthKind::Ntlm,
        &[
            ("username", "alice"),
            ("password", "pw"),
            ("domain", "CORP"),
        ],
    ));
    let response = send(request).await.unwrap();
    assert_eq!(response.body, "ok");

    let message = |raw: &str| {
        let line = raw
            .lines()
            .find(|l| l.to_lowercase().starts_with("authorization: ntlm "))
            .expect("NTLM authorization header");
        let bytes = STANDARD
            .decode(&line["authorization: ntlm ".len()..])
            .unwrap();
        Message::try_from(bytes.as_slice()).unwrap()
    };
    let seen = server.join().unwrap();
    // "NTLMSSP\0" followed by message type 1, in base64.
    assert!(seen[0].contains("authorization: NTLM TlRMTVNTUAABAAAA"));
    match message(&seen[1]) {
        Message::Authenticate(auth) => {
            assert_eq!(auth.user_name, "alice");
            assert_eq!(auth.domain_name, "CORP");
            assert!(!auth.ntlm_response.is_empty());
        }
        other => panic!("expected an authenticate message, got {other:?}"),
    }
}

#[tokio::test]
async fn imports_a_served_swagger_document() {
    let (url, server) = serve_once(concat!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
        r#"{"swagger":"2.0","info":{"title":""},"basePath":"/api","paths":{"/ping":{"get":{"responses":{}}}}}"#
    ));
    let root = url.trim_end_matches("/echo").to_string();

    let result = import_url(&url).await.unwrap();
    assert!(server.join().unwrap().starts_with("GET /echo"));
    assert_eq!(result.source, "openapi");
    assert!(result.warnings.is_empty());
    let collection = &result.collections[0];
    assert_eq!(
        collection.name, "echo",
        "untitled documents take the file name"
    );
    assert_eq!(collection.variables[0].value, format!("{root}/api"));
    assert_eq!(collection.requests()[0].1.url, "{{baseUrl}}/ping");

    assert!(matches!(
        import_url("not a url").await,
        Err(Error::InvalidUrl { .. })
    ));
}

fn with_settings(request: &Request, change: impl FnOnce(&mut RequestSettings)) -> Request {
    let mut request = request.clone();
    let mut settings = RequestSettings::default();
    change(&mut settings);
    request.settings = Some(settings);
    request
}

#[tokio::test]
async fn a_send_records_every_exchange_for_the_session_log() {
    let (url, server) = serve(vec![
        reply("302 Found", "Location: /next\r\n", ""),
        reply("200 OK", "Content-Type: text/plain\r\n", "done"),
    ]);
    let mut request = Request::new("POST", &url);
    request.body = Some("payload".into());
    let sent = send_with(&request, &[], &SendOptions::default(), &[])
        .await
        .unwrap();
    server.join().unwrap();

    let log: Vec<_> = sent
        .exchanges
        .iter()
        .map(|e| (e.request.method.as_str(), e.response.status))
        .collect();
    assert_eq!(log, [("POST", 302), ("GET", 200)]);
    assert!(sent.exchanges[1].request.url.ends_with("/next"));
    assert!(sent.exchanges[0].started_ms > 1_700_000_000_000);

    let har: serde_json::Value = serde_json::from_str(&to_har(&sent.exchanges)).unwrap();
    let entries = har["log"]["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0]["response"]["redirectURL"], "/next");
    assert_eq!(entries[0]["request"]["postData"]["text"], "payload");
    assert_eq!(entries[1]["response"]["content"]["text"], "done");
}

#[tokio::test]
async fn redirects_follow_the_request_settings() {
    let moved = |status: &str| {
        reply(
            status,
            "Location: /next?x=1\r\nSet-Cookie: hop=1; Path=/\r\n",
            "",
        )
    };
    let mut post = Request::new("POST", "");
    post.add_header("Content-Type", "text/plain");
    post.add_header("Authorization", "Bearer t");
    post.add_header("X-Api-Key", "k");
    post.body = Some("payload".into());
    let to = |url: &str| {
        let mut request = post.clone();
        request.url = format!("{url}#frag");
        request
    };

    // Default: a 302 turns the POST into a GET, with a Referer and the hop's cookie.
    let (url, server) = serve(vec![moved("302 Found"), reply("200 OK", "", "done")]);
    let mut jar = Vec::new();
    let response = send_opts(to(&url), &SendOptions::default(), &mut jar)
        .await
        .unwrap();
    assert_eq!((response.status, response.body.as_str()), (200, "done"));
    let seen = server.join().unwrap();
    assert!(seen[0].starts_with("POST /echo"));
    assert!(seen[1].starts_with("GET /next?x=1"), "{}", seen[1]);
    assert!(!seen[1].contains("payload") && !seen[1].contains("content-type"));
    assert!(
        seen[1].contains(&format!("referer: {url}\r\n")),
        "{}",
        seen[1]
    );
    assert!(
        seen[1].contains("authorization: Bearer t"),
        "same host keeps credentials"
    );
    assert!(seen[1].contains("cookie: hop=1"));

    // Follow original method, without a Referer.
    let (url, server) = serve(vec![moved("302 Found"), reply("200 OK", "", "")]);
    let request = with_settings(&to(&url), |s| {
        s.follow_original_method = true;
        s.remove_referer = true;
    });
    send(request).await.unwrap();
    let seen = server.join().unwrap();
    assert!(seen[1].starts_with("POST /next?x=1"));
    assert!(seen[1].ends_with("payload"));
    assert!(!seen[1].contains("referer:"));

    // A 307 repeats the request without being asked to.
    let (url, server) = serve(vec![
        moved("307 Temporary Redirect"),
        reply("200 OK", "", ""),
    ]);
    send(to(&url)).await.unwrap();
    assert!(server.join().unwrap()[1].starts_with("POST /next"));

    // Not following returns the redirect itself.
    let (url, server) = serve(vec![moved("301 Moved Permanently")]);
    let request = with_settings(&to(&url), |s| s.follow_redirects = false);
    assert_eq!(send(request).await.unwrap().status, 301);
    server.join().unwrap();

    // The cap stops a chain.
    let (url, server) = serve(vec![moved("302 Found"), moved("302 Found")]);
    let request = with_settings(&to(&url), |s| s.max_redirects = 1);
    let error = send(request).await.unwrap_err().to_string();
    assert!(error.contains("stopped after 1 redirect"), "{error}");
    server.join().unwrap();

    // Another port is another site: credentials stay behind unless asked.
    for keep in [false, true] {
        let (target, second) = serve(vec![reply("200 OK", "", "")]);
        let hop = reply("302 Found", &format!("Location: {target}\r\n"), "");
        let (url, first) = serve(vec![hop]);
        let request = with_settings(&to(&url), |s| s.follow_auth_header = keep);
        send(request).await.unwrap();
        first.join().unwrap();
        let seen = second.join().unwrap();
        assert_eq!(
            seen[0].contains("authorization: Bearer t"),
            keep,
            "{}",
            seen[0]
        );
        // An API key in a header of its own is a credential too.
        assert_eq!(seen[0].contains("x-api-key: k"), keep, "{}", seen[0]);
    }
}

#[tokio::test]
async fn request_settings_override_the_app_and_the_jar() {
    let base = Request::new("GET", "");
    let to = |url: &str| {
        let mut request = base.clone();
        request.url = url.to_string();
        request
    };

    // With the jar disabled, nothing is sent from it and nothing is stored.
    let (url, server) = serve(vec![reply("200 OK", "Set-Cookie: new=1; Path=/\r\n", "")]);
    let mut jar = Vec::new();
    store_set_cookie(
        &mut jar,
        "old=1; Path=/",
        &reqwest::Url::parse(&url).unwrap(),
        0,
    );
    let request = with_settings(&to(&url), |s| s.disable_cookie_jar = true);
    send_opts(request, &SendOptions::default(), &mut jar)
        .await
        .unwrap();
    assert!(!server.join().unwrap()[0].to_lowercase().contains("cookie:"));
    assert_eq!(jar.len(), 1);
    assert_eq!(jar[0].name, "old");

    // The request's HTTP version wins over the app-wide one.
    let (url, server) = serve(vec![reply("200 OK", "", "")]);
    let forced_http2 = SendOptions {
        http_mode: HttpMode::Http2,
        timeout_ms: Some(5_000),
        ..SendOptions::default()
    };
    let request = with_settings(&to(&url), |s| s.http_mode = Some(HttpMode::Http1));
    let response = send_opts(request, &forced_http2, &mut Vec::new())
        .await
        .unwrap();
    assert_eq!(response.http_version, "HTTP/1.1");
    server.join().unwrap();

    // Lenient parsing tolerates a malformed header; strict parsing does not.
    let odd =
        "HTTP/1.1 200 OK\r\nBad Header : x\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
    let (url, server) = serve(vec![odd.to_string()]);
    assert_eq!(send(to(&url)).await.unwrap().body, "ok");
    server.join().unwrap();
    let (url, server) = serve(vec![odd.to_string()]);
    let request = with_settings(&to(&url), |s| s.strict_http_parser = true);
    assert!(send(request).await.is_err());
    server.join().unwrap();

    // Defaults are not written to disk, and old files load without the field.
    let saved = serde_json::to_string(&base).unwrap();
    assert!(!saved.contains("settings"));
    let partial: RequestSettings = serde_json::from_str(r#"{"max_redirects": 3}"#).unwrap();
    assert_eq!(partial.max_redirects, 3);
    assert!(partial.verify_ssl && partial.follow_redirects);
}

#[tokio::test]
async fn sends_each_body_type() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("note.txt");
    std::fs::write(&file, "file contents").unwrap();
    let path = file.to_string_lossy().into_owned();
    let ok = || reply("200 OK", "", "");
    let (url, server) = serve(vec![ok(), ok(), ok(), ok(), ok()]);
    let post = |change: &dyn Fn(&mut Request)| {
        let mut request = Request::new("POST", url.clone());
        change(&mut request);
        request
    };

    // Url-encoded fields, with a variable resolved before encoding.
    let request = post(&|r| {
        r.body_mode = Some(BodyMode::UrlEncoded);
        r.form = vec![
            FormField::text("name", "a b&c"),
            FormField::text("who", "{{who}}"),
        ];
    });
    send_with(
        &request,
        &[Variable::new("who", "x=y")],
        &SendOptions::default(),
        &[],
    )
    .await
    .unwrap();

    // Multipart, with a text field and a file; a typed Content-Type is replaced.
    let request = post(&|r| {
        r.add_header("Content-Type", "text/plain");
        r.body_mode = Some(BodyMode::FormData);
        r.form = vec![
            FormField::text("title", "Hello"),
            FormField::file("doc", &path),
        ];
    });
    send(request).await.unwrap();

    // Binary sends the file's bytes.
    let request = post(&|r| {
        r.body_mode = Some(BodyMode::Binary);
        r.body = Some(path.clone());
    });
    send(request).await.unwrap();

    // Explicitly none ignores leftover text; an old request with only text is raw.
    let request = post(&|r| {
        r.body_mode = Some(BodyMode::None);
        r.body = Some("leftover".into());
    });
    send(request).await.unwrap();
    send(post(&|r| r.body = Some("legacy".into())))
        .await
        .unwrap();

    let seen = server.join().unwrap();
    assert!(seen[0].contains("content-type: application/x-www-form-urlencoded"));
    assert!(seen[0].ends_with("name=a+b%26c&who=x%3Dy"), "{}", seen[0]);

    assert!(seen[1].contains("content-type: multipart/form-data; boundary="));
    assert!(!seen[1].contains("text/plain\r\ncontent-type"));
    assert!(seen[1].contains("name=\"title\"\r\n\r\nHello"));
    assert!(seen[1].contains("name=\"doc\"; filename=\"note.txt\""));
    assert!(seen[1].contains("file contents"));

    assert!(seen[2].contains("content-type: application/octet-stream"));
    assert!(seen[2].ends_with("file contents"));

    assert!(!seen[3].contains("leftover"));
    assert!(seen[4].ends_with("legacy"));

    // A missing file is reported by name.
    let request = post(&|r| {
        r.body_mode = Some(BodyMode::Binary);
        r.body = Some("/no/such/file.bin".into());
    });
    let error = send(request).await.unwrap_err().to_string();
    assert!(error.contains("cannot read `/no/such/file.bin`"), "{error}");
}

#[tokio::test]
async fn cookies_are_kept_and_sent_back() {
    let set = "Set-Cookie: sid=abc; Path=/; HttpOnly\r\nSet-Cookie: lang=en; Path=/echo\r\n";
    let (url, server) = serve(vec![
        reply("200 OK", set, ""),
        reply("200 OK", "Set-Cookie: sid=; Path=/; Max-Age=0\r\n", ""),
        reply("200 OK", "", ""),
    ]);
    let options = SendOptions::default();

    let first = send_with(&Request::new("GET", url.clone()), &[], &options, &[])
        .await
        .unwrap();
    assert_eq!(first.cookies.len(), 2);
    assert_eq!(first.cookies[0].domain, "127.0.0.1");
    assert!(first.cookies[0].http_only);

    // The jar goes back, merged with a Cookie header the request sets itself.
    let mut request = Request::new("GET", url.clone());
    request.add_header("Cookie", "lang=fr; mine=1");
    let second = send_with(&request, &[], &options, &first.cookies)
        .await
        .unwrap();
    assert_eq!(second.cookies.len(), 1, "the server deleted sid");

    let third = send_with(&Request::new("GET", url), &[], &options, &second.cookies)
        .await
        .unwrap();
    assert_eq!(third.cookies, second.cookies);

    let seen = server.join().unwrap();
    assert!(!seen[0].to_lowercase().contains("cookie:"));
    assert!(
        seen[1].contains("cookie: lang=fr; mine=1; sid=abc"),
        "{}",
        seen[1]
    );
    assert!(seen[2].contains("cookie: lang=en\r\n"), "{}", seen[2]);
}

#[tokio::test]
async fn settings_choose_the_protocol_and_default_timeout() {
    // A file saved before settings existed loads with the defaults.
    let old: Workspace = serde_json::from_str(r#"{"collections": []}"#).unwrap();
    assert_eq!(old.settings, Settings::default());
    assert_eq!(old.settings.send_options(), SendOptions::default());
    let json = serde_json::to_string(&Settings {
        theme: AppTheme::Dark,
        http_mode: HttpMode::Http2,
        timeout_secs: 5,
        ..Settings::default()
    })
    .unwrap();
    assert!(json.starts_with(r#"{"theme":"dark","http_mode":"http2","timeout_secs":5,"#));
    // Settings saved before an option existed load with its default.
    let old: Settings = serde_json::from_str(r#"{"theme":"dark","timeout_secs":5}"#).unwrap();
    assert!(old.verify_ssl && old.follow_redirects && old.confirm_discard);
    assert_eq!((old.font_size, old.max_response_mb), (13, 0));

    // HTTP/1.1 only still talks to an HTTP/1.1 server.
    let (url, server) = serve_once("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
    let http1 = SendOptions {
        http_mode: HttpMode::Http1,
        timeout_ms: None,
        ..SendOptions::default()
    };
    let response = send_opts(Request::new("GET", url), &http1, &mut Vec::new())
        .await
        .unwrap();
    assert_eq!(response.http_version, "HTTP/1.1");
    server.join().unwrap();

    // Forced HTTP/2 does not fall back, and the error says why.
    let (url, server) = serve_once("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
    let http2 = SendOptions {
        http_mode: HttpMode::Http2,
        timeout_ms: Some(5_000),
        ..SendOptions::default()
    };
    let error = send_opts(Request::new("GET", url), &http2, &mut Vec::new())
        .await
        .unwrap_err()
        .to_string();
    assert!(error.contains("HTTP/2 is forced in settings"), "{error}");
    assert!(server.join().unwrap().starts_with("PRI * HTTP/2.0"));

    // A server that accepts the connection but never answers.
    let silent = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/", silent.local_addr().unwrap());
    let quick = Settings {
        timeout_secs: 1,
        ..Settings::default()
    }
    .send_options();
    assert_eq!(quick.timeout_ms, Some(1000));
    let started = Instant::now();
    let error = send_opts(Request::new("GET", url.clone()), &quick, &mut Vec::new()).await;
    assert!(matches!(error, Err(Error::Timeout)), "{error:?}");
    assert!(started.elapsed() < Duration::from_secs(3));

    // A request's own timeout wins over the setting.
    let mut request = Request::new("GET", url);
    request.timeout_ms = Some(100);
    let started = Instant::now();
    assert!(matches!(
        send_opts(request, &quick, &mut Vec::new()).await,
        Err(Error::Timeout)
    ));
    assert!(started.elapsed() < Duration::from_millis(900));
}

#[test]
fn workspace_round_trips_through_disk() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("nested/workspace.json");
    assert_eq!(Workspace::load(&path).unwrap(), Workspace::default());

    let workspace = Workspace {
        collections: Vec::new(),
        requests: vec![Item {
            name: "Ping".into(),
            request: Some(Request::new("GET", "{{base}}/ping")),
            items: Vec::new(),
        }],
        environments: vec![Environment {
            name: "Dev".into(),
            variables: vec![Variable::new("base", "http://localhost")],
        }],
        active_environment: Some("Dev".into()),
        settings: Settings {
            theme: AppTheme::Dark,
            http_mode: HttpMode::Http1,
            timeout_secs: 12,
            ..Settings::default()
        },
        cookies: Vec::new(),
    };
    workspace.save(&path).unwrap();
    assert_eq!(Workspace::load(&path).unwrap(), workspace);
    assert_eq!(workspace.active_variables().len(), 1);
}

#[tokio::test]
async fn app_settings_apply_to_requests_without_their_own() {
    // Redirects are not followed when the app says so...
    let redirect = "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n";
    let (url, server) = serve_once(redirect);
    let options = SendOptions {
        follow_redirects: false,
        no_cache: true,
        ..SendOptions::default()
    };
    let response = send_opts(Request::new("GET", &url), &options, &mut Vec::new())
        .await
        .unwrap();
    assert_eq!(response.status, 302);
    // ...and the no-cache header goes out with the request.
    assert!(
        server
            .join()
            .unwrap()
            .to_lowercase()
            .contains("cache-control: no-cache")
    );

    // A request's own header and settings win over the app's.
    let (url, server) = serve_once(redirect);
    let mut request = Request::new("GET", &url);
    request.add_header("Cache-Control", "max-age=60");
    request.settings = Some(RequestSettings {
        follow_redirects: false,
        ..RequestSettings::default()
    });
    let follow = SendOptions {
        no_cache: true,
        ..SendOptions::default()
    };
    let response = send_opts(request, &follow, &mut Vec::new()).await.unwrap();
    assert_eq!(response.status, 302);
    let raw = server.join().unwrap().to_lowercase();
    assert!(raw.contains("cache-control: max-age=60") && !raw.contains("no-cache"));

    let settings = Settings {
        max_response_mb: 2,
        verify_ssl: false,
        follow_redirects: false,
        send_no_cache: true,
        proxy: ProxyMode::Custom,
        proxy_url: " http://127.0.0.1:8080 ".into(),
        ..Settings::default()
    };
    let options = settings.send_options();
    assert_eq!(options.max_response_bytes, Some(2 * 1024 * 1024));
    assert!(!options.verify_ssl && !options.follow_redirects && options.no_cache);
    assert_eq!(options.proxy, Proxy::Custom("http://127.0.0.1:8080".into()));
    // A custom proxy with no address is no proxy setting at all.
    let unset = Settings {
        proxy: ProxyMode::Custom,
        ..Settings::default()
    };
    assert_eq!(unset.send_options().proxy, Proxy::System);
}

#[tokio::test]
async fn abandons_responses_over_the_size_limit() {
    const BODY: &str = "HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n01234567890123456789";
    let limit = |bytes| SendOptions {
        max_response_bytes: Some(bytes),
        ..SendOptions::default()
    };
    let (url, _server) = serve_once(BODY);
    let error = send_opts(Request::new("GET", url), &limit(10), &mut Vec::new())
        .await
        .unwrap_err();
    assert_eq!(
        error.to_string(),
        "the response is larger than the limit of 1 MB set in Settings"
    );

    let (url, _server) = serve_once(BODY);
    let response = send_opts(Request::new("GET", url), &limit(20), &mut Vec::new())
        .await
        .unwrap();
    assert_eq!(response.body.len(), 20);

    // A server that does not say how much is coming is cut off part way.
    let (url, _server) =
        serve_once("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n01234567890123456789");
    let error = send_opts(Request::new("GET", url), &limit(10), &mut Vec::new())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("larger than the limit"));
}

#[tokio::test]
async fn sends_through_the_chosen_proxy() {
    // The "proxy" is a server that sees the whole address it is asked for.
    let (proxy_url, proxy) = serve_once("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nproxied");
    let address = proxy_url.trim_end_matches("/echo").to_string();
    let options = SendOptions {
        proxy: Proxy::Custom(address),
        ..SendOptions::default()
    };
    let request = Request::new("GET", "http://far.away.test/items");
    let response = send_opts(request, &options, &mut Vec::new()).await.unwrap();
    assert_eq!(response.body, "proxied");
    assert!(
        proxy
            .join()
            .unwrap()
            .starts_with("GET http://far.away.test/items HTTP/1.1")
    );

    let bad = SendOptions {
        proxy: Proxy::Custom("not a proxy".into()),
        ..SendOptions::default()
    };
    let error = send_opts(
        Request::new("GET", "http://far.away.test"),
        &bad,
        &mut Vec::new(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().starts_with("invalid proxy address"));
}

#[tokio::test]
async fn refuses_to_send_a_credential_that_is_still_locked() {
    let locked = format!("{}abc:def", crate::LOCKED);
    let mut header = Request::new("GET", "http://127.0.0.1:1/");
    header.add_header("Authorization", format!("Bearer {locked}"));
    let mut auth = Request::new("GET", "http://127.0.0.1:1/");
    auth.auth = Some(Auth::new(AuthKind::Bearer, &[("token", &locked)]));
    // A locked variable is as locked once it has been filled in.
    let variable = Request::new("GET", "http://127.0.0.1:1/?key={{key}}");
    for request in [header, auth, variable] {
        let error = send_with(
            &request,
            &[Variable::new("key", &locked)],
            &SendOptions::default(),
            &[],
        )
        .await
        .unwrap_err();
        assert!(
            error
                .to_string()
                .starts_with("this request uses a credential that is still locked"),
            "{error}"
        );
    }
}

/// Serves an event stream: two events at once, then one more whenever
/// `more` is sent to, until it is dropped.
fn serve_events() -> (String, std::sync::mpsc::Sender<&'static str>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/events", listener.local_addr().unwrap());
    let (more, next) = std::sync::mpsc::channel::<&'static str>();
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buf = [0u8; 4096];
        let _ = stream.read(&mut buf).unwrap();
        stream
            .write_all(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\
                  Transfer-Encoding: chunked\r\n\r\n",
            )
            .unwrap();
        let mut chunk = |text: &str| {
            write!(stream, "{:x}\r\n{text}\r\n", text.len()).unwrap();
            stream.flush().unwrap();
        };
        chunk("data: one\n\n");
        chunk("data: two\n\n");
        while let Ok(text) = next.recv() {
            chunk(text);
        }
        chunk("");
    });
    (url, more)
}

#[tokio::test]
async fn reports_a_response_as_it_arrives() {
    let (url, more) = serve_events();
    let (events, mut seen) = tokio::sync::mpsc::unbounded_channel();
    let watch = Watch::new(
        move |event| {
            let _ = events.send(event);
        },
        Cancel::default(),
    );
    let request = Request::new("GET", &url);
    let send = tokio::spawn(async move {
        send_watched(&request, &[], &SendOptions::default(), &[], &watch).await
    });

    let SendEvent::Head {
        status, headers, ..
    } = seen.recv().await.unwrap()
    else {
        panic!("the head comes first");
    };
    assert_eq!(status, 200);
    assert!(headers.iter().any(|h| h.value == "text/event-stream"));
    // The first events are in hand while the response is still open.
    let mut text = String::new();
    while !text.ends_with("two\n\n") {
        let SendEvent::Body { text: part, .. } = seen.recv().await.unwrap() else {
            panic!("only the body follows the head");
        };
        text.push_str(&part);
    }
    assert_eq!(text, "data: one\n\ndata: two\n\n");
    assert!(!send.is_finished());

    more.send("data: three\n\n").unwrap();
    assert_eq!(
        seen.recv().await.unwrap(),
        SendEvent::Body {
            text: "data: three\n\n".into(),
            received: 35,
        }
    );
    drop(more);
    let sent = send.await.unwrap().unwrap();
    assert_eq!(
        sent.response.body,
        "data: one\n\ndata: two\n\ndata: three\n\n"
    );
}

#[tokio::test]
async fn a_send_stopped_part_way_keeps_what_had_arrived() {
    let (url, _more) = serve_events();
    let (events, mut seen) = tokio::sync::mpsc::unbounded_channel();
    let cancel = Cancel::default();
    let watch = Watch::new(
        move |event| {
            let _ = events.send(event);
        },
        cancel.clone(),
    );
    let request = Request::new("GET", &url);
    let send = tokio::spawn(async move {
        send_watched(&request, &[], &SendOptions::default(), &[], &watch).await
    });
    let mut received = 0;
    while received < 22 {
        if let SendEvent::Body { received: n, .. } = seen.recv().await.unwrap() {
            received = n;
        }
    }
    cancel.cancel();
    let sent = send.await.unwrap().unwrap();
    assert_eq!(sent.response.body, "data: one\n\ndata: two\n\n");
    assert_eq!(sent.exchanges.len(), 1);
}

#[tokio::test]
async fn a_send_stopped_before_any_answer_is_cancelled() {
    // A server that accepts the connection and never answers.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    let cancel = Cancel::default();
    let watch = Watch::new(|_| {}, cancel.clone());
    let request = Request::new("GET", &url);
    let send = tokio::spawn(async move {
        send_watched(&request, &[], &SendOptions::default(), &[], &watch).await
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    cancel.cancel();
    assert!(matches!(send.await.unwrap(), Err(Error::Cancelled)));
    drop(listener);
}
