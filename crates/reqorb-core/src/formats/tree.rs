//! A collection kept as a folder of files, one for each request, so that
//! it can be put under version control: a change to one request is a
//! change to one file, and two people's changes merge as files do.
//!
//! ```text
//! shop/
//!   collection.json           the name, the variables, the order of things
//!   Login.request.json        a request, with the name it goes by
//!   Orders/
//!     folder.json             the folder's name and order
//!     List orders.request.json
//! ```
//!
//! Credentials are left out of the files. Their values stay in the
//! workspace on this machine and are put back when the folder is read.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::auth::auth_fields;
use crate::redact::is_sensitive;
use crate::{Collection, Error, Item, Request, Variable};

const COLLECTION_FILE: &str = "collection.json";
const FOLDER_FILE: &str = "folder.json";
const REQUEST_SUFFIX: &str = ".request.json";
const VERSION: u32 = 1;

#[derive(Serialize, Deserialize)]
struct CollectionFile {
    reqorb: u32,
    name: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    variables: Vec<Variable>,
    /// The files and folders beside this one, in the order they are shown.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    order: Vec<String>,
}

#[derive(Serialize, Deserialize)]
struct FolderFile {
    name: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    order: Vec<String>,
}

#[derive(Serialize, Deserialize)]
struct RequestFile {
    name: String,
    request: Request,
}

fn io(what: &str, path: &Path, e: impl std::fmt::Display) -> Error {
    Error::Io(format!("could not {what} {}: {e}", path.display()))
}

fn pretty<T: Serialize>(value: &T) -> String {
    let mut text = serde_json::to_string_pretty(value).expect("the model serialises");
    text.push('\n');
    text
}

// ------------------------------------------------------------ credentials

/// A value that only refers to a variable gives nothing away.
fn is_reference(value: &str) -> bool {
    let value = value.trim();
    value.starts_with("{{") && value.ends_with("}}") && !value[2..].contains("{{")
}

/// Visits every credential in the collection with two keys that say whose
/// it is: one by where the request sits and what it is called, and one by
/// what the request does, which still holds after it is renamed or moved.
fn credentials(collection: &mut Collection, visit: &mut dyn FnMut([String; 2], &mut String)) {
    fn items(list: &mut [Item], prefix: &str, visit: &mut dyn FnMut([String; 2], &mut String)) {
        for item in list {
            let path = format!("{prefix}/{}", item.name);
            if let Some(request) = &mut item.request {
                let does = format!("{} {}", request.method.to_uppercase(), request.url);
                for header in &mut request.headers {
                    if is_sensitive(&header.name) {
                        let field = format!("#header:{}", header.name.to_lowercase());
                        visit(
                            [format!("at{path}{field}"), format!("does {does}{field}")],
                            &mut header.value,
                        );
                    }
                }
                if let Some(auth) = &mut request.auth {
                    let fields = auth_fields(auth.kind);
                    for param in &mut auth.params {
                        if fields.iter().any(|f| f.secret && f.key == param.key) {
                            let field = format!("#auth:{}", param.key);
                            visit(
                                [format!("at{path}{field}"), format!("does {does}{field}")],
                                &mut param.value,
                            );
                        }
                    }
                }
            }
            items(&mut item.items, &path, visit);
        }
    }
    for variable in &mut collection.variables {
        if variable.secret || is_sensitive(&variable.key) {
            let key = format!("variable:{}", variable.key);
            visit([key.clone(), key], &mut variable.value);
        }
    }
    items(&mut collection.items, "", visit);
}

/// The collection as it is written: without the values of its credentials.
fn without_credentials(collection: &Collection) -> Collection {
    let mut written = collection.clone();
    credentials(&mut written, &mut |_, value| {
        if !is_reference(value) {
            value.clear();
        }
    });
    written
}

