//! Reads a HAR archive and reports what happened in it: totals, where the
//! time and bytes went, and the things worth a second look.

use serde::Serialize;
use serde_json::Value;

use crate::import::str_field;
use crate::redact::is_sensitive;
use crate::{Error, REDACTED};

/// A request counts as slow from this many milliseconds.
const SLOW_MS: u64 = 1000;
/// A response counts as large from this many bytes.
const LARGE_BYTES: u64 = 1024 * 1024;
/// Text responses smaller than this are not worth compressing.
const COMPRESSIBLE_BYTES: u64 = 10 * 1024;
/// How many entries a finding spells out before it says "and N more".
const NAMED: usize = 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum HarSeverity {
    Error,
    Warning,
    Info,
}

/// Something in the archive worth a second look.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HarFinding {
    pub severity: HarSeverity,
    pub title: String,
    /// What it means and what to do about it.
    pub detail: String,
    /// Indexes into [`HarReport::entries`] of the requests concerned.
    pub entries: Vec<u32>,
}

/// One recorded request, reduced to what a table or waterfall shows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HarEntry {
    /// Milliseconds after the first request of the archive started.
    pub offset_ms: u64,
    pub method: String,
    pub url: String,
    pub host: String,
    /// 0 when the request never got a response.
    pub status: u16,
    /// The kind of content, such as `json`, `html`, `image` or `other`.
    pub kind: String,
    pub size_bytes: u64,
    pub time_ms: u64,
    /// Time spent waiting for the first byte, when the archive says.
    pub wait_ms: Option<u64>,
}

/// A group of requests and what they add up to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HarCount {
    pub name: String,
    pub count: u32,
    pub bytes: u64,
    pub time_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HarReport {
    /// The tool that recorded the archive, such as `reqorb 0.1.0`.
    pub creator: String,
    pub entries: Vec<HarEntry>,
    /// Requests that got a 4xx or 5xx status, or no response at all.
    pub failed: u32,
    pub total_bytes: u64,
    /// Every request's time added up.
    pub total_time_ms: u64,
    /// From the start of the first request to the end of the last.
    pub span_ms: u64,
    /// Requests by host, the host with the most requests first.
    pub hosts: Vec<HarCount>,
    /// Requests by status class, `2xx` to `5xx` and then `no response`.
    pub statuses: Vec<HarCount>,
    /// Requests by kind of content, the most common first.
    pub kinds: Vec<HarCount>,
    /// Most serious first.
    pub findings: Vec<HarFinding>,
}

/// Analyses the text of a HAR archive.
pub fn analyze_har(text: &str) -> Result<HarReport, Error> {
    let text = text.trim_start_matches('\u{feff}').trim();
    let value: Value =
        serde_json::from_str(text).map_err(|e| Error::Format(format!("invalid JSON: {e}")))?;
    let Some(recorded) = value["log"]["entries"].as_array() else {
        return Err(Error::Format(
            "not a HAR archive: `log.entries` is missing".into(),
        ));
    };
    let creator = &value["log"]["creator"];
    let creator_name = str_field(creator, "name").unwrap_or("");
    let creator = format!(
        "{creator_name} {}",
        str_field(creator, "version").unwrap_or("")
    )
    .trim()
    .to_string();

    let starts: Vec<Option<u64>> = recorded
        .iter()
        .map(|e| str_field(e, "startedDateTime").and_then(parse_time))
        .collect();
    let first = starts.iter().flatten().min().copied().unwrap_or(0);

    let entries: Vec<HarEntry> = recorded
        .iter()
        .zip(&starts)
        .map(|(entry, start)| summarize(entry, start.map_or(0, |s| s - first)))
        .collect();

    let mut report = HarReport {
        creator,
        failed: entries.iter().filter(|e| is_failure(e)).count() as u32,
        total_bytes: entries.iter().map(|e| e.size_bytes).sum(),
        total_time_ms: entries.iter().map(|e| e.time_ms).sum(),
        span_ms: entries
            .iter()
            .map(|e| e.offset_ms + e.time_ms)
            .max()
            .unwrap_or(0),
        hosts: count_by(&entries, |e| e.host.clone()),
        statuses: count_by(&entries, |e| match e.status {
            0 => "no response".to_string(),
            status => format!("{}xx", status / 100),
        }),
        kinds: count_by(&entries, |e| e.kind.clone()),
        findings: Vec::new(),
        entries,
    };
    // Status classes read better in their natural order than by size.
    report.statuses.sort_by(|a, b| a.name.cmp(&b.name));
    // reqorb decompresses responses and drops the header that says they were
    // compressed, so its own archives cannot be checked for compression.
    let own = creator_name == "reqorb";
    report.findings = findings(&report.entries, recorded, own);
    Ok(report)
}

