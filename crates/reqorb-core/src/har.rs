//! HTTP Archive (HAR 1.2): export of the exchanges a session made, and
//! import of the requests an archive recorded.

use serde_json::{Value, json};

use crate::import::{ImportResult, str_field};
use crate::{BodyMode, Collection, Error, Exchange, FormField, Header, Item, REDACTED, Request};

/// Renders `exchanges`, oldest first, as a HAR 1.2 document that browser
/// developer tools and HAR viewers can open.
pub fn to_har(exchanges: &[Exchange]) -> String {
    let entries: Vec<Value> = exchanges.iter().map(entry).collect();
    let har = json!({
        "log": {
            "version": "1.2",
            "creator": { "name": "reqorb", "version": env!("CARGO_PKG_VERSION") },
            "entries": entries,
        }
    });
    serde_json::to_string_pretty(&har).expect("HAR serialises")
}

/// Whether `value` is a HAR document.
pub(crate) fn is_har(value: &Value) -> bool {
    value["log"]["entries"].is_array()
}

/// Headers a recording holds that the client works out again for itself.
const COMPUTED_HEADERS: &[&str] = &["host", "content-length", "connection", "transfer-encoding"];

/// Turns the requests recorded in a HAR document into a collection named
/// `name`, one request per entry and in the order they were made. The
/// recorded responses are not kept.
pub(crate) fn from_har(value: &Value, name: &str) -> ImportResult {
    from_har_entries(value, name, None)
}

/// Imports the entries of the HAR archive in `text` whose positions are in
/// `entries`, as a collection named `name`.
pub fn import_har(text: &str, name: &str, entries: &[u32]) -> Result<ImportResult, Error> {
    let text = text.trim_start_matches('\u{feff}').trim();
    let value: Value =
        serde_json::from_str(text).map_err(|e| Error::Format(format!("invalid JSON: {e}")))?;
    if !is_har(&value) {
        return Err(Error::Format(
            "not a HAR archive: `log.entries` is missing".into(),
        ));
    }
    Ok(from_har_entries(&value, name, Some(entries)))
}

fn from_har_entries(value: &Value, name: &str, only: Option<&[u32]>) -> ImportResult {
    let mut warnings = Vec::new();
    let mut items: Vec<Item> = Vec::new();
    let mut files = 0;
    let mut redacted = false;
    let entries = value["log"]["entries"].as_array();
    for (index, entry) in entries.into_iter().flatten().enumerate() {
        if only.is_some_and(|only| !only.contains(&(index as u32))) {
            continue;
        }
        let recorded = &entry["request"];
        let Some(url) = str_field(recorded, "url").filter(|u| !u.is_empty()) else {
            continue;
        };
        let socket = url.starts_with("ws://") || url.starts_with("wss://");
        let method = match str_field(recorded, "method") {
            _ if socket => "WS".to_string(),
            Some(method) if !method.is_empty() => method.to_uppercase(),
            _ => "GET".to_string(),
        };
        let mut request = Request::new(method, url);
        let post = &recorded["postData"];
        let mime = str_field(post, "mimeType").unwrap_or("").to_lowercase();
        let multipart = mime.starts_with("multipart/");

        for header in recorded["headers"].as_array().into_iter().flatten() {
            let (Some(name), Some(value)) = (str_field(header, "name"), str_field(header, "value"))
            else {
                continue;
            };
            let lower = name.to_lowercase();
            // HTTP/2 pseudo-headers such as `:authority` repeat the URL, and
            // a multipart boundary only fits the body it was recorded with.
            if name.starts_with(':')
                || COMPUTED_HEADERS.contains(&lower.as_str())
                || (multipart && lower == "content-type")
            {
                continue;
            }
            request.add_header(name, value);
        }

        let fields: Vec<FormField> = post["params"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|param| {
                let key = str_field(param, "name")?;
                Some(match str_field(param, "fileName") {
                    Some(file) => FormField::file(key, file),
                    None => FormField::text(key, str_field(param, "value").unwrap_or("")),
                })
            })
            .collect();
        let text = str_field(post, "text").unwrap_or("");
        // reqorb's own export notes the file a binary body was read from.
        let file = str_field(post, "comment").and_then(|c| c.strip_prefix("file: "));
        if multipart && !fields.is_empty() {
            files += fields.iter().filter(|f| f.file).count();
            request.body_mode = Some(BodyMode::FormData);
            request.form = fields;
        } else if !text.is_empty() {
            request.body = Some(text.to_string());
        } else if mime.contains("x-www-form-urlencoded") && !fields.is_empty() {
            request.body_mode = Some(BodyMode::UrlEncoded);
            request.form = fields;
        } else if let Some(path) = file.filter(|p| !p.is_empty()) {
            request.body_mode = Some(BodyMode::Binary);
            request.body = Some(path.to_string());
        }

        redacted |= entry["request"].to_string().contains(REDACTED);
        // Requests are found by name, so repeats of one call are numbered.
        let base = format!("{} {}", request.method, short_path(url));
        let mut name = base.clone();
        let mut n = 1;
        while items.iter().any(|item| item.name == name) {
            n += 1;
            name = format!("{base} ({n})");
        }
        items.push(Item {
            name,
            request: Some(request),
            items: Vec::new(),
        });
    }

    if files > 0 {
        warnings.push(format!(
            "{files} uploaded file(s) are recorded by name only; choose the files again before sending"
        ));
    }
    if redacted {
        warnings.push(format!(
            "this archive was redacted; fill in the values marked {REDACTED} before sending"
        ));
    }
    ImportResult {
        source: "har".into(),
        collections: vec![Collection {
            name: name.to_string(),
            variables: Vec::new(),
            items,
        }],
        environments: Vec::new(),
        warnings,
    }
}

