//! Reading what the user supplied: files, headers, variables, credentials.

use std::io::Read;
use std::path::Path;

use anyhow::{Context, Result, bail};
use reqorb_core::{Auth, AuthKind, AuthParam, Header, ImportResult, Variable};

use crate::cli::{SendArgs, VarArgs};

/// Builds the request's auth from whichever auth options were given.
pub(crate) fn parse_auth(args: &SendArgs) -> Result<Option<Auth>> {
    if let Some(credentials) = &args.user {
        let (user, password) = credentials.split_once(':').unwrap_or((credentials, ""));
        let kind = if args.digest {
            AuthKind::Digest
        } else {
            AuthKind::Basic
        };
        return Ok(Some(Auth::new(
            kind,
            &[("username", user), ("password", password)],
        )));
    }
    if let Some(token) = &args.bearer {
        return Ok(Some(Auth::new(AuthKind::Bearer, &[("token", token)])));
    }
    let Some(id) = &args.auth else {
        return Ok(None);
    };
    let Some(kind) = AuthKind::from_id(&id.to_lowercase()) else {
        let known: Vec<&str> = AuthKind::ALL.iter().skip(1).map(|k| k.id()).collect();
        bail!("unknown auth type `{id}`; use one of {}", known.join(", "));
    };
    let fields = reqorb_core::auth_fields(kind);
    let mut auth = Auth::new(kind, &[]);
    for raw in &args.auth_params {
        let Some((key, value)) = raw.split_once('=') else {
            bail!("auth parameter `{raw}` must look like `key=value`");
        };
        if !fields.iter().any(|f| f.key == key) {
            let known: Vec<&str> = fields.iter().map(|f| f.key.as_str()).collect();
            bail!(
                "{} has no field `{key}`; its fields are {}",
                kind.label(),
                known.join(", ")
            );
        }
        auth.params.push(AuthParam {
            key: key.to_string(),
            value: value.to_string(),
        });
    }
    Ok(Some(auth))
}

pub(crate) fn parse_header(raw: &str) -> Result<Header> {
    let Some((name, value)) = raw.split_once(':') else {
        bail!("header `{raw}` must look like `Name: value`");
    };
    Ok(Header {
        name: name.trim().to_string(),
        value: value.trim().to_string(),
    })
}

pub(crate) fn read_body(arg: &str) -> Result<String> {
    match arg.strip_prefix('@') {
        Some("-") => read_input(Path::new("-")),
        Some(path) => read_input(Path::new(path)),
        None => Ok(arg.to_string()),
    }
}

pub(crate) fn read_input(path: &Path) -> Result<String> {
    if path == Path::new("-") {
        let mut buf = String::new();
        std::io::stdin().read_to_string(&mut buf)?;
        Ok(buf)
    } else {
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))
    }
}

/// Reads any importable file or `http(s)` URL, printing what could not be
/// carried over.
pub(crate) async fn load_source(source: &str) -> Result<ImportResult> {
    let result = if source.starts_with("http://") || source.starts_with("https://") {
        reqorb_core::import_url(source).await
    } else {
        let path = Path::new(source);
        let hint = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        let hint = hint.strip_suffix(".postman_collection").unwrap_or(hint);
        let hint = hint.strip_suffix(".postman_environment").unwrap_or(hint);
        reqorb_core::import(&read_input(path)?, hint)
    }
    .with_context(|| format!("importing {source}"))?;
    for warning in &result.warnings {
        eprintln!("warning: {warning}");
    }
    Ok(result)
}

/// Variables in priority order: `--var` first, then the `--env` file.
pub(crate) async fn load_variables(args: &VarArgs) -> Result<Vec<Variable>> {
    let mut variables = Vec::new();
    for raw in &args.vars {
        let Some((key, value)) = raw.split_once('=') else {
            bail!("variable `{raw}` must look like `KEY=VALUE`");
        };
        variables.push(Variable::new(key.trim(), value));
    }
    if let Some(path) = &args.env {
        let imported = load_source(&path.to_string_lossy()).await?;
        if imported.environments.is_empty() {
            bail!("{} does not contain an environment", path.display());
        }
        for environment in imported.environments {
            variables.extend(environment.variables);
        }
    }
    Ok(variables)
}
