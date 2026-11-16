//! Reads a HAR archive and reports what happened in it: totals, where the
//! time and bytes went, and the things worth a second look.

use serde::Serialize;
use serde_json::Value;

use crate::formats::util::str_field;
use crate::graphql::{self, graphql_errors};
use crate::redact::is_sensitive;
use crate::{Error, Header, REDACTED};

/// A request counts as slow from this many milliseconds.
const SLOW_MS: u64 = 1000;
/// A response counts as large from this many bytes.
const LARGE_BYTES: u64 = 1024 * 1024;
/// Text responses smaller than this are not worth compressing.
const COMPRESSIBLE_BYTES: u64 = 10 * 1024;
/// Response bodies are shown up to this many bytes.
const BODY_BYTES: usize = 200 * 1024;
/// The phases of a request, in order, by their HAR names.
const PHASES: &[&str] = &[
    "blocked", "dns", "connect", "ssl", "send", "wait", "receive",
];
/// How many entries a finding spells out before it says "and N more".
const NAMED: usize = 5;
/// A request counts as held back from this many milliseconds in the queue.
const QUEUED_MS: u64 = 500;
/// A WebSocket message is shown up to this many bytes.
const MESSAGE_BYTES: usize = 64 * 1024;
/// How many messages of one connection are kept; the rest are only counted.
const MESSAGES: usize = 5000;

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
    pub status_text: String,
    pub request_headers: Vec<Header>,
    pub response_headers: Vec<Header>,
    /// What was sent, as text; form fields are written one per line.
    pub request_body: Option<String>,
    /// For a GraphQL request, what it runs, such as `query Users`; every
    /// call to a GraphQL server shares one address.
    pub operation: Option<String>,
    /// What came back, when it is text. Long bodies are cut short and
    /// binary ones left out, as `body_note` then says.
    pub response_body: Option<String>,
    pub body_note: Option<String>,
    /// Where the time went, in the order the phases happen.
    pub phases: Vec<HarPhase>,
    /// Such as `HTTP/1.1` or `h2`; empty when the archive does not say.
    pub http_version: String,
    /// The address the request went to, when the archive says.
    pub server_ip: String,
    /// The conversation, when this is a WebSocket connection.
    pub socket: Option<HarSocket>,
}

/// What a WebSocket connection carried. Browsers record the messages
/// under `_webSocketMessages`, and so does reqorb when it saves a log.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HarSocket {
    /// Messages each way, counting those left out of `messages`.
    pub sent: u32,
    pub received: u32,
    pub sent_bytes: u64,
    pub received_bytes: u64,
    /// Oldest first, up to the first few thousand.
    pub messages: Vec<HarMessage>,
    /// How many later messages `messages` does not hold.
    pub left_out: u32,
    /// How the connection ended, when the archive says.
    pub ended: Option<String>,
}

/// One message on a WebSocket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HarMessage {
    /// Whether the client sent it; otherwise the server did.
    pub sent: bool,
    /// Milliseconds after the connection started.
    pub offset_ms: u64,
    pub binary: bool,
    pub size_bytes: u64,
    /// A text message, cut short when `cut` is set. Empty for binary ones.
    pub text: String,
    pub cut: bool,
}

/// One step of a request, such as `dns` or `wait`, and how long it took.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HarPhase {
    pub name: String,
    pub ms: u64,
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
        .map(|(entry, start)| summarize(entry, *start, first))
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

fn headers(message: &Value) -> Vec<Header> {
    message["headers"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|h| {
            Some(Header {
                name: str_field(h, "name")?.to_string(),
                value: str_field(h, "value").unwrap_or("").to_string(),
            })
        })
        .collect()
}

fn request_body(post: &Value) -> Option<String> {
    if let Some(text) = str_field(post, "text").filter(|t| !t.is_empty()) {
        return Some(text.to_string());
    }
    let fields: Vec<String> = post["params"]
        .as_array()?
        .iter()
        .filter_map(|param| {
            let name = str_field(param, "name")?;
            Some(match str_field(param, "fileName") {
                Some(file) => format!("{name}: (file) {file}"),
                None => format!("{name}: {}", str_field(param, "value").unwrap_or("")),
            })
        })
        .collect();
    (!fields.is_empty()).then(|| fields.join("\n"))
}

