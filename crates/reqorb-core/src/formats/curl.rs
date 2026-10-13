//! curl command lines.

use super::ImportResult;
use super::util::{append_query, basic_auth, form_encode};
use crate::{AuthKind, BodyMode, Collection, Error, FormField, Item, Request};

pub(super) fn curl(text: &str, name_hint: &str) -> Result<ImportResult, Error> {
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
    crate::graphql::detect(&mut request);

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
            link: None,
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

/// Renders the request as a curl command that a POSIX shell can run. Auth
/// uses curl's own options where it has them; types curl cannot compute are
/// left out and noted in a leading comment.
pub fn to_curl(request: &Request) -> String {
    let mut request = request.clone();
    let mut auth_args = Vec::new();
    let mut note = None;
    if let Some(auth) = request.auth.take() {
        let get = |key: &str| auth.get(key);
        let user = |name: &str, secret: &str| {
            format!(
                "-u {}",
                shell_quote(&format!("{}:{}", get(name), get(secret)))
            )
        };
        match auth.kind {
            AuthKind::None => {}
            AuthKind::Basic => auth_args.push(user("username", "password")),
            AuthKind::Digest => {
                auth_args.push(format!("--digest {}", user("username", "password")))
            }
            AuthKind::Ntlm => {
                let name = match get("domain") {
                    domain if domain.is_empty() => get("username"),
                    domain => format!("{domain}\\{}", get("username")),
                };
                auth_args.push(format!(
                    "--ntlm -u {}",
                    shell_quote(&format!("{name}:{}", get("password")))
                ));
            }
            AuthKind::AwsV4 => {
                auth_args.push(format!(
                    "--aws-sigv4 {} {}",
                    shell_quote(&format!("aws:amz:{}:{}", get("region"), get("service"))),
                    user("accessKey", "secretKey")
                ));
                if !get("sessionToken").is_empty() {
                    request.add_header("X-Amz-Security-Token", get("sessionToken"));
                }
            }
            AuthKind::Bearer => {
                request.add_header("Authorization", format!("Bearer {}", get("token")))
            }
            AuthKind::OAuth2 if !get("accessToken").is_empty() => {
                let value = format!("{} {}", get("headerPrefix"), get("accessToken"));
                request.add_header("Authorization", value.trim().to_string());
            }
            AuthKind::ApiKey if get("in") == "query" => {
                // Appended as written so `{{variables}}` stay intact.
                let separator = if request.url.contains('?') { '&' } else { '?' };
                request.url = format!("{}{separator}{}={}", request.url, get("key"), get("value"));
            }
            AuthKind::ApiKey => request.add_header(&get("key"), get("value")),
            kind => {
                note = Some(format!(
                    "# {} is computed by reqorb when sending and is not part of this command.\n",
                    kind.label()
                ))
            }
        }
    }
    request.materialize();
    let request = &request;
    let mode = request.effective_body_mode();
    let mut parts = vec![String::from("curl")];
    let has_body = match mode {
        BodyMode::None => false,
        BodyMode::FormData => !request.form.is_empty(),
        _ => request.body.is_some(),
    };
    let default_method = if has_body { "POST" } else { "GET" };
    if !request.method.eq_ignore_ascii_case(default_method) {
        parts.push(format!("-X {}", request.method.to_uppercase()));
    }
    parts.push(shell_quote(&request.url));
    for h in &request.headers {
        parts.push(format!(
            "-H {}",
            shell_quote(&format!("{}: {}", h.name, h.value))
        ));
    }
    match (mode, &request.body) {
        (BodyMode::FormData, _) => {
            for field in &request.form {
                let at = if field.file { "@" } else { "" };
                let option = if field.file || !field.value.starts_with('@') {
                    "-F"
                } else {
                    // Stops curl reading a text value that starts with @ as a file.
                    "--form-string"
                };
                parts.push(format!(
                    "{option} {}",
                    shell_quote(&format!("{}={at}{}", field.key, field.value))
                ));
            }
        }
        (BodyMode::Binary, Some(path)) => {
            parts.push(format!(
                "--data-binary {}",
                shell_quote(&format!("@{path}"))
            ));
        }
        (BodyMode::Raw | BodyMode::UrlEncoded, Some(body)) => {
            parts.push(format!("--data-raw {}", shell_quote(body)));
        }
        _ => {}
    }
    parts.extend(auth_args);
    if let Some(ms) = request.timeout_ms {
        parts.push(format!("--max-time {}", ms as f64 / 1000.0));
    }
    format!("{}{}", note.unwrap_or_default(), parts.join(" \\\n  "))
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
