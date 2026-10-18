//! Documents of any size, up to a gigabyte or so: the text an editor shows
//! and changes, held as the original bytes and the edits made to them.
//!
//! - `source`: the original bytes, from memory or read from a file a page
//!   at a time.
//! - `index`: where the original's newlines are, found in the background.
//! - `text`: the pieces of the original and of added text that make up
//!   the document now.
//! - `search`: finding text or a pattern in all of it.
//!
//! Positions are byte offsets. A line longer than [`ROW_BYTES`] is shown
//! over several rows; an editor works in rows, and in columns counted in
//! UTF-16 code units within a row, as Dart counts them.

mod index;
mod json;
mod search;
mod source;
#[cfg(test)]
mod tests;
mod text;

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard};
use std::time::SystemTime;

use memchr::memchr_iter;

use crate::Error;
use index::{Index, Indexed};
pub use json::{JsonKind, JsonNode, JsonPage};
pub use search::{Found, MAX_KEPT, Query};
use source::Source;
use text::{Piece, Text};

/// The most bytes of a line shown in one row. Longer lines go on over
/// several rows, so that a megabyte of JSON on one line can be shown.
pub const ROW_BYTES: u64 = 2048;

/// The size of the pages a file is read and indexed in.
const PAGE: u64 = 64 * 1024;

/// How much is read at once when going through a whole document.
const CHUNK: u64 = 1024 * 1024;

/// A NUL among this many bytes at the start means the file is not text.
const SNIFF: u64 = 8 * 1024;

/// One row of a document as shown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    /// The line it is part of, counted from 0.
    pub line: u64,
    /// Which row of a long line it is, counted from 0.
    pub part: u32,
    /// The bytes it shows, without the line break.
    pub start: u64,
    pub end: u64,
    /// Those bytes as text; anything not UTF-8 shows as `�`.
    pub text: String,
    /// Whether it begins inside a string in double quotes that an earlier
    /// row of the same long line opened, so that colouring it alone can
    /// start in the string. Always false for a line's first row.
    pub quoted: bool,
}

/// How far finding a document's lines has got.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Indexing {
    pub indexed: u64,
    pub len: u64,
    pub done: bool,
}

/// The bytes an undo or redo changed: where to put the caret after it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Change {
    pub start: u64,
    pub end: u64,
}

/// A copy of a document's text as it is, to search on another thread
/// while the document goes on being edited.
#[derive(Clone)]
pub struct Snapshot(Text);

impl Snapshot {
    pub fn len(&self) -> u64 {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.len() == 0
    }

    /// Finds every match of `query`, telling `progress` what each part of
    /// the document held and how far it has got.
    pub fn search(
        &self,
        query: &Query,
        cancel: &AtomicBool,
        progress: impl FnMut(&[(u64, u64)], u64),
    ) -> Result<Found, Error> {
        search::search(&self.0, query, cancel, progress)
    }

    /// The JSON value at the top of the text.
    pub fn json_root(&self) -> Result<JsonNode, Error> {
        json::root(&self.0)
    }

    /// Up to `count` children of the JSON object or array at `at`: from its
    /// first, or from `from`, where a page before left off. Only as much
    /// of the text is read as they take up.
    pub fn json_children(
        &self,
        at: u64,
        from: Option<u64>,
        count: usize,
    ) -> Result<JsonPage, Error> {
        json::children(&self.0, at, from, count)
    }

    /// Writes the text, which is JSON, to `out`: indented by `indent`, or
    /// minified when there is none. A megabyte is read at a time, and
    /// `progress` told how far it has got.
    pub fn format_json(
        &self,
        indent: Option<&str>,
        out: &mut dyn Write,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(u64),
    ) -> Result<(), Error> {
        json::format(&self.0, indent, out, cancel, progress)
    }
}