fn is_failure(entry: &HarEntry) -> bool {
    entry.status == 0 || entry.status >= 400
}

fn number(value: &Value) -> Option<u64> {
    value
        .as_f64()
        .filter(|n| *n >= 0.0)
        .map(|n| n.round() as u64)
}

fn header<'a>(message: &'a Value, name: &str) -> Option<&'a str> {
    message["headers"]
        .as_array()?
        .iter()
        .find(|h| str_field(h, "name").is_some_and(|n| n.eq_ignore_ascii_case(name)))
        .and_then(|h| str_field(h, "value"))
}

fn summarize(entry: &Value, offset_ms: u64) -> HarEntry {
    let request = &entry["request"];
    let response = &entry["response"];
    let content = &response["content"];
    let url = str_field(request, "url").unwrap_or("").to_string();
    let mime = str_field(content, "mimeType")
        .filter(|m| !m.is_empty())
        .or_else(|| header(response, "content-type"))
        .unwrap_or("");
    // What went over the wire when the archive knows it, else the decoded size.
    let size_bytes = number(&response["_transferSize"])
        .filter(|n| *n > 0)
        .or_else(|| number(&response["bodySize"]).filter(|n| *n > 0))
        .or_else(|| number(&content["size"]))
        .unwrap_or_else(|| str_field(content, "text").map_or(0, |t| t.len() as u64));
    HarEntry {
        offset_ms,
        method: str_field(request, "method").unwrap_or("GET").to_uppercase(),
        host: host_of(&url),
        url,
        status: number(&response["status"]).unwrap_or(0).min(999) as u16,
        kind: kind_of(mime).to_string(),
        size_bytes,
        time_ms: number(&entry["time"]).unwrap_or(0),
        wait_ms: number(&entry["timings"]["wait"]),
    }
}

fn host_of(url: &str) -> String {
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    host.to_lowercase()
}

fn kind_of(mime: &str) -> &'static str {
    let mime = mime.to_lowercase();
    let mime = mime.split(';').next().unwrap_or("").trim();
    match mime {
        "" => "other",
        m if m.contains("json") => "json",
        m if m.contains("javascript") || m.contains("ecmascript") => "script",
        "text/html" | "application/xhtml+xml" => "html",
        "text/css" => "css",
        m if m.starts_with("image/") => "image",
        m if m.starts_with("font/") || m.contains("font") => "font",
        m if m.starts_with("video/") || m.starts_with("audio/") => "media",
        m if m.contains("xml") => "xml",
        m if m.starts_with("text/") => "text",
        _ => "other",
    }
}

/// Groups in order of size: most requests first, then most bytes.
fn count_by(entries: &[HarEntry], key: impl Fn(&HarEntry) -> String) -> Vec<HarCount> {
    let mut counts: Vec<HarCount> = Vec::new();
    for entry in entries {
        let name = key(entry);
        let at = match counts.iter().position(|c| c.name == name) {
            Some(at) => at,
            None => {
                counts.push(HarCount {
                    name,
                    count: 0,
                    bytes: 0,
                    time_ms: 0,
                });
                counts.len() - 1
            }
        };
        counts[at].count += 1;
        counts[at].bytes += entry.size_bytes;
        counts[at].time_ms += entry.time_ms;
    }
    counts.sort_by(|a, b| b.count.cmp(&a.count).then(b.bytes.cmp(&a.bytes)));
    counts
}

