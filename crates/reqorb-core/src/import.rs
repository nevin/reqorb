//! Importers for Postman collections and environments, OpenAPI/Swagger
//! documents, curl commands, `.env` files and reqorb's own JSON format. HAR
//! archives are read in `har`.

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    Auth, AuthKind, AuthParam, BodyMode, Collection, DisabledTls, Environment, Error, FormField,
    HttpMode, Item, Request, RequestSettings, Variable, openapi,
};

/// Version written to the `reqorb` field of native files.
pub(crate) const NATIVE_VERSION: u32 = 1;

/// reqorb's own file format: any number of collections and environments.
#[derive(Debug, Default, Serialize, Deserialize)]
pub(crate) struct NativeFile {
    pub reqorb: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub collections: Vec<Collection>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub environments: Vec<Environment>,
}

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
        if crate::har::is_har(&value) {
            return Ok(crate::har::from_har(&value, name_hint));
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

pub(crate) fn str_field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// Postman stores most values as strings but allows numbers and booleans.
pub(crate) fn loose_string(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

fn basic_auth(user: &str, password: &str) -> String {
    let encoded = base64::engine::general_purpose::STANDARD.encode(format!("{user}:{password}"));
    format!("Basic {encoded}")
}

/// Form-encodes a value but keeps `{{variable}}` markers intact.
pub(crate) fn form_encode(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes())
        .collect::<String>()
        .replace("%7B%7B", "{{")
        .replace("%7D%7D", "}}")
}

pub(crate) fn append_query(url: &mut String, query: &str) {
    if query.is_empty() {
        return;
    }
    url.push(if url.contains('?') { '&' } else { '?' });
    url.push_str(query);
}

// ---------------------------------------------------------------- Postman

/// Works for both the `enabled` flag of environments and the `disabled` flag
/// of collection variables, headers and form fields.
fn is_enabled(entry: &Value) -> bool {
    if entry.get("disabled").and_then(Value::as_bool) == Some(true) {
        return false;
    }
    entry.get("enabled").and_then(Value::as_bool) != Some(false)
}

fn postman_variables(values: &Value) -> Vec<Variable> {
    values
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| {
            Some(Variable {
                key: str_field(v, "key")?.to_string(),
                value: v.get("value").map(loose_string).unwrap_or_default(),
                enabled: is_enabled(v),
            })
        })
        .collect()
}

#[derive(Default)]
struct Postman {
    warnings: Vec<String>,
    scripts: usize,
}

impl Postman {
    fn finish(mut self) -> Vec<String> {
        if self.scripts > 0 {
            self.warnings.push(format!(
                "{} pre-request/test script(s) were not imported",
                self.scripts
            ));
        }
        self.warnings
    }

    fn collection(&mut self, value: &Value, name_hint: &str) -> Collection {
        self.count_scripts(value);
        Collection {
            name: str_field(&value["info"], "name")
                .unwrap_or(name_hint)
                .to_string(),
            variables: postman_variables(&value["variable"]),
            items: self.items(&value["item"], own_auth(value)),
        }
    }

    fn count_scripts(&mut self, value: &Value) {
        let events = value.get("event").and_then(Value::as_array);
        self.scripts += events.into_iter().flatten().count();
    }

