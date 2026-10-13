//! Tests a response must pass and values captured from it for later
//! requests, each written as one line of text.
//!
//! ```text
//! status == 200
//! time < 500
//! header content-type contains json
//! body.items[0].name == Widget
//! body.token exists
//!
//! token = body.token
//! ```

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::vars::fill;
use crate::{Response, Variable};

/// How one test line came out.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TestResult {
    /// The test as written.
    pub test: String,
    pub passed: bool,
    /// What was found instead, or why the line could not be read; empty
    /// when the test passed.
    pub detail: String,
}

const OPERATORS: &[&str] = &[
    "==", "!=", "<=", ">=", "<", ">", "contains", "exists", "missing",
];

/// Lines worth reading: not blank and not a `#` comment.
fn lines(text: &[String]) -> impl Iterator<Item = &str> {
    text.iter()
        .flat_map(|t| t.lines())
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
}

/// Quotes around a value are optional and dropped.
fn unquote(text: &str) -> &str {
    let text = text.trim();
    for quote in ['"', '\''] {
        if let Some(inner) = text.strip_prefix(quote).and_then(|t| t.strip_suffix(quote)) {
            return inner;
        }
    }
    text
}

/// Reads the value `source` names from the response. `Ok(None)` means the
/// response has no such header or field.
fn read(source: &str, response: &Response) -> Result<Option<String>, String> {
    let source = source.trim();
    let lower = source.to_ascii_lowercase();
    match lower.as_str() {
        "status" => return Ok(Some(response.status.to_string())),
        "time" => return Ok(Some(response.elapsed_ms.to_string())),
        "size" => return Ok(Some(response.size_bytes.to_string())),
        "body" => return Ok(Some(response.body.clone())),
        _ => {}
    }
    if let Some(name) = lower.strip_prefix("header ") {
        let name = name.trim();
        return Ok(response
            .headers
            .iter()
            .find(|h| h.name.eq_ignore_ascii_case(name))
            .map(|h| h.value.clone()));
    }
    if lower.starts_with("body.") || lower.starts_with("body[") {
        let Ok(mut value) = serde_json::from_str::<Value>(&response.body) else {
            return Err("the body is not JSON".into());
        };
        for step in path(&source[4..])? {
            let next = match step {
                Step::Key(key) => value.get_mut(key).map(Value::take),
                Step::Index(index) => value.get_mut(index).map(Value::take),
            };
            match next {
                Some(next) => value = next,
                None => return Ok(None),
            }
        }
        return Ok(match value {
            Value::Null => None,
            Value::String(text) => Some(text),
            other => Some(other.to_string()),
        });
    }
    Err(format!(
        "unknown value `{source}`: use status, time, size, header NAME, body or body.path"
    ))
}

enum Step<'a> {
    Key(&'a str),
    Index(usize),
}

/// Splits `.items[0].name` into its keys and indexes.
fn path(text: &str) -> Result<Vec<Step<'_>>, String> {
    let mut steps = Vec::new();
    let mut rest = text;
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix('[') {
            let Some((index, after)) = after.split_once(']') else {
                return Err(format!("`[` without `]` in `body{text}`"));
            };
            let index = unquote(index);
            steps.push(match index.parse() {
                Ok(index) => Step::Index(index),
                // `["odd key"]` reaches keys a dot cannot.
                Err(_) => Step::Key(index),
            });
            rest = after;
        } else {
            let after = rest.strip_prefix('.').unwrap_or(rest);
            let end = after.find(['.', '[']).unwrap_or(after.len());
            if end == 0 {
                return Err(format!("empty name in `body{text}`"));
            }
            steps.push(Step::Key(&after[..end]));
            rest = &after[end..];
        }
    }
    Ok(steps)
}

/// Splits a test into what it reads, its operator and what it expects.
fn parse(line: &str) -> Result<(&str, &str, &str), String> {
    // The operator is the first one standing alone between spaces, so that
    // a header or field name may contain `-` or `=`.
    let mut at = 0;
    for word in line.split(' ') {
        if let Some(op) = OPERATORS.iter().find(|op| op.eq_ignore_ascii_case(word)) {
            if at == 0 {
                break;
            }
            return Ok((line[..at].trim(), op, line[at + word.len()..].trim()));
        }
        at += word.len() + 1;
    }
    Err(format!(
        "no comparison found: write it as `status == 200`, using one of {}",
        OPERATORS.join(" ")
    ))
}

fn check(line: &str, response: &Response, variables: &[Variable]) -> Result<(), String> {
    let (source, op, expected) = parse(line)?;
    let found = read(source, response)?;
    let expected = fill(unquote(expected), variables);
    match op {
        "exists" => return found.map(|_| ()).ok_or(format!("{source} was not found")),
        "missing" => {
            return match found {
                None => Ok(()),
                Some(found) => Err(format!("was {}", shorten(&found))),
            };
        }
        _ => {}
    }
    let Some(found) = found else {
        return Err(format!("{source} was not found"));
    };
    let numbers = found
        .trim()
        .parse::<f64>()
        .ok()
        .zip(expected.trim().parse::<f64>().ok());
    let passed = match (op, numbers) {
        ("==", Some((a, b))) => a == b,
        ("!=", Some((a, b))) => a != b,
        ("==", None) => found == expected,
        ("!=", None) => found != expected,
        ("contains", _) => found.to_lowercase().contains(&expected.to_lowercase()),
        ("<", Some((a, b))) => a < b,
        ("<=", Some((a, b))) => a <= b,
        (">", Some((a, b))) => a > b,
        (">=", Some((a, b))) => a >= b,
        _ => {
            return Err(format!(
                "`{op}` needs numbers, but found {}",
                shorten(&found)
            ));
        }
    };
    if passed {
        Ok(())
    } else {
        Err(format!("was {}", shorten(&found)))
    }
}

