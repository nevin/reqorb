//! `.env` files: one `KEY=value` per line.

use crate::Variable;

/// Parses `KEY=VALUE` lines; `None` if any line is something else.
pub(super) fn dotenv(text: &str) -> Option<Vec<Variable>> {
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

pub(super) fn dotenv_line(variable: &Variable) -> String {
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
