//! Response bodies too big to hold in memory, written to files as they
//! arrive. A [`crate::Response`] with a `body_file` keeps only the start of
//! its body as text; the whole of it is in the file.
//!
//! The files are kept in a folder of their own, readable by this user
//! alone (see [`private_dir`]). Only the most recent few are kept, and
//! [`clean_spilled`] removes all of them, as the app does when it starts.

use std::borrow::Cow;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::{Error, Response};

/// Bodies larger than this are written to a file, unless
/// [`set_spill_bytes`] says otherwise.
pub const SPILL_BYTES: u64 = 16 * 1024 * 1024;

static SPILL_AT: AtomicU64 = AtomicU64::new(SPILL_BYTES);

/// Sets how large a body is held in memory before it goes to a file: less
/// on a device with little memory.
pub fn set_spill_bytes(bytes: u64) {
    SPILL_AT.store(bytes.max(PREVIEW_BYTES as u64), Ordering::Relaxed);
}

/// How large a body is held in memory before it goes to a file.
pub fn spill_bytes() -> u64 {
    SPILL_AT.load(Ordering::Relaxed)
}

/// What went wrong reading or writing a file, put plainly when the disk
/// is full.
pub fn io_problem(e: &io::Error) -> String {
    if e.kind() == io::ErrorKind::StorageFull {
        "there is not enough free space on the disk".into()
    } else {
        e.to_string()
    }
}

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
    private_dir("reqorb-bodies")
}

/// Where a copy of a file being written over is kept, while a document
/// still reads it.
pub(crate) fn originals_dir() -> PathBuf {
    private_dir("reqorb-originals")
}

/// Deletes every body written to a file, as nothing refers to them once
/// the app that wrote them has quit, and any copy of an original left by
/// an app that stopped without deleting it. A copy still open elsewhere
/// is read through its open file, which deleting it leaves readable.
pub fn clean_spilled() {
    let _ = fs::remove_dir_all(spill_dir());
    let _ = fs::remove_dir_all(originals_dir());
}

/// A new file in [`spill_dir`], for a body or for a document written out
/// again, after deleting all but the most recent of the others.
pub fn new_spill_file() -> io::Result<(File, PathBuf)> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let dir = spill_dir();
    if let Ok(entries) = fs::read_dir(&dir) {
        let mut old: Vec<_> = entries
            .filter_map(Result::ok)
            .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
            .collect();
        if old.len() >= KEPT {
            old.sort();
            for (_, path) in &old[..=old.len() - KEPT] {
                let _ = fs::remove_file(path);
            }
        }
    }
    let path = dir.join(format!(
        "body-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    Ok((new_private_file(&path)?, path))
}

/// A folder of reqorb's own, `name`, for files no other user may read.
///
/// macOS, iOS and Windows give each user a temporary folder of their own,
/// so it is made there. Elsewhere the temporary folder is shared by every
/// user, any of whom could make the folder first or leave a link in it,
/// so it is made in this user's cache folder instead.
pub(crate) fn private_dir(name: &str) -> PathBuf {
    #[cfg(any(not(unix), target_vendor = "apple"))]
    let base = std::env::temp_dir();
    #[cfg(all(unix, not(target_vendor = "apple")))]
    let base = cache_dir(|key| std::env::var_os(key)).unwrap_or_else(std::env::temp_dir);
    base.join(name)
}

/// This user's cache folder, as the XDG convention has it, from the
/// environment variables `var` reads; none when neither is set.
#[cfg(any(test, all(unix, not(target_vendor = "apple"))))]
fn cache_dir(var: impl Fn(&str) -> Option<std::ffi::OsString>) -> Option<PathBuf> {
    let absolute = |key: &str| var(key).map(PathBuf::from).filter(|p| p.is_absolute());
    absolute("XDG_CACHE_HOME").or_else(|| absolute("HOME").map(|home| home.join(".cache")))
}

/// Makes a new file at `path`, which only this user can read or write, in
/// a folder of theirs that only they can use, made if need be. Fails when
/// anything is already at `path`, so a link put there is never written
/// through, and when the folder is a link or belongs to someone else.
pub(crate) fn new_private_file(path: &Path) -> io::Result<File> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "the path names no folder"))?;
    let mut options = fs::OpenOptions::new();
    options.read(true).write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
        options.mode(0o600);
    }
    #[cfg(not(unix))]
    fs::create_dir_all(dir)?;
    let file = options.open(path)?;
    #[cfg(unix)]
    if let Err(e) = keep_to_owner(dir, &file) {
        drop(file);
        let _ = fs::remove_file(path);
        return Err(e);
    }
    Ok(file)
}

