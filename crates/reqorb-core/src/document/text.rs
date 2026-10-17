//! The text of a document now: pieces of the original and of the text
//! added since, in order. An edit changes which pieces there are, never
//! the bytes they point at, so undoing one copies no text and a copy of
//! the whole can be searched while editing goes on.

use std::sync::{Arc, RwLock};

use memchr::memchr_iter;

use super::index::{Lines, Pages, Slice};
use super::source::Source;
use super::{read_lock, write_lock};

/// A run of bytes from the original or from the added text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Piece {
    pub(super) added: bool,
    pub(super) start: u64,
    pub(super) len: u64,
    pub(super) newlines: u64,
}

/// Everything typed or pasted into a document, only ever added to.
#[derive(Default)]
pub(super) struct Added {
    bytes: Vec<u8>,
    lines: Lines,
}

#[derive(Clone)]
pub(super) struct Text {
    source: Arc<Source>,
    /// The original's newlines, as far as they are known.
    lines: Arc<Lines>,
    added: Arc<RwLock<Added>>,
    pieces: Arc<Vec<Piece>>,
    /// Where each piece ends, in bytes and in newlines, from the start.
    ends: Arc<Vec<u64>>,
    newline_ends: Arc<Vec<u64>>,
}

impl Text {
    pub(super) fn new(source: Arc<Source>, lines: Lines) -> Self {
        let mut text = Self {
            source,
            lines: Arc::default(),
            added: Arc::default(),
            pieces: Arc::default(),
            ends: Arc::default(),
            newline_ends: Arc::default(),
        };
        let len = text.source.len();
        if len > 0 {
            text.set_pieces(vec![Piece {
                added: false,
                start: 0,
                len,
                newlines: 0,
            }]);
        }
        text.set_lines(lines);
        text
    }

    /// Takes in more of the original's newlines, as they are found. Only
    /// a document not yet edited is still being indexed.
    pub(super) fn set_lines(&mut self, lines: Lines) {
        let total = lines.total();
        self.lines = Arc::new(lines);
        if let [piece] = Arc::make_mut(&mut self.pieces).as_mut_slice() {
            piece.newlines = total;
            self.recount(0);
        }
    }

    pub(super) fn source(&self) -> &Source {
        &self.source
    }

    pub(super) fn len(&self) -> u64 {
        self.ends.last().copied().unwrap_or(0)
    }

    pub(super) fn newlines(&self) -> u64 {
        self.newline_ends.last().copied().unwrap_or(0)
    }

    pub(super) fn pieces(&self) -> &[Piece] {
        &self.pieces
    }

    fn start_of(&self, i: usize) -> u64 {
        if i == 0 { 0 } else { self.ends[i - 1] }
    }

    fn newlines_to(&self, i: usize) -> u64 {
        if i == 0 { 0 } else { self.newline_ends[i - 1] }
    }

    /// The piece holding byte `at`: the number of pieces when `at` is the end.
    fn piece_at(&self, at: u64) -> usize {
        self.ends.partition_point(|&e| e <= at)
    }

    /// Bytes `start..end`.
    pub(super) fn read(&self, start: u64, end: u64) -> Vec<u8> {
        let end = end.min(self.len());
        let mut out = Vec::with_capacity(end.saturating_sub(start) as usize);
        let mut at = start;
        let mut i = self.piece_at(start);
        while at < end {
            let p = self.pieces[i];
            let first = self.start_of(i);
            let (from, to) = (
                p.start + at - first,
                p.start + end.min(self.ends[i]) - first,
            );
            if p.added {
                out.extend_from_slice(&read_lock(&self.added).bytes[from as usize..to as usize]);
            } else {
                self.source.read(from, to, &mut out);
            }
            at = self.ends[i];
            i += 1;
        }
        out
    }

    /// How many newlines a piece's bytes `start..end` hold, by their
    /// offsets in its buffer.
    fn count(&self, added: bool, start: u64, end: u64) -> u64 {
        if added {
            let store = read_lock(&self.added);
            let slice = Slice {
                bytes: &store.bytes,
                step: self.source.step(),
            };
            store.lines.count_before(&slice, end) - store.lines.count_before(&slice, start)
        } else {
            self.lines.count_before(&*self.source, end)
                - self.lines.count_before(&*self.source, start)
        }
    }

    /// Where the `k`th newline from `start` is in a buffer.
    fn find(&self, added: bool, start: u64, k: u64) -> Option<u64> {
        if added {
            let store = read_lock(&self.added);
            let slice = Slice {
                bytes: &store.bytes,
                step: self.source.step(),
            };
            let before = store.lines.count_before(&slice, start);
            store.lines.find(&slice, before + k)
        } else {
            let before = self.lines.count_before(&*self.source, start);
            self.lines.find(&*self.source, before + k)
        }
    }