/// The path of `url` without its host or query, to name a request by.
fn short_path(url: &str) -> String {
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let rest = rest.split(['?', '#']).next().unwrap_or(rest);
    match rest.find('/') {
        Some(at) if rest.len() > at + 1 => rest[at..].to_string(),
        _ => "/".to_string(),
    }
}

fn entry(exchange: &Exchange) -> Value {
    let request = &exchange.request;
    let response = &exchange.response;
    let url = reqwest::Url::parse(&request.url).ok();
    let query: Vec<Value> = url
        .iter()
        .flat_map(|u| u.query_pairs())
        .map(|(name, value)| json!({ "name": name, "value": value }))
        .collect();

    let mut har_request = json!({
        "method": request.method.to_uppercase(),
        "url": request.url,
        "httpVersion": response.http_version,
        "cookies": request_cookies(&request.headers),
        "headers": headers(&request.headers),
        "queryString": query,
        "headersSize": -1,
        "bodySize": -1,
    });
    let content_type = header(&request.headers, "content-type");
    match request.effective_body_mode() {
        BodyMode::Raw | BodyMode::UrlEncoded => {
            if let Some(body) = &request.body {
                har_request["bodySize"] = json!(body.len());
                har_request["postData"] = json!({
                    "mimeType": content_type.unwrap_or("text/plain"),
                    "text": body,
                });
            }
        }
        BodyMode::FormData => {
            let params: Vec<Value> = request
                .form
                .iter()
                .map(|f| {
                    if f.file {
                        json!({ "name": f.key, "fileName": f.value })
                    } else {
                        json!({ "name": f.key, "value": f.value })
                    }
                })
                .collect();
            har_request["postData"] = json!({
                "mimeType": "multipart/form-data",
                "params": params,
                "text": "",
            });
        }
        BodyMode::Binary => {
            har_request["postData"] = json!({
                "mimeType": content_type.unwrap_or("application/octet-stream"),
                "text": "",
                "comment": format!("file: {}", request.body.as_deref().unwrap_or("")),
            });
        }
        BodyMode::None => {}
    }

    json!({
        "startedDateTime": iso_time(exchange.started_ms),
        "time": response.elapsed_ms,
        "request": har_request,
        "response": {
            "status": response.status,
            "statusText": response.status_text,
            "httpVersion": response.http_version,
            "cookies": response_cookies(&response.headers),
            "headers": headers(&response.headers),
            "content": {
                "size": response.size_bytes,
                "mimeType": header(&response.headers, "content-type").unwrap_or(""),
                "text": response.body,
            },
            "redirectURL": header(&response.headers, "location").unwrap_or(""),
            "headersSize": -1,
            "bodySize": -1,
        },
        "cache": {},
        // Only the total is measured, so it is all reported as waiting.
        "timings": { "send": 0, "wait": response.elapsed_ms, "receive": 0 },
    })
}

fn header<'a>(headers: &'a [Header], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str())
}

fn headers(headers: &[Header]) -> Vec<Value> {
    headers
        .iter()
        .map(|h| json!({ "name": h.name, "value": h.value }))
        .collect()
}