/// Long values are cut so a result stays one line.
fn shorten(text: &str) -> String {
    let text = text.trim();
    let flat: String = text
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    if flat.chars().count() > 80 {
        format!("{}…", flat.chars().take(80).collect::<String>())
    } else if flat.is_empty() {
        "empty".into()
    } else {
        flat
    }
}

/// Runs every test line against `response`. `{{variables}}` may be used in
/// the expected values.
pub fn run_tests(tests: &[String], response: &Response, variables: &[Variable]) -> Vec<TestResult> {
    lines(tests)
        .map(|line| {
            let outcome = check(line, response, variables);
            TestResult {
                test: line.to_string(),
                passed: outcome.is_ok(),
                detail: outcome.err().unwrap_or_default(),
            }
        })
        .collect()
}

/// Reads each `name = value` capture from `response`. Returns the variables
/// captured and, for each capture that found nothing, why.
pub fn capture(captures: &[String], response: &Response) -> (Vec<Variable>, Vec<String>) {
    let mut variables = Vec::new();
    let mut problems = Vec::new();
    for line in lines(captures) {
        let Some((name, source)) = line.split_once('=') else {
            problems.push(format!("`{line}`: write a capture as `name = body.field`"));
            continue;
        };
        let name = name.trim();
        match read(source, response) {
            Ok(Some(value)) if !name.is_empty() => variables.push(Variable::new(name, value)),
            Ok(Some(_)) => problems.push(format!("`{line}`: the variable has no name")),
            Ok(None) => problems.push(format!("{name}: {} was not found", source.trim())),
            Err(why) => problems.push(format!("{name}: {why}")),
        }
    }
    (variables, problems)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Header;

    fn response() -> Response {
        Response {
            status: 201,
            status_text: "Created".into(),
            http_version: "HTTP/1.1".into(),
            headers: vec![Header {
                name: "Content-Type".into(),
                value: "application/json; charset=utf-8".into(),
            }],
            body: r#"{"token":"abc","user":{"id":42,"name":"Ann","tags":["a","b"]},"none":null,"odd key":true,"items":[{"price":9.5}]}"#.into(),
            size_bytes: 100,
            elapsed_ms: 120,
        }
    }

    fn outcomes(tests: &[&str]) -> Vec<(bool, String)> {
        let tests: Vec<String> = tests.iter().map(|t| t.to_string()).collect();
        let variables = [Variable::new("id", "42")];
        run_tests(&tests, &response(), &variables)
            .into_iter()
            .map(|r| (r.passed, r.detail))
            .collect()
    }

    #[test]
    fn passing_tests() {
        let results = outcomes(&[
            "status == 201",
            "status != 500",
            "status < 300",
            "time <= 120",
            "size > 10",
            "header content-type contains JSON",
            "header x-missing missing",
            "body contains \"token\"",
            "body.token == abc",
            "body.token == \"abc\"",
            "body.user.id == {{id}}",
            "body.user.id >= 42.0",
            "body.user.tags[1] == b",
            "body.user.tags == [\"a\",\"b\"]",
            "body.items[0].price > 9",
            "body[\"odd key\"] == true",
            "body.user exists",
            "body.none missing",
            "body.user.email missing",
            "# a comment",
            "",
        ]);
        assert_eq!(results.len(), 19);
        for (i, (passed, detail)) in results.iter().enumerate() {
            assert!(passed, "test {i} failed: {detail}");
        }
    }

    #[test]
    fn failing_tests_say_what_was_found() {
        assert_eq!(
            outcomes(&[
                "status == 200",
                "body.user.name == Bob",
                "body.user.email exists",
                "body.token missing",
                "body.token < 5",
                "header x-id == 1",
                "status",
                "cookies == 1",
                "body.user[ == 1",
            ]),
            [
                (false, "was 201".to_string()),
                (false, "was Ann".to_string()),
                (false, "body.user.email was not found".to_string()),
                (false, "was abc".to_string()),
                (false, "`<` needs numbers, but found abc".to_string()),
                (false, "header x-id was not found".to_string()),
                (
                    false,
                    "no comparison found: write it as `status == 200`, using one of == != <= >= < > contains exists missing"
                        .to_string()
                ),
                (
                    false,
                    "unknown value `cookies`: use status, time, size, header NAME, body or body.path"
                        .to_string()
                ),
                (false, "`[` without `]` in `body.user[`".to_string()),
            ]
        );

        let mut plain = response();
        plain.body = "hello".into();
        let results = run_tests(&["body.a == 1".to_string()], &plain, &[]);
        assert_eq!(results[0].detail, "the body is not JSON");
    }

    #[test]
    fn captures_values() {
        let captures: Vec<String> = [
            "token = body.token",
            "user_id=body.user.id",
            "type = header content-type",
            "code = status",
            "missing = body.nope",
            "nonsense",
        ]
        .iter()
        .map(|c| c.to_string())
        .collect();
        let (variables, problems) = capture(&captures, &response());
        let pairs: Vec<(&str, &str)> = variables
            .iter()
            .map(|v| (v.key.as_str(), v.value.as_str()))
            .collect();
        assert_eq!(
            pairs,
            [
                ("token", "abc"),
                ("user_id", "42"),
                ("type", "application/json; charset=utf-8"),
                ("code", "201"),
            ]
        );
        assert_eq!(
            problems,
            [
                "missing: body.nope was not found",
                "`nonsense`: write a capture as `name = body.field`",
            ]
        );
    }
}
