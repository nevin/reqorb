//! Exporters for reqorb's own JSON format, Postman, Bruno, curl and `.env`.

use serde_json::{Value, json};

use crate::import::{NATIVE_VERSION, NativeFile};
use crate::{
    Auth, AuthKind, BodyMode, Collection, DisabledTls, Environment, Error, HttpMode, Item, Request,
    RequestSettings, Variable,
};

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

fn pretty(value: &impl serde::Serialize) -> String {
    let mut out = serde_json::to_string_pretty(value).expect("serialises to JSON");
    out.push('\n');
    out
}

/// Bundles collections and environments into one reqorb file.
pub fn export_native(collections: &[Collection], environments: &[Environment]) -> String {
    pretty(&NativeFile {
        reqorb: NATIVE_VERSION,
        collections: collections.to_vec(),
        environments: environments.to_vec(),
    })
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
                "type": "default",
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

fn dotenv_line(variable: &Variable) -> String {
    let needs_quotes = variable.value.is_empty()
        || variable
            .value
            .chars()
            .any(|c| c.is_whitespace() || "#\"'\\".contains(c));
    let value = if needs_quotes && !variable.value.is_empty() {
        format!(
            "\"{}\"",
            variable
                .value
                .replace('\\', "\\\\")
                .replace('"', "\\\"")
                .replace('\n', "\\n")
        )
    } else {
        variable.value.clone()
    };
    let prefix = if variable.enabled { "" } else { "# " };
    format!("{prefix}{}={value}\n", variable.key)
}

fn postman_collection(collection: &Collection) -> Value {
    let mut out = json!({
        "info": {
            "name": collection.name,
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
        },
        "item": collection.items.iter().map(postman_item).collect::<Vec<_>>(),
    });
    if !collection.variables.is_empty() {
        out["variable"] = collection
            .variables
            .iter()
            .map(|v| {
                let mut entry = json!({"key": v.key, "value": v.value, "type": "string"});
                if !v.enabled {
                    entry["disabled"] = json!(true);
                }
                entry
            })
            .collect();
    }
    out
}

fn postman_item(item: &Item) -> Value {
    let Some(request) = &item.request else {
        return json!({
            "name": item.name,
            "item": item.items.iter().map(postman_item).collect::<Vec<_>>(),
        });
    };
    let mut out = json!({
        "method": request.method,
        "header": request.headers.iter().map(|h| json!({
            "key": h.name,
            "value": h.value,
        })).collect::<Vec<_>>(),
        "url": {"raw": request.url},
    });
    if let Some(auth) = &request.auth {
        let params: Vec<Value> = auth
            .params
            .iter()
            .map(|p| {
                // Postman stores this one choice as a boolean.
                let value = if auth.kind == AuthKind::OAuth1 && p.key == "addParamsToHeader" {
                    json!(p.value != "query")
                } else {
                    json!(p.value)
                };
                json!({"key": p.key, "value": value, "type": "string"})
            })
            .collect();
        out["auth"] = json!({"type": auth.kind.id(), auth.kind.id(): params});
    }
    let fields = |files: bool| -> Vec<Value> {
        request
            .form
            .iter()
            .map(|f| match (f.file, files) {
                (true, true) => json!({"key": f.key, "type": "file", "src": f.value}),
                _ => json!({"key": f.key, "value": f.value, "type": "text"}),
            })
            .collect()
    };
    match (request.effective_body_mode(), &request.body) {
        (BodyMode::FormData, _) => {
            out["body"] = json!({"mode": "formdata", "formdata": fields(true)});
        }
        (BodyMode::UrlEncoded, _) if !request.form.is_empty() => {
            out["body"] = json!({"mode": "urlencoded", "urlencoded": fields(false)});
        }
        (BodyMode::Binary, Some(path)) => {
            out["body"] = json!({"mode": "file", "file": {"src": path}});
        }
        (BodyMode::Raw | BodyMode::UrlEncoded, Some(body)) => {
            let language = request
                .headers
                .iter()
                .find(|h| h.name.eq_ignore_ascii_case("content-type"))
                .map(|h| h.value.to_ascii_lowercase())
                .map(|ct| {
                    if ct.contains("json") {
                        "json"
                    } else if ct.contains("xml") {
                        "xml"
                    } else if ct.contains("html") {
                        "html"
                    } else {
                        "text"
                    }
                })
                .unwrap_or("text");
            out["body"] = json!({
                "mode": "raw",
                "raw": body,
                "options": {"raw": {"language": language}},
            });
        }
        _ => {}
    }
    let mut exported = json!({"name": item.name, "request": out, "response": []});
    if let Some(profile) = request.settings.as_ref().and_then(postman_profile) {
        exported["protocolProfileBehavior"] = profile;
    }
    exported
}

/// Bruno identifies everything by a 21-character alphanumeric id. It assigns
/// fresh ones on import, but its schema still requires them to be present.
fn bruno_uid() -> String {
    use std::hash::{BuildHasher, Hasher};
    const ALPHABET: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut out = String::with_capacity(21);
    while out.len() < 21 {
        // Each RandomState is seeded differently, which is all the randomness needed.
        let mut bits = std::collections::hash_map::RandomState::new()
            .build_hasher()
            .finish();
        for _ in 0..12 {
            if out.len() < 21 {
                out.push(ALPHABET[(bits % 36) as usize] as char);
                bits /= 36;
            }
        }
    }
    out
}

fn bruno_pair(name: &str, value: &str) -> Value {
    json!({"uid": bruno_uid(), "name": name, "value": value, "enabled": true})
}

fn bruno_collection(collection: &Collection) -> Value {
    let mut out = json!({
        "name": collection.name,
        "version": "1",
        "uid": bruno_uid(),
        "items": bruno_items(&collection.items),
        "environments": [],
        "brunoConfig": {
            "version": "1",
            "name": collection.name,
            "type": "collection",
            "ignore": ["node_modules", ".git"],
        },
    });
    if !collection.variables.is_empty() {
        let vars: Vec<Value> = collection
            .variables
            .iter()
            .map(|v| json!({"uid": bruno_uid(), "name": v.key, "value": v.value, "enabled": v.enabled}))
            .collect();
        out["root"] = json!({"request": {"vars": {"req": vars}}});
    }
    out
}

fn bruno_items(items: &[Item]) -> Vec<Value> {
    items
        .iter()
        .enumerate()
        .map(|(index, item)| {
            let Some(request) = &item.request else {
                return json!({
                    "uid": bruno_uid(),
                    "type": "folder",
                    "name": item.name,
                    "seq": index + 1,
                    "items": bruno_items(&item.items),
                });
            };
            let mut out = json!({
                "uid": bruno_uid(),
                "type": "http-request",
                "name": item.name,
                "seq": index + 1,
                "request": bruno_request(request),
            });
            if let Some(ms) = request.timeout_ms {
                out["settings"] = json!({"timeout": ms});
            }
            out
        })
        .collect()
}

fn bruno_request(request: &Request) -> Value {
    // Url-encoded fields become body text first, so one code path handles them.
    let mut request = request.clone();
    request.materialize();
    let request = &request;
    // Bruno lists query parameters alongside the URL that contains them.
    let query = request
        .url
        .split_once('?')
        .map(|(_, q)| q.split('#').next().unwrap_or(""))
        .unwrap_or("");
    let params: Vec<Value> = query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
            let mut param = bruno_pair(name, value);
            param["type"] = json!("query");
            param
        })
        .collect();

    let content_type = request
        .headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case("content-type"))
        .map(|h| h.value.to_ascii_lowercase())
        .unwrap_or_default();
    let text = match request.effective_body_mode() {
        BodyMode::Raw | BodyMode::UrlEncoded => request.body.as_ref(),
        _ => None,
    };
    let body = match text {
        _ if request.effective_body_mode() == BodyMode::FormData => json!({
            "mode": "multipartForm",
            "multipartForm": request.form.iter().map(|f| {
                let value = if f.file { json!([f.value]) } else { json!(f.value) };
                json!({
                    "uid": bruno_uid(),
                    "type": if f.file { "file" } else { "text" },
                    "name": f.key,
                    "value": value,
                    "enabled": true,
                })
            }).collect::<Vec<_>>(),
        }),
        None => json!({"mode": "none"}),
        Some(body) if content_type.contains("json") => json!({"mode": "json", "json": body}),
        Some(body) if content_type.contains("xml") => json!({"mode": "xml", "xml": body}),
        Some(body) if content_type.contains("x-www-form-urlencoded") => json!({
            "mode": "formUrlEncoded",
            "formUrlEncoded": url::form_urlencoded::parse(body.as_bytes())
                .map(|(name, value)| bruno_pair(&name, &value))
                .collect::<Vec<_>>(),
        }),
        Some(body) => json!({"mode": "text", "text": body}),
    };

    json!({
        "url": request.url,
        "method": request.method.to_uppercase(),
        "headers": request.headers.iter().map(|h| bruno_pair(&h.name, &h.value)).collect::<Vec<_>>(),
        "params": params,
        "body": body,
        "auth": bruno_auth(request.auth.as_ref()),
        "script": {},
        "vars": {},
        "assertions": [],
        "tests": "",
        "docs": "",
    })
}

