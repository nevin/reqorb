//! One HTTP exchange, and the redirects that may follow it.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::cookies::Jar;
use crate::time::now_ms;
use crate::{BodyMode, Error, Exchange, Header, Request, RequestSettings, Response};

pub(super) const USER_AGENT: &str = concat!("reqorb/", env!("CARGO_PKG_VERSION"));

/// The encodings the client offers to decode, as it sends them when the
/// request does not name its own.
const ACCEPT_ENCODING: &str = "zstd,gzip,deflate,br";

/// The HTTP client for one send, with the request's redirect rules.
pub(crate) struct Transport {
    client: reqwest::Client,
    settings: RequestSettings,
    /// Cookies to send and update, unless the request turned the jar off.
    jar: Option<Arc<Jar>>,
    /// Each exchange made through this transport, for the session log.
    log: Mutex<Vec<Exchange>>,
}

impl Transport {
    pub(super) fn new(
        client: reqwest::Client,
        settings: RequestSettings,
        jar: Option<Arc<Jar>>,
    ) -> Self {
        Self {
            client,
            settings,
            jar,
            log: Mutex::default(),
        }
    }

    /// Hands over the exchanges made so far, oldest first.
    pub(super) fn take_log(&self) -> Vec<Exchange> {
        std::mem::take(&mut *self.log.lock().unwrap())
    }
}

/// Performs an exchange, following redirects as the request's settings say.
pub(crate) async fn execute(transport: &Transport, request: &Request) -> Result<Response, Error> {
    let rules = &transport.settings;
    let mut current = request.clone();
    let mut hops = 0;
    loop {
        let started_ms = now_ms();
        let (response, sent) = execute_once(transport, &current).await?;
        transport.log.lock().unwrap().push(Exchange {
            started_ms,
            request: Request {
                headers: sent,
                ..current.clone()
            },
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

/// Whether a body with this Content-Type is text, whatever its bytes say.
pub(super) fn is_text(content_type: &str) -> bool {
    let mime = content_type.to_ascii_lowercase();
    let mime = mime.split(';').next().unwrap_or("").trim();
    mime.starts_with("text/")
        || ["json", "xml", "javascript", "x-www-form-urlencoded", "yaml"]
            .iter()
            .any(|kind| mime.contains(kind))
}

/// Performs one HTTP exchange exactly as the request is written. Returns the
/// response and the headers that were sent, the client's own included.
async fn execute_once(
    transport: &Transport,
    request: &Request,
) -> Result<(Response, Vec<Header>), Error> {
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
    let mut builder = transport.client.request(method, url.clone());
    for h in &request.headers {
        // A multipart body brings its own Content-Type, with the boundary in
        // it, and the Cookie header is worked out with the jar below.
        if (mode == BodyMode::FormData && h.name.eq_ignore_ascii_case("content-type"))
            || h.name.eq_ignore_ascii_case("cookie")
        {
            continue;
        }
        builder = builder.header(&h.name, &h.value);
    }
    if !request.has_header("user-agent") {
        builder = builder.header("User-Agent", USER_AGENT);
    }
    if !request.has_header("accept") {
        builder = builder.header("Accept", "*/*");
    }
    let own_cookies = request
        .headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case("cookie"))
        .map(|h| h.value.as_str());
    let cookies = match &transport.jar {
        Some(jar) => jar.header_for(&url, own_cookies),
        None => own_cookies.map(str::to_string),
    };
    if let Some(cookies) = cookies {
        builder = builder.header("Cookie", cookies);
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

    let built = builder.build()?;
    let mut sent: Vec<Header> = built
        .headers()
        .iter()
        .map(|(name, value)| Header {
            name: name.to_string(),
            value: String::from_utf8_lossy(value.as_bytes()).into_owned(),
        })
        .collect();
    // The rest are added on the way out, so they are noted here to match.
    let has = |sent: &[Header], name: &str| sent.iter().any(|h| h.name == name);
    if !has(&sent, "accept-encoding") && !has(&sent, "range") {
        sent.push(Header {
            name: "accept-encoding".into(),
            value: ACCEPT_ENCODING.into(),
        });
    }
    if let Some(body) = built.body().and_then(|b| b.as_bytes())
        && !has(&sent, "content-length")
    {
        sent.push(Header {
            name: "content-length".into(),
            value: body.len().to_string(),
        });
    }

    let started = Instant::now();
    let resp = transport.client.execute(built).await?;

    let status = resp.status();
    let version = resp.version();
    let headers: Vec<Header> = resp
        .headers()
        .iter()
        .map(|(name, value)| Header {
            name: name.to_string(),
            value: String::from_utf8_lossy(value.as_bytes()).into_owned(),
        })
        .collect();
    if let Some(jar) = &transport.jar {
        let set = headers
            .iter()
            .filter(|h| h.name.eq_ignore_ascii_case("set-cookie"))
            .map(|h| h.value.as_str());
        jar.store(set, &url);
    }
    // HTTP/1 names the host in a header; HTTP/2 carries it another way.
    if version < reqwest::Version::HTTP_2
        && let Some(host) = url.host_str()
    {
        let value = match url.port() {
            Some(port) => format!("{host}:{port}"),
            None => host.to_string(),
        };
        sent.insert(
            0,
            Header {
                name: "host".into(),
                value,
            },
        );
    }

    let bytes = resp.bytes().await?;
    let elapsed_ms = started.elapsed().as_millis() as u64;
    let content_type = headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case("content-type"))
        .map_or("", |h| h.value.as_str());
    // Bytes that are not UTF-8 are kept as they are, unless the server says
    // they are text in some other encoding.
    let (body, raw) = match std::str::from_utf8(&bytes) {
        Ok(text) => (text.to_string(), None),
        Err(_) if is_text(content_type) => (String::from_utf8_lossy(&bytes).into_owned(), None),
        Err(_) => (String::new(), Some(bytes.to_vec())),
    };

    Ok((
        Response {
            status: status.as_u16(),
            status_text: status.canonical_reason().unwrap_or("").to_string(),
            http_version: format!("{version:?}"),
            headers,
            size_bytes: bytes.len() as u64,
            body,
            bytes: raw,
            elapsed_ms,
        },
        sent,
    ))
}
