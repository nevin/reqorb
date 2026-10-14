//! Keeping credentials out of the workspace file.
//!
//! The workspace is saved as readable JSON, which is no place for tokens
//! and passwords. Before it is written, every value that holds a
//! credential is encrypted where it stands, with a key that lives in the
//! system keychain and nowhere else. Read back on the same machine, the
//! values are decrypted again; anyone else who gets hold of the file sees
//! only that they are there.

use std::path::Path;
use std::sync::Mutex;

use base64::Engine;
use chacha20poly1305::aead::Aead;
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce};
use hmac::{Hmac, Mac};
use sha2::Sha256;

use crate::auth::auth_fields;
use crate::redact::is_sensitive;
use crate::{Error, Item, Request, Variable, Workspace};

/// What an encrypted value starts with. The number is the format, so that
/// it can change without old files becoming unreadable.
pub const LOCKED: &str = "reqorb-enc:1:";

pub(crate) const KEY_BYTES: usize = 32;
const NONCE_BYTES: usize = 24;

/// Where the key that encrypts a workspace's secrets is kept.
pub trait KeyStore: Send + Sync {
    /// The key, or `None` when none has been made yet.
    fn load(&self) -> Result<Option<Vec<u8>>, String>;
    fn save(&self, key: &[u8]) -> Result<(), String>;
}

/// The system keychain: Keychain Services on macOS and iOS, the Credential
/// Manager on Windows, and the Secret Service (GNOME Keyring, KWallet) on
/// Linux.
pub struct Keychain;

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
))]
mod system {
    use std::sync::LazyLock;

    use keyring_core::{Entry, Error};

    /// The keychain is set up once, on first use.
    static READY: LazyLock<Result<(), String>> = LazyLock::new(|| {
        #[cfg(target_os = "macos")]
        let store = apple_native_keyring_store::keychain::Store::new();
        #[cfg(target_os = "ios")]
        let store = apple_native_keyring_store::protected::Store::new();
        #[cfg(target_os = "windows")]
        let store = windows_native_keyring_store::Store::new();
        #[cfg(target_os = "linux")]
        let store = zbus_secret_service_keyring_store::Store::new();
        keyring_core::set_default_store(store.map_err(|e| e.to_string())?);
        Ok(())
    });

    fn entry() -> Result<Entry, String> {
        READY.clone()?;
        Entry::new("reqorb", "workspace-key").map_err(|e| e.to_string())
    }

    pub(super) fn load() -> Result<Option<Vec<u8>>, String> {
        match entry()?.get_secret() {
            Ok(key) => Ok(Some(key)),
            Err(Error::NoEntry) => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    pub(super) fn save(key: &[u8]) -> Result<(), String> {
        entry()?.set_secret(key).map_err(|e| e.to_string())
    }
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux"
)))]
mod system {
    const WHY: &str = "reqorb cannot use this system's keychain yet";

    pub(super) fn load() -> Result<Option<Vec<u8>>, String> {
        Err(WHY.into())
    }

    pub(super) fn save(_: &[u8]) -> Result<(), String> {
        Err(WHY.into())
    }
}

/// The key once read, so the keychain is asked once per run and not on
/// every save.
static CACHED: Mutex<Option<Vec<u8>>> = Mutex::new(None);

impl KeyStore for Keychain {
    fn load(&self) -> Result<Option<Vec<u8>>, String> {
        let mut cached = CACHED.lock().unwrap_or_else(|e| e.into_inner());
        if cached.is_none() {
            *cached = system::load()?;
        }
        Ok(cached.clone())
    }

    fn save(&self, key: &[u8]) -> Result<(), String> {
        system::save(key)?;
        *CACHED.lock().unwrap_or_else(|e| e.into_inner()) = Some(key.to_vec());
        Ok(())
    }
}

/// The key from `keys`, made and stored first if there is none and
/// `create` is set.
pub(crate) fn key_from(
    keys: &dyn KeyStore,
    create: bool,
) -> Result<Option<[u8; KEY_BYTES]>, String> {
    let stored = match keys.load()? {
        Some(key) => key,
        None if create => {
            let mut key = [0u8; KEY_BYTES];
            getrandom::fill(&mut key).map_err(|e| format!("no random numbers: {e}"))?;
            keys.save(&key)?;
            key.to_vec()
        }
        None => return Ok(None),
    };
    stored
        .try_into()
        .map(Some)
        .map_err(|_| "the key in the keychain is not one reqorb made".to_string())
}

fn mac(key: &[u8], label: &[u8], text: &[u8]) -> Vec<u8> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(label);
    mac.update(text);
    mac.finalize().into_bytes().to_vec()
}

