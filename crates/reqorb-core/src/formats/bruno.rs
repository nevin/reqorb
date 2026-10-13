//! Bruno collections, as the single JSON file Bruno imports.

use serde_json::{Value, json};

use crate::{Auth, AuthKind, BodyMode, Collection, Item, Request};

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

pub(super) fn bruno_collection(collection: &Collection) -> Value {
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