    /// How many newlines there are before byte `at`.
    pub(super) fn newlines_before(&self, at: u64) -> u64 {
        let i = self.piece_at(at);
        if i == self.pieces.len() {
            return self.newlines();
        }
        let p = self.pieces[i];
        self.newlines_to(i) + self.count(p.added, p.start, p.start + at - self.start_of(i))
    }

    /// Where newline `k` is, counted from 0.
    pub(super) fn newline_at(&self, k: u64) -> Option<u64> {
        let i = self.newline_ends.partition_point(|&e| e <= k);
        let p = *self.pieces.get(i)?;
        let at = self.find(p.added, p.start, k - self.newlines_to(i))?;
        Some(self.start_of(i) + at - p.start)
    }

    /// Bytes `from..to` of piece `p`, counted within it.
    fn cut(&self, p: Piece, from: u64, to: u64) -> Piece {
        let (start, end) = (p.start + from, p.start + to);
        Piece {
            added: p.added,
            start,
            len: to - from,
            newlines: if from == 0 && to == p.len {
                p.newlines
            } else {
                self.count(p.added, start, end)
            },
        }
    }

    /// The pieces making up bytes `start..end`.
    pub(super) fn pieces_in(&self, start: u64, end: u64) -> Vec<Piece> {
        let mut out = Vec::new();
        if start >= end {
            return out;
        }
        let mut i = self.piece_at(start);
        while i < self.pieces.len() && self.start_of(i) < end {
            let first = self.start_of(i);
            let p = self.pieces[i];
            let from = start.saturating_sub(first);
            let to = (end - first).min(p.len);
            out.push(self.cut(p, from, to));
            i += 1;
        }
        out
    }

    /// Puts `new` in place of bytes `start..end`, and gives back what was
    /// there.
    pub(super) fn splice(&mut self, start: u64, end: u64, new: &[Piece]) -> Vec<Piece> {
        let removed = self.pieces_in(start, end);
        let i = self.piece_at(start);
        let mut replacement = Vec::with_capacity(new.len() + 2);
        if i < self.pieces.len() && start > self.start_of(i) {
            replacement.push(self.cut(self.pieces[i], 0, start - self.start_of(i)));
        }
        replacement.extend(new.iter().copied().filter(|p| p.len > 0));
        let mut k = self.piece_at(end);
        if k < self.pieces.len() && end > self.start_of(k) {
            let p = self.pieces[k];
            replacement.push(self.cut(p, end - self.start_of(k), p.len));
            k += 1;
        }
        Arc::make_mut(&mut self.pieces).splice(i..k, replacement);
        self.recount(i);
        removed
    }

    /// Makes the text these pieces.
    pub(super) fn set_pieces(&mut self, pieces: Vec<Piece>) {
        self.pieces = Arc::new(pieces);
        self.recount(0);
    }

    /// Adds `bytes` to the added text, as a piece not yet placed.
    pub(super) fn append(&self, bytes: &[u8]) -> Piece {
        let mut store = write_lock(&self.added);
        let start = store.bytes.len() as u64;
        let newlines = store.lines.total();
        store.bytes.extend_from_slice(bytes);
        store.lines.push(bytes, self.source.step());
        Piece {
            added: true,
            start,
            len: bytes.len() as u64,
            newlines: store.lines.total() - newlines,
        }
    }

    /// Adds `bytes` to the end of the added piece `p` that ends at `at`,
    /// as typing does, when nothing has been added after it.
    pub(super) fn extend(&mut self, at: u64, p: Piece, bytes: &[u8]) -> bool {
        let i = self.ends.partition_point(|&e| e < at);
        let Some(&q) = self.pieces.get(i) else {
            return false;
        };
        let end = p.start + p.len;
        if !q.added || self.ends[i] != at || q.start + q.len != end {
            return false;
        }
        {
            let mut store = write_lock(&self.added);
            if store.bytes.len() as u64 != end {
                return false;
            }
            store.bytes.extend_from_slice(bytes);
            store.lines.push(bytes, self.source.step());
        }
        let piece = &mut Arc::make_mut(&mut self.pieces)[i];
        piece.len += bytes.len() as u64;
        piece.newlines += memchr_iter(b'\n', bytes).count() as u64;
        self.recount(i);
        true
    }

    /// Works out where the pieces end, from piece `from` on.
    fn recount(&mut self, from: usize) {
        let ends = Arc::make_mut(&mut self.ends);
        let newline_ends = Arc::make_mut(&mut self.newline_ends);
        ends.truncate(from);
        newline_ends.truncate(from);
        let (mut end, mut newlines) = (
            ends.last().copied().unwrap_or(0),
            newline_ends.last().copied().unwrap_or(0),
        );
        for p in &self.pieces[from..] {
            end += p.len;
            newlines += p.newlines;
            ends.push(end);
            newline_ends.push(newlines);
        }
    }
}
