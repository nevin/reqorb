//! Where the newlines are, counted every few kilobytes: enough to find any
//! line of a gigabyte quickly while keeping little of it in memory.

use std::sync::{Arc, Condvar, Mutex};

use memchr::memchr_iter;

use super::source::Source;
use super::{ROW_BYTES, lock};

/// Bytes that can be read in the steps their newlines are counted in.
pub(super) trait Pages {
    fn step(&self) -> u64;
    /// Runs `f` on step `n`, which is short only at the end.
    fn with_step<R>(&self, n: u64, f: impl FnOnce(&[u8]) -> R) -> R;
}

/// Bytes held whole.
pub(super) struct Slice<'a> {
    pub(super) bytes: &'a [u8],
    pub(super) step: u64,
}

impl Pages for Slice<'_> {
    fn step(&self) -> u64 {
        self.step
    }

    fn with_step<R>(&self, n: u64, f: impl FnOnce(&[u8]) -> R) -> R {
        let start = ((n * self.step) as usize).min(self.bytes.len());
        let end = (start + self.step as usize).min(self.bytes.len());
        f(&self.bytes[start..end])
    }
}

/// How many newlines come before each step of some bytes that only ever
/// grow at the end.
#[derive(Clone, Default, Debug)]
pub(super) struct Lines {
    before: Vec<u64>,
    total: u64,
    len: u64,
}

impl Lines {
    /// Takes note of `bytes` added at the end.
    pub(super) fn push(&mut self, bytes: &[u8], step: u64) {
        let mut rest = bytes;
        while !rest.is_empty() {
            if self.len.is_multiple_of(step) {
                self.before.push(self.total);
            }
            let room = (step - self.len % step) as usize;
            let (now, later) = rest.split_at(room.min(rest.len()));
            self.total += memchr_iter(b'\n', now).count() as u64;
            self.len += now.len() as u64;
            rest = later;
        }
    }

    /// Takes note of a whole step added at the end, already counted.
    fn push_step(&mut self, newlines: u64, len: u64) {
        self.before.push(self.total);
        self.total += newlines;
        self.len += len;
    }

    /// How many newlines there are in all.
    pub(super) fn total(&self) -> u64 {
        self.total
    }

    /// How many bytes have been counted.
    pub(super) fn len(&self) -> u64 {
        self.len
    }

    /// How many newlines there are in bytes `0..at`, reading at most a step.
    pub(super) fn count_before(&self, pages: &impl Pages, at: u64) -> u64 {
        if at >= self.len {
            return self.total;
        }
        let n = at / pages.step();
        let within = (at % pages.step()) as usize;
        self.before[n as usize]
            + pages.with_step(n, |p| memchr_iter(b'\n', &p[..within]).count() as u64)
    }

    /// Where newline `k` is, counted from 0, reading one step.
    pub(super) fn find(&self, pages: &impl Pages, k: u64) -> Option<u64> {
        if k >= self.total {
            return None;
        }
        // The last step with no more than `k` newlines before it holds it.
        let n = self.before.partition_point(|&b| b <= k) - 1;
        let skip = (k - self.before[n]) as usize;
        pages
            .with_step(n as u64, |p| memchr_iter(b'\n', p).nth(skip))
            .map(|i| n as u64 * pages.step() + i as u64)
    }
}

/// What is known so far of an original's lines.
#[derive(Clone, Default)]
pub(super) struct Indexed {
    pub(super) lines: Lines,
    /// The lines longer than a row, as (line, length in bytes).
    pub(super) long: Vec<(u64, u64)>,
    pub(super) done: bool,
}

/// The lines of an original, found on a thread of their own for a file,
/// so that its start can be shown while the rest is still being read.
pub(super) struct Index {
    state: Mutex<(Indexed, bool)>,
    changed: Condvar,
}

/// Pages counted between telling anyone how far it has got.
const BATCH: u64 = 256;

impl Index {
    /// Indexes `source`, in the background when `background` is set.
    pub(super) fn build(source: Arc<Source>, background: bool) -> Arc<Self> {
        let index = Arc::new(Self {
            state: Mutex::default(),
            changed: Condvar::new(),
        });
        if background {
            let building = index.clone();
            std::thread::Builder::new()
                .name("reqorb-index".into())
                .spawn(move || building.run(&source))
                .ok();
        } else {
            index.run(&source);
        }
        index
    }

    fn run(&self, source: &Source) {
        let (page, step) = (source.page_size(), source.step());
        let pages = source.len().div_ceil(page);
        let (mut line, mut line_start) = (0u64, 0u64);
        let mut counted = Vec::new();
        let mut long = Vec::new();
        for n in 0..pages {
            source.with_page_uncached(n, |bytes| {
                for (k, part) in bytes.chunks(step as usize).enumerate() {
                    let first = n * page + k as u64 * step;
                    let before = line;
                    for i in memchr_iter(b'\n', part) {
                        let at = first + i as u64;
                        if at - line_start > ROW_BYTES {
                            long.push((line, at - line_start));
                        }
                        line += 1;
                        line_start = at + 1;
                    }
                    counted.push((line - before, part.len() as u64));
                }
            });
            let last = n + 1 == pages;
            if last && source.len() - line_start > ROW_BYTES {
                long.push((line, source.len() - line_start));
            }
            // The first page is told at once, so that it can be shown.
            if n == 0 || (n + 1) % BATCH == 0 || last {
                let mut state = lock(&self.state);
                if state.1 {
                    return;
                }
                for (newlines, len) in counted.drain(..) {
                    state.0.lines.push_step(newlines, len);
                }
                state.0.long.append(&mut long);
                state.0.done = last;
                self.changed.notify_all();
            }
        }
        let mut state = lock(&self.state);
        state.0.done = true;
        self.changed.notify_all();
    }

    /// What has been found so far.
    pub(super) fn indexed(&self) -> Indexed {
        lock(&self.state).0.clone()
    }

    /// How far it has got, without copying what it found.
    pub(super) fn progress(&self) -> (u64, bool) {
        let state = lock(&self.state);
        (state.0.lines.len(), state.0.done)
    }

    /// Waits until every line is known, or with `started`, until the
    /// lines of the first page are.
    pub(super) fn wait(&self, started: bool) {
        let mut state = lock(&self.state);
        while !state.0.done && !state.1 && !(started && state.0.lines.len() > 0) {
            state = self
                .changed
                .wait(state)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
        }
    }

    /// Stops the work, for a document that has been closed.
    pub(super) fn stop(&self) {
        lock(&self.state).1 = true;
        self.changed.notify_all();
    }
}