    fn items(&mut self, items: &Value, inherited_auth: Option<&Value>) -> Vec<Item> {
        let mut out = Vec::new();
        for entry in items.as_array().into_iter().flatten() {
            self.count_scripts(entry);
            let name = str_field(entry, "name").unwrap_or("Untitled").to_string();
            if let Some(children) = entry.get("item") {
                let auth = own_auth(entry).or(inherited_auth);
                out.push(Item {
                    name,
                    request: None,
                    items: self.items(children, auth),
                });
            } else if let Some(request) = entry.get("request") {
                let mut request = self.request(request, inherited_auth, &name);
                request.settings = postman_settings(&entry["protocolProfileBehavior"]);
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
                let variables = str_field(gql, "variables")
                    .and_then(|v| serde_json::from_str::<Value>(v).ok())
                    .unwrap_or_else(|| serde_json::json!({}));
                let payload = serde_json::json!({
                    "query": str_field(gql, "query").unwrap_or(""),
                    "variables": variables,
                });
                request.body = Some(serde_json::to_string_pretty(&payload).expect("valid JSON"));
                Some("application/json")
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

fn curl(text: &str, name_hint: &str) -> Result<ImportResult, Error> {
    let tokens = shell_split(text)?;
    let mut warnings = Vec::new();

    let mut method: Option<String> = None;
    let mut url: Option<String> = None;
    let mut request = Request::default();
    let mut data: Vec<String> = Vec::new();
    let (mut as_query, mut head, mut json, mut upload) = (false, false, false, false);

    let mut args = tokens.into_iter().skip(1);
    while let Some(arg) = args.next() {
        // Normalise `--name=value`, `--name value`, `-n value` and `-nvalue`
        // into a list of (option, inline value) pairs.
        let mut options: Vec<(String, Option<String>)> = Vec::new();
        if let Some(long) = arg.strip_prefix("--") {
            match long.split_once('=') {
                Some((name, value)) => options.push((name.to_string(), Some(value.to_string()))),
                None => options.push((long.to_string(), None)),
            }
        } else if arg.len() > 1 && arg.starts_with('-') {
            let cluster = &arg[1..];
            for (i, c) in cluster.char_indices() {
                let name = short_option(c);
                if takes_value(name) {
                    let inline = &cluster[i + c.len_utf8()..];
                    options.push((
                        name.to_string(),
                        (!inline.is_empty()).then(|| inline.to_string()),
                    ));
                    break;
                }
                options.push((name.to_string(), None));
            }
        } else {
            if url.is_none() {
                url = Some(arg);
            }
            continue;
        }

        for (name, inline) in options {
            let value = if takes_value(&name) {
                match inline.or_else(|| args.next()) {
                    Some(v) => v,
                    None => {
                        return Err(Error::Format(format!("curl option `{name}` needs a value")));
                    }
                }
            } else {
                String::new()
            };
            match name.as_str() {
                "request" => method = Some(value.to_uppercase()),
                "url" => url = Some(value),
                "header" => {
                    let (key, val) = value
                        .split_once(':')
                        .or_else(|| value.split_once(';'))
                        .unwrap_or((value.as_str(), ""));
                    request.add_header(key.trim(), val.trim());
                }
                "data-binary" if value.starts_with('@') => {
                    request.body_mode = Some(BodyMode::Binary);
                    request.body = Some(value[1..].to_string());
                }
                "data" | "data-raw" | "data-binary" | "data-ascii" => {
                    if name != "data-raw" && value.starts_with('@') {
                        warnings.push(format!(
                            "file reference `{value}` was kept as literal body text"
                        ));
                    }
                    data.push(value);
                }
                "data-urlencode" => data.push(match value.split_once('=') {
                    Some((key, content)) if !key.is_empty() => {
                        format!("{key}={}", form_encode(content))
                    }
                    Some((_, content)) => form_encode(content),
                    None => form_encode(&value),
                }),
                "json" => {
                    json = true;
                    data.push(value);
                }
                "user" => {
                    let (user, password) = value.split_once(':').unwrap_or((value.as_str(), ""));
                    request.add_header("Authorization", basic_auth(user, password));
                }
                "oauth2-bearer" => request.add_header("Authorization", format!("Bearer {value}")),
                "user-agent" => request.add_header("User-Agent", value),
                "referer" => request.add_header("Referer", value),
                "cookie" if value.contains('=') => request.add_header("Cookie", value),
                "max-time" => {
                    request.timeout_ms = value.parse::<f64>().ok().map(|s| (s * 1000.0) as u64);
                }
                "head" => head = true,
                "get" => as_query = true,
                "form" | "form-string" => {
                    let (key, content) = value.split_once('=').unwrap_or((value.as_str(), ""));
                    // `key=@path;type=...` uploads a file; `--form-string` never does.
                    let field = match content.strip_prefix('@') {
                        Some(path) if name == "form" => {
                            FormField::file(key, path.split(';').next().unwrap_or(path))
                        }
                        _ => FormField::text(key, content),
                    };
                    request.body_mode = Some(BodyMode::FormData);
                    request.form.push(field);
                }
                "upload-file" => {
                    request.body_mode = Some(BodyMode::Binary);
                    request.body = Some(value);
                    upload = true;
                }
                // Everything else only affects how curl itself behaves.
                _ => {}
            }
        }
    }

    let Some(mut url) = url else {
        return Err(Error::Format("curl command has no URL".into()));
    };
    // A leading variable usually holds the scheme already.
    if !url.contains("://") && !url.starts_with("{{") {
        url = format!("http://{url}");
    }

    if as_query {
        append_query(&mut url, &data.join("&"));
    } else if !data.is_empty() {
        request.body = Some(data.join("&"));
        if json {
            if !request.has_header("content-type") {
                request.add_header("Content-Type", "application/json");
            }
            if !request.has_header("accept") {
                request.add_header("Accept", "application/json");
            }
        } else if !request.has_header("content-type") {
            request.add_header("Content-Type", "application/x-www-form-urlencoded");
        }
    }
    request.method = method.unwrap_or_else(|| {
        if head {
            "HEAD".into()
        } else if upload {
            "PUT".into()
        } else if request.body.is_some() || !request.form.is_empty() {
            "POST".into()
        } else {
            "GET".into()
        }
    });

    let path = url::Url::parse(&url)
        .map(|u| u.path().to_string())
        .unwrap_or_default();
    let item_name = format!("{} {}", request.method, path).trim().to_string();
    request.url = url;

    Ok(ImportResult {
        source: "curl".into(),
        collections: vec![Collection {
            name: name_hint.to_string(),
            variables: Vec::new(),
            items: vec![Item {
                name: item_name,
                request: Some(request),
                items: Vec::new(),
            }],
        }],
        environments: Vec::new(),
        warnings,
    })
}

/// Long name for a curl short option; unknown ones map to themselves.
fn short_option(c: char) -> &'static str {
    match c {
        'X' => "request",
        'H' => "header",
        'd' => "data",
        'u' => "user",
        'A' => "user-agent",
        'e' => "referer",
        'b' => "cookie",
        'm' => "max-time",
        'I' => "head",
        'G' => "get",
        'F' => "form",
        'T' => "upload-file",
        'o' => "output",
        'x' => "proxy",
        'c' => "cookie-jar",
        'r' => "range",
        'w' => "write-out",
        'K' => "config",
        'E' => "cert",
        _ => "",
    }
}

fn takes_value(name: &str) -> bool {
    matches!(
        name,
        "request"
            | "header"
            | "data"
            | "data-raw"
            | "data-binary"
            | "data-ascii"
            | "data-urlencode"
            | "json"
            | "user"
            | "oauth2-bearer"
            | "user-agent"
            | "referer"
            | "cookie"
            | "url"
            | "max-time"
            | "connect-timeout"
            | "form"
            | "form-string"
            | "upload-file"
            | "output"
            | "proxy"
            | "proxy-user"
            | "cookie-jar"
            | "range"
            | "write-out"
            | "config"
            | "cert"
            | "key"
            | "cacert"
            | "resolve"
            | "retry"
            | "max-redirs"
            | "limit-rate"
            | "interface"
    )
}

/// Splits a command line the way a POSIX shell would, including `$'...'`
/// quoting, which browsers use in "Copy as cURL".
fn shell_split(input: &str) -> Result<Vec<String>, Error> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut in_token = false;
    let mut chars = input.chars().peekable();

    while let Some(c) = chars.next() {
        match c {
            c if c.is_whitespace() => {
                if in_token {
                    tokens.push(std::mem::take(&mut current));
                    in_token = false;
                }
            }
            '\\' => match chars.next() {
                // Line continuation.
                Some('\n') => {}
                Some('\r') if chars.peek() == Some(&'\n') => {
                    chars.next();
                }
                Some(escaped) => {
                    current.push(escaped);
                    in_token = true;
                }
                None => {}
            },
            '\'' => {
                in_token = true;
                loop {
                    match chars.next() {
                        Some('\'') => break,
                        Some(ch) => current.push(ch),
                        None => return Err(Error::Format("unterminated ' in curl command".into())),
                    }
                }
            }
            '"' => {
                in_token = true;
                loop {
                    match chars.next() {
                        Some('"') => break,
                        Some('\\') => match chars.next() {
                            Some('\n') => {}
                            Some(ch @ ('"' | '\\' | '$' | '`')) => current.push(ch),
                            Some(ch) => {
                                current.push('\\');
                                current.push(ch);
                            }
                            None => {}
                        },
                        Some(ch) => current.push(ch),
                        None => {
                            return Err(Error::Format("unterminated \" in curl command".into()));
                        }
                    }
                }
            }
            '$' if chars.peek() == Some(&'\'') => {
                chars.next();
                in_token = true;
                loop {
                    match chars.next() {
                        Some('\'') => break,
                        Some('\\') => match chars.next() {
                            Some('n') => current.push('\n'),
                            Some('r') => current.push('\r'),
                            Some('t') => current.push('\t'),
                            Some(ch) => current.push(ch),
                            None => {}
                        },
                        Some(ch) => current.push(ch),
                        None => {
                            return Err(Error::Format("unterminated $' in curl command".into()));
                        }
                    }
                }
            }
            other => {
                current.push(other);
                in_token = true;
            }
        }
    }
    if in_token {
        tokens.push(current);
    }
    Ok(tokens)
}

// ----------------------------------------------------------------- dotenv

/// Parses `KEY=VALUE` lines; `None` if any line is something else.
fn dotenv(text: &str) -> Option<Vec<Variable>> {
    let mut variables = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line);
        let (key, value) = line.split_once('=')?;
        let key = key.trim();
        if key.is_empty()
            || !key
                .chars()
                .all(|c| c.is_alphanumeric() || "_.-".contains(c))
        {
            return None;
        }
        let value = value.trim();
        let value = match value.as_bytes() {
            [b'"', .., b'"'] => value[1..value.len() - 1]
                .replace("\\\"", "\"")
                .replace("\\n", "\n")
                .replace("\\\\", "\\"),
            [b'\'', .., b'\''] => value[1..value.len() - 1].to_string(),
            _ => value.to_string(),
        };
        variables.push(Variable::new(key, value));
    }
    (!variables.is_empty()).then_some(variables)
}