/// The request's settings as Postman's protocol profile, listing only what
/// differs from the defaults.
fn postman_profile(settings: &RequestSettings) -> Option<Value> {
    let defaults = RequestSettings::default();
    let mut profile = serde_json::Map::new();
    let mut flag = |key: &str, value: bool, default: bool| {
        if value != default {
            profile.insert(key.to_string(), json!(value));
        }
    };
    flag(
        "followRedirects",
        settings.follow_redirects,
        defaults.follow_redirects,
    );
    flag(
        "followOriginalHttpMethod",
        settings.follow_original_method,
        defaults.follow_original_method,
    );
    flag(
        "followAuthorizationHeader",
        settings.follow_auth_header,
        defaults.follow_auth_header,
    );
    flag(
        "removeRefererHeaderOnRedirect",
        settings.remove_referer,
        defaults.remove_referer,
    );
    flag("strictSSL", settings.verify_ssl, defaults.verify_ssl);
    flag(
        "disableCookies",
        settings.disable_cookie_jar,
        defaults.disable_cookie_jar,
    );
    // Postman's flag has the opposite sense: it turns leniency on.
    flag(
        "insecureHTTPParser",
        !settings.strict_http_parser,
        !defaults.strict_http_parser,
    );
    if settings.max_redirects != defaults.max_redirects {
        profile.insert("maxRedirects".into(), json!(settings.max_redirects));
    }
    if let Some(mode) = settings.http_mode {
        let version = match mode {
            HttpMode::Auto => "auto",
            HttpMode::Http1 => "http1",
            HttpMode::Http2 => "http2",
        };
        profile.insert("protocolVersion".into(), json!(version));
    }
    match settings.disabled_tls {
        DisabledTls::None => {}
        DisabledTls::Tls12 => {
            drop(profile.insert("tlsDisabledProtocols".into(), json!(["TLSv1_2"])))
        }
        DisabledTls::Tls13 => {
            drop(profile.insert("tlsDisabledProtocols".into(), json!(["TLSv1_3"])))
        }
    }
    (!profile.is_empty()).then_some(Value::Object(profile))
}

