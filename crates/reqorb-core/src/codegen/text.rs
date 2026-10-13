//! Writing text as a string literal, which every language does its own way.

use serde_json::Value;

/// How a language writes the characters it cannot take as they are.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Escapes {
    /// `\u001f`: JavaScript, Python, Go, Java and C#.
    Unicode,
    /// `\u001f`, and `\$` for a dollar sign: Kotlin and Dart.
    Dollar,
    /// `\u{1f}`: Rust and Swift.
    Braced,
    /// `\u{1f}`, and `\$` for a dollar sign: PHP between double quotes.
    BracedDollar,
    /// `\u001f`, and `\#` for a hash, which opens an interpolation: Ruby
    /// between double quotes.
    Hash,
    /// `\037`: C++.
    Octal,
}

/// The text between `quote` marks, with whatever needs it escaped.
pub(super) fn quoted(text: &str, quote: char, escapes: Escapes) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push(quote);
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '$' if matches!(escapes, Escapes::Dollar | Escapes::BracedDollar) => {
                out.push_str("\\$")
            }
            '#' if escapes == Escapes::Hash => out.push_str("\\#"),
            c if c == quote => {
                out.push('\\');
                out.push(c);
            }
            c if (c as u32) < 0x20 || c as u32 == 0x7f => match escapes {
                Escapes::Unicode | Escapes::Dollar | Escapes::Hash => {
                    out.push_str(&format!("\\u{:04x}", c as u32))
                }
                Escapes::Braced | Escapes::BracedDollar => {
                    out.push_str(&format!("\\u{{{:x}}}", c as u32))
                }
                Escapes::Octal => out.push_str(&format!("\\{:03o}", c as u32)),
            },
            c => out.push(c),
        }
    }
    out.push(quote);
    out
}

/// A double-quoted string in the languages that share JSON's escapes.
pub(super) fn double(text: &str) -> String {
    quoted(text, '"', Escapes::Unicode)
}

/// A single-quoted string where only the quote and the backslash are
/// special, as in Ruby and PHP.
fn single(text: &str) -> String {
    format!("'{}'", text.replace('\\', "\\\\").replace('\'', "\\'"))
}

/// Whether the text holds a character that would not survive being
/// written as it is: a carriage return, which a file's line endings
/// swallow, or one that cannot be seen.
pub(super) fn needs_escapes(text: &str) -> bool {
    text.chars()
        .any(|c| c != '\n' && ((c as u32) < 0x20 || c as u32 == 0x7f))
}

/// A Ruby string: between single quotes, where nothing is interpolated,
/// unless it holds characters that have to be escaped.
pub(super) fn ruby_string(text: &str) -> String {
    if needs_escapes(text) {
        quoted(text, '"', Escapes::Hash)
    } else {
        single(text)
    }
}

/// A PHP string, on the same terms as a Ruby one.
pub(super) fn php_string(text: &str) -> String {
    if needs_escapes(text) {
        quoted(text, '"', Escapes::BracedDollar)
    } else {
        single(text)
    }
}

/// Every line after the first moved in by `indent`.
pub(super) fn hang(text: &str, indent: &str) -> String {
    text.replace('\n', &format!("\n{indent}"))
}

/// JSON over several lines, which is also how JavaScript writes the value.
pub(super) fn pretty_json(value: &Value) -> String {
    serde_json::to_string_pretty(value).expect("a JSON value serialises")
}

/// The value as a Python literal.
pub(super) fn python_literal(value: &Value, indent: usize) -> String {
    let pad = "    ".repeat(indent + 1);
    let close = "    ".repeat(indent);
    match value {
        Value::Null => "None".into(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => double(s),
        Value::Array(items) if items.is_empty() => "[]".into(),
        Value::Object(fields) if fields.is_empty() => "{}".into(),
        Value::Array(items) => {
            let lines: Vec<String> = items
                .iter()
                .map(|item| format!("{pad}{},\n", python_literal(item, indent + 1)))
                .collect();
            format!("[\n{}{close}]", lines.concat())
        }
        Value::Object(fields) => {
            let lines: Vec<String> = fields
                .iter()
                .map(|(key, item)| {
                    format!(
                        "{pad}{}: {},\n",
                        double(key),
                        python_literal(item, indent + 1)
                    )
                })
                .collect();
            format!("{{\n{}{close}}}", lines.concat())
        }
    }
}
