//! Helpers shared by the format modules.

use base64::Engine;
use serde_json::Value;

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

pub(super) fn basic_auth(user: &str, password: &str) -> String {
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

pub(super) fn pretty(value: &impl serde::Serialize) -> String {
    let mut out = serde_json::to_string_pretty(value).expect("serialises to JSON");
    out.push('\n');
    out
}
