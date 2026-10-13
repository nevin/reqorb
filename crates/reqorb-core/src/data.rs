//! Data files for a run: one set of variables for each time the requests
//! are gone through, read from CSV or from a JSON array of objects.

use serde_json::Value;

use crate::error::Error;
use crate::model::Variable;

/// The rows of a data file, each as the variables it sets. `name` is the
/// file's name, which settles the format when the text does not.
pub fn parse_run_data(name: &str, text: &str) -> Result<Vec<Vec<Variable>>, Error> {
    let text = text.trim_start_matches('\u{feff}');
    let json = name.to_ascii_lowercase().ends_with(".json")
        || matches!(text.trim_start().chars().next(), Some('[' | '{'));
    let rows = if json {
        from_json(text)?
    } else {
        from_csv(text)?
    };
    if rows.is_empty() {
        return Err(Error::Format("the data file has no rows".into()));
    }
    Ok(rows)
}

fn variable(key: &str, value: String) -> Variable {
    Variable {
        key: key.to_string(),
        value,
        enabled: true,
        secret: false,
    }
}

fn from_json(text: &str) -> Result<Vec<Vec<Variable>>, Error> {
    let value: Value = serde_json::from_str(text)
        .map_err(|e| Error::Format(format!("the data file is not valid JSON: {e}")))?;
    let Value::Array(rows) = value else {
        return Err(Error::Format(
            "a JSON data file must be an array of objects".into(),
        ));
    };
    rows.iter()
        .enumerate()
        .map(|(i, row)| {
            let Value::Object(fields) = row else {
                return Err(Error::Format(format!(
                    "row {} of the data file is not an object",
                    i + 1
                )));
            };
            Ok(fields
                .iter()
                .map(|(key, value)| {
                    let value = match value {
                        Value::String(s) => s.clone(),
                        Value::Null => String::new(),
                        other => other.to_string(),
                    };
                    variable(key, value)
                })
                .collect())
        })
        .collect()
}

/// CSV with a header row. Fields may be quoted, and a quoted field may
/// hold commas, line breaks and doubled quotes.
fn from_csv(text: &str) -> Result<Vec<Vec<Variable>>, Error> {
    let mut records = records(text)?.into_iter();
    let Some(header) = records.next() else {
        return Ok(Vec::new());
    };
    let header: Vec<String> = header.iter().map(|h| h.trim().to_string()).collect();
    if header.iter().any(String::is_empty) {
        return Err(Error::Format(
            "the first line of a CSV data file names its columns, and one is empty".into(),
        ));
    }
    Ok(records
        .map(|record| {
            header
                .iter()
                .enumerate()
                .map(|(i, key)| variable(key, record.get(i).cloned().unwrap_or_default()))
                .collect()
        })
        .collect())
}

fn records(text: &str) -> Result<Vec<Vec<String>>, Error> {
    let mut out = Vec::new();
    let mut record: Vec<String> = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    // Whether the field began with a quote, so `""` is kept as empty.
    let mut was_quoted = false;
    let mut chars = text.chars().peekable();
    let mut end = |record: &mut Vec<String>, field: &mut String, was_quoted: bool| {
        record.push(std::mem::take(field));
        // A blank line is not a row.
        if record.len() > 1 || !record[0].is_empty() || was_quoted {
            out.push(std::mem::take(record));
        } else {
            record.clear();
        }
    };
    while let Some(c) = chars.next() {
        if quoted {
            match c {
                '"' if chars.peek() == Some(&'"') => {
                    chars.next();
                    field.push('"');
                }
                '"' => quoted = false,
                c => field.push(c),
            }
            continue;
        }
        match c {
            '"' if field.is_empty() => {
                quoted = true;
                was_quoted = true;
            }
            ',' => {
                record.push(std::mem::take(&mut field));
                was_quoted = false;
            }
            '\r' if chars.peek() == Some(&'\n') => {}
            '\n' | '\r' => {
                end(&mut record, &mut field, was_quoted);
                was_quoted = false;
            }
            c => field.push(c),
        }
    }
    if quoted {
        return Err(Error::Format(
            "a quoted field in the data file is never closed".into(),
        ));
    }
    if !field.is_empty() || !record.is_empty() || was_quoted {
        end(&mut record, &mut field, was_quoted);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pairs(row: &[Variable]) -> Vec<(&str, &str)> {
        row.iter()
            .map(|v| (v.key.as_str(), v.value.as_str()))
            .collect()
    }

    #[test]
    fn reads_csv_with_quotes_and_blank_lines() {
        let rows = parse_run_data(
            "users.csv",
            "name, note\r\nAda,\"likes \"\"tea\"\", and\nlong walks\"\n\nBob\n",
        )
        .unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(
            pairs(&rows[0]),
            [("name", "Ada"), ("note", "likes \"tea\", and\nlong walks")]
        );
        assert_eq!(pairs(&rows[1]), [("name", "Bob"), ("note", "")]);
    }

    #[test]
    fn reads_a_json_array_of_objects() {
        let rows = parse_run_data(
            "rows",
            r#"[{"id": 7, "ok": true, "name": "Ada", "tags": ["a"], "gone": null}]"#,
        )
        .unwrap();
        assert_eq!(
            pairs(&rows[0]),
            [
                ("id", "7"),
                ("ok", "true"),
                ("name", "Ada"),
                ("tags", "[\"a\"]"),
                ("gone", "")
            ]
        );
    }

    #[test]
    fn explains_what_is_wrong_with_a_file() {
        let message = |name: &str, text: &str| parse_run_data(name, text).unwrap_err().to_string();
        assert!(message("a.csv", "name\n").contains("no rows"));
        assert!(message("a.csv", "a,\"b\n").contains("never closed"));
        assert!(message("a.json", "{\"a\": 1}").contains("array of objects"));
        assert!(message("a.json", "[1]").contains("row 1"));
        assert!(message("a.csv", "a,,c\n1,2,3\n").contains("names its columns"));
    }
}