#[cfg(test)]
mod tests {
    use super::*;

    const POSTMAN: &str = r#"{
      "info": {"name": "Shop", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
      "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "{{token}}"}]},
      "variable": [{"key": "base", "value": "https://shop.test"}, {"key": "old", "value": 1, "disabled": true}],
      "event": [{"listen": "test", "script": {"exec": ["pm.test()"]}}],
      "item": [
        {"name": "Orders", "item": [
          {"name": "List", "request": {"method": "GET", "url": {"raw": "{{base}}/orders?page=1"},
            "header": [{"key": "Accept", "value": "application/json"}, {"key": "X-Off", "value": "1", "disabled": true}]}},
          {"name": "Create", "request": {"method": "POST", "url": "{{base}}/orders",
            "auth": {"type": "basic", "basic": [{"key": "username", "value": "bob"}, {"key": "password", "value": "pw"}]},
            "body": {"mode": "raw", "raw": "{\"sku\": 1}", "options": {"raw": {"language": "json"}}}}}
        ]},
        {"name": "Login", "request": {"method": "POST", "auth": {"type": "noauth"},
          "url": {"protocol": "https", "host": ["shop", "test"], "path": ["login"]},
          "body": {"mode": "urlencoded", "urlencoded": [{"key": "user", "value": "a b"}, {"key": "pw", "value": "{{pw}}"}]}}},
        {"name": "Upload", "request": {"method": "POST", "url": "{{base}}/upload", "body": {"mode": "formdata", "formdata": []}}}
      ]
    }"#;