fn cipher(key: &[u8; KEY_BYTES]) -> XChaCha20Poly1305 {
    // Encryption and the nonces below each get a key of their own.
    let derived = mac(key, b"encrypt", b"");
    XChaCha20Poly1305::new_from_slice(&derived).expect("a SHA-256 output is a key")
}

fn as_nonce(bytes: &[u8]) -> XNonce {
    XNonce::try_from(bytes).expect("callers pass exactly a nonce's worth")
}

/// Encrypts one value. The nonce is derived from the value itself, so the
/// same value always encrypts to the same text and an unchanged workspace
/// saves to an unchanged file. A nonce is then only ever reused for the
/// value it was first used with, which gives nothing away.
pub(crate) fn lock(key: &[u8; KEY_BYTES], plain: &str) -> String {
    let nonce = &mac(key, b"nonce", plain.as_bytes())[..NONCE_BYTES];
    let sealed = cipher(key)
        .encrypt(&as_nonce(nonce), plain.as_bytes())
        .expect("encrypting in memory cannot fail");
    let encode = |bytes: &[u8]| base64::engine::general_purpose::STANDARD_NO_PAD.encode(bytes);
    format!("{LOCKED}{}:{}", encode(nonce), encode(&sealed))
}

/// Decrypts a value made by [`lock`]; `None` when the key is not the one
/// it was encrypted with or the text has been altered.
pub(crate) fn unlock(key: &[u8; KEY_BYTES], locked: &str) -> Option<String> {
    let (nonce, sealed) = locked.strip_prefix(LOCKED)?.split_once(':')?;
    let decode = |text: &str| {
        base64::engine::general_purpose::STANDARD_NO_PAD
            .decode(text)
            .ok()
    };
    let nonce = decode(nonce).filter(|n| n.len() == NONCE_BYTES)?;
    let plain = cipher(key)
        .decrypt(&as_nonce(&nonce), decode(sealed)?.as_slice())
        .ok()?;
    String::from_utf8(plain).ok()
}

/// Calls `visit` with every value in the workspace that holds a credential.
fn secrets(workspace: &mut Workspace, visit: &mut dyn FnMut(&mut String)) {
    fn variables(list: &mut [Variable], visit: &mut dyn FnMut(&mut String)) {
        // Marked as a credential, or named like one.
        for variable in list.iter_mut().filter(|v| v.secret || is_sensitive(&v.key)) {
            visit(&mut variable.value);
        }
    }
    fn request(request: &mut Request, visit: &mut dyn FnMut(&mut String)) {
        for header in &mut request.headers {
            if is_sensitive(&header.name) {
                visit(&mut header.value);
            }
        }
        if let Some(auth) = &mut request.auth {
            let fields = auth_fields(auth.kind);
            for param in &mut auth.params {
                if fields.iter().any(|f| f.secret && f.key == param.key) {
                    visit(&mut param.value);
                }
            }
        }
    }
    fn items(list: &mut [Item], visit: &mut dyn FnMut(&mut String)) {
        for item in list {
            if let Some(found) = &mut item.request {
                request(found, visit);
            }
            items(&mut item.items, visit);
        }
    }

    for collection in &mut workspace.collections {
        variables(&mut collection.variables, visit);
        items(&mut collection.items, visit);
    }
    items(&mut workspace.requests, visit);
    for environment in &mut workspace.environments {
        variables(&mut environment.variables, visit);
    }
    for cookie in &mut workspace.cookies {
        visit(&mut cookie.value);
    }
    // A proxy address may carry a user name and password.
    let proxy = &workspace.settings.proxy_url;
    if proxy.contains('@') || proxy.starts_with(LOCKED) {
        visit(&mut workspace.settings.proxy_url);
    }
}

/// Encrypts every credential in the workspace that is not encrypted yet.
fn seal(workspace: &mut Workspace, key: &[u8; KEY_BYTES]) {
    secrets(workspace, &mut |value| {
        if !value.is_empty() && !value.starts_with(LOCKED) {
            *value = lock(key, value);
        }
    });
}

/// Decrypts the encrypted credentials in the workspace and returns how many
/// could not be. Those are left as they are, so that saving the workspace
/// again does not destroy them.
///
/// Only the places [`seal`] encrypts are decrypted. Otherwise anyone holding
/// a copy of the file could have its credentials read out, by handing the
/// user a collection whose URL is one of them and waiting for it to be sent.
fn unseal(workspace: &mut Workspace, key: Option<&[u8; KEY_BYTES]>) -> u32 {
    let mut locked = 0;
    secrets(workspace, &mut |value| {
        if value.starts_with(LOCKED) {
            match key.and_then(|key| unlock(key, value)) {
                Some(plain) => *value = plain,
                None => locked += 1,
            }
        }
    });
    locked
}

