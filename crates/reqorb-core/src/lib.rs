//! Request engine shared by the reqorb CLI and desktop/iPad app.

mod analyze;
mod auth;
mod cookies;
mod export;
mod grpc;
mod har;
mod import;
mod model;
mod openapi;
mod redact;
mod vars;
mod ws;

use std::time::{Duration, Instant};

pub use analyze::{HarCount, HarEntry, HarFinding, HarReport, HarSeverity, analyze_har};
pub use auth::{Auth, AuthField, AuthKind, AuthParam, auth_fields};
pub use cookies::{Cookie, cookie_header, store_set_cookie};
pub use export::{ExportFormat, export_collection, export_environment, export_native, to_curl};
pub use grpc::{
    GrpcCall, GrpcMethod, GrpcReply, GrpcSchema, grpc_call, grpc_load_proto, grpc_reflect,
};
pub use har::to_har;
pub use import::{ImportResult, import};
pub use model::{
    AppTheme, BodyMode, Collection, DisabledTls, Environment, Exchange, FormField, Header,
    HttpMode, Item, Request, RequestSettings, Response, SendOptions, Settings, Variable, Workspace,
};
pub use redact::{REDACTED, redact_collection, redact_environment, redact_exchanges, redact_text};
pub use vars::{Resolved, resolve};
pub use ws::{WsEvent, WsEventKind, WsHandle, ws_connect};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid HTTP method `{0}`")]
    InvalidMethod(String),
    #[error("invalid URL `{url}`: {reason}")]
    InvalidUrl { url: String, reason: String },
    #[error("request timed out")]
    Timeout,
    #[error("could not connect: {0}")]
    Connect(String),
    #[error("{0}")]
    Http(String),
    #[error("unresolved variable(s): {}", .0.join(", "))]
    UnresolvedVariables(Vec<String>),
    #[error("{0}")]
    Format(String),
    #[error("{0}")]
    Auth(String),
    #[error("{0}")]
    Io(String),
}

impl From<reqwest::Error> for Error {
    fn from(e: reqwest::Error) -> Self {
        // reqwest's Display omits the underlying cause, which is the useful part.
        let mut msg = e.to_string();
        let mut source = std::error::Error::source(&e);
        while let Some(s) = source {
            msg = format!("{msg}: {s}");
            source = s.source();
        }
        if e.is_timeout() {
            Error::Timeout
        } else if e.is_connect() {
            Error::Connect(msg)
        } else {
            Error::Http(msg)
        }
    }
}

/// A response plus the variables that were referenced but not defined.
#[derive(Debug, Clone)]
pub struct Sent {
    pub response: Response,
    pub unresolved: Vec<String>,
    /// The cookie jar after the exchange, including anything the server set.
    pub cookies: Vec<Cookie>,
    /// Every HTTP exchange the send made, oldest first: redirects and
    /// authorization round trips as well as the final one.
    pub exchanges: Vec<Exchange>,
}

/// Substitutes `variables` into the request and sends it. Undefined
/// variables are sent as written, unless they leave the URL unusable, in
/// which case naming them is more helpful than a URL parse error.
pub async fn send_with(
    request: &Request,
    variables: &[Variable],
    options: &SendOptions,
    cookies: &[Cookie],
) -> Result<Sent, Error> {
    let resolved = resolve(request, variables);
    let unusable = match reqwest::Url::parse(&resolved.request.url) {
        Ok(url) => url
            .host_str()
            .is_some_and(|h| h.contains("{{") || h.contains("%7B%7B")),
        Err(_) => true,
    };
    if unusable && !resolved.unresolved.is_empty() {
        return Err(Error::UnresolvedVariables(resolved.unresolved));
    }
    let mut jar = cookies.to_vec();
    let (response, exchanges) = send_logged(resolved.request, options, &mut jar).await?;
    Ok(Sent {
        response,
        unresolved: resolved.unresolved,
        cookies: jar,
        exchanges,
    })
}

