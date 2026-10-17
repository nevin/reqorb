//! The requests that were sent and what came back, kept from one launch
//! to the next.
//!
//! History is a file with one entry per line, so that recording a request
//! means adding a line, not rewriting everything before it. Responses can
//! hold as much that is private as requests do, so when credentials are
//! protected every line is encrypted whole.

use std::io::Write;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::vault::{KeyStore, LOCKED, key_from, lock, unlock};
use crate::{Error, Exchange, Request};

/// The most of one body that is kept. History is for finding a request
/// again and seeing how it went, not for archiving downloads.
const BODY_BYTES: usize = 512 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub exchange: Exchange,
    /// The request as it was written, before variables were filled in and
    /// authorization applied. Missing for the redirects and authorization
    /// round trips a send made on the way to its answer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<Request>,
    /// The name the request was saved under, if it was.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub name: String,
    /// Whether a body was too large to keep whole.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cut: bool,
}

/// What a history file holds.
#[derive(Debug, Clone, Default)]
pub struct History {
    /// Oldest first.
    pub entries: Vec<HistoryEntry>,
    /// Lines that could not be read: encrypted with a key that is not in
    /// this keychain, or damaged. They are left in the file.
    pub unreadable: u32,
}

fn io(path: &Path) -> impl Fn(std::io::Error) -> Error + '_ {
    move |e| Error::Io(format!("{}: {e}", path.display()))
}

/// Cuts `text` to at most [`BODY_BYTES`], on a character boundary.
fn shorten(text: &mut String) -> bool {
    if text.len() <= BODY_BYTES {
        return false;
    }
    let mut end = BODY_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text.truncate(end);
    true
}

/// The entry as it is kept: without binary content, and with long bodies
/// cut short.
fn compact(entry: &HistoryEntry) -> HistoryEntry {
    let mut entry = entry.clone();
    let response = &mut entry.exchange.response;
    entry.cut |= response.bytes.take().is_some();
    // The file goes when the app quits; what was kept of it stays.
    entry.cut |= response.body_file.take().is_some();
    entry.cut |= shorten(&mut response.body);
    for request in [Some(&mut entry.exchange.request), entry.source.as_mut()]
        .into_iter()
        .flatten()
    {
        if let Some(body) = &mut request.body {
            entry.cut |= shorten(body);
        }
    }
    entry
}

/// Reads the history at `path`. A missing file is an empty history.
pub fn load_history(path: &Path, keys: &dyn KeyStore) -> Result<History, Error> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(History::default()),
        Err(e) => return Err(io(path)(e)),
    };
    // The keychain is only troubled when there is something to decrypt.
    let key = if text.contains(LOCKED) {
        key_from(keys, false).ok().flatten()
    } else {
        None
    };
    let mut history = History::default();
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let plain = match (line.starts_with(LOCKED), &key) {
            (true, Some(key)) => unlock(key, line),
            (true, None) => None,
            (false, _) => Some(line.to_string()),
        };
        match plain.and_then(|p| serde_json::from_str(&p).ok()) {
            Some(entry) => history.entries.push(entry),
            None => history.unreadable += 1,
        }
    }
    Ok(history)
}

