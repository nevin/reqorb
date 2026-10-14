//! Reading and writing other tools' formats: detecting what a piece of text
//! is and importing it, and exporting collections and environments.
//!
//! Each format has its own module holding both directions.

mod bruno;
mod curl;
mod dotenv;
pub(crate) mod har;
mod native;
mod openapi;
mod postman;
mod tree;
pub(crate) mod util;

#[cfg(test)]
mod export_tests;
#[cfg(test)]
mod import_tests;

use serde_json::{Value, json};

pub use curl::to_curl;
pub use har::{import_har, to_har};
pub use native::export_native;
pub use tree::{
    collection_dir_stamp, is_collection_dir, read_collection_dir, write_collection_dir,
};

use self::bruno::bruno_collection;
use self::curl::curl;
use self::dotenv::{dotenv, dotenv_line};
use self::native::NativeFile;
use self::postman::{Postman, postman_collection, postman_variables};
use self::util::{pretty, str_field};
use crate::{Collection, Environment, Error, Item, Request, send};

#[derive(Debug, Clone, Default)]
pub struct ImportResult {
    /// What the input was recognised as: `reqorb`, `postman-collection`,
    /// `postman-environment`, `openapi`, `har`, `curl` or `dotenv`.
    pub source: String,
    pub collections: Vec<Collection>,
    pub environments: Vec<Environment>,
    /// Things that could not be carried over.
    pub warnings: Vec<String>,
}

/// Detects the format of `text` and imports it. `name_hint` names things the
/// format itself leaves unnamed, such as a `.env` file's environment.
pub fn import(text: &str, name_hint: &str) -> Result<ImportResult, Error> {
    import_from(text, name_hint, None)
}

/// Like [`import`], for text downloaded from `origin`. An OpenAPI document
/// that does not name its server is assumed to describe that host.
pub(crate) fn import_from(
    text: &str,
    name_hint: &str,
    origin: Option<&url::Url>,
) -> Result<ImportResult, Error> {
    let mut result = parse(text, name_hint, origin)?;
    // A curl command is one line, read in full as it is pasted.
    if result.source == "curl" {
        return Ok(result);
    }
    // Scripts and files from elsewhere wait to be allowed before use.
    let mut scripted = 0;
    let mut files = 0;
    for collection in &mut result.collections {
        scripted += collection.scripts().len();
        files += collection.files().len();
        collection.unreviewed = collection.needs_review();
    }
    if files > 0 {
        result.warnings.insert(
            0,
            format!(
                "{files} file(s) are read from your disk and sent by these requests. reqorb \
                 asks before they are first read."
            ),
        );
    }
    if scripted > 0 {
        result.warnings.insert(
            0,
            format!(
                "{scripted} request(s) carry scripts, which run each time they are sent and can \
                 read your variables, credentials included. reqorb asks before they first run."
            ),
        );
    }
    Ok(result)
}

fn parse(text: &str, name_hint: &str, origin: Option<&url::Url>) -> Result<ImportResult, Error> {
    let text = text.trim_start_matches('\u{feff}').trim();
    let name_hint = if name_hint.trim().is_empty() {
        "Imported"
    } else {
        name_hint.trim()
    };

    if text.starts_with('{') {
        let value: Value =
            serde_json::from_str(text).map_err(|e| Error::Format(format!("invalid JSON: {e}")))?;
        // The Postman API wraps exports in `{"collection": {...}}`.
        let value = match value.get("collection") {
            Some(inner) if inner.get("item").is_some() => inner.clone(),
            _ => value,
        };
        if openapi::is_spec(&value) {
            return Ok(openapi_result(&value, name_hint, origin));
        }
        if value.get("reqorb").is_some() {
            let file: NativeFile = serde_json::from_value(value)
                .map_err(|e| Error::Format(format!("invalid reqorb file: {e}")))?;
            return Ok(ImportResult {
                source: "reqorb".into(),
                collections: file.collections,
                environments: file.environments,
                warnings: Vec::new(),
            });
        }
        if value.get("item").is_some_and(Value::is_array) {
            let mut ctx = Postman::default();
            let collection = ctx.collection(&value, name_hint);
            return Ok(ImportResult {
                source: "postman-collection".into(),
                collections: vec![collection],
                environments: Vec::new(),
                warnings: ctx.finish(),
            });
        }
        if value.get("values").is_some_and(Value::is_array) {
            return Ok(ImportResult {
                source: "postman-environment".into(),
                collections: Vec::new(),
                environments: vec![Environment {
                    name: str_field(&value, "name").unwrap_or(name_hint).to_string(),
                    variables: postman_variables(&value["values"]),
                }],
                warnings: Vec::new(),
            });
        }
        if har::is_har(&value) {
            return Ok(har::from_har(&value, name_hint));
        }
        return Err(Error::Format(
            "JSON is not a reqorb file, Postman collection, Postman environment, OpenAPI document or HAR archive"
                .into(),
        ));
    }

    // OpenAPI documents are as often YAML as JSON.
    if text
        .lines()
        .any(|l| l.starts_with("openapi:") || l.starts_with("swagger:"))
    {
        let value: Value = serde_yaml_ng::from_str(text)
            .map_err(|e| Error::Format(format!("invalid YAML: {e}")))?;
        if openapi::is_spec(&value) {
            return Ok(openapi_result(&value, name_hint, origin));
        }
    }

    if text.split_whitespace().next() == Some("curl") {
        return curl(text, name_hint);
    }

    match dotenv(text) {
        Some(variables) => Ok(ImportResult {
            source: "dotenv".into(),
            collections: Vec::new(),
            environments: vec![Environment {
                name: name_hint.to_string(),
                variables,
            }],
            warnings: Vec::new(),
        }),
        None => Err(Error::Format(
            "unrecognised format: expected reqorb, Postman or OpenAPI/Swagger JSON, a curl command, or KEY=VALUE lines"
                .into(),
        )),
    }
}