/// Downloads `url` and imports it, typically a served `swagger.json`.
pub async fn import_url(url: &str) -> Result<ImportResult, Error> {
    let origin = reqwest::Url::parse(url).map_err(|e| Error::InvalidUrl {
        url: url.to_string(),
        reason: e.to_string(),
    })?;
    let mut request = Request::new("GET", url);
    request.add_header("Accept", "application/json, application/yaml, */*");
    request.timeout_ms = Some(30_000);
    let response = send(request).await?;
    if response.status >= 400 {
        return Err(Error::Http(format!(
            "{url} answered {} {}",
            response.status, response.status_text
        )));
    }
    // Name the import after the file, or the host when the path has none.
    let hint = origin
        .path_segments()
        .and_then(|mut segments| segments.next_back())
        .map(|file| file.rsplit_once('.').map_or(file, |(stem, _)| stem))
        .filter(|stem| !stem.is_empty())
        .or(origin.host_str())
        .unwrap_or("Imported");
    import::import_from(&response.body, hint, Some(&origin))
}

/// Sends the request with default options.
pub async fn send(request: Request) -> Result<Response, Error> {
    send_opts(request, &SendOptions::default(), &mut Vec::new()).await
}

/// Sends the request, applying its authorization first. Types that need a
/// challenge from the server or a token take more than one round trip, all
/// of which count towards the reported time.
///
/// Matching cookies from `cookies` are sent, and the jar is updated with
/// whatever the server sets, including on redirects along the way.
pub async fn send_opts(
    request: Request,
    options: &SendOptions,
    cookies: &mut Vec<Cookie>,
) -> Result<Response, Error> {
    Ok(send_logged(request, options, cookies).await?.0)
}

/// Like [`send_opts`], also returning each exchange that took place.
async fn send_logged(
    mut request: Request,
    options: &SendOptions,
    cookies: &mut Vec<Cookie>,
) -> Result<(Response, Vec<Exchange>), Error> {
    let auth = request.auth.take().unwrap_or_default();
    let settings = request.settings.take().unwrap_or_default();
    request.timeout_ms = request.timeout_ms.or(options.timeout_ms);
    request.materialize();
    let http_mode = settings.http_mode.unwrap_or(options.http_mode);
    let use_jar = !settings.disable_cookie_jar;

    let jar = std::sync::Arc::new(cookies::Jar::new(cookies));
    // The client leaves a request's own Cookie header alone, so jar cookies
    // the request does not already name are added to it here.
    if use_jar
        && let Some(own) = request
            .headers
            .iter_mut()
            .find(|h| h.name.eq_ignore_ascii_case("cookie"))
        && let Ok(url) = reqwest::Url::parse(&request.url)
        && let Some(stored) = cookie_header(&jar.snapshot(), &url, cookies::now())
    {
        let named: Vec<&str> = own
            .value
            .split(';')
            .filter_map(|pair| pair.split('=').next())
            .map(str::trim)
            .collect();
        let extra: Vec<&str> = stored
            .split("; ")
            .filter(|pair| !named.contains(&pair.split('=').next().unwrap_or("")))
            .collect();
        if !extra.is_empty() {
            own.value = format!(
                "{}; {}",
                own.value.trim_end_matches([';', ' ']),
                extra.join("; ")
            );
        }
    }

    let mut builder = reqwest::Client::builder()
        .user_agent(concat!("reqorb/", env!("CARGO_PKG_VERSION")))
        // Redirects are followed by `execute`, which knows the request's rules.
        .redirect(reqwest::redirect::Policy::none())
        .danger_accept_invalid_certs(!settings.verify_ssl);
    if use_jar {
        builder = builder.cookie_provider(jar.clone());
    }
    if !settings.strict_http_parser {
        builder = builder
            .http1_ignore_invalid_headers_in_responses(true)
            .http1_allow_obsolete_multiline_headers_in_responses(true)
            .http1_allow_spaces_after_header_name_in_responses(true);
    }
    builder = match settings.disabled_tls {
        DisabledTls::None => builder,
        DisabledTls::Tls12 => builder.min_tls_version(reqwest::tls::Version::TLS_1_3),
        DisabledTls::Tls13 => builder.max_tls_version(reqwest::tls::Version::TLS_1_2),
    };
    builder = match http_mode {
        HttpMode::Auto => builder,
        HttpMode::Http1 => builder.http1_only(),
        // Speaks HTTP/2 from the first byte, with no fallback to HTTP/1.1.
        HttpMode::Http2 => builder.http2_prior_knowledge(),
    };
    if auth.kind == AuthKind::Ntlm {
        // NTLM authenticates a connection, so every step must reuse the same one.
        builder = builder.pool_max_idle_per_host(1);
    }
    let transport = Transport {
        client: builder.build()?,
        settings,
        log: Default::default(),
    };

    let started = Instant::now();
    let result = if auth::sign(&mut request, &auth, &auth::Clock::now())? {
        execute(&transport, &request).await
    } else {
        auth::negotiate(&transport, request, &auth).await
    };
    if use_jar {
        *cookies = jar.snapshot();
    }
    match result {
        Ok(mut response) => {
            response.elapsed_ms = started.elapsed().as_millis() as u64;
            let exchanges = std::mem::take(&mut *transport.log.lock().unwrap());
            Ok((response, exchanges))
        }
        // A server that only speaks HTTP/1.1 fails in ways that do not name the cause.
        Err(Error::Http(message)) if http_mode == HttpMode::Http2 => Err(Error::Http(format!(
            "{message} (HTTP/2 is forced in settings; the server may only support HTTP/1.1)"
        ))),
        Err(e) => Err(e),
    }
}

