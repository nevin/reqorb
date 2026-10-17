//! Documents of any size for the editor. They are held here, and Dart
//! reaches each by its number, as it does sends and sockets. Calls made on
//! every frame are sync; opening, saving and searching are not, and none
//! of them holds a document while it reads or writes a whole file.

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard, PoisonError};

use flutter_rust_bridge::frb;
use reqorb_core::Document;

use crate::frb_generated::StreamSink;

type Shared = Arc<Mutex<Document>>;

static DOCS: LazyLock<Mutex<HashMap<u32, Shared>>> = LazyLock::new(Default::default);
static NEXT: AtomicU32 = AtomicU32::new(1);

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn keep(doc: Document) -> u32 {
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    lock(&DOCS).insert(id, Arc::new(Mutex::new(doc)));
    id
}

fn shared(id: u32) -> Result<Shared, String> {
    lock(&DOCS)
        .get(&id)
        .cloned()
        .ok_or_else(|| "the document has been closed".to_string())
}

/// Runs `f` on document `id`, or gives `missing` if it has been closed.
fn with<R>(id: u32, missing: R, f: impl FnOnce(&mut Document) -> R) -> R {
    match shared(id) {
        Ok(doc) => f(&mut lock(&doc)),
        Err(_) => missing,
    }
}

/// A new document holding `text`, not saved anywhere.
#[frb(sync)]
pub fn doc_from_text(text: String) -> u32 {
    keep(Document::from_text(&text))
}

/// Opens a file. Its first page is ready when this returns; the rest of
/// its lines are found in the background, as [`doc_info`] tells.
pub fn doc_open(path: String) -> Result<u32, String> {
    Document::open(Path::new(&path))
        .map(keep)
        .map_err(|e| e.to_string())
}

/// Lets go of a document.
#[frb(sync)]
pub fn doc_close(id: u32) {
    lock(&DOCS).remove(&id);
}

/// What the editor needs to know about a document on each frame.
#[derive(Debug, Clone, Default)]
pub struct DocInfo {
    pub len: u64,
    pub line_count: u64,
    pub row_count: u64,
    /// Changes with every edit, undo and redo, and as lines are found.
    pub version: u64,
    pub modified: bool,
    pub can_undo: bool,
    pub can_redo: bool,
    /// How many bytes' lines are known so far, until all of them are.
    pub indexed: u64,
    pub indexing_done: bool,
    pub path: Option<String>,
    /// Why part of the file could not be read, if it could not.
    pub problem: Option<String>,
}

/// Takes in the lines found since last asked, and tells about the document.
#[frb(sync)]
pub fn doc_info(id: u32) -> DocInfo {
    with(id, DocInfo::default(), |doc| {
        let indexing = doc.indexing();
        DocInfo {
            len: doc.len(),
            line_count: doc.line_count(),
            row_count: doc.row_count(),
            version: doc.version(),
            modified: doc.is_modified(),
            can_undo: doc.can_undo(),
            can_redo: doc.can_redo(),
            indexed: indexing.indexed,
            indexing_done: indexing.done,
            path: doc.path().map(|p| p.display().to_string()),
            problem: doc.problem(),
        }
    })
}

/// Whether the start of the document holds a NUL, as binary files do.
#[frb(sync)]
pub fn doc_looks_binary(id: u32) -> bool {
    with(id, false, |doc| doc.looks_binary())
}

/// One row of a document as shown.
#[derive(Debug, Clone)]
pub struct DocRow {
    pub line: u64,
    /// Which row of a long line it is, counted from 0.
    pub segment: u32,
    pub start: u64,
    pub end: u64,
    pub text: String,
}

/// Up to `count` rows from row `first`.
#[frb(sync)]
pub fn doc_rows(id: u32, first: u64, count: u32) -> Vec<DocRow> {
    with(id, Vec::new(), |doc| {
        doc.rows(first, count as usize)
            .into_iter()
            .map(|r| DocRow {
                line: r.line,
                segment: r.part,
                start: r.start,
                end: r.end,
                text: r.text,
            })
            .collect()
    })
}

/// A row and a column within it, counted in UTF-16 units.
#[derive(Debug, Clone, Copy)]
pub struct DocPosition {
    pub row: u64,
    pub col: u32,
}

/// Where byte `offset` is shown.
#[frb(sync)]
pub fn doc_position(id: u32, offset: u64) -> DocPosition {
    with(id, DocPosition { row: 0, col: 0 }, |doc| {
        let (row, col) = doc.position_of(offset);
        DocPosition { row, col }
    })
}

/// The byte shown at column `col` of row `row`.
#[frb(sync)]
pub fn doc_offset(id: u32, row: u64, col: u32) -> u64 {
    with(id, 0, |doc| doc.offset_of(row, col))
}

/// The first row of line `line`.
#[frb(sync)]
pub fn doc_row_of_line(id: u32, line: u64) -> u64 {
    with(id, 0, |doc| doc.row_of_line(line))
}

/// A run of bytes.
#[derive(Debug, Clone, Copy)]
pub struct DocSpan {
    pub start: u64,
    pub end: u64,
}

