//! Postman collections (v2.0 and v2.1) and environments.

use serde_json::{Value, json};

use super::util::{append_query, loose_string, str_field};
use crate::{
    Auth, AuthKind, AuthParam, BodyMode, Collection, DisabledTls, FormField, HttpMode, Item,
    Request, RequestSettings, Variable,
};

/// Works for both the `enabled` flag of environments and the `disabled` flag
/// of collection variables, headers and form fields.
fn is_enabled(entry: &Value) -> bool {
    if entry.get("disabled").and_then(Value::as_bool) == Some(true) {
        return false;
    }
    entry.get("enabled").and_then(Value::as_bool) != Some(false)
}

pub(super) fn postman_variables(values: &Value) -> Vec<Variable> {
    values
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| {
            Some(Variable {
                key: str_field(v, "key")?.to_string(),
                value: v.get("value").map(loose_string).unwrap_or_default(),
                enabled: is_enabled(v),
                secret: str_field(v, "type") == Some("secret"),
            })
        })
        .collect()
}

#[derive(Default)]
pub(super) struct Postman {
    warnings: Vec<String>,
    /// Scripts that use what reqorb's scripts do not have.
    out_of_reach: usize,
}

/// The scripts an entry carries for before a request and after it, each
/// as one text.
fn scripts(value: &Value) -> (String, String) {
    let mut found = (String::new(), String::new());
    for event in value
        .get("event")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let text = match &event["script"]["exec"] {
            Value::Array(lines) => lines
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("\n"),
            Value::String(text) => text.clone(),
            _ => continue,
        };
        match event["listen"].as_str() {
            Some("prerequest") => found.0 = text,
            Some("test") => found.1 = text,
            _ => {}
        }
    }
    found
}

/// A script with those of the folders around it in front, which is the
/// order Postman runs them in.
fn joined(outer: &str, inner: &str) -> String {
    match (outer.trim().is_empty(), inner.trim().is_empty()) {
        (true, _) => inner.to_string(),
        (false, true) => outer.to_string(),
        (false, false) => format!("{outer}\n\n{inner}"),
    }
}

impl Postman {
    pub(super) fn finish(mut self) -> Vec<String> {
        if self.out_of_reach > 0 {
            self.warnings.push(format!(
                "{} script(s) use pm.sendRequest or require, which reqorb's scripts do not have",
                self.out_of_reach
            ));
        }
        self.warnings
    }

    pub(super) fn collection(&mut self, value: &Value, name_hint: &str) -> Collection {
        Collection {
            name: str_field(&value["info"], "name")
                .unwrap_or(name_hint)
                .to_string(),
            variables: postman_variables(&value["variable"]),
            items: self.items(&value["item"], own_auth(value), &scripts(value)),
            link: None,
            unreviewed: false,
        }
    }

    fn items(
        &mut self,
        items: &Value,
        inherited_auth: Option<&Value>,
        inherited: &(String, String),
    ) -> Vec<Item> {
        let mut out = Vec::new();
        for entry in items.as_array().into_iter().flatten() {
            let own = scripts(entry);
            let both = (joined(&inherited.0, &own.0), joined(&inherited.1, &own.1));
            let name = str_field(entry, "name").unwrap_or("Untitled").to_string();
            if let Some(children) = entry.get("item") {
                let auth = own_auth(entry).or(inherited_auth);
                out.push(Item {
                    name,
                    request: None,
                    items: self.items(children, auth, &both),
                });
            } else if let Some(request) = entry.get("request") {
                let mut request = self.request(request, inherited_auth, &name);
                request.settings = postman_settings(&entry["protocolProfileBehavior"]);
                for script in [&both.0, &both.1] {
                    if script.contains("pm.sendRequest") || script.contains("require(") {
                        self.out_of_reach += 1;
                    }
                }
                request.pre_script = Some(both.0).filter(|s| !s.trim().is_empty());
                request.post_script = Some(both.1).filter(|s| !s.trim().is_empty());
                out.push(Item {
                    name,
                    request: Some(request),
                    items: Vec::new(),
                });
            }
        }
        out
    }

    fn request(&mut self, value: &Value, inherited_auth: Option<&Value>, name: &str) -> Request {
        if let Some(url) = value.as_str() {
            return Request::new("GET", url);
        }
        let method = str_field(value, "method").unwrap_or("GET");
        let mut request = Request::new(method, postman_url(&value["url"]));

        for h in value["header"].as_array().into_iter().flatten() {
            if let (true, Some(key)) = (is_enabled(h), str_field(h, "key")) {
                request.add_header(key, h.get("value").map(loose_string).unwrap_or_default());
            }
        }

        self.body(&value["body"], &mut request);
        if let Some(auth) = own_auth(value).or(inherited_auth) {
            self.auth(auth, &mut request, name);
        }
        request
    }