/// Maps the auth types Bruno shares with reqorb; the rest export as none.
fn bruno_auth(auth: Option<&Auth>) -> Value {
    let Some(auth) = auth else {
        return json!({"mode": "none"});
    };
    let get = |key: &str| auth.get(key);
    match auth.kind {
        AuthKind::Basic => json!({
            "mode": "basic",
            "basic": {"username": get("username"), "password": get("password")},
        }),
        AuthKind::Bearer => json!({"mode": "bearer", "bearer": {"token": get("token")}}),
        AuthKind::Digest => json!({
            "mode": "digest",
            "digest": {"username": get("username"), "password": get("password")},
        }),
        AuthKind::Ntlm => json!({
            "mode": "ntlm",
            "ntlm": {"username": get("username"), "password": get("password"), "domain": get("domain")},
        }),
        AuthKind::ApiKey => json!({
            "mode": "apikey",
            "apikey": {
                "key": get("key"),
                "value": get("value"),
                "placement": if get("in") == "query" { "queryparams" } else { "header" },
            },
        }),
        AuthKind::AwsV4 => json!({
            "mode": "awsv4",
            "awsv4": {
                "accessKeyId": get("accessKey"),
                "secretAccessKey": get("secretKey"),
                "sessionToken": get("sessionToken"),
                "service": get("service"),
                "region": get("region"),
                "profileName": "",
            },
        }),
        _ => json!({"mode": "none"}),
    }
}