/// The response body as text, and a note when it is not all there.
fn response_body(content: &Value) -> (Option<String>, Option<String>) {
    let Some(text) = str_field(content, "text").filter(|t| !t.is_empty()) else {
        return (None, None);
    };
    if str_field(content, "encoding").is_some_and(|e| e.eq_ignore_ascii_case("base64")) {
        return (None, Some("Binary content is not shown.".into()));
    }
    if text.len() <= BODY_BYTES {
        return (Some(text.to_string()), None);
    }
    let mut end = BODY_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    (
        Some(text[..end].to_string()),
        Some(format!(
            "Showing the first {} KB of {} KB.",
            BODY_BYTES / 1024,
            text.len() / 1024
        )),
    )
}

/// The time of a WebSocket message in milliseconds since the Unix epoch.
/// Browsers write seconds with a fraction.
fn message_time(message: &Value) -> Option<u64> {
    let time = message["time"].as_f64().filter(|t| *t >= 0.0)?;
    let ms = if time >= 1e11 { time } else { time * 1000.0 };
    Some(ms.round() as u64)
}

/// The conversation of a WebSocket connection that started at `started`,
/// or `None` when the entry is an ordinary request.
fn socket(entry: &Value, url: &str, started: Option<u64>) -> Option<HarSocket> {
    let recorded = entry["_webSocketMessages"].as_array();
    let upgrade = |message: &Value| {
        header(message, "upgrade").is_some_and(|u| u.eq_ignore_ascii_case("websocket"))
    };
    let url = url.to_lowercase();
    if recorded.is_none()
        && !str_field(entry, "_resourceType").is_some_and(|t| t.eq_ignore_ascii_case("websocket"))
        && !url.starts_with("ws://")
        && !url.starts_with("wss://")
        && !upgrade(&entry["request"])
        && !upgrade(&entry["response"])
    {
        return None;
    }
    let recorded = recorded.map_or(&[][..], Vec::as_slice);
    // Without a start for the connection, the first message stands in.
    let start = started.or_else(|| recorded.iter().find_map(message_time));
    let offset = |at: Option<u64>| {
        at.zip(start)
            .map_or(0, |(at, start)| at.saturating_sub(start))
    };
    let mut socket = HarSocket {
        sent: 0,
        received: 0,
        sent_bytes: 0,
        received_bytes: 0,
        messages: Vec::new(),
        left_out: 0,
        ended: None,
    };
    for message in recorded {
        let sent = str_field(message, "type") == Some("send");
        let binary = number(&message["opcode"]) == Some(2);
        let data = str_field(message, "data").unwrap_or("");
        // Binary messages are written in base64, four characters to three bytes.
        let size_bytes = if binary {
            let padding = data.bytes().rev().take_while(|b| *b == b'=').count();
            (data.len() / 4 * 3).saturating_sub(padding) as u64
        } else {
            data.len() as u64
        };
        if sent {
            socket.sent += 1;
            socket.sent_bytes += size_bytes;
        } else {
            socket.received += 1;
            socket.received_bytes += size_bytes;
        }
        if socket.messages.len() == MESSAGES {
            socket.left_out += 1;
            continue;
        }
        let mut end = if binary {
            0
        } else {
            data.len().min(MESSAGE_BYTES)
        };
        while !data.is_char_boundary(end) {
            end -= 1;
        }
        socket.messages.push(HarMessage {
            sent,
            offset_ms: offset(message_time(message)),
            binary,
            size_bytes,
            text: data[..end].to_string(),
            cut: !binary && end < data.len(),
        });
    }
    // reqorb's own logs say how the connection ended; browsers do not.
    let closed = &entry["_webSocketClosed"];
    socket.ended = match str_field(entry, "_webSocketError") {
        Some(error) => Some(format!("Failed: {error}")),
        None => str_field(closed, "reason").map(|reason| match number(&closed["code"]) {
            Some(code) if code > 0 => format!("Closed: {reason} (code {code})"),
            _ => format!("Closed: {reason}"),
        }),
    };
    Some(socket)
}

