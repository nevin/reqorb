//! HTTP Archive (HAR 1.2) export of the exchanges a session made.

use serde_json::{Value, json};

use crate::{BodyMode, Exchange, Header};

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
}