/// Where line `line` starts and ends, before its line break.
#[frb(sync)]
pub fn doc_line_span(id: u32, line: u64) -> DocSpan {
    with(id, DocSpan { start: 0, end: 0 }, |doc| DocSpan {
        start: doc.line_start(line),
        end: doc.line_end(line),
    })
}

/// The line byte `offset` is on.
#[frb(sync)]
pub fn doc_line_of(id: u32, offset: u64) -> u64 {
    with(id, 0, |doc| doc.line_of(offset))
}

/// Bytes `start..end` as text.
#[frb(sync)]
pub fn doc_text(id: u32, start: u64, end: u64) -> String {
    with(id, String::new(), |doc| doc.text(start, end))
}

/// Puts `text` in place of bytes `start..end`. With `typing`, text that
/// carries straight on from the last edit joins it as one step of undo.
#[frb(sync)]
pub fn doc_replace(id: u32, start: u64, end: u64, text: String, typing: bool) {
    with(id, (), |doc| doc.replace(start, end, &text, typing));
}

/// Puts `text` in place of every one of `spans`, in order, as one step.
pub fn doc_replace_all(id: u32, spans: Vec<DocSpan>, text: String) {
    let ranges: Vec<_> = spans.iter().map(|s| (s.start, s.end)).collect();
    with(id, (), |doc| doc.replace_all(&ranges, &text));
}

/// Undoes the last edit, and gives the bytes it changed.
#[frb(sync)]
pub fn doc_undo(id: u32) -> Option<DocSpan> {
    with(id, None, |doc| doc.undo()).map(|c| DocSpan {
        start: c.start,
        end: c.end,
    })
}

/// Does again the last edit undone, and gives the bytes it changed.
#[frb(sync)]
pub fn doc_redo(id: u32) -> Option<DocSpan> {
    with(id, None, |doc| doc.redo()).map(|c| DocSpan {
        start: c.start,
        end: c.end,
    })
}

/// Whether the file has been changed by something else since it was
/// opened or saved.
#[frb(sync)]
pub fn doc_changed_on_disk(id: u32) -> bool {
    with(id, false, |doc| doc.changed_on_disk())
}

/// Saves to `path`, or to the file the document came from. The text is
/// written as it was when this was called; edits made meanwhile are kept
/// and still count as unsaved.
pub fn doc_save(id: u32, path: Option<String>, force: bool) -> Result<(), String> {
    let doc = shared(id)?;
    let job = lock(&doc)
        .save_job(path.as_deref().map(Path::new), force)
        .map_err(|e| e.to_string())?;
    job.write().map_err(|e| e.to_string())?;
    lock(&doc).saved(&job);
    Ok(())
}

/// What to look for.
#[derive(Debug, Clone, Default)]
pub struct DocQuery {
    pub text: String,
    pub regex: bool,
    pub case_sensitive: bool,
    pub whole_word: bool,
}

/// News of a search: matches found since the last, how far it has got,
/// and in the last one, how many there are in all or why it failed.
#[derive(Debug, Clone, Default)]
pub struct DocSearchUpdate {
    pub found: Vec<DocSpan>,
    pub searched: u64,
    pub done: bool,
    pub count: u64,
    pub error: Option<String>,
}

static SEARCHES: LazyLock<Mutex<HashMap<u32, Arc<AtomicBool>>>> = LazyLock::new(Default::default);

/// Searches document `id` as it is now, reporting matches as they are
/// found. [`doc_cancel_search`] with `search` stops it.
pub fn doc_search(id: u32, search: u32, query: DocQuery, sink: StreamSink<DocSearchUpdate>) {
    let snapshot = match shared(id) {
        Ok(doc) => lock(&doc).snapshot(),
        Err(e) => {
            let _ = sink.add(DocSearchUpdate {
                done: true,
                error: Some(e),
                ..Default::default()
            });
            return;
        }
    };
    let cancel = Arc::new(AtomicBool::new(false));
    lock(&SEARCHES).insert(search, cancel.clone());
    let query = reqorb_core::Query {
        text: query.text,
        regex: query.regex,
        case_sensitive: query.case_sensitive,
        whole_word: query.whole_word,
    };
    let spans = |ranges: &[(u64, u64)]| {
        ranges
            .iter()
            .map(|&(start, end)| DocSpan { start, end })
            .collect::<Vec<_>>()
    };
    let result = snapshot.search(&query, &cancel, |found, searched| {
        let _ = sink.add(DocSearchUpdate {
            found: spans(found),
            searched,
            ..Default::default()
        });
    });
    lock(&SEARCHES).remove(&search);
    let _ = sink.add(match result {
        Ok(found) => DocSearchUpdate {
            searched: snapshot.len(),
            done: true,
            count: found.count,
            ..Default::default()
        },
        Err(e) => DocSearchUpdate {
            done: true,
            error: Some(e.to_string()),
            ..Default::default()
        },
    });
}

/// Stops search `search`, if it is still going.
#[frb(sync)]
pub fn doc_cancel_search(search: u32) -> bool {
    lock(&SEARCHES)
        .get(&search)
        .map(|cancel| cancel.store(true, Ordering::Relaxed))
        .is_some()
}