    fn body(&mut self, body: &Value, request: &mut Request) {
        if body.get("disabled").and_then(Value::as_bool) == Some(true) {
            return;
        }
        let content_type = match str_field(body, "mode") {
            Some("raw") => {
                request.body = str_field(body, "raw").map(str::to_string);
                match str_field(&body["options"]["raw"], "language") {
                    Some("json") => Some("application/json"),
                    Some("xml") => Some("application/xml"),
                    Some("html") => Some("text/html"),
                    Some("javascript") => Some("application/javascript"),
                    _ => None,
                }
            }
            Some("urlencoded") => {
                request.body_mode = Some(BodyMode::UrlEncoded);
                request.form = postman_fields(&body["urlencoded"]);
                None
            }
            Some("formdata") => {
                request.body_mode = Some(BodyMode::FormData);
                request.form = postman_fields(&body["formdata"]);
                None
            }
            Some("file") => {
                request.body_mode = Some(BodyMode::Binary);
                request.body = Some(postman_file(&body["file"]["src"]));
                None
            }
            Some("graphql") => {
                let gql = &body["graphql"];
                request.body_mode = Some(BodyMode::GraphQl);
                request.body = Some(str_field(gql, "query").unwrap_or("").to_string());
                // Postman keeps the variables as JSON text; an empty
                // object says no more than nothing at all.
                request.graphql_variables = str_field(gql, "variables")
                    .map(str::trim)
                    .filter(|v| !v.is_empty() && v.replace(char::is_whitespace, "") != "{}")
                    .map(str::to_string);
                request.graphql_operation = str_field(gql, "operationName")
                    .filter(|name| !name.is_empty())
                    .map(str::to_string);
                None
            }
            _ => None,
        };
        if let (Some(content_type), false) = (content_type, request.has_header("content-type")) {
            request.add_header("Content-Type", content_type);
        }
    }

    fn auth(&mut self, auth: &Value, request: &mut Request, name: &str) {
        let id = str_field(auth, "type").unwrap_or("noauth");
        let Some(kind) = AuthKind::from_id(id) else {
            self.warnings
                .push(format!("{name}: `{id}` auth is not supported"));
            return;
        };
        if kind == AuthKind::None {
            return;
        }
        // v2.1 lists `[{key, value}]`; v2.0 uses a plain `{key: value}` object.
        let mut params: Vec<AuthParam> = match &auth[id] {
            Value::Array(entries) => entries
                .iter()
                .filter_map(|e| {
                    Some(AuthParam {
                        key: str_field(e, "key")?.to_string(),
                        value: e.get("value").map(loose_string).unwrap_or_default(),
                    })
                })
                .collect(),
            Value::Object(map) => map
                .iter()
                .map(|(key, value)| AuthParam {
                    key: key.clone(),
                    value: loose_string(value),
                })
                .collect(),
            _ => Vec::new(),
        };
        // Postman stores this one choice as a boolean.
        if kind == AuthKind::OAuth1 {
            for param in params.iter_mut().filter(|p| p.key == "addParamsToHeader") {
                param.value = if param.value == "false" {
                    "query"
                } else {
                    "header"
                }
                .into();
            }
        }
        request.auth = Some(Auth { kind, params });
    }
}

/// Postman writes a file reference as one path or a list of them.
fn postman_file(src: &Value) -> String {
    match src {
        Value::Array(paths) => paths.first().map(loose_string).unwrap_or_default(),
        other => loose_string(other),
    }
}

/// The enabled fields of a form-data or url-encoded body.
fn postman_fields(fields: &Value) -> Vec<FormField> {
    fields
        .as_array()
        .into_iter()
        .flatten()
        .filter(|f| is_enabled(f))
        .filter_map(|f| {
            let key = str_field(f, "key")?;
            Some(if str_field(f, "type") == Some("file") {
                FormField::file(key, postman_file(&f["src"]))
            } else {
                FormField::text(key, f.get("value").map(loose_string).unwrap_or_default())
            })
        })
        .collect()
}