/// One step of undo: the pieces an edit took out and put in at `at`,
/// and the long lines of the lines it changed, before and after.
#[derive(Clone)]
struct Step {
    id: u64,
    at: u64,
    removed: Vec<Piece>,
    inserted: Vec<Piece>,
    line: u64,
    newlines_removed: u64,
    newlines_inserted: u64,
    long_before: Vec<(u64, u64)>,
    long_after: Vec<(u64, u64)>,
}

fn total_len(pieces: &[Piece]) -> u64 {
    pieces.iter().map(|p| p.len).sum()
}

/// What a file was like when it was read or written, to tell whether
/// something else has changed it since.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    len: u64,
    modified: Option<SystemTime>,
}

impl Stamp {
    fn of(path: &Path) -> Option<Self> {
        let meta = fs::metadata(path).ok()?;
        Some(Self {
            len: meta.len(),
            modified: meta.modified().ok(),
        })
    }
}

pub struct Document {
    text: Text,
    index: Arc<Index>,
    /// Whether every line of the original is known.
    settled: bool,
    path: Option<PathBuf>,
    stamp: Option<Stamp>,
    /// Lines longer than a row, as (line, length in bytes), in order.
    long: Vec<(u64, u64)>,
    /// How many rows the long lines before each one add: `extra[j]` for
    /// `long[..j]`.
    extra: Vec<u64>,
    undo: Vec<Step>,
    redo: Vec<Step>,
    next_id: u64,
    /// The undo step the document was last saved at; `None` for as opened.
    saved: Option<u64>,
    /// Changes with every edit, undo and redo.
    version: u64,
    /// For the long lines shown lately, whether each of their rows begins
    /// inside a string, as of `version`.
    quoted: Mutex<Quoted>,
}

/// Which rows of long lines begin inside a string, worked out as far as
/// rows are asked for, and kept until the document changes.
#[derive(Default)]
struct Quoted {
    version: u64,
    lines: HashMap<u64, Scan>,
}

/// How far through a long line the strings have been followed.
struct Scan {
    /// For each row read past so far, whether it begins inside a string,
    /// and just after a backslash in one.
    rows: Vec<(bool, bool)>,
    /// Where reading got to, and what it was in there.
    at: u64,
    in_string: bool,
    escaped: bool,
}

/// How many long lines' rows are kept.
const QUOTED_LINES: usize = 16;

impl Document {
    /// A document holding `bytes`, not yet saved anywhere.
    pub fn from_bytes(bytes: Vec<u8>) -> Self {
        Self::with_source(Source::memory(bytes, PAGE), false, None)
    }

    pub fn from_text(text: &str) -> Self {
        Self::from_bytes(text.as_bytes().to_vec())
    }

    /// Opens the file at `path`. Only its first page is read before this
    /// returns; its lines are found in the background, as
    /// [`Document::indexing`] tells.
    pub fn open(path: &Path) -> Result<Self, Error> {
        Self::open_paged(path, PAGE)
    }

    fn open_paged(path: &Path, page: u64) -> Result<Self, Error> {
        let file = File::open(path)
            .map_err(|e| Error::Io(format!("{} could not be opened: {e}", path.display())))?;
        let meta = file
            .metadata()
            .map_err(|e| Error::Io(format!("{} could not be read: {e}", path.display())))?;
        if meta.is_dir() {
            return Err(Error::Io(format!("{} is a folder", path.display())));
        }
        let source = Source::file(file, meta.len(), page);
        Ok(Self::with_source(source, true, Some(path)))
    }

    fn with_source(source: Source, background: bool, path: Option<&Path>) -> Self {
        let source = Arc::new(source);
        let index = Index::build(source.clone(), background);
        index.wait(true);
        let mut doc = Self {
            text: Text::new(source, Default::default()),
            index,
            settled: false,
            path: path.map(Path::to_path_buf),
            stamp: path.and_then(Stamp::of),
            long: Vec::new(),
            extra: vec![0],
            undo: Vec::new(),
            redo: Vec::new(),
            next_id: 1,
            saved: None,
            version: 0,
            quoted: Mutex::default(),
        };
        doc.indexing();
        doc
    }

