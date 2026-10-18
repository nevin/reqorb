//! Finding text or a pattern anywhere in a document, a megabyte at a time,
//! on whatever thread asks.

use std::sync::atomic::{AtomicBool, Ordering};

use memchr::memmem;
use regex::bytes::{Regex, RegexBuilder};

use super::text::Text;
use crate::Error;

/// What to look for.
#[derive(Debug, Clone, Default)]
pub struct Query {
    pub text: String,
    /// `text` is a regular expression rather than text to match as it is.
    pub regex: bool,
    pub case_sensitive: bool,
    /// Only matches that are whole words.
    pub whole_word: bool,
}

/// What a search found.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Found {
    /// Where each match is, as byte ranges, in order; at most [`MAX_KEPT`].
    pub ranges: Vec<(u64, u64)>,
    /// How many matches there are, including those not kept.
    pub count: u64,
}

/// The most matches kept: more than anyone steps through, and as many
/// as fit in 16 MB.
pub const MAX_KEPT: usize = 1_000_000;

/// How much is searched at once.
const CHUNK: u64 = 1024 * 1024;
/// How far past a chunk a match may run and still be found whole.
const OVERLAP: u64 = 64 * 1024;
/// How much before a chunk is read too, so that a word boundary or the
/// start of a line at its first byte is seen as it is.
const BEHIND: u64 = 4;

enum Matcher {
    Bytes(memmem::Finder<'static>),
    Regex(Regex),
}

impl Matcher {
    fn new(query: &Query) -> Result<Self, Error> {
        if !query.regex && query.case_sensitive && !query.whole_word {
            return Ok(Self::Bytes(
                memmem::Finder::new(query.text.as_bytes()).into_owned(),
            ));
        }
        let mut pattern = if query.regex {
            query.text.clone()
        } else {
            regex::escape(&query.text)
        };
        if query.whole_word {
            pattern = format!(r"\b(?:{pattern})\b");
        }
        RegexBuilder::new(&pattern)
            .case_insensitive(!query.case_sensitive)
            .multi_line(true)
            .build()
            .map(Self::Regex)
            .map_err(|e| Error::Format(format!("the pattern is not valid: {e}")))
    }

    /// Calls `f` with each match in `bytes`, until it returns false.
    fn each(&self, bytes: &[u8], mut f: impl FnMut(usize, usize) -> bool) {
        match self {
            Self::Bytes(finder) => {
                let len = finder.needle().len();
                for start in finder.find_iter(bytes) {
                    if !f(start, start + len) {
                        return;
                    }
                }
            }
            Self::Regex(regex) => {
                for m in regex.find_iter(bytes) {
                    if !f(m.start(), m.end()) {
                        return;
                    }
                }
            }
        }
    }
}

/// Searches `text`, telling `progress` what each chunk found and how far
/// it has got. Stops with [`Error::Cancelled`] once `cancel` is set.
pub(super) fn search(
    text: &Text,
    query: &Query,
    cancel: &AtomicBool,
    progress: impl FnMut(&[(u64, u64)], u64),
) -> Result<Found, Error> {
    search_in(text, query, cancel, progress, CHUNK)
}

pub(super) fn search_in(
    text: &Text,
    query: &Query,
    cancel: &AtomicBool,
    mut progress: impl FnMut(&[(u64, u64)], u64),
    chunk: u64,
) -> Result<Found, Error> {
    let mut found = Found::default();
    if query.text.is_empty() {
        return Ok(found);
    }
    let matcher = Matcher::new(query)?;
    let len = text.len();
    let mut at = 0;
    while at < len {
        if cancel.load(Ordering::Relaxed) {
            return Err(Error::Cancelled);
        }
        let end = (at + chunk).min(len);
        let read_end = (end + OVERLAP).min(len);
        let last = read_end == len;
        let read_start = at.saturating_sub(BEHIND);
        let bytes = text.read(read_start, read_end);
        let kept = found.ranges.len();
        let mut next = end;
        matcher.each(&bytes, |s, e| {
            let (s, e) = (read_start + s as u64, read_start + e as u64);
            if s < at || s == e {
                return true;
            }
            // What starts past this chunk is found again with the next.
            if s >= end && !last {
                return false;
            }
            found.count += 1;
            if found.ranges.len() < MAX_KEPT {
                found.ranges.push((s, e));
            }
            next = next.max(e);
            true
        });
        if last {
            next = len;
        }
        progress(&found.ranges[kept..], next);
        at = next;
    }
    Ok(found)
}