/// Adds `entries` to the history at `path`, then drops the oldest so that
/// about `limit` remain; with a limit of 0 nothing is kept. Entries are
/// encrypted when `protect` is set and the keychain can be used, and
/// written as they are otherwise.
pub fn append_history(
    path: &Path,
    entries: &[HistoryEntry],
    limit: u32,
    protect: bool,
    keys: &dyn KeyStore,
) -> Result<(), Error> {
    if limit == 0 {
        return clear_history(path);
    }
    if entries.is_empty() {
        return Ok(());
    }
    let key = if protect {
        key_from(keys, true).ok().flatten()
    } else {
        None
    };
    let mut lines = String::new();
    for entry in entries {
        let line = serde_json::to_string(&compact(entry)).expect("history serialises");
        lines.push_str(&match &key {
            Some(key) => lock(key, &line),
            None => line,
        });
        lines.push('\n');
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(io(path))?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    // What was sent and received is this user's business alone.
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options
        .open(path)
        .and_then(|mut file| file.write_all(lines.as_bytes()))
        .map_err(io(path))?;

    // Trimming rewrites the file, so it waits until there is a fair
    // amount to drop instead of happening on every send. Counting needs
    // only the line breaks, not the text decoded.
    let limit = limit as usize;
    let bytes = std::fs::read(path).map_err(io(path))?;
    if bytes.iter().filter(|&&b| b == b'\n').count() <= limit + (limit / 4).max(10) {
        return Ok(());
    }
    let text = String::from_utf8_lossy(&bytes);
    let kept: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    if kept.len() > limit + (limit / 4).max(10) {
        let mut trimmed = kept[kept.len() - limit..].join("\n");
        trimmed.push('\n');
        crate::files::replace_file(path, trimmed.as_bytes(), true).map_err(io(path))?;
    }
    Ok(())
}

/// Forgets everything at `path`.
pub fn clear_history(path: &Path) -> Result<(), Error> {
    match std::fs::remove_file(path) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(io(path)(e)),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault::tests::MemoryKeys;
    use crate::{Auth, AuthKind, Response};

    fn entry(n: u32) -> HistoryEntry {
        let mut request = Request::new("GET", format!("https://api.test/items/{n}"));
        request.add_header("Authorization", "Bearer s3cret");
        let mut source = Request::new("GET", "{{base}}/items/{{n}}");
        source.auth = Some(Auth::new(AuthKind::Bearer, &[("token", "{{token}}")]));
        HistoryEntry {
            exchange: Exchange {
                started_ms: 1_700_000_000_000 + u64::from(n),
                request,
                response: Response {
                    status: 200,
                    status_text: "OK".into(),
                    http_version: "HTTP/1.1".into(),
                    headers: Vec::new(),
                    body: format!(r#"{{"n":{n},"session":"pr1vate"}}"#),
                    bytes: None,
                    body_file: None,
                    size_bytes: 30,
                    elapsed_ms: 12,
                },
            },
            source: Some(source),
            name: format!("Item {n}"),
            cut: false,
        }
    }

    fn urls(history: &History) -> Vec<String> {
        history
            .entries
            .iter()
            .map(|e| {
                e.exchange
                    .request
                    .url
                    .rsplit('/')
                    .next()
                    .unwrap()
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn remembers_what_was_sent_in_order() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub/history.jsonl");
        let keys = MemoryKeys::default();
        assert!(load_history(&path, &keys).unwrap().entries.is_empty());

        append_history(&path, &[entry(1), entry(2)], 100, true, &keys).unwrap();
        append_history(&path, &[], 100, true, &keys).unwrap();
        append_history(&path, &[entry(3)], 100, true, &keys).unwrap();
        let history = load_history(&path, &keys).unwrap();
        assert_eq!(urls(&history), ["1", "2", "3"]);
        assert_eq!(history.unreadable, 0);
        let first = &history.entries[0];
        assert_eq!(first.name, "Item 1");
        assert_eq!(first.source.as_ref().unwrap().url, "{{base}}/items/{{n}}");
        assert_eq!(
            first.exchange.response.body,
            r#"{"n":1,"session":"pr1vate"}"#
        );
        assert!(!first.cut);

        clear_history(&path).unwrap();
        clear_history(&path).unwrap();
        assert!(load_history(&path, &keys).unwrap().entries.is_empty());
    }

    #[test]
    fn nothing_private_is_readable_in_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.jsonl");
        let keys = MemoryKeys::default();
        append_history(&path, &[entry(1), entry(2)], 100, true, &keys).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert_eq!(text.lines().count(), 2);
        assert!(text.lines().all(|l| l.starts_with(LOCKED)));
        for private in ["s3cret", "pr1vate", "api.test", "Item"] {
            assert!(!text.contains(private), "{private} is in the file");
        }

        // Without the key the entries cannot be read, and are left alone.
        let other = MemoryKeys::default();
        let history = load_history(&path, &other).unwrap();
        assert_eq!((history.entries.len(), history.unreadable), (0, 2));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text);

        // With protection off, or no keychain to use, entries are plain,
        // and a file may hold both kinds.
        append_history(&path, &[entry(3)], 100, false, &keys).unwrap();
        assert!(std::fs::read_to_string(&path).unwrap().contains("s3cret"));
        assert_eq!(urls(&load_history(&path, &keys).unwrap()), ["1", "2", "3"]);
        let history = load_history(&path, &other).unwrap();
        assert_eq!(
            (urls(&history), history.unreadable),
            (vec!["3".to_string()], 2)
        );
    }

    #[test]
    fn drops_the_oldest_beyond_the_limit() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.jsonl");
        let keys = MemoryKeys::default();
        // Twenty are kept, with room for ten more before any are dropped.
        for n in 1..=30 {
            append_history(&path, &[entry(n)], 20, true, &keys).unwrap();
        }
        assert_eq!(load_history(&path, &keys).unwrap().entries.len(), 30);
        append_history(&path, &[entry(31)], 20, true, &keys).unwrap();
        let history = load_history(&path, &keys).unwrap();
        assert_eq!(history.entries.len(), 20);
        assert_eq!(urls(&history).first().map(String::as_str), Some("12"));
        assert_eq!(urls(&history).last().map(String::as_str), Some("31"));

        // A limit of nothing keeps nothing, including what was there.
        append_history(&path, &[entry(32)], 0, true, &keys).unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn keeps_large_and_binary_bodies_out() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.jsonl");
        let keys = MemoryKeys::default();
        let mut large = entry(1);
        large.exchange.response.body = "é".repeat(400_000);
        large.exchange.response.size_bytes = 800_000;
        let mut binary = entry(2);
        binary.exchange.response.body = String::new();
        binary.exchange.response.bytes = Some(vec![0, 159, 146, 150]);
        let mut upload = entry(3);
        upload.exchange.request.body = Some("x".repeat(BODY_BYTES + 1));
        // Too big to have been held: its start is here, the rest in a file.
        let mut spilled = entry(5);
        spilled.exchange.response.body = "start".into();
        spilled.exchange.response.body_file = Some("/tmp/body".into());
        append_history(
            &path,
            &[large, binary, upload, entry(4), spilled],
            100,
            false,
            &keys,
        )
        .unwrap();

        let history = load_history(&path, &keys).unwrap();
        let [large, binary, upload, small, spilled] = &history.entries[..] else {
            panic!("five entries");
        };
        assert!(spilled.cut);
        assert_eq!(spilled.exchange.response.body_file, None);
        assert_eq!(spilled.exchange.response.body, "start");
        assert!(large.cut);
        // Cut between characters, never through one.
        assert_eq!(large.exchange.response.body.len(), BODY_BYTES);
        assert_eq!(large.exchange.response.size_bytes, 800_000);
        assert!(binary.cut);
        assert_eq!(binary.exchange.response.bytes, None);
        assert!(upload.cut);
        assert_eq!(
            upload.exchange.request.body.as_ref().unwrap().len(),
            BODY_BYTES
        );
        assert!(!small.cut);
    }

    #[test]
    fn a_damaged_line_costs_only_itself() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.jsonl");
        let keys = MemoryKeys::default();
        append_history(&path, &[entry(1)], 100, false, &keys).unwrap();
        std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"{ half a line\n\n")
            .unwrap();
        append_history(&path, &[entry(2)], 100, true, &keys).unwrap();
        let history = load_history(&path, &keys).unwrap();
        assert_eq!(
            (urls(&history), history.unreadable),
            (vec!["1".to_string(), "2".to_string()], 1)
        );
    }
}
