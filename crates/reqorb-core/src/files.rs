//! The files a request may read: a body sent from a file, or a file field
//! of a form. When a working directory is set, paths are looked up in it
//! and, unless allowed otherwise, may not lead out of it.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::Error;

/// Where requests may read files from.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FileAccess {
    /// The working directory; relative paths are looked up in it.
    pub root: Option<PathBuf>,
    /// Whether files outside the working directory may be read. Without a
    /// working directory there is nothing to be outside of.
    pub allow_outside: bool,
}

impl FileAccess {
    /// Where `path` is on disk: itself when absolute, otherwise inside the
    /// working directory.
    pub fn resolve(&self, path: &str) -> PathBuf {
        let path = Path::new(path.trim());
        match &self.root {
            Some(root) if path.is_relative() => root.join(path),
            _ => path.to_path_buf(),
        }
    }

    /// Reads the file a request names, if it is one the request may read.
    pub fn read(&self, path: &str) -> Result<Vec<u8>, Error> {
        let resolved = self.resolve(path);
        let unreadable = |e: std::io::Error| {
            Error::Io(format!(
                "cannot read `{}`: {e}; choose the file again",
                resolved.display()
            ))
        };
        if let Some(root) = &self.root
            && !self.allow_outside
        {
            // Compared as the real locations, so that neither `..` nor a
            // link can lead out of the directory.
            let real = resolved.canonicalize().map_err(unreadable)?;
            let root = root.canonicalize().map_err(|e| {
                Error::Io(format!(
                    "cannot open the working directory `{}`: {e}; choose it again in Settings",
                    root.display()
                ))
            })?;
            if !real.starts_with(&root) {
                return Err(Error::Io(format!(
                    "`{}` is outside the working directory `{}`; move the file into it, or \
                     allow reading files outside it in Settings",
                    resolved.display(),
                    root.display()
                )));
            }
            // The file that was checked is the one read, even if a link
            // is changed in between.
            return std::fs::read(&real).map_err(unreadable);
        }
        std::fs::read(&resolved).map_err(unreadable)
    }
}

/// Writes `contents` to `path` whole or not at all: into a new file beside
/// it, flushed to disk, which then takes its place. A link at `path` is
/// replaced, never followed. A `private` file is readable by its owner
/// alone, as anything holding credentials should be.
pub(crate) fn replace_file(path: &Path, contents: &[u8], private: bool) -> std::io::Result<()> {
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};

    // Saves may overlap, so each takes a name of its own.
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let name = path.file_name().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "the path names no file")
    })?;
    let mut temporary = std::ffi::OsString::from(".");
    temporary.push(name);
    temporary.push(format!(
        ".{}-{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let temporary = path.with_file_name(temporary);

    let mut options = std::fs::OpenOptions::new();
    // A new file, so that nothing already at that name is written through.
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(if private { 0o600 } else { 0o644 });
    }
    #[cfg(not(unix))]
    let _ = private;
    let written = options.open(&temporary).and_then(|mut file| {
        file.write_all(contents)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temporary, path)
    });
    if written.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    written
}

/// What can be done with a directory, to tell whether it will serve as the
/// working directory.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct DirAccess {
    /// It is there and it is a directory.
    pub exists: bool,
    /// Its contents can be listed.
    pub readable: bool,
    /// Files can be created in it.
    pub writable: bool,
}

/// Tries `path` out as a directory: lists it, and creates and removes a
/// file in it.
pub fn check_directory(path: &str) -> DirAccess {
    let dir = Path::new(path.trim());
    let exists = !path.trim().is_empty() && dir.is_dir();
    let readable = exists && std::fs::read_dir(dir).is_ok();
    let probe = dir.join(format!(".reqorb-access-{}", std::process::id()));
    let writable = exists && std::fs::write(&probe, b"").is_ok();
    if writable {
        let _ = std::fs::remove_file(&probe);
    }
    DirAccess {
        exists,
        readable,
        writable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_inside_the_working_directory_only() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::create_dir(root.path().join("data")).unwrap();
        std::fs::write(root.path().join("data/in.txt"), "inside").unwrap();
        std::fs::write(outside.path().join("out.txt"), "outside").unwrap();
        let out = outside.path().join("out.txt");
        let out = out.to_str().unwrap();

        let confined = FileAccess {
            root: Some(root.path().to_path_buf()),
            allow_outside: false,
        };
        // A relative path is looked up in the working directory.
        assert_eq!(confined.read("data/in.txt").unwrap(), b"inside");
        assert_eq!(confined.read(" data/in.txt ").unwrap(), b"inside");
        let absolute = root.path().join("data/in.txt");
        assert_eq!(
            confined.read(absolute.to_str().unwrap()).unwrap(),
            b"inside"
        );

        // Neither an absolute path nor `..` leads out of it.
        let error = confined.read(out).unwrap_err().to_string();
        assert!(
            error.contains("is outside the working directory"),
            "{error}"
        );
        let name = outside.path().file_name().unwrap().to_str().unwrap();
        let climbing = format!("../{name}/out.txt");
        let error = confined.read(&climbing).unwrap_err().to_string();
        assert!(
            error.contains("is outside the working directory"),
            "{error}"
        );
        assert!(confined.read("data/missing.txt").is_err());

        // Unless that is allowed, or there is no working directory at all.
        let open = FileAccess {
            allow_outside: true,
            ..confined.clone()
        };
        assert_eq!(open.read(out).unwrap(), b"outside");
        assert_eq!(open.read("data/in.txt").unwrap(), b"inside");
        assert_eq!(FileAccess::default().read(out).unwrap(), b"outside");
    }

    #[cfg(unix)]
    #[test]
    fn a_link_cannot_lead_out_of_the_working_directory() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("secret"), "s").unwrap();
        std::os::unix::fs::symlink(outside.path().join("secret"), root.path().join("link"))
            .unwrap();
        let confined = FileAccess {
            root: Some(root.path().to_path_buf()),
            allow_outside: false,
        };
        assert!(confined.read("link").is_err());
    }

    #[test]
    fn checks_what_a_directory_allows() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_str().unwrap();
        assert_eq!(
            check_directory(path),
            DirAccess {
                exists: true,
                readable: true,
                writable: true
            }
        );
        // The probe file is not left behind.
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);

        let none = DirAccess {
            exists: false,
            readable: false,
            writable: false,
        };
        assert_eq!(check_directory(&format!("{path}/missing")), none);
        assert_eq!(check_directory(""), none);

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let locked = dir.path().join("locked");
            std::fs::create_dir(&locked).unwrap();
            std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o555)).unwrap();
            let access = check_directory(locked.to_str().unwrap());
            assert!(access.exists && access.readable && !access.writable);
        }
    }
}