/// Checks that `dir`, which holds `file`, is a folder and not a link, and
/// is the same user's as the file just made in it, and closes it to
/// everyone else if it was open to them.
#[cfg(unix)]
fn keep_to_owner(dir: &Path, file: &File) -> io::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let me = file.metadata()?.uid();
    let folder = fs::symlink_metadata(dir)?;
    if !folder.is_dir() || folder.uid() != me {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "{} is not a folder of this user's own, so reqorb keeps no files there",
                dir.display()
            ),
        ));
    }
    if folder.mode() & 0o077 != 0 {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Copies the file at `from` to a new file at `to`, made as
/// [`new_private_file`] makes one.
pub(crate) fn private_copy(from: &Path, to: &Path) -> io::Result<()> {
    #[cfg(target_vendor = "apple")]
    {
        // Made first to make and check the folder, which is in this
        // user's own temporary folder, then left to `fs::copy`, which on
        // APFS clones the file, taking no time or space, and makes it
        // only when nothing is there.
        new_private_file(to)?;
        fs::remove_file(to)?;
        fs::copy(from, to).map(drop)
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let mut copy = new_private_file(to)?;
        io::copy(&mut File::open(from)?, &mut copy).map(drop)
    }
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
        let failed = |e: io::Error| {
            Error::Io(format!(
                "the response could not be kept on disk: {}",
                io_problem(&e)
            ))
        };
        if let Some((file, _)) = &mut self.file {
            return file.write_all(chunk).map_err(failed);
        }
        self.bytes.extend_from_slice(chunk);
        if self.len > spill_bytes() {
            let (mut file, path) = new_spill_file().map_err(failed)?;
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
                file.sync_all().map_err(|e| {
                    Error::Io(format!(
                        "the response could not be kept on disk: {}",
                        io_problem(&e)
                    ))
                })?;
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
    fn a_full_disk_is_said_plainly() {
        let full = io::Error::from(io::ErrorKind::StorageFull);
        assert_eq!(
            io_problem(&full),
            "there is not enough free space on the disk"
        );
        let other = io::Error::other("something else");
        assert_eq!(io_problem(&other), "something else");
    }

    #[test]
    fn a_preview_ends_on_a_whole_character() {
        let bytes = "aé".as_bytes();
        assert_eq!(preview(&bytes[..2]), "a");
        assert_eq!(preview(bytes), "aé");
        assert_eq!(preview(&[b'a', 0xff, b'b']), "a\u{fffd}b");
    }

    #[test]
    fn the_cache_folder_follows_xdg_then_home() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |key: &str| {
                pairs
                    .iter()
                    .find(|(k, _)| *k == key)
                    .map(|(_, v)| std::ffi::OsString::from(v))
            }
        };
        assert_eq!(
            cache_dir(env(&[("XDG_CACHE_HOME", "/c"), ("HOME", "/h")])),
            Some(PathBuf::from("/c"))
        );
        assert_eq!(
            cache_dir(env(&[("HOME", "/h")])),
            Some(PathBuf::from("/h/.cache"))
        );
        // A relative path is ignored, as the convention says.
        assert_eq!(
            cache_dir(env(&[("XDG_CACHE_HOME", "c"), ("HOME", "/h")])),
            Some(PathBuf::from("/h/.cache"))
        );
        assert_eq!(cache_dir(env(&[])), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_private_file_is_this_users_alone() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("bodies");
        let path = dir.join("body");
        new_private_file(&path).unwrap();
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir), 0o700);
        assert_eq!(mode(&path), 0o600);

        // A folder left open to others is closed to them.
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o777)).unwrap();
        new_private_file(&dir.join("second")).unwrap();
        assert_eq!(mode(&dir), 0o700);
    }

    #[cfg(unix)]
    #[test]
    fn a_link_is_never_written_through() {
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("target");
        fs::write(&target, "kept").unwrap();

        // A link where the file is to go.
        let dir = root.path().join("bodies");
        fs::create_dir(&dir).unwrap();
        let path = dir.join("body");
        std::os::unix::fs::symlink(&target, &path).unwrap();
        let e = new_private_file(&path).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read_to_string(&target).unwrap(), "kept");

        // A link where the folder is to be.
        let elsewhere = root.path().join("elsewhere");
        fs::create_dir(&elsewhere).unwrap();
        let linked = root.path().join("linked");
        std::os::unix::fs::symlink(&elsewhere, &linked).unwrap();
        let e = new_private_file(&linked.join("body")).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(fs::read_dir(&elsewhere).unwrap().count(), 0);
    }

    #[test]
    fn a_private_copy_has_all_of_the_file() {
        let root = tempfile::tempdir().unwrap();
        let from = root.path().join("from");
        fs::write(&from, "the original").unwrap();
        let to = root.path().join("copies").join("copy");
        private_copy(&from, &to).unwrap();
        assert_eq!(fs::read_to_string(&to).unwrap(), "the original");
        // Never over something already there.
        assert!(private_copy(&from, &to).is_err());
    }
}