/// How many values in the workspace are still encrypted, because the key
/// they were encrypted with could not be read.
pub fn locked_secrets(workspace: &Workspace) -> u32 {
    unseal(&mut workspace.clone(), None)
}

/// Whether credentials can be encrypted here, and if not, why. Makes the
/// key if there is none yet.
pub fn check_keys(keys: &dyn KeyStore) -> Result<(), String> {
    key_from(keys, true).map(|_| ())
}

/// A workspace read from disk, and what could not be read with it.
#[derive(Debug, Clone)]
pub struct Loaded {
    pub workspace: Workspace,
    /// Credentials left encrypted because their key could not be read.
    pub locked: u32,
    /// Why the key could not be read, when it could not.
    pub problem: Option<String>,
}

/// Loads the workspace at `path`, decrypting its credentials with the key
/// in `keys`. A missing file is an empty workspace.
pub fn load_workspace(path: &Path, keys: &dyn KeyStore) -> Result<Loaded, Error> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Loaded {
                workspace: Workspace::default(),
                locked: 0,
                problem: None,
            });
        }
        Err(e) => return Err(Error::Io(format!("{}: {e}", path.display()))),
    };
    let mut workspace: Workspace = serde_json::from_str(&text)
        .map_err(|e| Error::Format(format!("{}: {e}", path.display())))?;
    // The keychain is only troubled when there is something to decrypt.
    let (key, problem) = if text.contains(LOCKED) {
        match key_from(keys, false) {
            Ok(Some(key)) => (Some(key), None),
            Ok(None) => (None, Some("its key is not in this keychain".to_string())),
            Err(why) => (None, Some(why)),
        }
    } else {
        (None, None)
    };
    let locked = unseal(&mut workspace, key.as_ref());
    Ok(Loaded {
        workspace,
        locked,
        problem: problem.filter(|_| locked > 0),
    })
}