fn openapi_result(value: &Value, name_hint: &str, origin: Option<&url::Url>) -> ImportResult {
    let mut warnings = Vec::new();
    let collection = openapi::collection(value, name_hint, origin, &mut warnings);
    ImportResult {
        source: "openapi".into(),
        collections: vec![collection],
        environments: Vec::new(),
        warnings,
    }
}

/// Downloads `url` and imports it, typically a served `swagger.json`.
pub async fn import_url(url: &str) -> Result<ImportResult, Error> {
    let origin = reqwest::Url::parse(url).map_err(|e| Error::InvalidUrl {
        url: url.to_string(),
        reason: e.to_string(),
    })?;
    let mut request = Request::new("GET", url);
    request.add_header("Accept", "application/json, application/yaml, */*");
    request.timeout_ms = Some(30_000);
    let response = send(request).await?;
    if response.status >= 400 {
        return Err(Error::Http(format!(
            "{url} answered {} {}",
            response.status, response.status_text
        )));
    }
    // Name the import after the file, or the host when the path has none.
    let hint = origin
        .path_segments()
        .and_then(|mut segments| segments.next_back())
        .map(|file| file.rsplit_once('.').map_or(file, |(stem, _)| stem))
        .filter(|stem| !stem.is_empty())
        .or(origin.host_str())
        .unwrap_or("Imported");
    import_from(&response.body, hint, Some(&origin))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportFormat {
    /// reqorb's own JSON; works for collections and environments.
    Reqorb,
    /// Postman collection v2.1 or Postman environment.
    Postman,
    /// Bruno collection JSON, for Bruno's "Import Collection"; collections only.
    Bruno,
    /// One curl command per request; collections only.
    Curl,
    /// `KEY=VALUE` lines; environments only.
    Dotenv,
}

impl ExportFormat {
    /// Conventional file extension for this format.
    pub fn extension(self) -> &'static str {
        match self {
            ExportFormat::Reqorb | ExportFormat::Postman | ExportFormat::Bruno => "json",
            ExportFormat::Curl => "sh",
            ExportFormat::Dotenv => "env",
        }
    }
}

/// The collection without its WebSocket and gRPC requests, which the HTTP
/// formats of other tools have no way to describe.
fn http_only(collection: &Collection) -> Collection {
    fn keep(items: &[Item]) -> Vec<Item> {
        items
            .iter()
            .filter(|item| {
                item.request.as_ref().is_none_or(|request| {
                    !["WS", "GRPC"].contains(&request.method.to_uppercase().as_str())
                })
            })
            .map(|item| Item {
                name: item.name.clone(),
                request: item.request.clone(),
                items: keep(&item.items),
            })
            .collect()
    }
    Collection {
        name: collection.name.clone(),
        variables: collection.variables.clone(),
        items: keep(&collection.items),
        link: None,
        unreviewed: false,
    }
}

pub fn export_collection(collection: &Collection, format: ExportFormat) -> Result<String, Error> {
    if format == ExportFormat::Reqorb {
        return Ok(export_native(std::slice::from_ref(collection), &[]));
    }
    let collection = &http_only(collection);
    match format {
        ExportFormat::Reqorb => unreachable!("handled above"),
        ExportFormat::Postman => Ok(pretty(&postman_collection(collection))),
        ExportFormat::Bruno => Ok(pretty(&bruno_collection(collection))),
        ExportFormat::Curl => {
            let mut out = String::from("#!/bin/sh\n");
            for (path, request) in collection.requests() {
                out.push_str(&format!("\n# {path}\n{}\n", to_curl(request)));
            }
            Ok(out)
        }
        ExportFormat::Dotenv => Err(Error::Format(
            "a collection cannot be exported as .env; use reqorb, postman, bruno or curl".into(),
        )),
    }
}

pub fn export_environment(
    environment: &Environment,
    format: ExportFormat,
) -> Result<String, Error> {
    match format {
        ExportFormat::Reqorb => Ok(export_native(&[], std::slice::from_ref(environment))),
        ExportFormat::Postman => Ok(pretty(&json!({
            "name": environment.name,
            "values": environment.variables.iter().map(|v| json!({
                "key": v.key,
                "value": v.value,
                "type": if v.secret { "secret" } else { "default" },
                "enabled": v.enabled,
            })).collect::<Vec<_>>(),
            "_postman_variable_scope": "environment",
        }))),
        ExportFormat::Dotenv => Ok(environment.variables.iter().map(dotenv_line).collect()),
        ExportFormat::Curl | ExportFormat::Bruno => Err(Error::Format(
            "an environment can only be exported as reqorb, postman or dotenv".into(),
        )),
    }
}
