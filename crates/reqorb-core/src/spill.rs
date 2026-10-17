//! Response bodies too big to hold in memory, written to files as they
//! arrive. A [`crate::Response`] with a `body_file` keeps only the start of
//! its body as text; the whole of it is in the file.
//!
//! The files are kept in a folder of their own in the system's temporary
//! folder. Only the most recent few are kept, and [`clean_spilled`]
//! removes all of them, as the app does when it starts.

use std::borrow::Cow;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::{Error, Response};

/// Bodies larger than this are written to a file.
pub const SPILL_BYTES: u64 = 16 * 1024 * 1024;

/// How much of a body written to a file is kept in memory, as text.
pub const PREVIEW_BYTES: usize = 1024 * 1024;

/// The largest body read back whole: for tests, captures and scripts,
/// which need all of it at once.
pub const READ_LIMIT: u64 = 256 * 1024 * 1024;

/// How many bodies are kept on disk at once. Older ones are deleted as
/// new ones are written.
const KEPT: usize = 8;

/// Where the bodies go.
pub fn spill_dir() -> PathBuf {
    std::env::temp_dir().join("reqorb-bodies")
}

/// Deletes every body written to a file, as nothing refers to them once
/// the app that wrote them has quit.
pub fn clean_spilled() {
    let _ = fs::remove_dir_all(spill_dir());
}

/// A new file for a body, after deleting all but the most recent of the
/// others.
fn create() -> io::Result<(File, PathBuf)> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let dir = spill_dir();
    fs::create_dir_all(&dir)?;
    let mut old: Vec<_> = fs::read_dir(&dir)?
        .filter_map(Result::ok)
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    if old.len() >= KEPT {
        old.sort();
        for (_, path) in &old[..=old.len() - KEPT] {
            let _ = fs::remove_file(path);
        }
    }
    let path = dir.join(format!(
        "body-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    Ok((File::create(&path)?, path))
}

/// Takes in a body as it arrives: in memory until it passes
/// [`SPILL_BYTES`], then in a file, keeping only its start in memory.
#[derive(Default)]
pub(crate) struct BodySink {
    bytes: Vec<u8>,
    file: Option<(File, PathBuf)>,
    len: u64,
}

impl BodySink {
    pub(crate) fn push(&mut self, chunk: &[u8]) -> Result<(), Error> {
        self.len += chunk.len() as u64;
        let failed = |e: io::Error| Error::Io(format!("the response could not be saved: {e}"));
        if let Some((file, _)) = &mut self.file {
            return file.write_all(chunk).map_err(failed);
        }
        self.bytes.extend_from_slice(chunk);
        if self.len > SPILL_BYTES {
            let (mut file, path) = create().map_err(failed)?;
            file.write_all(&self.bytes).map_err(failed)?;
            self.bytes.truncate(PREVIEW_BYTES);
            self.bytes.shrink_to_fit();
            self.file = Some((file, path));
        }
        Ok(())
    }

    pub(crate) fn len(&self) -> u64 {
        self.len
    }

    pub(crate) fn spilled(&self) -> bool {
        self.file.is_some()
    }

    /// The bytes held, all of the body or its start, and the file with
    /// all of it, if there is one.
    pub(crate) fn finish(self) -> Result<(Vec<u8>, Option<String>), Error> {
        match self.file {
            None => Ok((self.bytes, None)),
            Some((file, path)) => {
                file.sync_all()
                    .map_err(|e| Error::Io(format!("the response could not be saved: {e}")))?;
                Ok((self.bytes, Some(path.display().to_string())))
            }
        }
    }
}

/// The text of `bytes`, the start of a body, cut back to the last whole
/// character.
pub(crate) fn preview(bytes: &[u8]) -> String {
    let end = match std::str::from_utf8(bytes) {
        Ok(_) => bytes.len(),
        Err(e) if e.error_len().is_none() => e.valid_up_to(),
        Err(_) => bytes.len(),
    };
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

/// Reads a body written to a file, if it is not too big to hold.
pub fn read_spilled(path: &Path) -> Result<String, Error> {
    let len = fs::metadata(path)
        .map_err(|e| Error::Io(format!("the response body could not be read: {e}")))?
        .len();
    if len > READ_LIMIT {
        return Err(Error::Io(format!(
            "the response body is {} MB, too large to read whole (at most {} MB)",
            len.div_ceil(1024 * 1024),
            READ_LIMIT / (1024 * 1024)
        )));
    }
    let bytes = fs::read(path)
        .map_err(|e| Error::Io(format!("the response body could not be read: {e}")))?;
    Ok(match String::from_utf8(bytes) {
        Ok(text) => text,
        Err(e) => String::from_utf8_lossy(e.as_bytes()).into_owned(),
    })
}

impl Response {
    /// All of the body as text, read from its file if it was written to
    /// one. Fails for a body too big to read whole.
    pub fn full_body(&self) -> Result<Cow<'_, str>, Error> {
        match &self.body_file {
            None => Ok(Cow::Borrowed(&self.body)),
            Some(path) => read_spilled(Path::new(path)).map(Cow::Owned),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_body_past_the_limit_goes_to_a_file() {
        let mut sink = BodySink::default();
        let chunk = vec![b'a'; 1024 * 1024];
        for _ in 0..16 {
            sink.push(&chunk).unwrap();
        }
        assert!(!sink.spilled());
        sink.push("é".as_bytes()).unwrap();
        sink.push(b"end").unwrap();
        assert!(sink.spilled());
        assert_eq!(sink.len(), SPILL_BYTES + 5);
        let (start, file) = sink.finish().unwrap();
        assert_eq!(start.len(), PREVIEW_BYTES);
        let file = file.unwrap();
        let written = fs::read(&file).unwrap();
        assert_eq!(written.len() as u64, SPILL_BYTES + 5);
        assert!(written.ends_with("éend".as_bytes()));
        let response = Response {
            body_file: Some(file.clone()),
            ..Response::default()
        };
        assert!(response.full_body().unwrap().ends_with("éend"));
        fs::remove_file(file).unwrap();
    }

    #[test]
    fn a_preview_ends_on_a_whole_character() {
        let bytes = "aé".as_bytes();
        assert_eq!(preview(&bytes[..2]), "a");
        assert_eq!(preview(bytes), "aé");
        assert_eq!(preview(&[b'a', 0xff, b'b']), "a\u{fffd}b");
    }
}