/// `GET /path` for a finding's detail, short enough to list several.
fn label(entry: &HarEntry) -> String {
    let rest = entry
        .url
        .split_once("://")
        .map_or(entry.url.as_str(), |(_, r)| r);
    let path = rest.find('/').map_or("/", |at| &rest[at..]);
    let path = path.split(['?', '#']).next().unwrap_or(path);
    format!("{} {path}", entry.method)
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

struct Findings<'a> {
    entries: &'a [HarEntry],
    found: Vec<HarFinding>,
}

impl Findings<'_> {
    /// Adds a finding about the entries at `hits`, if there are any. `note`
    /// describes one entry in the list under the advice.
    fn add(
        &mut self,
        severity: HarSeverity,
        hits: Vec<usize>,
        title: impl Fn(usize) -> String,
        advice: &str,
        note: impl Fn(&HarEntry) -> String,
    ) {
        if hits.is_empty() {
            return;
        }
        let mut lines: Vec<String> = hits
            .iter()
            .take(NAMED)
            .map(|&i| note(&self.entries[i]))
            .collect();
        if hits.len() > NAMED {
            lines.push(format!("and {} more", hits.len() - NAMED));
        }
        self.found.push(HarFinding {
            severity,
            title: title(hits.len()),
            detail: format!("{advice}\n{}", lines.join("\n")),
            entries: hits.into_iter().map(|i| i as u32).collect(),
        });
    }
}

