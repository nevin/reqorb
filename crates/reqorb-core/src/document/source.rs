//! Where a document's original bytes come from: memory, or a file read a
//! page at a time and never held whole.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use super::index::Pages;
use super::{lock, read_lock, write_lock};

/// How much of a file is kept in memory at once, at most.
const CACHE_BYTES: u64 = 64 * 1024 * 1024;

/// How often newlines are counted. Finding a line reads at most this much.
const STEP: u64 = 4 * 1024;

pub(super) struct Source {
    bytes: Bytes,
    len: u64,
    /// The size of the pages the bytes are read in.
    page: u64,
    /// How often newlines are counted: a whole number of steps fit a page.
    step: u64,
    /// Why part of the file could not be read, if it could not.
    problem: Mutex<Option<String>>,
}

enum Bytes {
    Memory(Vec<u8>),
    File {
        file: RwLock<Held>,
        cache: Mutex<Cache>,
    },
}

/// The file the bytes are read from: the one opened, or a copy of it kept
/// before that one was written over.
struct Held {
    file: File,
    /// The copy's path, deleted when it is no longer read.
    copy: Option<PathBuf>,
}

impl Drop for Held {
    fn drop(&mut self) {
        if let Some(copy) = &self.copy {
            let _ = fs::remove_file(copy);
        }
    }
}

/// The pages read most recently, each with when it was last used.
#[derive(Default)]
struct Cache {
    pages: HashMap<u64, (Arc<[u8]>, u64)>,
    tick: u64,
}

impl Source {
    pub(super) fn memory(bytes: Vec<u8>, page: u64) -> Self {
        Self {
            len: bytes.len() as u64,
            bytes: Bytes::Memory(bytes),
            page,
            step: STEP.min(page),
            problem: Mutex::default(),
        }
    }

    pub(super) fn file(file: File, len: u64, page: u64) -> Self {
        Self {
            bytes: Bytes::File {
                file: RwLock::new(Held { file, copy: None }),
                cache: Mutex::default(),
            },
            len,
            page,
            step: STEP.min(page),
            problem: Mutex::default(),
        }
    }

    pub(super) fn len(&self) -> u64 {
        self.len
    }

    pub(super) fn page_size(&self) -> u64 {
        self.page
    }

    /// Why part of the file could not be read. What could not be read
    /// reads as zero bytes, so that everything after it stays in place.
    pub(super) fn problem(&self) -> Option<String> {
        lock(&self.problem).clone()
    }

    /// Runs `f` on page `n` read straight from the file, for a pass over
    /// all of it that would only push everything else out of the cache.
    pub(super) fn with_page_uncached<R>(&self, n: u64, f: impl FnOnce(&[u8]) -> R) -> R {
        match &self.bytes {
            Bytes::Memory(bytes) => f(&bytes[self.page_range(n)]),
            Bytes::File { file, .. } => f(&self.read_page(&read_lock(file).file, n)),
        }
    }

    /// Appends bytes `start..end` to `out`.
    pub(super) fn read(&self, start: u64, end: u64, out: &mut Vec<u8>) {
        let end = end.min(self.len);
        if let Bytes::Memory(bytes) = &self.bytes {
            if start < end {
                out.extend_from_slice(&bytes[start as usize..end as usize]);
            }
            return;
        }
        let mut at = start;
        while at < end {
            let n = at / self.page;
            let first = n * self.page;
            self.with_page(n, |page| {
                let to = (end - first).min(page.len() as u64);
                out.extend_from_slice(&page[(at - first) as usize..to as usize]);
            });
            at = first + self.page;
        }
    }

    fn page_range(&self, n: u64) -> Range<usize> {
        let start = (n * self.page).min(self.len);
        let end = (start + self.page).min(self.len);
        start as usize..end as usize
    }

    fn read_page(&self, file: &File, n: u64) -> Vec<u8> {
        let range = self.page_range(n);
        let mut buf = vec![0; range.len()];
        if let Err(e) = read_at(file, &mut buf, range.start as u64) {
            lock(&self.problem)
                .get_or_insert_with(|| format!("part of the file could not be read: {e}"));
        }
        buf
    }