    #[test]
    fn imports_postman_collection() {
        let result = import(POSTMAN, "hint").unwrap();
        assert_eq!(result.source, "postman-collection");
        let collection = &result.collections[0];
        assert_eq!(collection.name, "Shop");
        assert_eq!(collection.variables.len(), 2);
        assert!(!collection.variables[1].enabled);
        assert_eq!(collection.variables[1].value, "1");

        let requests = collection.requests();
        let paths: Vec<&str> = requests.iter().map(|(p, _)| p.as_str()).collect();
        assert_eq!(paths, ["Orders/List", "Orders/Create", "Login", "Upload"]);

        let list = requests[0].1;
        assert_eq!(list.url, "{{base}}/orders?page=1");
        assert_eq!(list.headers.len(), 1, "disabled header skipped");
        let inherited = list.auth.as_ref().expect("collection auth is inherited");
        assert_eq!(inherited.kind, AuthKind::Bearer);
        assert_eq!(inherited.get("token"), "{{token}}");

        let create = requests[1].1;
        assert_eq!(create.body.as_deref(), Some("{\"sku\": 1}"));
        assert!(create.headers.iter().any(|h| h.value == "application/json"));
        let own = create.auth.as_ref().expect("request auth wins");
        assert_eq!(own.kind, AuthKind::Basic);
        assert_eq!(
            (own.get("username"), own.get("password")),
            ("bob".into(), "pw".into())
        );

        let login = requests[2].1;
        assert_eq!(login.url, "https://shop.test/login");
        assert_eq!(login.body_mode, Some(BodyMode::UrlEncoded));
        assert_eq!(
            login.form,
            [
                FormField::text("user", "a b"),
                FormField::text("pw", "{{pw}}")
            ]
        );
        let mut ready = login.clone();
        ready.materialize();
        assert_eq!(ready.body.as_deref(), Some("user=a+b&pw={{pw}}"));
        assert!(ready.has_header("content-type"));
        assert_eq!(requests[3].1.body_mode, Some(BodyMode::FormData));
        assert_eq!(login.auth, None, "noauth overrides inherited auth");

        assert_eq!(result.warnings.len(), 1, "{:?}", result.warnings);
    }