fn findings(entries: &[HarEntry], recorded: &[Value], own: bool) -> Vec<HarFinding> {
    use HarSeverity::{Error, Info, Warning};
    let mut out = Findings {
        entries,
        found: Vec::new(),
    };
    let pick = |test: &dyn Fn(usize, &HarEntry) -> bool| -> Vec<usize> {
        (0..entries.len())
            .filter(|&i| test(i, &entries[i]))
            .collect()
    };

    out.add(
        Error,
        pick(&|_, e| e.status == 0),
        |n| format!("{} got no response", plural(n, "request", "requests")),
        "The request was blocked, cancelled or could not connect.",
        label,
    );
    out.add(
        Error,
        pick(&|_, e| e.status >= 500),
        |n| plural(n, "server error", "server errors"),
        "The server failed to handle these requests (5xx).",
        |e| format!("{} {}", e.status, label(e)),
    );
    out.add(
        Error,
        pick(&|_, e| (400..500).contains(&e.status)),
        |n| plural(n, "client error", "client errors"),
        "The server rejected these requests (4xx): check the address, the \
         authorization and what was sent.",
        |e| format!("{} {}", e.status, label(e)),
    );

    let mut slow = pick(&|_, e| e.time_ms >= SLOW_MS);
    slow.sort_by_key(|&i| std::cmp::Reverse(entries[i].time_ms));
    out.add(
        Warning,
        slow,
        |n| {
            format!(
                "{} took a second or longer",
                plural(n, "request", "requests")
            )
        },
        "Slowest first. A long wait before the first byte points at the \
         server; a long download points at the size of the response.",
        |e| match e.wait_ms {
            Some(wait) => format!("{} ms ({wait} ms waiting) {}", e.time_ms, label(e)),
            None => format!("{} ms {}", e.time_ms, label(e)),
        },
    );

    let mut large = pick(&|_, e| e.size_bytes >= LARGE_BYTES);
    large.sort_by_key(|&i| std::cmp::Reverse(entries[i].size_bytes));
    out.add(
        Warning,
        large,
        |n| format!("{} over 1 MB", plural(n, "response is", "responses are")),
        "Largest first. Consider paging, trimming fields or compressing.",
        |e| {
            format!(
                "{:.1} MB {}",
                e.size_bytes as f64 / LARGE_BYTES as f64,
                label(e)
            )
        },
    );

    out.add(
        Warning,
        pick(&|i, e| {
            let secret = |(name, value): (&str, &str)| {
                is_sensitive(name) && !value.is_empty() && !value.contains(REDACTED)
            };
            let rest = e.url.split_once('?').map_or("", |(_, query)| query);
            let query = rest.split('#').next().unwrap_or("");
            query
                .split('&')
                .filter_map(|p| p.split_once('='))
                .any(secret)
                || recorded[i]["request"]["queryString"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|p| Some((str_field(p, "name")?, str_field(p, "value")?)))
                    .any(secret)
        }),
        |n| {
            format!(
                "{} a credential in the URL",
                plural(n, "request has", "requests have")
            )
        },
        "URLs end up in logs, browser history and Referer headers. Send \
         tokens and keys in a header instead, and redact this archive before \
         sharing it.",
        label,
    );

    out.add(
        Warning,
        pick(&|_, e| {
            let local = ["localhost", "127.0.0.1", "[::1]"]
                .iter()
                .any(|l| e.host == *l || e.host.starts_with(&format!("{l}:")));
            e.url.to_lowercase().starts_with("http://") && !local
        }),
        |n| format!("{} not encrypted", plural(n, "request is", "requests are")),
        "Sent over plain http://, so anyone on the network path can read or \
         change them.",
        label,
    );

    out.add(
        Info,
        pick(&|i, _| {
            let response = &recorded[i]["response"];
            response["headers"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|h| {
                    str_field(h, "name").is_some_and(|n| n.eq_ignore_ascii_case("set-cookie"))
                })
                .filter_map(|h| str_field(h, "value"))
                .any(|cookie| {
                    let attributes = cookie.to_lowercase();
                    let has = |flag: &str| attributes.split(';').any(|a| a.trim() == flag);
                    !has("secure") || !has("httponly")
                })
        }),
        |n| {
            format!(
                "{} cookies without Secure or HttpOnly",
                plural(n, "response sets", "responses set")
            )
        },
        "Without Secure a cookie can travel over plain HTTP; without \
         HttpOnly, scripts on the page can read it.",
        label,
    );

    if !own {
        out.add(
            Info,
            pick(&|i, e| {
                let response = &recorded[i]["response"];
                let text = matches!(
                    e.kind.as_str(),
                    "json" | "script" | "html" | "css" | "xml" | "text"
                );
                let size = number(&response["content"]["size"]).unwrap_or(e.size_bytes);
                text && size >= COMPRESSIBLE_BYTES
                    && e.status != 0
                    && header(response, "content-encoding").is_none()
            }),
            |n| {
                format!(
                    "{} not compressed",
                    plural(n, "text response is", "text responses are")
                )
            },
            "Text over 10 KB with no Content-Encoding. Turning on gzip or \
             Brotli on the server usually cuts these to a fraction.",
            |e| format!("{} KB {}", e.size_bytes / 1024, label(e)),
        );
    }

    out.add(
        Info,
        pick(&|_, e| (300..400).contains(&e.status) && e.status != 304),
        |n| plural(n, "redirect", "redirects"),
        "Each redirect is an extra round trip. Calling the final address \
         directly saves it.",
        |e| format!("{} {}", e.status, label(e)),
    );

    // The same call made again, counting every copy after the first.
    let body = |i: usize| str_field(&recorded[i]["request"]["postData"], "text").unwrap_or("");
    out.add(
        Info,
        pick(&|i, e| {
            (0..i).any(|j| {
                entries[j].method == e.method && entries[j].url == e.url && body(j) == body(i)
            })
        }),
        |n| format!("{} repeated", plural(n, "request is", "requests are")),
        "The same method, address and body as an earlier request. Repeats \
         may be retries, polling, or a call that could be cached.",
        label,
    );

    out.found.sort_by_key(|f| f.severity);
    out.found
}