/// Puts back the credentials that `read` came without, from `local`, the
/// copy of the collection this machine holds.
fn restore_credentials(read: &mut Collection, local: &Collection) {
    let mut placed = HashMap::new();
    // By what a request does, only where that picks out a single value.
    let mut doing: HashMap<String, Option<String>> = HashMap::new();
    credentials(&mut local.clone(), &mut |[at, does], value| {
        placed.insert(at, value.clone());
        doing
            .entry(does)
            .and_modify(|known| {
                if known.as_deref() != Some(value.as_str()) {
                    *known = None;
                }
            })
            .or_insert_with(|| Some(value.clone()));
    });
    credentials(read, &mut |[at, does], value| {
        if !value.is_empty() {
            return;
        }
        if let Some(kept) = placed.get(&at) {
            value.clone_from(kept);
        } else if let Some(Some(kept)) = doing.get(&does) {
            value.clone_from(kept);
        }
    });
}

// ------------------------------------------------------------------ names

/// A file name for something called `name`: the same where it can be, and
/// never one that a file system refuses or that two names would share.
fn file_name(name: &str, taken: &mut BTreeSet<String>) -> String {
    let mut base: String = name
        .trim()
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    base = base.trim_matches(|c| c == '.' || c == ' ').to_string();
    if base.is_empty() {
        base = "untitled".into();
    }
    base.truncate(base.char_indices().nth(80).map_or(base.len(), |(i, _)| i));
    let mut candidate = base.clone();
    // Some file systems take `Login` and `login` for the same name.
    let mut n = 2;
    while !taken.insert(candidate.to_lowercase()) {
        candidate = format!("{base} {n}");
        n += 1;
    }
    candidate
}

// ---------------------------------------------------------------- writing

/// Works out the files for `items`, which live in `dir`, and returns the
/// order they are to be listed in.
fn plan(items: &[Item], dir: &Path, files: &mut BTreeMap<PathBuf, String>) -> Vec<String> {
    let mut taken = BTreeSet::from([COLLECTION_FILE.to_string(), FOLDER_FILE.to_string()]);
    let mut order = Vec::new();
    for item in items {
        match &item.request {
            Some(request) => {
                // The suffix is part of the name two requests must not share.
                let mut stems = BTreeSet::new();
                let stem = loop {
                    let stem = file_name(&item.name, &mut stems);
                    if taken.insert(format!("{stem}{REQUEST_SUFFIX}").to_lowercase()) {
                        break stem;
                    }
                };
                let name = format!("{stem}{REQUEST_SUFFIX}");
                files.insert(
                    dir.join(&name),
                    pretty(&RequestFile {
                        name: item.name.clone(),
                        request: request.clone(),
                    }),
                );
                order.push(name);
            }
            None => {
                let name = file_name(&item.name, &mut taken);
                let folder = dir.join(&name);
                let inner = plan(&item.items, &folder, files);
                files.insert(
                    folder.join(FOLDER_FILE),
                    pretty(&FolderFile {
                        name: item.name.clone(),
                        order: inner,
                    }),
                );
                order.push(name);
            }
        }
    }
    order
}

/// The files in `dir` that an earlier write put there: its requests, and
/// those of every folder that says it is one of ours.
fn owned(dir: &Path, found: &mut Vec<PathBuf>, folders: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        if path.is_dir() {
            if path.join(FOLDER_FILE).is_file() {
                owned(&path, found, folders);
                folders.push(path);
            }
        } else if name == FOLDER_FILE || name == COLLECTION_FILE || name.ends_with(REQUEST_SUFFIX) {
            found.push(path);
        }
    }
}