/// The HTTP client for one send, with the request's redirect rules.
pub(crate) struct Transport {
    client: reqwest::Client,
    settings: RequestSettings,
    /// Each exchange made through this transport, for the session log.
    log: std::sync::Mutex<Vec<Exchange>>,
}

/// Performs an exchange, following redirects as the request's settings say.
pub(crate) async fn execute(transport: &Transport, request: &Request) -> Result<Response, Error> {
    let rules = &transport.settings;
    let mut current = request.clone();
    let mut hops = 0;
    loop {
        let started_ms = cookies::now_ms();
        let response = execute_once(&transport.client, &current).await?;
        transport.log.lock().unwrap().push(Exchange {
            started_ms,
            request: current.clone(),
            response: response.clone(),
        });
        let location = response
            .headers
            .iter()
            .find(|h| h.name.eq_ignore_ascii_case("location"))
            .map(|h| h.value.clone());
        let (true, true, Some(location)) = (
            rules.follow_redirects,
            matches!(response.status, 301 | 302 | 303 | 307 | 308),
            location,
        ) else {
            return Ok(response);
        };
        if hops >= rules.max_redirects {
            return Err(Error::Http(format!(
                "stopped after {} redirect(s), the maximum for this request",
                rules.max_redirects
            )));
        }
        hops += 1;

        let invalid = |e: url::ParseError| Error::InvalidUrl {
            url: location.clone(),
            reason: e.to_string(),
        };
        let from = reqwest::Url::parse(&current.url).map_err(invalid)?;
        let to = from.join(&location).map_err(invalid)?;

        // 307 and 308 always repeat the request. Otherwise browsers turn a
        // POST into a GET, and a 303 does so for every method but HEAD.
        let method = current.method.to_uppercase();
        let becomes_get = !rules.follow_original_method
            && match response.status {
                303 => method != "GET" && method != "HEAD",
                301 | 302 => method == "POST",
                _ => false,
            };
        if becomes_get {
            current.method = "GET".into();
            current.body = None;
            current.headers.retain(|h| {
                !["content-type", "content-length"].contains(&h.name.to_ascii_lowercase().as_str())
            });
        }

        let same_origin = from.scheme() == to.scheme()
            && from.host_str() == to.host_str()
            && from.port_or_known_default() == to.port_or_known_default();
        current.headers.retain(|h| {
            let name = h.name.to_ascii_lowercase();
            // Credentials are not handed to a different site unless asked.
            let credential =
                ["authorization", "cookie", "proxy-authorization"].contains(&name.as_str());
            name != "referer" && (same_origin || rules.follow_auth_header || !credential)
        });
        // Like browsers, never reveal an HTTPS address to a plain HTTP site.
        if !rules.remove_referer && !(from.scheme() == "https" && to.scheme() == "http") {
            let mut referer = from.clone();
            referer.set_fragment(None);
            let _ = referer.set_username("");
            let _ = referer.set_password(None);
            current.add_header("Referer", referer.as_str());
        }
        current.url = to.to_string();
    }
}