/// Parses an ISO 8601 timestamp such as `2024-02-29T12:34:56.789+01:00`
/// into milliseconds since the Unix epoch.
fn parse_time(text: &str) -> Option<u64> {
    let (date, time) = text.trim().split_once(['T', 't', ' '])?;
    let mut parts = date.split('-').map(|p| p.parse::<i64>().ok());
    let (year, month, day) = (parts.next()??, parts.next()??, parts.next()??);

    // The zone is `Z` or a signed offset after the time.
    let (clock, offset_minutes) = match time.find(['Z', 'z', '+', '-']) {
        Some(at) => {
            let zone = &time[at..];
            let minutes = if zone.eq_ignore_ascii_case("z") {
                0
            } else {
                let digits: String = zone[1..].chars().filter(char::is_ascii_digit).collect();
                let hours: i64 = digits.get(..2)?.parse().ok()?;
                let minutes: i64 = digits.get(2..4).map_or(Some(0), |m| m.parse().ok())?;
                let total = hours * 60 + minutes;
                if zone.starts_with('-') { -total } else { total }
            };
            (&time[..at], minutes)
        }
        None => (time, 0),
    };
    let mut clock = clock.split(':');
    let hour: i64 = clock.next()?.parse().ok()?;
    let minute: i64 = clock.next()?.parse().ok()?;
    let seconds: f64 = clock.next().map_or(Some(0.0), |s| s.parse().ok())?;

    // Civil date to days since the epoch (Howard Hinnant's algorithm).
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;

    let minutes = days * 1440 + hour * 60 + minute - offset_minutes;
    let ms = minutes * 60_000 + (seconds * 1000.0).round() as i64;
    u64::try_from(ms).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_timestamps() {
        assert_eq!(parse_time("1970-01-01T00:00:00.000Z"), Some(0));
        assert_eq!(
            parse_time("2024-02-29T12:34:56.789Z"),
            Some(1_709_210_096_789)
        );
        assert_eq!(
            parse_time("2024-02-29T13:34:56.789+01:00"),
            Some(1_709_210_096_789)
        );
        assert_eq!(
            parse_time("2024-02-29T07:04:56.789-0530"),
            Some(1_709_210_096_789)
        );
        assert_eq!(parse_time("2026-12-31T23:59:59Z"), Some(1_798_761_599_000));
        assert_eq!(parse_time("yesterday"), None);
    }

    fn entry(
        started: &str,
        method: &str,
        url: &str,
        status: u16,
        mime: &str,
        size: u64,
        time: u64,
    ) -> Value {
        json!({
            "startedDateTime": started,
            "time": time,
            "request": { "method": method, "url": url, "headers": [] },
            "response": {
                "status": status,
                "headers": [],
                "content": { "size": size, "mimeType": mime },
                "bodySize": -1,
            },
            "timings": { "send": 0, "wait": time / 2, "receive": time / 2 },
        })
    }

    fn sample() -> Value {
        let mut cookie = entry(
            "2024-01-01T00:00:02.000Z",
            "POST",
            "https://api.test/login",
            200,
            "application/json",
            40,
            100,
        );
        cookie["response"]["headers"] = json!([
            { "name": "Set-Cookie", "value": "sid=1; Path=/; Secure" },
        ]);
        json!({ "log": {
            "creator": { "name": "WebInspector", "version": "537.36" },
            "entries": [
                entry("2024-01-01T00:00:00.000Z", "GET", "https://api.test/items?page=1", 200, "application/json; charset=utf-8", 20_000, 120),
                entry("2024-01-01T00:00:00.500Z", "GET", "https://api.test/items?page=1", 200, "application/json", 20_000, 80),
                entry("2024-01-01T00:00:01.000Z", "GET", "https://cdn.test/app.js?api_key=abc", 200, "text/javascript", 2_500_000, 1800),
                entry("2024-01-01T00:00:01.200Z", "GET", "http://old.test/a", 301, "text/html", 0, 30),
                entry("2024-01-01T00:00:01.300Z", "GET", "https://api.test/missing", 404, "application/json", 30, 40),
                entry("2024-01-01T00:00:01.400Z", "GET", "https://api.test/boom", 503, "text/plain", 10, 60),
                entry("2024-01-01T00:00:01.500Z", "GET", "https://api.test/blocked", 0, "", 0, 5),
                cookie,
            ],
        } })
    }

    #[test]
    fn summarises_an_archive() {
        let report = analyze_har(&sample().to_string()).unwrap();
        assert_eq!(report.creator, "WebInspector 537.36");
        assert_eq!(report.entries.len(), 8);
        assert_eq!(report.failed, 3);
        assert_eq!(report.total_bytes, 2_540_080);
        assert_eq!(report.total_time_ms, 2235);
        // The script started at 1.0 s and ran for 1.8 s.
        assert_eq!(report.span_ms, 2800);

        let script = &report.entries[2];
        assert_eq!(
            (script.offset_ms, script.host.as_str(), script.kind.as_str()),
            (1000, "cdn.test", "script")
        );
        assert_eq!(script.wait_ms, Some(900));

        let names = |counts: &[HarCount]| -> Vec<String> {
            counts
                .iter()
                .map(|c| format!("{} {}", c.name, c.count))
                .collect()
        };
        assert_eq!(
            names(&report.hosts),
            ["api.test 6", "cdn.test 1", "old.test 1"]
        );
        assert_eq!(
            names(&report.statuses),
            ["2xx 4", "3xx 1", "4xx 1", "5xx 1", "no response 1"]
        );
        assert_eq!(report.kinds[0].name, "json");
        assert_eq!(report.kinds[0].count, 4);
    }

    #[test]
    fn reports_findings_most_serious_first() {
        let report = analyze_har(&sample().to_string()).unwrap();
        let found: Vec<(HarSeverity, &str, &[u32])> = report
            .findings
            .iter()
            .map(|f| (f.severity, f.title.as_str(), f.entries.as_slice()))
            .collect();
        use HarSeverity::{Error, Info, Warning};
        assert_eq!(
            found,
            [
                (Error, "1 request got no response", &[6][..]),
                (Error, "1 server error", &[5][..]),
                (Error, "1 client error", &[4][..]),
                (Warning, "1 request took a second or longer", &[2][..]),
                (Warning, "1 response is over 1 MB", &[2][..]),
                (Warning, "1 request has a credential in the URL", &[2][..]),
                (Warning, "1 request is not encrypted", &[3][..]),
                (
                    Info,
                    "1 response sets cookies without Secure or HttpOnly",
                    &[7][..]
                ),
                (Info, "3 text responses are not compressed", &[0, 1, 2][..]),
                (Info, "1 redirect", &[3][..]),
                (Info, "1 request is repeated", &[1][..]),
            ]
        );
        let slow = &report.findings[3];
        assert!(
            slow.detail
                .ends_with("1800 ms (900 ms waiting) GET /app.js")
        );
        let errors = &report.findings[2];
        assert!(errors.detail.ends_with("404 GET /missing"));
    }

    #[test]
    fn reads_reqorb_archives_and_rejects_other_json() {
        let request = crate::Request::new("GET", "http://localhost:8080/big?token=[REDACTED]");
        let response = crate::Response {
            status: 200,
            status_text: "OK".into(),
            http_version: "HTTP/1.1".into(),
            headers: vec![crate::Header {
                name: "content-type".into(),
                value: "application/json".into(),
            }],
            body: "x".repeat(20_000),
            size_bytes: 20_000,
            elapsed_ms: 12,
        };
        let har = crate::to_har(&[crate::Exchange {
            started_ms: 1_709_210_096_789,
            request,
            response,
        }]);
        let report = analyze_har(&har).unwrap();
        assert_eq!(report.entries[0].size_bytes, 20_000);
        assert_eq!(report.entries[0].host, "localhost:8080");
        // Local plain HTTP, a redacted token and reqorb's own decompressed
        // bodies are all fine.
        assert_eq!(report.findings, []);

        assert!(analyze_har("{\"item\": []}").is_err());
        assert!(analyze_har("curl api.test").is_err());
        let empty = analyze_har("{\"log\": {\"entries\": []}}").unwrap();
        assert_eq!((empty.entries.len(), empty.span_ms), (0, 0));
    }
}