/// Postman's per-request settings, which it calls the protocol profile.
/// Returns `None` when nothing differs from the defaults.
fn postman_settings(profile: &Value) -> Option<RequestSettings> {
    let flag = |key: &str| profile.get(key).and_then(Value::as_bool);
    let mut settings = RequestSettings::default();
    if let Some(on) = flag("followRedirects") {
        settings.follow_redirects = on;
    }
    if let Some(on) = flag("followOriginalHttpMethod") {
        settings.follow_original_method = on;
    }
    if let Some(on) = flag("followAuthorizationHeader") {
        settings.follow_auth_header = on;
    }
    if let Some(on) = flag("removeRefererHeaderOnRedirect") {
        settings.remove_referer = on;
    }
    if let Some(on) = flag("strictSSL") {
        settings.verify_ssl = on;
    }
    if let Some(on) = flag("disableCookies") {
        settings.disable_cookie_jar = on;
    }
    // Postman's flag has the opposite sense: it turns leniency on.
    if let Some(lenient) = flag("insecureHTTPParser") {
        settings.strict_http_parser = !lenient;
    }
    if let Some(max) = profile.get("maxRedirects").and_then(Value::as_u64) {
        settings.max_redirects = max as u32;
    }
    settings.http_mode = match str_field(profile, "protocolVersion") {
        Some("http1") => Some(HttpMode::Http1),
        Some("http2") => Some(HttpMode::Http2),
        Some("auto") => Some(HttpMode::Auto),
        _ => None,
    };
    let disabled: Vec<&str> = profile["tlsDisabledProtocols"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    // Only TLS 1.2 and 1.3 are ever offered, so older entries change nothing.
    settings.disabled_tls = if disabled.contains(&"TLSv1_3") {
        DisabledTls::Tls13
    } else if disabled.contains(&"TLSv1_2") {
        DisabledTls::Tls12
    } else {
        DisabledTls::None
    };
    (settings != RequestSettings::default()).then_some(settings)
}

/// The auth block set on this element itself, ignoring null placeholders.
fn own_auth(value: &Value) -> Option<&Value> {
    value.get("auth").filter(|a| a.is_object())
}

fn postman_url(url: &Value) -> String {
    if let Some(s) = url.as_str() {
        return s.to_string();
    }
    if let Some(raw) = str_field(url, "raw") {
        return raw.to_string();
    }
    // No `raw`: rebuild from the parsed parts.
    let join = |value: &Value, sep: &str| match value {
        Value::Array(parts) => parts.iter().map(loose_string).collect::<Vec<_>>().join(sep),
        other => loose_string(other),
    };
    let mut out = String::new();
    if let Some(protocol) = str_field(url, "protocol") {
        out.push_str(protocol);
        out.push_str("://");
    }
    out.push_str(&join(&url["host"], "."));
    if let Some(port) = url.get("port").map(loose_string).filter(|p| !p.is_empty()) {
        out.push(':');
        out.push_str(&port);
    }
    let path = join(&url["path"], "/");
    if !path.is_empty() {
        out.push('/');
        out.push_str(&path);
    }
    let query: Vec<String> = url["query"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|q| is_enabled(q))
        .filter_map(|q| {
            let value = q.get("value").map(loose_string).unwrap_or_default();
            Some(format!("{}={value}", str_field(q, "key")?))
        })
        .collect();
    append_query(&mut out, &query.join("&"));
    out
}

// ------------------------------------------------------------------- curl

pub(super) fn postman_collection(collection: &Collection) -> Value {
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
        (BodyMode::GraphQl, query) => {
            let mut graphql = json!({
                "query": query.as_deref().unwrap_or(""),
                "variables": request.graphql_variables.as_deref().unwrap_or(""),
            });
            if let Some(operation) = &request.graphql_operation {
                graphql["operationName"] = json!(operation);
            }
            out["body"] = json!({"mode": "graphql", "graphql": graphql});
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
    let events: Vec<Value> = [
        ("prerequest", &request.pre_script),
        ("test", &request.post_script),
    ]
    .into_iter()
    .filter_map(|(listen, script)| {
        let script = script.as_deref().filter(|s| !s.trim().is_empty())?;
        Some(json!({
            "listen": listen,
            "script": {
                "type": "text/javascript",
                "exec": script.lines().collect::<Vec<_>>(),
            },
        }))
    })
    .collect();
    if !events.is_empty() {
        exported["event"] = events.into();
    }
    if let Some(profile) = request.settings.as_ref().and_then(postman_profile) {
        exported["protocolProfileBehavior"] = profile;
    }
    exported
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