/// Performs one HTTP exchange exactly as the request is written.
async fn execute_once(client: &reqwest::Client, request: &Request) -> Result<Response, Error> {
    let method = reqwest::Method::from_bytes(request.method.to_uppercase().as_bytes())
        .map_err(|_| Error::InvalidMethod(request.method.clone()))?;
    let url = reqwest::Url::parse(&request.url).map_err(|e| Error::InvalidUrl {
        url: request.url.clone(),
        reason: e.to_string(),
    })?;

    let mode = request.effective_body_mode();
    let unreadable = |path: &str, e: std::io::Error| {
        Error::Io(format!("cannot read `{path}`: {e}; choose the file again"))
    };
    let mut builder = client.request(method, url);
    for h in &request.headers {
        // A multipart body brings its own Content-Type, with the boundary in it.
        if mode == BodyMode::FormData && h.name.eq_ignore_ascii_case("content-type") {
            continue;
        }
        builder = builder.header(&h.name, &h.value);
    }
    match (mode, &request.body) {
        (BodyMode::Raw | BodyMode::UrlEncoded, Some(body)) => builder = builder.body(body.clone()),
        (BodyMode::Binary, Some(path)) if !path.trim().is_empty() => {
            let path = path.trim();
            let bytes = std::fs::read(path).map_err(|e| unreadable(path, e))?;
            if !request.has_header("content-type") {
                builder = builder.header("Content-Type", "application/octet-stream");
            }
            builder = builder.body(bytes);
        }
        (BodyMode::FormData, _) => {
            let mut form = reqwest::multipart::Form::new();
            for field in &request.form {
                if field.file {
                    let path = field.value.trim();
                    let bytes = std::fs::read(path).map_err(|e| unreadable(path, e))?;
                    let name = std::path::Path::new(path)
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    let part = reqwest::multipart::Part::bytes(bytes).file_name(name);
                    form = form.part(field.key.clone(), part);
                } else {
                    form = form.text(field.key.clone(), field.value.clone());
                }
            }
            builder = builder.multipart(form);
        }
        _ => {}
    }
    if let Some(ms) = request.timeout_ms {
        builder = builder.timeout(Duration::from_millis(ms));
    }

    let started = Instant::now();
    let resp = builder.send().await?;

    let status = resp.status();
    let http_version = format!("{:?}", resp.version());
    let headers = resp
        .headers()
        .iter()
        .map(|(name, value)| Header {
            name: name.to_string(),
            value: String::from_utf8_lossy(value.as_bytes()).into_owned(),
        })
        .collect();
    let bytes = resp.bytes().await?;
    let elapsed_ms = started.elapsed().as_millis() as u64;

    Ok(Response {
        status: status.as_u16(),
        status_text: status.canonical_reason().unwrap_or("").to_string(),
        http_version,
        headers,
        size_bytes: bytes.len() as u64,
        body: String::from_utf8_lossy(&bytes).into_owned(),
        elapsed_ms,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
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
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"theme":"dark","http_mode":"http2","timeout_secs":5}"#
        );

        // HTTP/1.1 only still talks to an HTTP/1.1 server.
        let (url, server) = serve_once("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
        let http1 = SendOptions {
            http_mode: HttpMode::Http1,
            timeout_ms: None,
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
            },
            cookies: Vec::new(),
        };
        workspace.save(&path).unwrap();
        assert_eq!(Workspace::load(&path).unwrap(), workspace);
        assert_eq!(workspace.active_variables().len(), 1);
    }
}
