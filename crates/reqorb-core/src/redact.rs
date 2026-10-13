//! Removes credentials from data that is about to leave the app in an export.
//!
//! Values are picked by the name they are stored under (a header, a query
//! parameter, a JSON key, a variable), so a secret sitting in free text or
//! under an unrelated name is not found.

use serde_json::Value;

use crate::{
    BodyMode, Collection, Environment, Exchange, Header, Item, Request, Response, Variable,
    auth_fields,
};

/// What a removed value is replaced with.
pub const REDACTED: &str = "[REDACTED]";

/// Parts of a name that mark its value as a credential, compared after
/// dropping case and punctuation so `X-Api-Key` and `api_key` both match.
const SENSITIVE_PARTS: &[&str] = &[
    "authorization",
    "cookie",
    "token",
    "secret",
    "password",
    "passwd",
    "passphrase",
    "credential",
    "signature",
    "session",
    "apikey",
    "accesskey",
    "privatekey",
    "authkey",
];

/// Short names that only count as a whole, as they turn up inside other words.
const SENSITIVE_NAMES: &[&str] = &["auth", "pwd", "pin", "otp", "cvv", "sid", "jwt"];

/// Names whose value is a credential even when it is a number. Other numbers
/// are left alone, so that `max_tokens: 100` stays readable.
const NUMERIC_SECRETS: &[&str] = &["password", "passwd", "secret", "pwd", "pin", "otp", "cvv"];

