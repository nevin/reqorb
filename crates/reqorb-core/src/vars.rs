//! `{{variable}}` substitution.

use crate::{Request, Variable};

/// Variables may reference other variables up to this depth.
const MAX_DEPTH: u8 = 8;

#[derive(Debug, Clone)]
pub struct Resolved {
    pub request: Request,
    /// Names that appeared as `{{name}}` but had no enabled variable.
    pub unresolved: Vec<String>,
}

/// Substitutes variables in the URL, headers and body. The first enabled
/// variable with a matching key wins, so pass higher-priority variables first.
pub fn resolve(request: &Request, variables: &[Variable]) -> Resolved {
    let mut unresolved = Vec::new();
    let mut sub = |s: &str| substitute(s, variables, 0, &mut unresolved);

    let mut out = request.clone();
    out.url = sub(&request.url);
    for h in &mut out.headers {
        h.name = sub(&h.name);
        h.value = sub(&h.value);
    }
    out.body = request.body.as_deref().map(&mut sub);
    for field in &mut out.form {
        field.key = sub(&field.key);
        field.value = sub(&field.value);
    }
    if let Some(auth) = &mut out.auth {
        for param in &mut auth.params {
            param.value = sub(&param.value);
        }
    }

    Resolved {
        request: out,
        unresolved,
    }
}

/// Substitutes variables in one piece of text, leaving unknown ones as written.
pub(crate) fn fill(input: &str, variables: &[Variable]) -> String {
    substitute(input, variables, 0, &mut Vec::new())
}

fn substitute(input: &str, vars: &[Variable], depth: u8, unresolved: &mut Vec<String>) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(start) = rest.find("{{") {
        let Some(len) = rest[start + 2..].find("}}") else {
            break;
        };
        let end = start + 2 + len + 2;
        let name = rest[start + 2..start + 2 + len].trim();
        out.push_str(&rest[..start]);
        match vars.iter().find(|v| v.enabled && v.key == name) {
            Some(v) if depth < MAX_DEPTH => {
                out.push_str(&substitute(&v.value, vars, depth + 1, unresolved));
            }
            _ => {
                out.push_str(&rest[start..end]);
                if !unresolved.iter().any(|u| u == name) {
                    unresolved.push(name.to_string());
                }
            }
        }
        rest = &rest[end..];
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Header;

    #[test]
    fn substitutes_everywhere_and_reports_missing() {
        let mut request = Request::new("GET", "{{base}}/users/{{ id }}");
        request.headers.push(Header {
            name: "Authorization".into(),
            value: "Bearer {{token}}".into(),
        });
        request.body = Some(r#"{"a":{"b":"{{id}}"}}"#.into());

        let vars = [
            Variable::new("base", "https://{{host}}"),
            Variable::new("host", "api.test"),
            Variable::new("id", "7"),
            Variable {
                key: "token".into(),
                value: "secret".into(),
                enabled: false,
            },
        ];
        let resolved = resolve(&request, &vars);

        assert_eq!(resolved.request.url, "https://api.test/users/7");
        assert_eq!(resolved.request.headers[0].value, "Bearer {{token}}");
        assert_eq!(resolved.request.body.unwrap(), r#"{"a":{"b":"7"}}"#);
        assert_eq!(resolved.unresolved, ["token"]);
    }

    #[test]
    fn first_variable_wins_and_cycles_terminate() {
        let request = Request::new("GET", "{{a}}/{{loop}}");
        let vars = [
            Variable::new("a", "env"),
            Variable::new("a", "collection"),
            Variable::new("loop", "{{loop}}"),
        ];
        let resolved = resolve(&request, &vars);
        assert_eq!(resolved.request.url, "env/{{loop}}");
        assert_eq!(resolved.unresolved, ["loop"]);
    }
}