/// Saves the workspace to `path`, with its credentials encrypted when its
/// settings ask for that. Returns why they were left as they are, if the
/// keychain could not be used; the workspace is saved either way.
pub fn save_workspace(
    workspace: &Workspace,
    path: &Path,
    keys: &dyn KeyStore,
) -> Result<Option<String>, Error> {
    if !workspace.settings.protect_secrets {
        workspace.save(path)?;
        return Ok(None);
    }
    match key_from(keys, true) {
        Ok(Some(key)) => {
            let mut sealed = workspace.clone();
            seal(&mut sealed, &key);
            sealed.save(path)?;
            Ok(None)
        }
        Ok(None) => unreachable!("a key is made when there is none"),
        Err(why) => {
            workspace.save(path)?;
            Ok(Some(why))
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{Auth, AuthKind, Collection, Cookie, Environment, Header};

    /// A keychain that lasts as long as the test.
    #[derive(Default)]
    pub(crate) struct MemoryKeys {
        key: Mutex<Option<Vec<u8>>>,
        /// Makes every use fail, as a locked or missing keychain would.
        broken: bool,
    }

    impl KeyStore for MemoryKeys {
        fn load(&self) -> Result<Option<Vec<u8>>, String> {
            if self.broken {
                return Err("the keychain is locked".into());
            }
            Ok(self.key.lock().unwrap().clone())
        }

        fn save(&self, key: &[u8]) -> Result<(), String> {
            if self.broken {
                return Err("the keychain is locked".into());
            }
            *self.key.lock().unwrap() = Some(key.to_vec());
            Ok(())
        }
    }

    fn sample() -> Workspace {
        let mut request = Request::new("GET", "https://api.test/me?page=2");
        request.headers = vec![
            Header {
                name: "Authorization".into(),
                value: "Bearer h3ader".into(),
            },
            Header {
                name: "Accept".into(),
                value: "application/json".into(),
            },
        ];
        request.auth = Some(Auth::new(
            AuthKind::Basic,
            &[("username", "ann"), ("password", "hunter2")],
        ));
        let plain = Variable::new("base", "https://api.test");
        // One is a credential by its name, the other because it says so.
        let token = Variable::new("token", "t0ken");
        let mut marked = Variable::new("lunch", "s4ndwich");
        marked.secret = true;
        let mut workspace = Workspace {
            collections: vec![Collection {
                name: "API".into(),
                variables: vec![token.clone()],
                items: vec![Item {
                    name: "Folder".into(),
                    request: None,
                    items: vec![Item {
                        name: "Me".into(),
                        request: Some(request.clone()),
                        items: Vec::new(),
                    }],
                }],
                link: None,
                unreviewed: false,
            }],
            requests: vec![Item {
                name: "Loose".into(),
                request: Some(request),
                items: Vec::new(),
            }],
            environments: vec![Environment {
                folder: None,
                name: "dev".into(),
                variables: vec![plain, token, marked, {
                    let mut empty = Variable::new("unset", "");
                    empty.secret = true;
                    empty
                }],
            }],
            cookies: vec![Cookie {
                name: "sid".into(),
                value: "c00kie".into(),
                domain: "api.test".into(),
                path: "/".into(),
                expires: None,
                secure: true,
                http_only: true,
                host_only: true,
            }],
            ..Workspace::default()
        };
        workspace.settings.proxy_url = "http://ann:pr0xy@proxy.test:8080".into();
        workspace
    }

    const SECRETS: [&str; 6] = ["h3ader", "hunter2", "t0ken", "s4ndwich", "c00kie", "pr0xy"];

    #[test]
    fn values_lock_and_unlock() {
        let key = [7u8; KEY_BYTES];
        let locked = lock(&key, "hunter2 – ünïcode");
        assert!(locked.starts_with(LOCKED));
        assert!(!locked.contains("hunter2"));
        assert_eq!(unlock(&key, &locked).as_deref(), Some("hunter2 – ünïcode"));
        // The same value locks to the same text, so files do not churn;
        // different values and different keys do not.
        assert_eq!(lock(&key, "hunter2 – ünïcode"), locked);
        assert_ne!(lock(&key, "hunter3"), lock(&key, "hunter2"));
        assert_ne!(lock(&[8u8; KEY_BYTES], "hunter2"), lock(&key, "hunter2"));

        // Another key, or a changed character, opens nothing.
        assert_eq!(unlock(&[8u8; KEY_BYTES], &locked), None);
        let mut altered = locked.clone();
        let last = altered.pop().unwrap();
        altered.push(if last == 'A' { 'B' } else { 'A' });
        assert_eq!(unlock(&key, &altered), None);
        for nonsense in ["hunter2", LOCKED, "reqorb-enc:1:abc", "reqorb-enc:1:!!:??"] {
            assert_eq!(unlock(&key, nonsense), None, "{nonsense}");
        }
    }

    #[test]
    fn the_saved_file_holds_no_credentials_and_loads_back_whole() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workspace.json");
        let keys = MemoryKeys::default();
        let workspace = sample();

        assert_eq!(save_workspace(&workspace, &path, &keys).unwrap(), None);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600, "only its owner may read the file");
        }
        let text = std::fs::read_to_string(&path).unwrap();
        for secret in SECRETS {
            assert!(!text.contains(secret), "{secret} is in the file");
        }
        // What is not a credential stays readable.
        for plain in [
            "https://api.test/me?page=2",
            "application/json",
            "ann",
            "sid",
            "token",
            "lunch",
        ] {
            assert!(text.contains(plain), "{plain} is not in the file");
        }
        // Six credentials in nine places; the empty one is left.
        assert_eq!(text.matches(LOCKED).count(), 9);

        let loaded = load_workspace(&path, &keys).unwrap();
        assert_eq!(loaded.workspace, workspace);
        assert_eq!((loaded.locked, loaded.problem), (0, None));

        // Saved again unchanged, the file is the same to the byte.
        save_workspace(&loaded.workspace, &path, &keys).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
    }

    #[test]
    fn a_credential_copied_where_none_belongs_is_not_decrypted() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workspace.json");
        let keys = MemoryKeys::default();
        save_workspace(&sample(), &path, &keys).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        let stolen = text
            .split('"')
            .find(|part| part.starts_with(LOCKED))
            .unwrap()
            .to_string();

        // A collection someone else wrote, that would send the value to them.
        let mut planted = sample();
        let request = Request::new("GET", &stolen);
        planted.requests.push(Item {
            name: "Bait".into(),
            request: Some(request),
            items: Vec::new(),
        });
        planted.collections[0].name = stolen.clone();
        save_workspace(&planted, &path, &keys).unwrap();

        let loaded = load_workspace(&path, &keys).unwrap().workspace;
        let bait = loaded.requests.last().unwrap().request.as_ref().unwrap();
        assert_eq!(bait.url, stolen);
        assert_eq!(loaded.collections[0].name, stolen);
        // The credentials where they belong still open.
        assert_eq!(loaded.environments, sample().environments);
    }

    #[test]
    fn without_the_key_credentials_stay_locked_and_survive_a_save() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workspace.json");
        let keys = MemoryKeys::default();
        save_workspace(&sample(), &path, &keys).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();

        // Another machine: a keychain with no key, or one that will not open.
        let empty = MemoryKeys::default();
        let loaded = load_workspace(&path, &empty).unwrap();
        assert_eq!(loaded.locked, 9);
        assert_eq!(
            loaded.problem.as_deref(),
            Some("its key is not in this keychain")
        );
        assert_eq!(locked_secrets(&loaded.workspace), 9);
        // Reading must not have made a key, which would hide the problem.
        assert_eq!(empty.load().unwrap(), None);
        let broken = MemoryKeys {
            broken: true,
            ..MemoryKeys::default()
        };
        let stuck = load_workspace(&path, &broken).unwrap();
        assert_eq!(stuck.problem.as_deref(), Some("the keychain is locked"));
        assert_eq!(stuck.locked, 9);

        // The rest of the workspace is all there.
        let request = stuck.workspace.requests[0].request.as_ref().unwrap();
        assert_eq!(request.url, "https://api.test/me?page=2");
        assert!(request.headers[0].value.starts_with(LOCKED));

        // Saved from there, with or without a working keychain, what was
        // locked is still what it was, ready for the day the key is back.
        for keychain in [&broken, &empty] {
            save_workspace(&stuck.workspace, &path, keychain).unwrap();
            assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
        }
        assert_eq!(load_workspace(&path, &keys).unwrap().workspace, sample());
    }

    #[test]
    fn falls_back_to_plain_when_the_keychain_fails_or_protection_is_off() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workspace.json");
        let broken = MemoryKeys {
            broken: true,
            ..MemoryKeys::default()
        };
        // The workspace is saved all the same, and the caller told why
        // it is not protected.
        assert_eq!(
            save_workspace(&sample(), &path, &broken)
                .unwrap()
                .as_deref(),
            Some("the keychain is locked")
        );
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("hunter2") && !text.contains(LOCKED));
        assert_eq!(check_keys(&broken).unwrap_err(), "the keychain is locked");

        let keys = MemoryKeys::default();
        let mut open = sample();
        open.settings.protect_secrets = false;
        assert_eq!(save_workspace(&open, &path, &keys).unwrap(), None);
        assert!(std::fs::read_to_string(&path).unwrap().contains("hunter2"));
        // No key was made for a workspace that does not want one.
        assert_eq!(keys.load().unwrap(), None);
        let loaded = load_workspace(&path, &keys).unwrap();
        assert_eq!(loaded.workspace, open);

        // Turned on, the next save protects what was plain.
        save_workspace(&sample(), &path, &keys).unwrap();
        assert!(!std::fs::read_to_string(&path).unwrap().contains("hunter2"));
        assert!(check_keys(&keys).is_ok());
    }

    #[test]
    fn a_missing_file_is_an_empty_workspace_and_a_plain_one_needs_no_key() {
        let dir = tempfile::tempdir().unwrap();
        let broken = MemoryKeys {
            broken: true,
            ..MemoryKeys::default()
        };
        let loaded = load_workspace(&dir.path().join("none.json"), &broken).unwrap();
        assert_eq!(loaded.workspace, Workspace::default());

        // A file from before credentials were protected loads untouched,
        // without the keychain being asked for anything.
        let path = dir.path().join("old.json");
        let mut old = sample();
        old.settings.protect_secrets = false;
        old.save(&path).unwrap();
        let loaded = load_workspace(&path, &broken).unwrap();
        assert_eq!(loaded.workspace, old);
        assert_eq!((loaded.locked, loaded.problem), (0, None));

        std::fs::write(&path, "{ not json").unwrap();
        assert!(load_workspace(&path, &broken).is_err());
    }

    /// Exercises the real keychain. Run by hand, as it leaves a key behind
    /// and may ask for permission: `cargo test -p reqorb-core real_keychain -- --ignored`
    #[test]
    #[ignore]
    fn real_keychain_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workspace.json");
        check_keys(&Keychain).unwrap();
        assert_eq!(save_workspace(&sample(), &path, &Keychain).unwrap(), None);
        assert!(!std::fs::read_to_string(&path).unwrap().contains("hunter2"));
        // Read afresh from the keychain, not from this run's memory.
        *CACHED.lock().unwrap() = None;
        let loaded = load_workspace(&path, &Keychain).unwrap();
        assert_eq!(loaded.workspace, sample());
        assert_eq!(loaded.locked, 0);
    }
}