    #[test]
    fn imports_postman_environment() {
        let text = r#"{"name": "Staging", "_postman_variable_scope": "environment",
          "values": [{"key": "base", "value": "https://staging.test", "enabled": true},
                     {"key": "debug", "value": "1", "enabled": false}]}"#;
        let result = import(text, "hint").unwrap();
        assert_eq!(result.source, "postman-environment");
        let env = &result.environments[0];
        assert_eq!(env.name, "Staging");
        assert_eq!(
            env.variables[0],
            Variable::new("base", "https://staging.test")
        );
        assert!(!env.variables[1].enabled);
    }

    #[test]
    fn imports_curl() {
        let text = "curl -sSL -X PUT 'https://api.test/items/1?x=1' \\\n  -H 'Accept: text/plain' \\\n  -u bob:pw --json '{\"a\": \"it'\\''s\"}' --max-time 2.5 --compressed";
        let result = import(text, "Pasted").unwrap();
        assert_eq!(result.source, "curl");
        let collection = &result.collections[0];
        assert_eq!(collection.name, "Pasted");
        assert_eq!(collection.items[0].name, "PUT /items/1");
        let request = collection.items[0].request.as_ref().unwrap();
        assert_eq!(request.method, "PUT");
        assert_eq!(request.url, "https://api.test/items/1?x=1");
        assert_eq!(request.body.as_deref(), Some("{\"a\": \"it's\"}"));
        assert_eq!(request.timeout_ms, Some(2500));
        let header = |name: &str| {
            request
                .headers
                .iter()
                .find(|h| h.name.eq_ignore_ascii_case(name))
                .map(|h| h.value.as_str())
        };
        assert_eq!(header("accept"), Some("text/plain"));
        assert_eq!(header("authorization"), Some("Basic Ym9iOnB3"));
        assert_eq!(header("content-type"), Some("application/json"));
    }

    #[test]
    fn curl_defaults_and_get_data() {
        let post = import("curl api.test/login -d user=a -d pw=b", "x").unwrap();
        let request = post.collections[0].items[0].request.clone().unwrap();
        assert_eq!(request.method, "POST");
        assert_eq!(request.url, "http://api.test/login");
        assert_eq!(request.body.as_deref(), Some("user=a&pw=b"));
        assert!(request.has_header("content-type"));

        let get = import(
            "curl -G https://api.test/s --data-urlencode 'q=a b' -I",
            "x",
        )
        .unwrap();
        let request = get.collections[0].items[0].request.clone().unwrap();
        assert_eq!(request.method, "HEAD");
        assert_eq!(request.url, "https://api.test/s?q=a+b");
        assert_eq!(request.body, None);

        let browser = import("curl 'https://api.test/' --data-raw $'line1\\nline2'", "x").unwrap();
        let request = browser.collections[0].items[0].request.clone().unwrap();
        assert_eq!(request.body.as_deref(), Some("line1\nline2"));
    }

    #[test]
    fn curl_uploads_become_body_types() {
        let form = import("curl https://api.test/u -F title=Hi -F 'doc=@/tmp/a b.pdf;type=application/pdf' --form-string 'raw=@x'", "x").unwrap();
        let request = form.collections[0].items[0].request.clone().unwrap();
        assert_eq!(request.method, "POST");
        assert_eq!(request.body_mode, Some(BodyMode::FormData));
        assert_eq!(
            request.form,
            [
                FormField::text("title", "Hi"),
                FormField::file("doc", "/tmp/a b.pdf"),
                FormField::text("raw", "@x"),
            ]
        );
        assert!(form.warnings.is_empty());

        let binary = import("curl https://api.test/u --data-binary @/tmp/data.bin", "x").unwrap();
        let request = binary.collections[0].items[0].request.clone().unwrap();
        assert_eq!(request.method, "POST");
        assert_eq!(request.body_mode, Some(BodyMode::Binary));
        assert_eq!(request.body.as_deref(), Some("/tmp/data.bin"));
        assert!(!request.has_header("content-type"));

        let put = import("curl -T /tmp/up.txt https://api.test/u", "x").unwrap();
        let request = put.collections[0].items[0].request.clone().unwrap();
        assert_eq!(request.method, "PUT");
        assert_eq!(request.body_mode, Some(BodyMode::Binary));
    }

    #[test]
    fn imports_dotenv_and_rejects_noise() {
        let text = "# comment\nexport BASE=https://api.test\nTOKEN=\"a b\"\nEMPTY=\n";
        let result = import(text, "local").unwrap();
        assert_eq!(result.source, "dotenv");
        let env = &result.environments[0];
        assert_eq!(env.name, "local");
        assert_eq!(env.variables[0], Variable::new("BASE", "https://api.test"));
        assert_eq!(env.variables[1], Variable::new("TOKEN", "a b"));
        assert_eq!(env.variables[2], Variable::new("EMPTY", ""));

        assert!(import("just some prose", "x").is_err());
        assert!(import("{\"foo\": 1}", "x").is_err());
        assert!(import("curl", "x").is_err());
    }
}