fn summarize(entry: &Value, started: Option<u64>, first: u64) -> HarEntry {
    let offset_ms = started.map_or(0, |s| s - first);
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
    let (response_body, body_note) = response_body(content);
    let socket = socket(entry, &url, started);
    let time_ms = number(&entry["time"]).unwrap_or(0);
    let version = str_field(response, "httpVersion")
        .filter(|v| !v.is_empty())
        .or_else(|| str_field(request, "httpVersion"))
        .unwrap_or("");
    HarEntry {
        offset_ms,
        method: match &socket {
            Some(_) => "WS".to_string(),
            None => str_field(request, "method").unwrap_or("GET").to_uppercase(),
        },
        host: host_of(&url),
        url,
        status: number(&response["status"]).unwrap_or(0).min(999) as u16,
        kind: match &socket {
            Some(_) => "socket",
            None => kind_of(mime),
        }
        .to_string(),
        // The handshake of a WebSocket weighs nothing; its messages do.
        size_bytes: match &socket {
            Some(socket) if socket.sent + socket.received > 0 => {
                socket.sent_bytes + socket.received_bytes
            }
            _ => size_bytes,
        },
        // A connection lasts at least until its last message.
        time_ms: socket
            .iter()
            .flat_map(|s| s.messages.last())
            .fold(time_ms, |ms, last| ms.max(last.offset_ms)),
        wait_ms: number(&entry["timings"]["wait"]),
        status_text: str_field(response, "statusText").unwrap_or("").to_string(),
        request_headers: headers(request),
        response_headers: headers(response),
        request_body: request_body(&request["postData"]),
        operation: str_field(&request["postData"], "text").and_then(graphql::operation_of),
        response_body,
        body_note,
        // Phases the archive marks as not applicable (-1) or instant are
        // left out. `ssl` is part of `connect`, so it is taken out of it.
        phases: PHASES
            .iter()
            .filter_map(|&name| {
                let timings = &entry["timings"];
                let mut ms = number(&timings[name])?;
                if name == "connect" {
                    ms = ms.saturating_sub(number(&timings["ssl"]).unwrap_or(0));
                }
                (ms > 0).then(|| HarPhase {
                    name: name.to_string(),
                    ms,
                })
            })
            .collect(),
        http_version: version.to_string(),
        server_ip: str_field(entry, "serverIPAddress")
            .unwrap_or("")
            .to_string(),
        socket,
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
        "text/event-stream" => "events",
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
    match &entry.operation {
        Some(operation) => format!("{} {path} ({operation})", entry.method),
        None => format!("{} {path}", entry.method),
    }
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
        let entries = self.entries;
        self.add_at(severity, hits, title, advice, |i| note(&entries[i]));
    }

    /// As `add`, for a note that needs the entry's position.
    fn add_at(
        &mut self,
        severity: HarSeverity,
        hits: Vec<usize>,
        title: impl Fn(usize) -> String,
        advice: &str,
        note: impl Fn(usize) -> String,
    ) {
        if hits.is_empty() {
            return;
        }
        let mut lines: Vec<String> = hits.iter().take(NAMED).map(|&i| note(i)).collect();
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

    // A WebSocket or an event stream stays open on purpose.
    let mut slow = pick(&|_, e| e.time_ms >= SLOW_MS && e.socket.is_none() && e.kind != "events");
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
            let url = e.url.to_lowercase();
            (url.starts_with("http://") || url.starts_with("ws://")) && !local
        }),
        |n| format!("{} not encrypted", plural(n, "request is", "requests are")),
        "Sent over plain http:// or ws://, so anyone on the network path can \
         read or change them.",
        label,
    );

    let queued = |i: usize| number(&recorded[i]["timings"]["blocked"]).unwrap_or(0);
    let mut held = pick(&|i, _| queued(i) >= QUEUED_MS);
    held.sort_by_key(|&i| std::cmp::Reverse(queued(i)));
    out.add_at(
        Info,
        held,
        |n| {
            format!(
                "{} held back before being sent",
                plural(n, "request was", "requests were")
            )
        },
        "Longest first. The browser queued these for half a second or more, \
         usually because it already had six connections open to the host \
         (HTTP/1.1) or was busy with requests it ranked higher.",
        |i| format!("{} ms queued {}", queued(i), label(&entries[i])),
    );

    out.add(
        Info,
        pick(&|i, e| {
            let recorded = &recorded[i];
            e.method == "OPTIONS"
                && header(&recorded["request"], "access-control-request-method").is_some()
                && e.status != 0
                && header(&recorded["response"], "access-control-max-age").is_none()
        }),
        |n| {
            format!(
                "{} not remembered",
                plural(n, "CORS preflight is", "CORS preflights are")
            )
        },
        "The browser asks permission before some cross-origin requests, and \
         asks again within seconds unless the answer carries \
         Access-Control-Max-Age. Setting it saves a round trip per call.",
        label,
    );

    out.add(
        Info,
        pick(&|i, e| {
            let response = &recorded[i]["response"];
            matches!(e.kind.as_str(), "script" | "css" | "image" | "font")
                && e.status == 200
                // An archive without headers says nothing either way.
                && !e.response_headers.is_empty()
                && header(response, "cache-control").is_none()
                && header(response, "expires").is_none()
        }),
        |n| {
            format!(
                "{} no caching headers",
                plural(n, "static file has", "static files have")
            )
        },
        "Without Cache-Control or Expires the browser has to guess how long \
         to keep a file. A long max-age on files whose names change with \
         their content saves fetching them again.",
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

    // A GraphQL server answers 200 whether or not the query worked.
    let errors = |i: usize| {
        let content = &recorded[i]["response"]["content"];
        graphql_errors(str_field(content, "text").unwrap_or(""))
    };
    out.add(
        Warning,
        pick(&|i, e| e.operation.is_some() && e.status < 400 && !errors(i).is_empty()),
        |n| {
            format!(
                "{} errors despite a successful status",
                plural(n, "GraphQL response reports", "GraphQL responses report")
            )
        },
        "GraphQL servers answer 200 even when a query fails, so the status \
         alone does not show these. The response's `errors` say what went wrong.",
        label,
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
        let phases: Vec<(&str, u64)> = script
            .phases
            .iter()
            .map(|p| (p.name.as_str(), p.ms))
            .collect();
        assert_eq!(phases, [("wait", 900), ("receive", 900)]);

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
    fn keeps_the_detail_of_each_request() {
        let har = json!({ "log": { "entries": [{
            "startedDateTime": "2024-01-01T00:00:00Z",
            "time": 300,
            "request": {
                "method": "POST",
                "url": "https://api.test/upload",
                "headers": [{ "name": "Accept", "value": "*/*" }],
                "postData": {
                    "mimeType": "multipart/form-data",
                    "params": [
                        { "name": "title", "value": "Hi" },
                        { "name": "doc", "fileName": "a.pdf" },
                    ],
                },
            },
            "response": {
                "status": 200,
                "statusText": "OK",
                "headers": [{ "name": "Content-Type", "value": "image/png" }],
                "content": { "size": 4, "mimeType": "image/png", "text": "AAAA", "encoding": "base64" },
            },
            "timings": { "blocked": -1, "dns": 20, "connect": 80, "ssl": 50, "send": 0, "wait": 150, "receive": 50 },
        }] } });
        let report = analyze_har(&har.to_string()).unwrap();
        let entry = &report.entries[0];
        assert_eq!(entry.status_text, "OK");
        assert_eq!(entry.request_headers[0].name, "Accept");
        assert_eq!(entry.response_headers[0].value, "image/png");
        assert_eq!(
            entry.request_body.as_deref(),
            Some("title: Hi\ndoc: (file) a.pdf")
        );
        assert_eq!(entry.response_body, None);
        assert_eq!(
            entry.body_note.as_deref(),
            Some("Binary content is not shown.")
        );
        let phases: Vec<(&str, u64)> = entry
            .phases
            .iter()
            .map(|p| (p.name.as_str(), p.ms))
            .collect();
        assert_eq!(
            phases,
            [
                ("dns", 20),
                ("connect", 30),
                ("ssl", 50),
                ("wait", 150),
                ("receive", 50)
            ]
        );

        let long = "é".repeat(150_000);
        let (body, note) = response_body(&json!({ "text": long }));
        assert!(body.unwrap().len() <= BODY_BYTES);
        assert_eq!(note.as_deref(), Some("Showing the first 200 KB of 292 KB."));
    }

    #[test]
    fn reads_the_messages_of_a_websocket() {
        let mut socket = entry(
            "2024-01-01T00:00:00.000Z",
            "GET",
            "ws://chat.test/live",
            101,
            "",
            0,
            4,
        );
        socket["_resourceType"] = json!("websocket");
        socket["response"]["httpVersion"] = json!("HTTP/1.1");
        socket["serverIPAddress"] = json!("10.0.0.7");
        let long = "x".repeat(MESSAGE_BYTES + 10);
        socket["_webSocketMessages"] = json!([
            { "type": "send", "time": 1_704_067_200.5, "opcode": 1, "data": "{\"op\":\"hi\"}" },
            { "type": "receive", "time": 1_704_067_201.25, "opcode": 1, "data": long },
            { "type": "receive", "time": 1_704_067_203.0, "opcode": 2, "data": "AAECAw==" },
        ]);
        // A handshake that was turned down has no messages, but is a socket.
        let mut refused = entry(
            "2024-01-01T00:00:05.000Z",
            "GET",
            "https://chat.test/live",
            403,
            "",
            0,
            20,
        );
        refused["request"]["headers"] = json!([{ "name": "Upgrade", "value": "websocket" }]);
        let stream = entry(
            "2024-01-01T00:00:06.000Z",
            "GET",
            "https://api.test/events",
            200,
            "text/event-stream",
            100,
            9000,
        );
        let har = json!({ "log": { "entries": [socket, refused, stream] } });
        let report = analyze_har(&har.to_string()).unwrap();

        let entry = &report.entries[0];
        assert_eq!(
            (entry.method.as_str(), entry.kind.as_str()),
            ("WS", "socket")
        );
        assert_eq!(
            (entry.http_version.as_str(), entry.server_ip.as_str()),
            ("HTTP/1.1", "10.0.0.7")
        );
        // It lasted until its last message, three seconds in.
        assert_eq!(entry.time_ms, 3000);
        let socket = entry.socket.as_ref().unwrap();
        assert_eq!((socket.sent, socket.received, socket.left_out), (1, 2, 0));
        assert_eq!(socket.sent_bytes, 11);
        assert_eq!(socket.received_bytes, MESSAGE_BYTES as u64 + 10 + 4);
        assert_eq!(entry.size_bytes, socket.sent_bytes + socket.received_bytes);
        let offsets: Vec<u64> = socket.messages.iter().map(|m| m.offset_ms).collect();
        assert_eq!(offsets, [500, 1250, 3000]);
        assert!(socket.messages[1].cut);
        assert_eq!(socket.messages[1].text.len(), MESSAGE_BYTES);
        let binary = &socket.messages[2];
        assert_eq!(
            (binary.binary, binary.size_bytes, binary.text.as_str()),
            (true, 4, "")
        );
        assert_eq!(socket.ended, None);

        assert!(report.entries[1].socket.is_some());
        assert_eq!(report.entries[2].kind, "events");
        // Neither the open socket nor the stream is slow; ws:// is plain.
        let titles: Vec<&str> = report.findings.iter().map(|f| f.title.as_str()).collect();
        assert_eq!(titles, ["1 client error", "1 request is not encrypted"]);
        assert_eq!(report.findings[1].entries, [0]);
    }

    #[test]
    fn counts_the_messages_it_leaves_out() {
        let message = json!({ "type": "receive", "time": 1.0, "opcode": 1, "data": "tick" });
        let mut socket = entry(
            "2024-01-01T00:00:00Z",
            "GET",
            "wss://feed.test/",
            101,
            "",
            0,
            1,
        );
        socket["_webSocketMessages"] = json!(vec![message; MESSAGES + 3]);
        let har = json!({ "log": { "entries": [socket] } });
        let report = analyze_har(&har.to_string()).unwrap();
        let socket = report.entries[0].socket.as_ref().unwrap();
        assert_eq!(socket.messages.len(), MESSAGES);
        assert_eq!((socket.received, socket.left_out), (MESSAGES as u32 + 3, 3));
        assert_eq!(socket.received_bytes, 4 * (MESSAGES as u64 + 3));
    }

    #[test]
    fn finds_queues_preflights_and_uncached_files() {
        let at = "2024-01-01T00:00:00Z";
        let mut queued = entry(
            at,
            "GET",
            "https://api.test/a",
            200,
            "application/json",
            10,
            900,
        );
        queued["timings"]["blocked"] = json!(750);
        let mut preflight = entry(at, "OPTIONS", "https://api.test/a", 204, "", 0, 20);
        preflight["request"]["headers"] =
            json!([{ "name": "Access-Control-Request-Method", "value": "POST" }]);
        let mut remembered = preflight.clone();
        remembered["request"]["url"] = json!("https://api.test/b");
        remembered["response"]["headers"] =
            json!([{ "name": "access-control-max-age", "value": "600" }]);
        let mut bare = entry(
            at,
            "GET",
            "https://cdn.test/app.css",
            200,
            "text/css",
            10,
            20,
        );
        bare["response"]["headers"] = json!([{ "name": "Content-Type", "value": "text/css" }]);
        let mut kept = entry(
            at,
            "GET",
            "https://cdn.test/logo.png",
            200,
            "image/png",
            10,
            20,
        );
        kept["response"]["headers"] = json!([{ "name": "Cache-Control", "value": "max-age=600" }]);
        let har = json!({ "log": {
            "creator": { "name": "reqorb" },
            "entries": [queued, preflight, remembered, bare, kept],
        } });
        let report = analyze_har(&har.to_string()).unwrap();
        let found: Vec<(&str, &[u32])> = report
            .findings
            .iter()
            .map(|f| (f.title.as_str(), f.entries.as_slice()))
            .collect();
        assert_eq!(
            found,
            [
                ("1 request was held back before being sent", &[0][..]),
                ("1 CORS preflight is not remembered", &[1][..]),
                ("1 static file has no caching headers", &[3][..]),
            ]
        );
        assert!(report.findings[0].detail.ends_with("750 ms queued GET /a"));
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
            bytes: None,
            body_file: None,
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