fn request_cookies(headers: &[Header]) -> Vec<Value> {
    headers
        .iter()
        .filter(|h| h.name.eq_ignore_ascii_case("cookie"))
        .flat_map(|h| h.value.split(';'))
        .filter_map(|pair| pair.trim().split_once('='))
        .map(|(name, value)| json!({ "name": name, "value": value }))
        .collect()
}

fn response_cookies(headers: &[Header]) -> Vec<Value> {
    headers
        .iter()
        .filter(|h| h.name.eq_ignore_ascii_case("set-cookie"))
        .filter_map(|h| h.value.split(';').next()?.trim().split_once('='))
        .map(|(name, value)| json!({ "name": name, "value": value }))
        .collect()
}

/// Milliseconds since the Unix epoch as an ISO 8601 UTC timestamp.
fn iso_time(unix_ms: u64) -> String {
    let secs = unix_ms / 1000;
    let (days, rest) = (secs / 86_400, secs % 86_400);
    // Days since the epoch to a civil date (Howard Hinnant's algorithm).
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60,
        unix_ms % 1000
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Request, Response};

    #[test]
    fn formats_timestamps() {
        assert_eq!(iso_time(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso_time(1_709_210_096_789), "2024-02-29T12:34:56.789Z");
        assert_eq!(iso_time(1_798_761_599_000), "2026-12-31T23:59:59.000Z");
    }

    #[test]
    fn writes_a_har_entry_per_exchange() {
        let mut request = Request::new("post", "https://api.test/items?page=2&q=a%20b");
        request.add_header("Content-Type", "application/json");
        request.add_header("Cookie", "sid=1; theme=dark");
        request.body = Some(r#"{"n":1}"#.into());
        let response = Response {
            status: 201,
            status_text: "Created".into(),
            http_version: "HTTP/1.1".into(),
            headers: vec![
                Header {
                    name: "content-type".into(),
                    value: "application/json".into(),
                },
                Header {
                    name: "set-cookie".into(),
                    value: "tok=abc; Path=/; HttpOnly".into(),
                },
            ],
            body: r#"{"ok":true}"#.into(),
            size_bytes: 11,
            elapsed_ms: 42,
        };
        let har = to_har(&[Exchange {
            started_ms: 1_709_210_096_789,
            request,
            response,
        }]);
        let doc: Value = serde_json::from_str(&har).unwrap();
        assert_eq!(doc["log"]["version"], "1.2");
        let entry = &doc["log"]["entries"][0];
        assert_eq!(entry["startedDateTime"], "2024-02-29T12:34:56.789Z");
        assert_eq!(entry["time"], 42);
        assert_eq!(entry["request"]["method"], "POST");
        assert_eq!(entry["request"]["queryString"][1]["value"], "a b");
        assert_eq!(entry["request"]["cookies"][1]["name"], "theme");
        assert_eq!(entry["request"]["postData"]["mimeType"], "application/json");
        assert_eq!(entry["request"]["postData"]["text"], r#"{"n":1}"#);
        assert_eq!(entry["response"]["status"], 201);
        assert_eq!(entry["response"]["cookies"][0]["value"], "abc");
        assert_eq!(entry["response"]["content"]["text"], r#"{"ok":true}"#);
    }
    fn imported(har: &Value) -> Vec<(String, Request)> {
        assert!(is_har(har));
        from_har(har, "session").collections[0]
            .items
            .iter()
            .map(|item| (item.name.clone(), item.request.clone().unwrap()))
            .collect()
    }

    #[test]
    fn imports_recorded_requests() {
        let har = json!({ "log": { "entries": [
            { "request": {
                "method": "get",
                "url": "https://api.test/items?page=2",
                "headers": [
                    { "name": ":authority", "value": "api.test" },
                    { "name": "Host", "value": "api.test" },
                    { "name": "Accept", "value": "application/json" },
                ],
            } },
            { "request": {
                "method": "POST",
                "url": "https://api.test/items?page=2",
                "headers": [
                    { "name": "Content-Type", "value": "application/json" },
                    { "name": "Content-Length", "value": "7" },
                ],
                "postData": { "mimeType": "application/json", "text": "{\"n\":1}" },
            } },
            { "request": {
                "method": "POST",
                "url": "https://api.test/upload",
                "headers": [
                    { "name": "Content-Type", "value": "multipart/form-data; boundary=xyz" },
                ],
                "postData": {
                    "mimeType": "multipart/form-data; boundary=xyz",
                    "params": [
                        { "name": "title", "value": "Hi" },
                        { "name": "doc", "fileName": "a.pdf" },
                    ],
                    "text": "--xyz...",
                },
            } },
            { "request": {
                "method": "POST",
                "url": "https://api.test/login",
                "headers": [],
                "postData": {
                    "mimeType": "application/x-www-form-urlencoded",
                    "params": [{ "name": "user", "value": "a b" }],
                },
            } },
            { "request": { "method": "GET", "url": "https://api.test/items?page=3", "headers": [] } },
            { "request": { "method": "GET", "url": "wss://api.test", "headers": [] } },
        ] } });
        let requests = imported(&har);
        let names: Vec<&str> = requests.iter().map(|(name, _)| name.as_str()).collect();
        assert_eq!(
            names,
            [
                "GET /items",
                "POST /items",
                "POST /upload",
                "POST /login",
                "GET /items (2)",
                "WS /"
            ]
        );

        let get = &requests[0].1;
        assert_eq!(get.url, "https://api.test/items?page=2");
        assert_eq!(get.headers.len(), 1);
        assert_eq!(get.headers[0].name, "Accept");

        let post = &requests[1].1;
        assert_eq!(post.body.as_deref(), Some(r#"{"n":1}"#));
        assert!(post.has_header("content-type") && !post.has_header("content-length"));

        let upload = &requests[2].1;
        assert_eq!(upload.body_mode, Some(BodyMode::FormData));
        assert_eq!(
            upload.form,
            [
                FormField::text("title", "Hi"),
                FormField::file("doc", "a.pdf")
            ]
        );
        assert!(upload.headers.is_empty() && upload.body.is_none());

        let login = &requests[3].1;
        assert_eq!(login.body_mode, Some(BodyMode::UrlEncoded));
        assert_eq!(login.form, [FormField::text("user", "a b")]);

        // A chosen few can be imported, by their position in the archive.
        let few = import_har(&har.to_string(), "few", &[4, 1]).unwrap();
        let names: Vec<&str> = few.collections[0]
            .items
            .iter()
            .map(|item| item.name.as_str())
            .collect();
        assert_eq!(names, ["POST /items", "GET /items"]);
        assert!(few.warnings.is_empty());
        assert!(import_har("{}", "x", &[]).is_err());

        let warnings = from_har(&har, "session").warnings;
        assert_eq!(warnings.len(), 1);
        assert!(warnings[0].contains("1 uploaded file"));
    }

    #[test]
    fn imports_what_it_exported() {
        let mut json = Request::new("PUT", "https://api.test/a?token=abc");
        json.add_header("Content-Type", "application/json");
        json.body = Some("{}".into());
        let mut form = Request::new("POST", "https://api.test/form");
        form.body_mode = Some(BodyMode::FormData);
        form.form = vec![
            FormField::text("a", "1"),
            FormField::file("f", "/tmp/f.txt"),
        ];
        let mut binary = Request::new("POST", "https://api.test/bin");
        binary.body_mode = Some(BodyMode::Binary);
        binary.body = Some("/tmp/photo.png".into());
        let sent = [json, form, binary];

        let response = Response {
            status: 200,
            status_text: "OK".into(),
            http_version: "HTTP/1.1".into(),
            headers: Vec::new(),
            body: String::new(),
            size_bytes: 0,
            elapsed_ms: 1,
        };
        let exchanges: Vec<Exchange> = sent
            .iter()
            .map(|request| Exchange {
                started_ms: 0,
                request: request.clone(),
                response: response.clone(),
            })
            .collect();

        let har: Value = serde_json::from_str(&to_har(&exchanges)).unwrap();
        let back: Vec<Request> = imported(&har).into_iter().map(|(_, r)| r).collect();
        assert_eq!(back[0].body, sent[0].body);
        assert_eq!(back[0].headers, sent[0].headers);
        assert_eq!(back[1].form, sent[1].form);
        assert_eq!(back[2].body_mode, Some(BodyMode::Binary));
        assert_eq!(back[2].body, sent[2].body);

        // A redacted archive still imports, and says what is missing.
        let redacted = to_har(&crate::redact_exchanges(&exchanges));
        let result = crate::import(&redacted, "session").unwrap();
        assert_eq!(result.source, "har");
        assert_eq!(result.collections[0].name, "session");
        assert_eq!(
            result.collections[0].items[0].request.as_ref().unwrap().url,
            "https://api.test/a?token=[REDACTED]"
        );
        assert!(result.warnings.iter().any(|w| w.contains("redacted")));
    }
}