/// Renders the request as a curl command that a POSIX shell can run. Auth
/// uses curl's own options where it has them; types curl cannot compute are
/// left out and noted in a leading comment.
pub fn to_curl(request: &Request) -> String {
    let mut request = request.clone();
    let mut auth_args = Vec::new();
    let mut note = None;
    if let Some(auth) = request.auth.take() {
        let get = |key: &str| auth.get(key);
        let user = |name: &str, secret: &str| {
            format!(
                "-u {}",
                shell_quote(&format!("{}:{}", get(name), get(secret)))
            )
        };
        match auth.kind {
            AuthKind::None => {}
            AuthKind::Basic => auth_args.push(user("username", "password")),
            AuthKind::Digest => {
                auth_args.push(format!("--digest {}", user("username", "password")))
            }
            AuthKind::Ntlm => {
                let name = match get("domain") {
                    domain if domain.is_empty() => get("username"),
                    domain => format!("{domain}\\{}", get("username")),
                };
                auth_args.push(format!(
                    "--ntlm -u {}",
                    shell_quote(&format!("{name}:{}", get("password")))
                ));
            }
            AuthKind::AwsV4 => {
                auth_args.push(format!(
                    "--aws-sigv4 {} {}",
                    shell_quote(&format!("aws:amz:{}:{}", get("region"), get("service"))),
                    user("accessKey", "secretKey")
                ));
                if !get("sessionToken").is_empty() {
                    request.add_header("X-Amz-Security-Token", get("sessionToken"));
                }
            }
            AuthKind::Bearer => {
                request.add_header("Authorization", format!("Bearer {}", get("token")))
            }
            AuthKind::OAuth2 if !get("accessToken").is_empty() => {
                let value = format!("{} {}", get("headerPrefix"), get("accessToken"));
                request.add_header("Authorization", value.trim().to_string());
            }
            AuthKind::ApiKey if get("in") == "query" => {
                // Appended as written so `{{variables}}` stay intact.
                let separator = if request.url.contains('?') { '&' } else { '?' };
                request.url = format!("{}{separator}{}={}", request.url, get("key"), get("value"));
            }
            AuthKind::ApiKey => request.add_header(&get("key"), get("value")),
            kind => {
                note = Some(format!(
                    "# {} is computed by reqorb when sending and is not part of this command.\n",
                    kind.label()
                ))
            }
        }
    }
    request.materialize();
    let request = &request;
    let mode = request.effective_body_mode();
    let mut parts = vec![String::from("curl")];
    let has_body = match mode {
        BodyMode::None => false,
        BodyMode::FormData => !request.form.is_empty(),
        _ => request.body.is_some(),
    };
    let default_method = if has_body { "POST" } else { "GET" };
    if !request.method.eq_ignore_ascii_case(default_method) {
        parts.push(format!("-X {}", request.method.to_uppercase()));
    }
    parts.push(shell_quote(&request.url));
    for h in &request.headers {
        parts.push(format!(
            "-H {}",
            shell_quote(&format!("{}: {}", h.name, h.value))
        ));
    }
    match (mode, &request.body) {
        (BodyMode::FormData, _) => {
            for field in &request.form {
                let at = if field.file { "@" } else { "" };
                let option = if field.file || !field.value.starts_with('@') {
                    "-F"
                } else {
                    // Stops curl reading a text value that starts with @ as a file.
                    "--form-string"
                };
                parts.push(format!(
                    "{option} {}",
                    shell_quote(&format!("{}={at}{}", field.key, field.value))
                ));
            }
        }
        (BodyMode::Binary, Some(path)) => {
            parts.push(format!(
                "--data-binary {}",
                shell_quote(&format!("@{path}"))
            ));
        }
        (BodyMode::Raw | BodyMode::UrlEncoded, Some(body)) => {
            parts.push(format!("--data-raw {}", shell_quote(body)));
        }
        _ => {}
    }
    parts.extend(auth_args);
    if let Some(ms) = request.timeout_ms {
        parts.push(format!("--max-time {}", ms as f64 / 1000.0));
    }
    format!("{}{}", note.unwrap_or_default(), parts.join(" \\\n  "))
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Header, import};

    fn sample() -> Collection {
        let mut create = Request::new("POST", "{{base}}/orders?x=it's");
        create.headers.push(Header {
            name: "Content-Type".into(),
            value: "application/json".into(),
        });
        create.body = Some("{\"sku\": \"a'b\"}".into());
        create.timeout_ms = Some(1500);
        Collection {
            name: "Shop".into(),
            variables: vec![
                Variable::new("base", "https://shop.test"),
                Variable {
                    key: "off".into(),
                    value: "1".into(),
                    enabled: false,
                },
            ],
            items: vec![
                Item {
                    name: "Orders".into(),
                    request: None,
                    items: vec![Item {
                        name: "Create".into(),
                        request: Some(create),
                        items: Vec::new(),
                    }],
                },
                Item {
                    name: "Ping".into(),
                    request: Some(Request::new("GET", "{{base}}/ping")),
                    items: Vec::new(),
                },
            ],
        }
    }

    fn sample_env() -> Environment {
        Environment {
            name: "Staging".into(),
            variables: vec![
                Variable::new("base", "https://staging.test"),
                Variable::new("note", "two words # \"quoted\""),
                Variable {
                    key: "debug".into(),
                    value: "1".into(),
                    enabled: false,
                },
            ],
        }
    }

    #[test]
    fn native_round_trip() {
        let text = export_native(&[sample()], &[sample_env()]);
        let back = import(&text, "x").unwrap();
        assert_eq!(back.source, "reqorb");
        assert_eq!(back.collections, [sample()]);
        assert_eq!(back.environments, [sample_env()]);
    }

    #[test]
    fn postman_round_trip() {
        let text = export_collection(&sample(), ExportFormat::Postman).unwrap();
        let back = import(&text, "x").unwrap();
        assert_eq!(back.source, "postman-collection");
        assert!(back.warnings.is_empty());
        // Postman has no per-request timeout, so that field is lost.
        let mut expected = sample();
        expected.items[0].items[0]
            .request
            .as_mut()
            .unwrap()
            .timeout_ms = None;
        assert_eq!(back.collections, [expected]);

        let text = export_environment(&sample_env(), ExportFormat::Postman).unwrap();
        let back = import(&text, "x").unwrap();
        assert_eq!(back.environments, [sample_env()]);
    }

    #[test]
    fn auth_survives_postman_and_reaches_other_formats() {
        let with = |auth: Auth| {
            let mut request = Request::new("GET", "{{base}}/secure?x=1");
            request.auth = Some(auth);
            request
        };
        let cases = [
            with(Auth::new(
                AuthKind::Basic,
                &[("username", "{{user}}"), ("password", "p'w")],
            )),
            with(Auth::new(AuthKind::Bearer, &[("token", "{{token}}")])),
            with(Auth::new(
                AuthKind::ApiKey,
                &[("key", "api_key"), ("value", "{{key}}"), ("in", "query")],
            )),
            with(Auth::new(
                AuthKind::Digest,
                &[("username", "u"), ("password", "p")],
            )),
            with(Auth::new(
                AuthKind::Ntlm,
                &[("username", "u"), ("password", "p"), ("domain", "CORP")],
            )),
            with(Auth::new(
                AuthKind::AwsV4,
                &[("accessKey", "AK"), ("secretKey", "SK"), ("service", "s3")],
            )),
            with(Auth::new(
                AuthKind::OAuth1,
                &[("consumerKey", "ck"), ("addParamsToHeader", "query")],
            )),
            with(Auth::new(
                AuthKind::Hawk,
                &[("authId", "id"), ("authKey", "key")],
            )),
        ];
        let collection = Collection {
            name: "Auth".into(),
            variables: Vec::new(),
            items: cases
                .iter()
                .map(|request| Item {
                    name: request.auth.as_ref().unwrap().kind.label().into(),
                    request: Some(request.clone()),
                    items: Vec::new(),
                })
                .collect(),
        };

        // Postman keeps every type, parameter for parameter.
        let postman = export_collection(&collection, ExportFormat::Postman).unwrap();
        let value: Value = serde_json::from_str(&postman).unwrap();
        assert_eq!(
            value["item"][6]["request"]["auth"]["oauth1"][1]["value"],
            false
        );
        let back = import(&postman, "x").unwrap();
        assert!(back.warnings.is_empty(), "{:?}", back.warnings);
        assert_eq!(back.collections, std::slice::from_ref(&collection));

        let curl: Vec<String> = cases.iter().map(to_curl).collect();
        assert!(curl[0].ends_with("-u '{{user}}:p'\\''w'"), "{}", curl[0]);
        assert!(curl[1].contains("-H 'Authorization: Bearer {{token}}'"));
        assert!(curl[2].contains("'{{base}}/secure?x=1&api_key={{key}}'"));
        assert!(curl[3].ends_with("--digest -u 'u:p'"));
        assert!(curl[4].ends_with("--ntlm -u 'CORP\\u:p'"));
        assert!(curl[5].ends_with("--aws-sigv4 'aws:amz:us-east-1:s3' -u 'AK:SK'"));
        assert!(curl[7].starts_with("# Hawk Authentication is computed by reqorb"));
        assert!(curl[7].contains("\ncurl "));

        let bruno: Value =
            serde_json::from_str(&export_collection(&collection, ExportFormat::Bruno).unwrap())
                .unwrap();
        let auth = |i: usize| &bruno["items"][i]["request"]["auth"];
        assert_eq!(auth(0)["basic"]["username"], "{{user}}");
        assert_eq!(auth(1)["bearer"]["token"], "{{token}}");
        assert_eq!(auth(2)["apikey"]["placement"], "queryparams");
        assert_eq!(auth(3)["mode"], "digest");
        assert_eq!(auth(4)["ntlm"]["domain"], "CORP");
        assert_eq!(auth(5)["awsv4"]["accessKeyId"], "AK");
        assert_eq!(auth(7)["mode"], "none");
    }

    #[test]
    fn body_types_reach_every_format() {
        use crate::FormField;
        let with = |name: &str, change: &dyn Fn(&mut Request)| {
            let mut request = Request::new("POST", "https://api.test/u");
            change(&mut request);
            Item {
                name: name.into(),
                request: Some(request),
                items: Vec::new(),
            }
        };
        let collection = Collection {
            name: "Bodies".into(),
            variables: Vec::new(),
            items: vec![
                with("form", &|r| {
                    r.body_mode = Some(BodyMode::FormData);
                    r.form = vec![
                        FormField::text("title", "it's {{x}}"),
                        FormField::text("at", "@home"),
                        FormField::file("doc", "/tmp/a b.pdf"),
                    ];
                }),
                with("encoded", &|r| {
                    r.body_mode = Some(BodyMode::UrlEncoded);
                    r.form = vec![FormField::text("q", "a b"), FormField::text("v", "{{v}}")];
                }),
                with("binary", &|r| {
                    r.body_mode = Some(BodyMode::Binary);
                    r.body = Some("/tmp/data.bin".into());
                }),
                with("none", &|r| r.body_mode = Some(BodyMode::None)),
            ],
        };

        // Postman keeps every type; an explicit "none" comes back as no body.
        let postman = export_collection(&collection, ExportFormat::Postman).unwrap();
        let value: Value = serde_json::from_str(&postman).unwrap();
        assert_eq!(
            value["item"][0]["request"]["body"]["formdata"][2]["src"],
            "/tmp/a b.pdf"
        );
        assert_eq!(
            value["item"][1]["request"]["body"]["urlencoded"][0]["value"],
            "a b"
        );
        assert_eq!(
            value["item"][2]["request"]["body"]["file"]["src"],
            "/tmp/data.bin"
        );
        assert!(value["item"][3]["request"].get("body").is_none());
        let back = import(&postman, "x").unwrap();
        assert_eq!(back.collections[0].items[..3], collection.items[..3]);
        assert_eq!(
            back.collections[0].items[3]
                .request
                .as_ref()
                .unwrap()
                .body_mode,
            None
        );

        // curl uses its own upload options, and they import back the same.
        let requests = collection.requests();
        let form = to_curl(requests[0].1);
        assert!(form.contains("-F 'title=it'\\''s {{x}}'"), "{form}");
        assert!(form.contains("--form-string 'at=@home'"));
        assert!(form.contains("-F 'doc=@/tmp/a b.pdf'"));
        assert!(!form.contains("-X"), "POST is curl's default with a form");
        let back = import(&form, "x").unwrap();
        assert_eq!(
            back.collections[0].items[0].request.as_ref(),
            Some(requests[0].1)
        );

        let encoded = to_curl(requests[1].1);
        assert!(encoded.contains("--data-raw 'q=a+b&v={{v}}'"), "{encoded}");
        assert!(encoded.contains("Content-Type: application/x-www-form-urlencoded"));
        let binary = to_curl(requests[2].1);
        assert!(
            binary.ends_with("--data-binary '@/tmp/data.bin'"),
            "{binary}"
        );
        assert_eq!(
            to_curl(requests[3].1),
            "curl \\\n  -X POST \\\n  'https://api.test/u'"
        );

        let bruno: Value =
            serde_json::from_str(&export_collection(&collection, ExportFormat::Bruno).unwrap())
                .unwrap();
        let body = |i: usize| &bruno["items"][i]["request"]["body"];
        assert_eq!(body(0)["mode"], "multipartForm");
        assert_eq!(body(0)["multipartForm"][0]["value"], "it's {{x}}");
        assert_eq!(body(0)["multipartForm"][2]["type"], "file");
        assert_eq!(body(0)["multipartForm"][2]["value"][0], "/tmp/a b.pdf");
        assert_eq!(body(1)["mode"], "formUrlEncoded");
        assert_eq!(body(1)["formUrlEncoded"][0]["value"], "a b");
        assert_eq!(body(2)["mode"], "none");
        assert_eq!(body(3)["mode"], "none");
    }

    #[test]
    fn request_settings_survive_postman() {
        let mut request = Request::new("GET", "https://api.test/");
        request.settings = Some(RequestSettings {
            http_mode: Some(HttpMode::Http1),
            verify_ssl: false,
            follow_redirects: false,
            follow_original_method: true,
            follow_auth_header: true,
            remove_referer: true,
            strict_http_parser: true,
            disable_cookie_jar: true,
            max_redirects: 3,
            disabled_tls: DisabledTls::Tls12,
        });
        let collection = Collection {
            name: "S".into(),
            variables: Vec::new(),
            items: vec![
                Item {
                    name: "custom".into(),
                    request: Some(request),
                    items: Vec::new(),
                },
                Item {
                    name: "plain".into(),
                    request: Some(Request::new("GET", "https://api.test/")),
                    items: Vec::new(),
                },
            ],
        };
        let text = export_collection(&collection, ExportFormat::Postman).unwrap();
        let value: Value = serde_json::from_str(&text).unwrap();
        let profile = &value["item"][0]["protocolProfileBehavior"];
        assert_eq!(profile["strictSSL"], false);
        assert_eq!(profile["insecureHTTPParser"], false);
        assert_eq!(profile["protocolVersion"], "http1");
        assert_eq!(profile["tlsDisabledProtocols"][0], "TLSv1_2");
        assert_eq!(profile["maxRedirects"], 3);
        assert!(value["item"][1].get("protocolProfileBehavior").is_none());

        let back = import(&text, "x").unwrap();
        assert_eq!(back.collections, std::slice::from_ref(&collection));
    }

    #[test]
    fn bruno_export() {
        let mut collection = sample();
        let mut login = Request::new("post", "{{base}}/login?next=%2Fhome&debug#top");
        login.add_header("Content-Type", "application/x-www-form-urlencoded");
        login.body = Some("user=a+b&pw={{pw}}".into());
        collection.items.push(Item {
            name: "Login".into(),
            request: Some(login),
            items: Vec::new(),
        });

        let text = export_collection(&collection, ExportFormat::Bruno).unwrap();
        let bruno: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(bruno["name"], "Shop");
        assert_eq!(bruno["version"], "1");
        assert_eq!(bruno["root"]["request"]["vars"]["req"][0]["name"], "base");
        assert_eq!(bruno["root"]["request"]["vars"]["req"][1]["enabled"], false);

        let folder = &bruno["items"][0];
        assert_eq!(folder["type"], "folder");
        let create = &folder["items"][0];
        assert_eq!(create["type"], "http-request");
        assert_eq!(create["seq"], 1);
        assert_eq!(create["settings"]["timeout"], 1500);
        assert_eq!(create["request"]["method"], "POST");
        assert_eq!(create["request"]["body"]["mode"], "json");
        assert_eq!(create["request"]["body"]["json"], "{\"sku\": \"a'b\"}");
        assert_eq!(create["request"]["params"][0]["name"], "x");
        assert_eq!(create["request"]["params"][0]["type"], "query");

        assert_eq!(bruno["items"][1]["request"]["body"]["mode"], "none");

        let login = &bruno["items"][2]["request"];
        assert_eq!(login["params"].as_array().unwrap().len(), 2);
        assert_eq!(login["params"][1]["name"], "debug");
        assert_eq!(login["body"]["mode"], "formUrlEncoded");
        assert_eq!(login["body"]["formUrlEncoded"][0]["value"], "a b");
        assert_eq!(login["body"]["formUrlEncoded"][1]["value"], "{{pw}}");

        // Every id is present, well formed and distinct.
        let mut uids = Vec::new();
        fn collect(value: &Value, uids: &mut Vec<String>) {
            match value {
                Value::Object(map) => {
                    for (key, child) in map {
                        if key == "uid" {
                            uids.push(child.as_str().unwrap().to_string());
                        }
                        collect(child, uids);
                    }
                }
                Value::Array(list) => list.iter().for_each(|v| collect(v, uids)),
                _ => {}
            }
        }
        collect(&bruno, &mut uids);
        assert!(uids.len() > 10);
        assert!(
            uids.iter()
                .all(|u| u.len() == 21 && u.chars().all(|c| c.is_ascii_alphanumeric()))
        );
        let unique: std::collections::HashSet<_> = uids.iter().collect();
        assert_eq!(unique.len(), uids.len());

        assert!(export_environment(&sample_env(), ExportFormat::Bruno).is_err());
    }

    #[test]
    fn curl_round_trip() {
        let collection = sample();
        let (_, request) = collection.requests()[0].clone();
        let command = to_curl(request);
        assert!(command.starts_with("curl \\\n  '{{base}}/orders?x=it'\\''s'"));
        let back = import(&command, "x").unwrap();
        assert_eq!(back.collections[0].items[0].request.as_ref(), Some(request));

        let script = export_collection(&collection, ExportFormat::Curl).unwrap();
        assert!(script.contains("# Orders/Create\ncurl"));
        assert!(script.contains("# Ping\ncurl \\\n  '{{base}}/ping'"));
    }

    #[test]
    fn other_tools_formats_leave_out_websocket_and_grpc_requests() {
        let item = |name: &str, method: &str| Item {
            name: name.into(),
            request: Some(Request::new(method, "example.com:50051")),
            items: vec![],
        };
        let collection = Collection {
            name: "Mixed".into(),
            variables: vec![],
            items: vec![
                item("Ping", "GET"),
                item("Feed", "WS"),
                item("Call", "GRPC"),
            ],
        };
        for format in [
            ExportFormat::Postman,
            ExportFormat::Bruno,
            ExportFormat::Curl,
        ] {
            let out = export_collection(&collection, format).unwrap();
            assert!(out.contains("Ping"), "{out}");
            assert!(!out.contains("Feed") && !out.contains("Call"), "{out}");
        }
        // reqorb's own format keeps everything.
        let native = export_collection(&collection, ExportFormat::Reqorb).unwrap();
        assert!(native.contains("Feed") && native.contains("GRPC"));
    }

    #[test]
    fn dotenv_export() {
        let text = export_environment(&sample_env(), ExportFormat::Dotenv).unwrap();
        assert_eq!(
            text,
            "base=https://staging.test\nnote=\"two words # \\\"quoted\\\"\"\n# debug=1\n"
        );
        let back = import(&text, "Staging").unwrap();
        // Disabled variables become comments, so only the enabled ones return.
        assert_eq!(back.environments[0].variables, sample_env().variables[..2]);

        assert!(export_collection(&sample(), ExportFormat::Dotenv).is_err());
        assert!(export_environment(&sample_env(), ExportFormat::Curl).is_err());
    }
}