/// Writes the collection into `dir`, one file for each request. Files that
/// are already as they should be are left untouched; requests and folders
/// that are no longer in the collection are removed, and nothing else in
/// the folder is.
pub fn write_collection_dir(dir: &str, collection: &Collection) -> Result<(), Error> {
    let root = Path::new(dir);
    let written = without_credentials(collection);
    let mut files = BTreeMap::new();
    let order = plan(&written.items, root, &mut files);
    files.insert(
        root.join(COLLECTION_FILE),
        pretty(&CollectionFile {
            reqorb: VERSION,
            name: written.name.clone(),
            variables: written.variables.clone(),
            order,
        }),
    );

    std::fs::create_dir_all(root).map_err(|e| io("create", root, e))?;
    let (mut stale, mut folders) = (Vec::new(), Vec::new());
    owned(root, &mut stale, &mut folders);
    for (path, text) in &files {
        if std::fs::read_to_string(path).is_ok_and(|current| &current == text) {
            continue;
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| io("create", parent, e))?;
        }
        std::fs::write(path, text).map_err(|e| io("write", path, e))?;
    }
    for path in stale.iter().filter(|path| !files.contains_key(*path)) {
        std::fs::remove_file(path).map_err(|e| io("remove", path, e))?;
    }
    // Deepest first; a folder that still holds something of the user's stays.
    for folder in &folders {
        let _ = std::fs::remove_dir(folder);
    }
    Ok(())
}

// ---------------------------------------------------------------- reading

fn read_json<T: for<'a> Deserialize<'a>>(path: &Path) -> Result<T, Error> {
    let text = std::fs::read_to_string(path).map_err(|e| io("read", path, e))?;
    // A file left half merged says so better than a JSON error would.
    if text.contains("<<<<<<< ") && text.contains(">>>>>>> ") {
        return Err(Error::Format(format!(
            "{} has an unresolved merge conflict",
            path.display()
        )));
    }
    serde_json::from_str(&text)
        .map_err(|e| Error::Format(format!("{} is not valid: {e}", path.display())))
}

/// The requests and folders in `dir`: those `order` names first, as it
/// names them, then any it does not know of, by name.
fn read_items(dir: &Path, order: &[String]) -> Result<Vec<Item>, Error> {
    let mut present = BTreeSet::new();
    for entry in std::fs::read_dir(dir).map_err(|e| io("read", dir, e))? {
        let entry = entry.map_err(|e| io("read", dir, e))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = entry.path();
        let ours = if path.is_dir() {
            !name.starts_with('.') && path.join(FOLDER_FILE).is_file()
        } else {
            name.ends_with(REQUEST_SUFFIX)
        };
        if ours {
            present.insert(name);
        }
    }
    let mut names: Vec<String> = order
        .iter()
        .filter(|name| present.remove(*name))
        .cloned()
        .collect();
    names.extend(present);

    let mut items = Vec::new();
    for name in names {
        let path = dir.join(&name);
        if path.is_dir() {
            let folder: FolderFile = read_json(&path.join(FOLDER_FILE))?;
            items.push(Item {
                name: folder.name,
                request: None,
                items: read_items(&path, &folder.order)?,
            });
        } else {
            let file: RequestFile = read_json(&path)?;
            items.push(Item {
                name: file.name,
                request: Some(file.request),
                items: Vec::new(),
            });
        }
    }
    Ok(items)
}

/// Whether `dir` holds a collection written by [`write_collection_dir`].
pub fn is_collection_dir(dir: &str) -> bool {
    Path::new(dir).join(COLLECTION_FILE).is_file()
}