    fn cached(&self, file: &RwLock<Held>, cache: &Mutex<Cache>, n: u64) -> Arc<[u8]> {
        let mut cache = lock(cache);
        cache.tick += 1;
        let tick = cache.tick;
        if let Some((page, used)) = cache.pages.get_mut(&n) {
            *used = tick;
            return page.clone();
        }
        let page: Arc<[u8]> = self.read_page(&read_lock(file).file, n).into();
        if cache.pages.len() as u64 >= (CACHE_BYTES / self.page).max(1) {
            let oldest = cache.pages.iter().min_by_key(|(_, (_, used))| *used);
            if let Some(&oldest) = oldest.map(|(n, _)| n) {
                cache.pages.remove(&oldest);
            }
        }
        cache.pages.insert(n, (page.clone(), tick));
        page
    }
}

impl Source {
    /// Whether the bytes are read from the file at `path` as it is now, so
    /// that writing over it would change them.
    pub(super) fn reads(&self, path: &Path) -> bool {
        let Bytes::File { file, .. } = &self.bytes else {
            return false;
        };
        match (read_lock(file).file.metadata(), fs::metadata(path)) {
            (Ok(held), Ok(there)) => same_file(&held, &there),
            _ => false,
        }
    }

    /// Copies the file at `path`, which this reads, and reads the copy from
    /// now on, so that the file can be written over. The copy is deleted
    /// when the document is.
    pub(super) fn keep_original(&self, path: &Path) -> io::Result<()> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let Bytes::File { file, .. } = &self.bytes else {
            return Ok(());
        };
        let copy = std::env::temp_dir().join(format!(
            "reqorb-original-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        // Held while copying, so that nothing reads the file meanwhile.
        let mut held = write_lock(file);
        let kept = (|| {
            // On APFS this clones the file, taking no time or space.
            fs::copy(path, &copy)?;
            let opened = File::open(&copy)?;
            if opened.metadata()?.len() != self.len {
                return Err(io::Error::other("the copy came out a different size"));
            }
            Ok(opened)
        })();
        match kept {
            Ok(opened) => {
                *held = Held {
                    file: opened,
                    copy: Some(copy),
                };
                Ok(())
            }
            Err(e) => {
                let _ = fs::remove_file(&copy);
                Err(e)
            }
        }
    }

    /// Runs `f` on page `n`, which is short only at the end.
    fn with_page<R>(&self, n: u64, f: impl FnOnce(&[u8]) -> R) -> R {
        match &self.bytes {
            Bytes::Memory(bytes) => f(&bytes[self.page_range(n)]),
            Bytes::File { file, cache } => f(&self.cached(file, cache, n)),
        }
    }
}

impl Pages for Source {
    fn step(&self) -> u64 {
        self.step
    }

    fn with_step<R>(&self, n: u64, f: impl FnOnce(&[u8]) -> R) -> R {
        let at = n * self.step;
        let first = at / self.page * self.page;
        self.with_page(at / self.page, |page| {
            let from = ((at - first) as usize).min(page.len());
            f(&page[from..(from + self.step as usize).min(page.len())])
        })
    }
}

#[cfg(unix)]
fn same_file(a: &fs::Metadata, b: &fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    a.dev() == b.dev() && a.ino() == b.ino()
}

/// Without a file's identity, the same size and times will do; a file
/// written over since shows a later time.
#[cfg(not(unix))]
fn same_file(a: &fs::Metadata, b: &fs::Metadata) -> bool {
    a.len() == b.len()
        && a.modified().ok() == b.modified().ok()
        && a.created().ok() == b.created().ok()
}

#[cfg(unix)]
fn read_at(file: &File, buf: &mut [u8], offset: u64) -> std::io::Result<()> {
    use std::os::unix::fs::FileExt;
    file.read_exact_at(buf, offset)
}

#[cfg(windows)]
fn read_at(file: &File, buf: &mut [u8], offset: u64) -> std::io::Result<()> {
    use std::os::windows::fs::FileExt;
    let mut done = 0;
    while done < buf.len() {
        match file.seek_read(&mut buf[done..], offset + done as u64)? {
            0 => return Err(std::io::ErrorKind::UnexpectedEof.into()),
            n => done += n,
        }
    }
    Ok(())
}