fn normalized(name: &str) -> String {
    name.chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

pub(crate) fn is_sensitive(name: &str) -> bool {
    let name = normalized(name);
    SENSITIVE_NAMES.contains(&name.as_str()) || SENSITIVE_PARTS.iter().any(|p| name.contains(p))
}

fn is_numeric_secret(name: &str) -> bool {
    let name = normalized(name);
    NUMERIC_SECRETS.iter().any(|p| name.contains(p))
}

/// The replacement for a credential. An empty value and a lone `{{variable}}`
/// are kept: neither gives anything away, and the reference keeps an exported
/// collection usable.
fn mask(value: &str) -> String {
    let trimmed = value.trim();
    let reference =
        trimmed.starts_with("{{") && trimmed.ends_with("}}") && trimmed.matches("{{").count() == 1;
    if trimmed.is_empty() || reference {
        value.to_string()
    } else {
        REDACTED.to_string()
    }
}

/// `name=value` pairs joined by `separator`, with sensitive values masked.
fn redact_pairs(pairs: &str, separator: char) -> String {
    pairs
        .split(separator)
        .map(|pair| match pair.split_once('=') {
            Some((name, value)) if is_sensitive(name) => format!("{name}={}", mask(value)),
            _ => pair.to_string(),
        })
        .collect::<Vec<_>>()
        .join(&separator.to_string())
}

/// Masks the password, sensitive query parameters and sensitive fragment
/// parameters of a URL. Works on the text, as a URL holding `{{variables}}`
/// does not always parse.
fn redact_url(url: &str) -> String {
    let (rest, fragment) = match url.split_once('#') {
        Some((rest, fragment)) => (rest, Some(fragment)),
        None => (url, None),
    };
    let (base, query) = match rest.split_once('?') {
        Some((base, query)) => (base, Some(query)),
        None => (rest, None),
    };

    let mut out = redact_userinfo(base);
    if let Some(query) = query {
        out.push('?');
        out.push_str(&redact_pairs(query, '&'));
    }
    if let Some(fragment) = fragment {
        out.push('#');
        // An OAuth implicit grant returns its token in the fragment.
        out.push_str(&redact_pairs(fragment, '&'));
    }
    out
}

/// Masks the password in `scheme://user:password@host/path`.
fn redact_userinfo(base: &str) -> String {
    let Some((scheme, rest)) = base.split_once("://") else {
        return base.to_string();
    };
    let (authority, path) = match rest.find('/') {
        Some(at) => rest.split_at(at),
        None => (rest, ""),
    };
    let Some((userinfo, host)) = authority.rsplit_once('@') else {
        return base.to_string();
    };
    match userinfo.split_once(':') {
        Some((user, password)) => {
            format!("{scheme}://{user}:{}@{host}{path}", mask(password))
        }
        None => base.to_string(),
    }
}

fn redact_headers(headers: &mut [Header]) {
    for header in headers {
        let name = header.name.to_ascii_lowercase();
        header.value = match name.as_str() {
            // The scheme says how the request authenticates, which is worth
            // keeping; only the credential after it goes.
            "authorization" | "proxy-authorization" => match header.value.trim().split_once(' ') {
                Some((scheme, credential)) => format!("{scheme} {}", mask(credential)),
                None => mask(&header.value),
            },
            // Every cookie may identify a session, whatever it is called.
            "cookie" => header
                .value
                .split(';')
                .map(|pair| match pair.split_once('=') {
                    Some((name, value)) => format!("{name}={}", mask(value)),
                    None => pair.to_string(),
                })
                .collect::<Vec<_>>()
                .join(";"),
            "set-cookie" => {
                let (cookie, attributes) = match header.value.split_once(';') {
                    Some((cookie, attributes)) => (cookie, Some(attributes)),
                    None => (header.value.as_str(), None),
                };
                let cookie = match cookie.split_once('=') {
                    Some((name, value)) => format!("{name}={}", mask(value)),
                    None => cookie.to_string(),
                };
                match attributes {
                    Some(attributes) => format!("{cookie};{attributes}"),
                    None => cookie,
                }
            }
            _ if is_sensitive(&name) => mask(&header.value),
            // Location, Referer and the like carry whole URLs.
            _ if header.value.contains("://") => redact_url(&header.value),
            _ => continue,
        };
    }
}

fn redact_json(value: &mut Value, name: Option<&str>) {
    let sensitive = name.is_some_and(is_sensitive);
    match value {
        Value::String(text) if sensitive => *text = mask(text),
        // Servers often echo the address they were called with.
        Value::String(text) if text.contains("://") => *text = redact_url(text),
        Value::Number(_) if name.is_some_and(is_numeric_secret) => *value = REDACTED.into(),
        // Everything under a sensitive name is a credential, so the name is
        // passed down rather than replaced by the names inside.
        Value::Array(items) => items.iter_mut().for_each(|v| redact_json(v, name)),
        Value::Object(fields) => {
            for (key, field) in fields {
                redact_json(field, if sensitive { name } else { Some(key) });
            }
        }
        _ => {}
    }
}

/// Masks the values under sensitive keys of a JSON document. Text that is
/// not JSON is returned as it is.
pub fn redact_text(text: &str) -> String {
    if !text.trim_start().starts_with(['{', '[']) {
        return text.to_string();
    }
    let Ok(mut value) = serde_json::from_str::<Value>(text) else {
        return text.to_string();
    };
    redact_json(&mut value, None);
    // Written back the way it came: indented if it was, compact otherwise.
    let written = if text.trim().contains('\n') {
        serde_json::to_string_pretty(&value)
    } else {
        serde_json::to_string(&value)
    };
    written.unwrap_or_else(|_| text.to_string())
}

fn redact_body(body: &str, headers: &[Header]) -> String {
    let url_encoded = headers.iter().any(|h| {
        h.name.eq_ignore_ascii_case("content-type")
            && h.value
                .to_ascii_lowercase()
                .contains("x-www-form-urlencoded")
    });
    if url_encoded {
        redact_pairs(body, '&')
    } else {
        redact_text(body)
    }
}

/// Masks the text given to a sensitive argument written into a GraphQL
/// query, as in `login(password: "hunter2")`.
fn redact_query(query: &str) -> String {
    let mut out = String::with_capacity(query.len());
    let mut rest = query;
    while let Some(colon) = rest.find(':') {
        let (before, after) = rest.split_at(colon);
        let name_at = before
            .trim_end()
            .rfind(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
            .map_or(0, |at| at + 1);
        let name = before[name_at..].trim_end();
        let value = after[1..].trim_start();
        let text = value
            .strip_prefix('"')
            .filter(|_| !value.starts_with("\"\"\""))
            .and_then(|text| {
                // The closing quote is the first one not escaped.
                let mut escaped = false;
                text.find(|c| {
                    let closes = c == '"' && !escaped;
                    escaped = c == '\\' && !escaped;
                    closes
                })
                .map(|end| &text[..end])
            });
        match text {
            Some(text) if is_sensitive(name) => {
                let skipped = after.len() - value.len();
                out.push_str(before);
                out.push_str(&after[..skipped]);
                out.push('"');
                out.push_str(&mask(text));
                out.push('"');
                rest = &value[text.len() + 2..];
            }
            _ => {
                out.push_str(before);
                out.push(':');
                rest = &after[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

fn redact_request(request: &mut Request) {
    request.url = redact_url(&request.url);
    redact_headers(&mut request.headers);
    match request.effective_body_mode() {
        BodyMode::UrlEncoded => {
            request.body = request.body.as_deref().map(|b| redact_pairs(b, '&'));
        }
        BodyMode::Raw => {
            request.body = request
                .body
                .as_deref()
                .map(|b| redact_body(b, &request.headers));
        }
        BodyMode::GraphQl => {
            request.body = request.body.as_deref().map(redact_query);
            request.graphql_variables = request.graphql_variables.as_deref().map(redact_text);
        }
        // A binary body is a file path; form-data is in `form`.
        BodyMode::None | BodyMode::FormData | BodyMode::Binary => {}
    }
    for field in &mut request.form {
        if !field.file && is_sensitive(&field.key) {
            field.value = mask(&field.value);
        }
    }
    if let Some(auth) = &mut request.auth {
        let fields = auth_fields(auth.kind);
        for param in &mut auth.params {
            if fields.iter().any(|f| f.secret && f.key == param.key) {
                param.value = mask(&param.value);
            }
        }
    }
}

fn redact_response(response: &mut Response) {
    redact_headers(&mut response.headers);
    response.body = redact_body(&response.body, &response.headers);
}

fn redact_variables(variables: &mut [Variable]) {
    for variable in variables {
        if variable.secret || is_sensitive(&variable.key) {
            variable.value = mask(&variable.value);
        }
    }
}

fn redact_items(items: &mut [Item]) {
    for item in items {
        if let Some(request) = &mut item.request {
            redact_request(request);
        }
        redact_items(&mut item.items);
    }
}

/// A copy of `exchanges` with the credentials taken out of both sides.
pub fn redact_exchanges(exchanges: &[Exchange]) -> Vec<Exchange> {
    let mut exchanges = exchanges.to_vec();
    for exchange in &mut exchanges {
        redact_request(&mut exchange.request);
        redact_response(&mut exchange.response);
    }
    exchanges
}

/// A copy of `collection` with the credentials taken out of its requests
/// and variables.
pub fn redact_collection(collection: &Collection) -> Collection {
    let mut collection = collection.clone();
    redact_variables(&mut collection.variables);
    redact_items(&mut collection.items);
    collection
}

/// A copy of `environment` with the values of sensitive variables taken out.
pub fn redact_environment(environment: &Environment) -> Environment {
    let mut environment = environment.clone();
    redact_variables(&mut environment.variables);
    environment
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Auth, AuthKind, FormField};

    fn header(name: &str, value: &str) -> Header {
        Header {
            name: name.into(),
            value: value.into(),
        }
    }

    #[test]
    fn recognises_sensitive_names() {
        for name in [
            "Authorization",
            "X-Api-Key",
            "api_key",
            "access_token",
            "clientSecret",
            "Set-Cookie",
            "X-Amz-Signature",
            "pwd",
            "PASSWORD",
        ] {
            assert!(is_sensitive(name), "{name}");
        }
        for name in [
            "Accept",
            "page",
            "shipping",
            "author",
            "key",
            "Content-Type",
        ] {
            assert!(!is_sensitive(name), "{name}");
        }
    }

    #[test]
    fn masks_urls() {
        assert_eq!(
            redact_url("https://me:hunter2@api.test/v1?page=2&api_key=abc&q=x#access_token=zzz"),
            "https://me:[REDACTED]@api.test/v1?page=2&api_key=[REDACTED]&q=x#access_token=[REDACTED]"
        );
        // Variable references and plain URLs are left as written.
        let plain = "{{base}}/items?token={{token}}&sort=name";
        assert_eq!(redact_url(plain), plain);
        assert_eq!(redact_url("api.test/a@b?x=1"), "api.test/a@b?x=1");
    }

    #[test]
    fn masks_headers_but_keeps_their_shape() {
        let mut headers = vec![
            header("Authorization", "Bearer abc.def.ghi"),
            header("Cookie", "sid=1; theme=dark"),
            header("Set-Cookie", "tok=abc; Path=/; HttpOnly"),
            header("X-API-Key", "k-123"),
            header("X-Auth-Token", "{{token}}"),
            header("Accept", "application/json"),
            header("Location", "https://api.test/cb?code=1&access_token=zzz"),
        ];
        redact_headers(&mut headers);
        let values: Vec<&str> = headers.iter().map(|h| h.value.as_str()).collect();
        assert_eq!(
            values,
            [
                "Bearer [REDACTED]",
                "sid=[REDACTED]; theme=[REDACTED]",
                "tok=[REDACTED]; Path=/; HttpOnly",
                "[REDACTED]",
                "{{token}}",
                "application/json",
                "https://api.test/cb?code=1&access_token=[REDACTED]",
            ]
        );
    }

    #[test]
    fn masks_json_by_key() {
        let text = r#"{"user":"alice","password":"s3cret","pin":1234,"max_tokens":100,"credentials":{"id":"a","parts":["x","y"]},"items":[{"access_token":"t","ok":true}],"url":"https://api.test/a?api_key=k&page=2"}"#;
        assert_eq!(
            redact_text(text),
            r#"{"user":"alice","password":"[REDACTED]","pin":"[REDACTED]","max_tokens":100,"credentials":{"id":"[REDACTED]","parts":["[REDACTED]","[REDACTED]"]},"items":[{"access_token":"[REDACTED]","ok":true}],"url":"https://api.test/a?api_key=[REDACTED]&page=2"}"#
        );
        // Indented input stays indented; anything else is untouched.
        assert_eq!(
            redact_text("{\n  \"token\": \"t\"\n}"),
            "{\n  \"token\": \"[REDACTED]\"\n}"
        );
        assert_eq!(redact_text("token=abc"), "token=abc");
        assert_eq!(redact_text("{not json"), "{not json");
    }

    #[test]
    fn masks_every_part_of_a_request() {
        let mut request = Request::new("POST", "https://api.test/login?apikey=abc");
        request.add_header("Content-Type", "application/x-www-form-urlencoded");
        request.body = Some("username=alice&password=s3cret".into());
        request.form = vec![
            FormField::text("client_secret", "shh"),
            FormField::text("note", "hello"),
            FormField::file("token", "/tmp/token.txt"),
        ];
        request.auth = Some(Auth::new(
            AuthKind::Basic,
            &[("username", "alice"), ("password", "s3cret")],
        ));
        redact_request(&mut request);

        assert_eq!(request.url, "https://api.test/login?apikey=[REDACTED]");
        assert_eq!(
            request.body.as_deref(),
            Some("username=alice&password=[REDACTED]")
        );
        let form: Vec<&str> = request.form.iter().map(|f| f.value.as_str()).collect();
        assert_eq!(form, ["[REDACTED]", "hello", "/tmp/token.txt"]);
        let auth: Vec<&str> = request
            .auth
            .as_ref()
            .unwrap()
            .params
            .iter()
            .map(|p| p.value.as_str())
            .collect();
        assert_eq!(auth, ["alice", "[REDACTED]"]);
    }

    #[test]
    fn redacted_exchanges_export_as_har() {
        let mut request = Request::new("GET", "https://me:pw@api.test/items?token=abc");
        request.add_header("Authorization", "Basic bWU6cHc=");
        let response = Response {
            status: 200,
            status_text: "OK".into(),
            http_version: "HTTP/1.1".into(),
            headers: vec![
                header("content-type", "application/json"),
                header("set-cookie", "sid=xyz; Path=/"),
            ],
            body: r#"{"refresh_token":"r","name":"n"}"#.into(),
            size_bytes: 32,
            bytes: None,
            elapsed_ms: 5,
        };
        let exchanges = [Exchange {
            started_ms: 0,
            request,
            response,
        }];
        let har = crate::to_har(&redact_exchanges(&exchanges));
        for secret in ["pw@", "abc", "bWU6cHc=", "xyz", "\\\"r\\\""] {
            assert!(!har.contains(secret), "{secret} survived in {har}");
        }
        let doc: Value = serde_json::from_str(&har).unwrap();
        let entry = &doc["log"]["entries"][0];
        assert_eq!(entry["request"]["queryString"][0]["value"], REDACTED);
        assert_eq!(entry["request"]["headers"][0]["value"], "Basic [REDACTED]");
        assert_eq!(entry["response"]["cookies"][0]["value"], REDACTED);
        assert_eq!(
            entry["response"]["content"]["text"],
            r#"{"refresh_token":"[REDACTED]","name":"n"}"#
        );
        // The original session is not changed.
        assert!(exchanges[0].request.url.contains("token=abc"));
    }

    #[test]
    fn masks_collection_and_environment_variables() {
        let collection = Collection {
            name: "Shop".into(),
            variables: vec![
                Variable::new("base", "https://api.test"),
                Variable::new("api_key", "k-1"),
            ],
            items: vec![Item {
                name: "Folder".into(),
                request: None,
                items: vec![Item {
                    name: "List".into(),
                    request: Some(Request::new("GET", "{{base}}/items?secret=abc")),
                    items: Vec::new(),
                }],
            }],
            link: None,
        };
        let redacted = redact_collection(&collection);
        assert_eq!(redacted.variables[0].value, "https://api.test");
        assert_eq!(redacted.variables[1].value, REDACTED);
        assert_eq!(
            redacted.requests()[0].1.url,
            "{{base}}/items?secret=[REDACTED]"
        );

        let environment = Environment {
            name: "dev".into(),
            variables: vec![Variable::new("token", "t"), Variable::new("host", "h")],
        };
        let redacted = redact_environment(&environment);
        assert_eq!(redacted.variables[0].value, REDACTED);
        assert_eq!(redacted.variables[1].value, "h");
    }
}