    /// Takes in the lines found since last asked, and tells how far
    /// finding them has got.
    pub fn indexing(&mut self) -> Indexing {
        let len = self.text.source().len();
        if self.settled {
            return Indexing {
                indexed: len,
                len,
                done: true,
            };
        }
        let Indexed { lines, long, done } = self.index.indexed();
        let indexed = lines.len();
        self.text.set_lines(lines);
        self.long = long;
        self.rebuild_extra();
        self.settled = done;
        self.version += 1;
        Indexing { indexed, len, done }
    }

    /// Waits until every line is known.
    pub fn wait_indexed(&mut self) {
        if !self.settled {
            self.index.wait(false);
            self.indexing();
        }
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    pub fn len(&self) -> u64 {
        self.text.len()
    }

    pub fn is_empty(&self) -> bool {
        self.text.len() == 0
    }

    /// Changes with every edit, undo and redo, and as lines are found.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// Whether there are edits that have not been saved.
    pub fn is_modified(&self) -> bool {
        self.undo.last().map(|s| s.id) != self.saved
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    /// Why part of the file could not be read, if it could not.
    pub fn problem(&self) -> Option<String> {
        self.text.source().problem()
    }

    /// Whether the start of the original holds a NUL, as binary files do
    /// and text never does.
    pub fn looks_binary(&self) -> bool {
        let mut start = Vec::new();
        let source = self.text.source();
        source.read(0, SNIFF.min(source.len()), &mut start);
        start.contains(&0)
    }

    /// How much of the text is known to be lines yet.
    fn visible_len(&self) -> u64 {
        if self.settled {
            self.text.len()
        } else {
            self.index.progress().0.min(self.text.len())
        }
    }

    pub fn line_count(&self) -> u64 {
        self.text.newlines() + 1
    }

    pub fn row_count(&self) -> u64 {
        self.line_count() + self.extra.last().copied().unwrap_or(0)
    }

    /// Where line `line` starts.
    pub fn line_start(&self, line: u64) -> u64 {
        match line {
            0 => 0,
            _ => self
                .text
                .newline_at(line - 1)
                .map_or(self.visible_len(), |at| at + 1),
        }
    }

    /// Where line `line` ends, before its newline.
    pub fn line_end(&self, line: u64) -> u64 {
        self.text
            .newline_at(line)
            .unwrap_or_else(|| self.visible_len())
    }

    /// The line byte `at` is on.
    pub fn line_of(&self, at: u64) -> u64 {
        self.text.newlines_before(at.min(self.visible_len()))
    }

    /// Bytes `start..end`.
    pub fn bytes(&self, start: u64, end: u64) -> Vec<u8> {
        self.text.read(start, end)
    }

    /// Bytes `start..end` as text; anything not UTF-8 shows as `�`.
    pub fn text(&self, start: u64, end: u64) -> String {
        String::from_utf8_lossy(&self.text.read(start, end)).into_owned()
    }

    /// A copy of the text as it is now, to search.
    pub fn snapshot(&self) -> Snapshot {
        Snapshot(self.text.clone())
    }

    // ----------------------------------------------------------------- rows

    fn rebuild_extra(&mut self) {
        self.extra.clear();
        self.extra.push(0);
        let mut extra = 0;
        for &(_, len) in &self.long {
            extra += parts(len) - 1;
            self.extra.push(extra);
        }
    }

    /// How many rows line `line` takes.
    fn parts_of(&self, line: u64) -> u64 {
        match self.long.binary_search_by_key(&line, |&(l, _)| l) {
            Ok(j) => parts(self.long[j].1),
            Err(_) => 1,
        }
    }

    /// The first row of line `line`.
    pub fn row_of_line(&self, line: u64) -> u64 {
        line + self.extra[self.long.partition_point(|&(l, _)| l < line)]
    }

    /// The line row `row` is part of, and which part of it.
    pub fn line_of_row(&self, row: u64) -> (u64, u64) {
        // How many long lines start at or before the row.
        let (mut lo, mut hi) = (0, self.long.len());
        while lo < hi {
            let mid = (lo + hi) / 2;
            if self.long[mid].0 + self.extra[mid] <= row {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if lo > 0 {
            let (line, len) = self.long[lo - 1];
            let first = line + self.extra[lo - 1];
            if row < first + parts(len) {
                return (line, row - first);
            }
        }
        (row - self.extra[lo], 0)
    }

    /// Where part `part` of the line `start..end` begins: a multiple of
    /// [`ROW_BYTES`] in, moved on to the start of a character.
    fn part_start(&self, start: u64, end: u64, part: u64) -> u64 {
        if part == 0 {
            return start;
        }
        let mut at = (start + part * ROW_BYTES).min(end);
        for b in self.text.read(at, (at + 3).min(end)) {
            if b & 0xC0 != 0x80 {
                break;
            }
            at += 1;
        }
        at
    }

    /// The bytes row `part` of a line shows, and those bytes.
    fn row_span(&self, line: u64, part: u64) -> (u64, u64, Vec<u8>) {
        let (ls, le) = (self.line_start(line), self.line_end(line));
        let parts = self.parts_of(line);
        let start = self.part_start(ls, le, part);
        let mut end = if part + 1 < parts {
            self.part_start(ls, le, part + 1)
        } else {
            le
        };
        // A line still being indexed is not known to be long yet.
        if end - start > ROW_BYTES + 3 {
            end = self.part_start(ls, le, part + 1);
        }
        let mut bytes = self.text.read(start, end);
        if end == le && bytes.last() == Some(&b'\r') {
            bytes.pop();
            end -= 1;
        }
        (start, end, bytes)
    }

    /// Up to `count` rows from row `first`.
    pub fn rows(&self, first: u64, count: usize) -> Vec<Row> {
        let total = self.row_count();
        let mut rows = Vec::with_capacity(count.min(total.saturating_sub(first) as usize));
        let mut row = first;
        while row < total && rows.len() < count {
            let (line, part) = self.line_of_row(row);
            let (start, end, bytes) = self.row_span(line, part);
            rows.push(Row {
                line,
                part: part as u32,
                start,
                end,
                text: String::from_utf8_lossy(&bytes).into_owned(),
                quoted: part > 0 && self.quoted_at(line, part),
            });
            row += 1;
        }
        rows
    }

    /// Whether row `part` of long line `line` begins inside a string in
    /// double quotes. The line is read from its start as far as that row,
    /// once; what was found is kept for the rows before it.
    fn quoted_at(&self, line: u64, part: u64) -> bool {
        // Until every line is found, the part not yet read through looks
        // like one long line, and would be read again as each part is
        // found; the colours are put right once it is.
        if !self.settled {
            return false;
        }
        let mut quoted = lock(&self.quoted);
        if quoted.version != self.version {
            quoted.lines.clear();
            quoted.version = self.version;
        }
        if !quoted.lines.contains_key(&line) && quoted.lines.len() >= QUOTED_LINES {
            quoted.lines.clear();
        }
        let (ls, le) = (self.line_start(line), self.line_end(line));
        let scan = quoted.lines.entry(line).or_insert(Scan {
            rows: vec![(false, false)],
            at: ls,
            in_string: false,
            escaped: false,
        });
        while scan.rows.len() as u64 <= part {
            let start = self.part_start(ls, le, scan.rows.len() as u64);
            self.follow_strings(scan, start);
            scan.rows.push((scan.in_string, scan.escaped));
        }
        scan.rows[part as usize].0
    }

    /// Takes in an edit from byte `at`, before the text changes: what was
    /// found about strings before it still holds, and is kept, so that
    /// typing in a long line reads it again only from the edit's row on.
    /// With `same_lines`, the edit puts in and takes out no line breaks,
    /// so the lines after it keep their numbers and what was found there.
    fn edited_from(&self, at: u64, same_lines: bool) {
        let line = self.line_of(at);
        let ls = self.line_start(line);
        let le = self.line_end(line);
        let mut quoted = lock(&self.quoted);
        // Lines after it may be numbered differently, or not be there.
        quoted.lines.retain(|&l, _| l <= line || same_lines);
        if let Some(scan) = quoted.lines.get_mut(&line) {
            let mut keep = scan.rows.len();
            while keep > 1 && self.part_start(ls, le, keep as u64 - 1) > at {
                keep -= 1;
            }
            scan.rows.truncate(keep);
            let (in_string, escaped) = scan.rows[keep - 1];
            scan.at = self.part_start(ls, le, keep as u64 - 1);
            scan.in_string = in_string;
            scan.escaped = escaped;
        }
        quoted.version = self.version;
    }

    /// Reads on from where `scan` got to, up to `to`, following strings in
    /// double quotes: in one, a backslash takes the character after it as
    /// it is. Jumps from quote to quote rather than reading each byte.
    fn follow_strings(&self, scan: &mut Scan, to: u64) {
        while scan.at < to {
            let end = (scan.at + CHUNK).min(to);
            let bytes = self.text.read(scan.at, end);
            let mut i = 0;
            if scan.escaped && !bytes.is_empty() {
                scan.escaped = false;
                i = 1;
            }
            while i < bytes.len() {
                if scan.in_string {
                    match memchr::memchr2(b'"', b'\\', &bytes[i..]) {
                        None => i = bytes.len(),
                        Some(k) if bytes[i + k] == b'"' => {
                            scan.in_string = false;
                            i += k + 1;
                        }
                        Some(k) => {
                            i += k + 2;
                            if i > bytes.len() {
                                // The character it escapes is in the next read.
                                scan.escaped = true;
                            }
                        }
                    }
                } else {
                    match memchr::memchr(b'"', &bytes[i..]) {
                        None => i = bytes.len(),
                        Some(k) => {
                            scan.in_string = true;
                            i += k + 1;
                        }
                    }
                }
            }
            scan.at = end;
        }
    }

    /// The row and column byte `at` is shown at.
    pub fn position_of(&self, at: u64) -> (u64, u32) {
        let at = at.min(self.visible_len());
        let line = self.line_of(at);
        let (ls, le) = (self.line_start(line), self.line_end(line));
        let mut part = ((at - ls) / ROW_BYTES).min(self.parts_of(line) - 1);
        while part > 0 && self.part_start(ls, le, part) > at {
            part -= 1;
        }
        let (start, _, bytes) = self.row_span(line, part);
        // Inside a character counts as at its start.
        let mut k = ((at - start) as usize).min(bytes.len());
        while k > 0 && k < bytes.len() && bytes[k] & 0xC0 == 0x80 {
            k -= 1;
        }
        (self.row_of_line(line) + part, utf16_len(&bytes[..k]))
    }

    /// The byte shown at column `col` of row `row`; the end of the row
    /// for a column past it.
    pub fn offset_of(&self, row: u64, col: u32) -> u64 {
        let row = row.min(self.row_count() - 1);
        let (line, part) = self.line_of_row(row);
        let (start, _, bytes) = self.row_span(line, part);
        start + utf16_to_byte(&bytes, col)
    }

    // ---------------------------------------------------------------- edits

    /// Waits for every line to be known, which an edit needs.
    fn ready(&mut self) {
        self.wait_indexed();
    }

    fn next_id(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    /// Puts `text` in place of bytes `start..end`. With `typing`, text
    /// typed straight after the last edit joins it as one step of undo.
    pub fn replace(&mut self, start: u64, end: u64, text: &str, typing: bool) {
        self.ready();
        let len = self.text.len();
        let (start, end) = (start.min(len), end.min(len).max(start.min(len)));
        if start == end && text.is_empty() {
            return;
        }
        self.redo.clear();
        self.version += 1;
        let same_lines = !text.contains('\n')
            && self.text.newlines_before(end) == self.text.newlines_before(start);
        self.edited_from(start, same_lines);
        if typing && start == end && !text.contains('\n') && self.join(start, text.as_bytes()) {
            return;
        }
        let line = self.text.newlines_before(start);
        let inserted: Vec<Piece> = if text.is_empty() {
            Vec::new()
        } else {
            vec![self.text.append(text.as_bytes())]
        };
        let removed = self.text.splice(start, end, &inserted);
        let newlines_removed = removed.iter().map(|p| p.newlines).sum();
        let newlines_inserted = inserted.iter().map(|p| p.newlines).sum();
        let long_after = self.long_lines_in(start, start + text.len() as u64, line);
        let long_before = self.swap_long(
            line,
            newlines_removed,
            newlines_inserted,
            long_after.clone(),
        );
        let id = self.next_id();
        self.undo.push(Step {
            id,
            at: start,
            removed,
            inserted,
            line,
            newlines_removed,
            newlines_inserted,
            long_before,
            long_after,
        });
    }

    /// Adds typing to the step before when it carries straight on from it.
    fn join(&mut self, at: u64, bytes: &[u8]) -> bool {
        let Some(last) = self.undo.last() else {
            return false;
        };
        if Some(last.id) == self.saved
            || !last.removed.is_empty()
            || last.newlines_inserted != 0
            || last.inserted.len() != 1
            || last.at + last.inserted[0].len != at
        {
            return false;
        }
        let (piece, line) = (last.inserted[0], last.line);
        if !self.text.extend(at, piece, bytes) {
            return false;
        }
        let len = self.line_end(line) - self.line_start(line);
        let long: Vec<_> = (len > ROW_BYTES)
            .then_some((line, len))
            .into_iter()
            .collect();
        self.swap_long(line, 0, 0, long.clone());
        let id = self.next_id();
        let last = self.undo.last_mut().expect("checked above");
        last.inserted[0].len += bytes.len() as u64;
        last.long_after = long;
        last.id = id;
        true
    }

    /// Puts `text` in place of every one of `ranges`, which must be in
    /// order and not overlap, as one step of undo.
    pub fn replace_all(&mut self, ranges: &[(u64, u64)], text: &str) {
        self.ready();
        if ranges.is_empty() {
            return;
        }
        self.redo.clear();
        self.version += 1;
        self.edited_from(ranges[0].0, false);
        let len = self.text.len();
        let piece = (!text.is_empty()).then(|| self.text.append(text.as_bytes()));
        let before = self.text.pieces().to_vec();
        let newlines_removed = self.text.newlines();
        let mut pieces = Vec::with_capacity(before.len() + ranges.len() * 3);
        let mut at = 0;
        for &(start, end) in ranges {
            let (start, end) = (
                start.clamp(at, len),
                end.clamp(at, len).max(start.clamp(at, len)),
            );
            pieces.extend(self.text.pieces_in(at, start));
            pieces.extend(piece);
            at = end;
        }
        pieces.extend(self.text.pieces_in(at, len));
        self.text.set_pieces(pieces);
        let long_after = self.long_lines_in(0, self.text.len(), 0);
        let long_before = std::mem::replace(&mut self.long, long_after.clone());
        self.rebuild_extra();
        let id = self.next_id();
        self.undo.push(Step {
            id,
            at: 0,
            removed: before,
            inserted: self.text.pieces().to_vec(),
            line: 0,
            newlines_removed,
            newlines_inserted: self.text.newlines(),
            long_before,
            long_after,
        });
    }

    /// Undoes the last edit.
    pub fn undo(&mut self) -> Option<Change> {
        let step = self.undo.pop()?;
        self.version += 1;
        self.edited_from(step.at, false);
        self.text
            .splice(step.at, step.at + total_len(&step.inserted), &step.removed);
        self.swap_long(
            step.line,
            step.newlines_inserted,
            step.newlines_removed,
            step.long_before.clone(),
        );
        let change = Change {
            start: step.at,
            end: step.at + total_len(&step.removed),
        };
        self.redo.push(step);
        Some(change)
    }

    /// Does again the last edit undone.
    pub fn redo(&mut self) -> Option<Change> {
        let step = self.redo.pop()?;
        self.version += 1;
        self.edited_from(step.at, false);
        self.text
            .splice(step.at, step.at + total_len(&step.removed), &step.inserted);
        self.swap_long(
            step.line,
            step.newlines_removed,
            step.newlines_inserted,
            step.long_after.clone(),
        );
        let change = Change {
            start: step.at,
            end: step.at + total_len(&step.inserted),
        };
        self.undo.push(step);
        Some(change)
    }

    /// Puts `long` in place of the long lines among lines
    /// `line..=line + removed`, moves those after on by the lines added,
    /// and gives back what was there.
    fn swap_long(
        &mut self,
        line: u64,
        removed: u64,
        added: u64,
        long: Vec<(u64, u64)>,
    ) -> Vec<(u64, u64)> {
        let a = self.long.partition_point(|&(l, _)| l < line);
        let b = self.long.partition_point(|&(l, _)| l <= line + removed);
        let count = long.len();
        let old: Vec<_> = self.long.splice(a..b, long).collect();
        for entry in &mut self.long[a + count..] {
            entry.0 = entry.0 + added - removed;
        }
        self.rebuild_extra();
        old
    }

    /// The long lines among those that bytes `start..end` are on, which
    /// starts at line `line`, reading only those bytes and the line's ends.
    fn long_lines_in(&self, start: u64, end: u64, line: u64) -> Vec<(u64, u64)> {
        let mut long = Vec::new();
        let (mut line, mut line_start) = (line, self.line_start(line));
        let mut at = start;
        while at < end {
            let to = (at + CHUNK).min(end);
            for i in memchr_iter(b'\n', &self.text.read(at, to)) {
                let newline = at + i as u64;
                if newline - line_start > ROW_BYTES {
                    long.push((line, newline - line_start));
                }
                line += 1;
                line_start = newline + 1;
            }
            at = to;
        }
        let len = self.line_end(line) - line_start;
        if len > ROW_BYTES {
            long.push((line, len));
        }
        long
    }

    // ---------------------------------------------------------------- files

    /// Whether the file has been changed by something else since it was
    /// opened or saved.
    pub fn changed_on_disk(&self) -> bool {
        match &self.path {
            Some(path) => Stamp::of(path) != self.stamp,
            None => false,
        }
    }

    /// Saves to `to`, or to the file it came from. Saving over a file that
    /// something else has changed fails unless `force` is set.
    pub fn save(&mut self, to: Option<&Path>, force: bool) -> Result<(), Error> {
        let job = self.save_job(to, force)?;
        job.write()?;
        self.saved(&job);
        Ok(())
    }

    /// Gets ready to save, as [`Document::save`] does, in three steps: this,
    /// which checks where to; [`SaveJob::write`], which needs no access to
    /// the document, so that editing can go on meanwhile; and
    /// [`Document::saved`].
    pub fn save_job(&self, to: Option<&Path>, force: bool) -> Result<SaveJob, Error> {
        let target = match to.or(self.path.as_deref()) {
            Some(path) => path.to_path_buf(),
            None => return Err(Error::Io("choose where to save the document".into())),
        };
        if !force && self.path.as_deref() == Some(target.as_path()) && self.changed_on_disk() {
            return Err(Error::Io(format!(
                "{} has been changed by another program since it was opened",
                target.display()
            )));
        }
        Ok(SaveJob {
            text: self.text.clone(),
            target,
            at: self.undo.last().map(|s| s.id),
        })
    }

    /// Takes note that `job` has been written.
    pub fn saved(&mut self, job: &SaveJob) {
        self.stamp = Stamp::of(&job.target);
        self.path = Some(job.target.clone());
        self.saved = job.at;
    }
}

/// The text of a document as it was when saving began, and where it goes.
pub struct SaveJob {
    text: Text,
    target: PathBuf,
    /// The undo step it was taken at.
    at: Option<u64>,
}

impl SaveJob {
    /// Writes the text beside the target and then moves it into place, so
    /// that a failure part way leaves the file as it was. The original is
    /// still read from the file as it was opened, which stays readable.
    ///
    /// Where nothing may be written beside the target, as in the macOS
    /// sandbox, which allows only the file chosen, the target is written
    /// over instead, by `write_over`.
    pub fn write(&self) -> Result<(), Error> {
        let target = &self.target;
        let failed = |e: io::Error| {
            Error::Io(format!(
                "{} could not be saved: {}",
                target.display(),
                crate::spill::io_problem(&e)
            ))
        };
        let name = target
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let temp = target.with_file_name(format!(".{name}.reqorb-{}", std::process::id()));
        let mut file = match File::create(&temp) {
            Ok(file) => file,
            Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
                return self.write_over().map_err(failed);
            }
            Err(e) => return Err(failed(e)),
        };
        let written = (|| {
            self.write_to(&mut file)?;
            if let Ok(meta) = fs::metadata(target) {
                fs::set_permissions(&temp, meta.permissions())?;
            }
            fs::rename(&temp, target)
        })();
        if written.is_err() {
            let _ = fs::remove_file(&temp);
        }
        written.map_err(failed)
    }

    /// Writes the text over the target in place. A failure part way leaves
    /// the file part written. If the document reads its original from the
    /// target, it is first given a copy to read instead.
    fn write_over(&self) -> io::Result<()> {
        let source = self.text.source();
        if source.reads(&self.target) {
            source.keep_original(&self.target)?;
        }
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .open(&self.target)?;
        self.write_to(&mut file)?;
        file.set_len(self.text.len())?;
        file.sync_all()
    }

    fn write_to(&self, file: &mut File) -> io::Result<()> {
        let mut at = 0;
        while at < self.text.len() {
            let to = (at + CHUNK).min(self.text.len());
            file.write_all(&self.text.read(at, to))?;
            at = to;
        }
        file.sync_all()
    }
}

impl Drop for Document {
    fn drop(&mut self) {
        self.index.stop();
    }
}

/// How many rows a line of `len` bytes takes.
fn parts(len: u64) -> u64 {
    len.div_ceil(ROW_BYTES).max(1)
}

/// How many UTF-16 code units `bytes` are as text, with anything not
/// UTF-8 counting as one `�` per run, as `from_utf8_lossy` makes it.
fn utf16_len(bytes: &[u8]) -> u32 {
    let mut len = 0;
    for chunk in bytes.utf8_chunks() {
        len += chunk.valid().encode_utf16().count() as u32;
        len += u32::from(!chunk.invalid().is_empty());
    }
    len
}

/// How many bytes of `bytes` the first `col` UTF-16 code units are. A
/// column inside a character counts as the start of it.
fn utf16_to_byte(bytes: &[u8], col: u32) -> u64 {
    let (mut units, mut at) = (0, 0);
    for chunk in bytes.utf8_chunks() {
        for ch in chunk.valid().chars() {
            if units + ch.len_utf16() as u32 > col {
                return at;
            }
            units += ch.len_utf16() as u32;
            at += ch.len_utf8() as u64;
        }
        if !chunk.invalid().is_empty() {
            if units + 1 > col {
                return at;
            }
            units += 1;
            at += chunk.invalid().len() as u64;
        }
    }
    at
}

pub(super) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

pub(super) fn read_lock<T>(lock: &RwLock<T>) -> RwLockReadGuard<'_, T> {
    lock.read().unwrap_or_else(PoisonError::into_inner)
}

pub(super) fn write_lock<T>(lock: &RwLock<T>) -> RwLockWriteGuard<'_, T> {
    lock.write().unwrap_or_else(PoisonError::into_inner)
}