/// Reads the collection kept in `dir`. Credentials, which the files do not
/// hold, are taken from `local` where it has them: the copy of the same
/// collection that this machine keeps.
pub fn read_collection_dir(dir: &str, local: Option<&Collection>) -> Result<Collection, Error> {
    let root = Path::new(dir);
    let path = root.join(COLLECTION_FILE);
    if !path.is_file() {
        return Err(Error::Format(format!(
            "{} is not a reqorb collection: it has no {COLLECTION_FILE}",
            root.display()
        )));
    }
    let file: CollectionFile = read_json(&path)?;
    if file.reqorb > VERSION {
        return Err(Error::Format(format!(
            "{} was written by a newer reqorb (format {}); update to read it",
            root.display(),
            file.reqorb
        )));
    }
    let mut collection = Collection {
        name: file.name,
        variables: file.variables,
        items: read_items(root, &file.order)?,
        link: local.and_then(|local| local.link.clone()),
    };
    if let Some(local) = local {
        restore_credentials(&mut collection, local);
    }
    Ok(collection)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Auth, AuthKind, FolderLink};

    fn leaf(name: &str, url: &str) -> Item {
        Item {
            name: name.into(),
            request: Some(Request::new("GET", url)),
            items: Vec::new(),
        }
    }

    fn shop() -> Collection {
        let mut login = leaf("Login", "{{base}}/login");
        let request = login.request.as_mut().unwrap();
        request.auth = Some(Auth::new(
            AuthKind::Basic,
            &[("username", "ada"), ("password", "s3cret")],
        ));
        request.add_header("X-Api-Key", "k-123");
        request.add_header("Accept", "application/json");
        let mut by_reference = leaf("Me", "{{base}}/me");
        by_reference.request.as_mut().unwrap().auth =
            Some(Auth::new(AuthKind::Bearer, &[("token", "{{token}}")]));
        Collection {
            name: "Shop".into(),
            variables: vec![
                Variable::new("base", "https://api.test"),
                Variable {
                    secret: true,
                    ..Variable::new("pin", "1234")
                },
            ],
            items: vec![
                login,
                Item {
                    name: "Orders".into(),
                    request: None,
                    items: vec![leaf("List: all?", "{{base}}/orders"), by_reference],
                },
                leaf("login", "{{base}}/again"),
            ],
            link: Some(FolderLink {
                path: "/somewhere".into(),
                grant: "g".into(),
            }),
        }
    }

    fn files(dir: &Path) -> Vec<String> {
        fn walk(dir: &Path, root: &Path, out: &mut Vec<String>) {
            for entry in std::fs::read_dir(dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    walk(&path, root, out);
                } else {
                    out.push(
                        path.strip_prefix(root)
                            .unwrap()
                            .to_string_lossy()
                            .replace('\\', "/"),
                    );
                }
            }
        }
        let mut out = Vec::new();
        walk(dir, dir, &mut out);
        out.sort();
        out
    }

    #[test]
    fn writes_one_file_for_each_request_and_reads_them_back() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_str().unwrap();
        let shop = shop();
        write_collection_dir(path, &shop).unwrap();
        assert_eq!(
            files(dir.path()),
            [
                "Login.request.json",
                "Orders/List_ all_.request.json",
                "Orders/Me.request.json",
                "Orders/folder.json",
                "collection.json",
                // Told apart even where `Login` and `login` are one name.
                "login 2.request.json",
            ]
        );
        assert!(is_collection_dir(path));

        // With the copy this machine holds, it comes back whole.
        assert_eq!(read_collection_dir(path, Some(&shop)).unwrap(), shop);
    }

    #[test]
    fn leaves_credentials_out_of_the_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_str().unwrap();
        write_collection_dir(path, &shop()).unwrap();
        let everything: String = files(dir.path())
            .iter()
            .map(|file| std::fs::read_to_string(dir.path().join(file)).unwrap())
            .collect();
        for secret in ["s3cret", "k-123", "1234", "/somewhere"] {
            assert!(!everything.contains(secret), "{secret} was written");
        }
        // What is not a credential is there, and so is a reference to one.
        for kept in ["ada", "application/json", "{{token}}", "https://api.test"] {
            assert!(everything.contains(kept), "{kept} is missing");
        }

        // Someone else, with no copy of their own, gets the blanks to fill.
        let fresh = read_collection_dir(path, None).unwrap();
        assert_eq!(fresh.link, None);
        assert_eq!(fresh.variables[1].value, "");
        let login = fresh.items[0].request.as_ref().unwrap();
        assert_eq!(login.auth.as_ref().unwrap().params[1].value, "");
        assert_eq!(login.headers[0].value, "");
    }

    #[test]
    fn credentials_follow_a_request_that_is_renamed_or_moved() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_str().unwrap();
        let local = shop();
        // As someone else left it: Login renamed and put inside Orders.
        let mut theirs = local.clone();
        let mut login = theirs.items.remove(0);
        login.name = "Sign in".into();
        theirs.items[0].items.push(login);
        write_collection_dir(path, &theirs).unwrap();

        let read = read_collection_dir(path, Some(&local)).unwrap();
        let login = read.items[0].items[2].request.as_ref().unwrap();
        assert_eq!(login.auth.as_ref().unwrap().params[1].value, "s3cret");
        assert_eq!(login.headers[0].value, "k-123");
    }

    #[test]
    fn a_second_write_touches_only_what_changed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_str().unwrap();
        let mut shop = shop();
        write_collection_dir(path, &shop).unwrap();
        // Things of the user's own, which are none of our business.
        std::fs::write(dir.path().join("README.md"), "notes").unwrap();
        std::fs::create_dir(dir.path().join("docs")).unwrap();
        std::fs::write(dir.path().join("docs/guide.request.json"), "{}").unwrap();
        let stamp = |file: &str| {
            std::fs::metadata(dir.path().join(file))
                .unwrap()
                .modified()
                .unwrap()
        };
        let before = stamp("Login.request.json");

        std::thread::sleep(std::time::Duration::from_millis(20));
        shop.items[2].request.as_mut().unwrap().url = "{{base}}/changed".into();
        shop.items.remove(1);
        write_collection_dir(path, &shop).unwrap();

        assert_eq!(stamp("Login.request.json"), before);
        assert_eq!(
            files(dir.path()),
            [
                "Login.request.json",
                "README.md",
                "collection.json",
                "docs/guide.request.json",
                "login 2.request.json",
            ]
        );
        let read = read_collection_dir(path, Some(&shop)).unwrap();
        assert_eq!(read, shop);
    }

    #[test]
    fn takes_up_files_added_by_hand_and_keeps_the_order_given() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_str().unwrap();
        write_collection_dir(path, &shop()).unwrap();
        // As a merge might leave it: a new request nobody listed, and the
        // order changed.
        std::fs::write(
            dir.path().join("Added.request.json"),
            r#"{"name": "Added by hand", "request": {"method": "GET", "url": "x"}}"#,
        )
        .unwrap();
        let mut file: CollectionFile = read_json(&dir.path().join(COLLECTION_FILE)).unwrap();
        file.order.reverse();
        file.order.push("gone.request.json".into());
        std::fs::write(dir.path().join(COLLECTION_FILE), pretty(&file)).unwrap();

        let read = read_collection_dir(path, None).unwrap();
        let names: Vec<&str> = read.items.iter().map(|i| i.name.as_str()).collect();
        assert_eq!(names, ["login", "Orders", "Login", "Added by hand"]);
    }

    #[test]
    fn explains_a_folder_it_cannot_read() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_str().unwrap();
        let message = |local| read_collection_dir(path, local).unwrap_err().to_string();
        assert!(message(None).contains("is not a reqorb collection"));

        write_collection_dir(path, &shop()).unwrap();
        std::fs::write(
            dir.path().join("Login.request.json"),
            "<<<<<<< HEAD\n{}\n=======\n{}\n>>>>>>> theirs\n",
        )
        .unwrap();
        assert!(message(None).contains("unresolved merge conflict"));

        std::fs::write(dir.path().join("Login.request.json"), "{").unwrap();
        assert!(message(None).contains("Login.request.json is not valid"));

        std::fs::write(
            dir.path().join(COLLECTION_FILE),
            r#"{"reqorb": 99, "name": "x"}"#,
        )
        .unwrap();
        assert!(message(None).contains("newer reqorb"));
    }
}
