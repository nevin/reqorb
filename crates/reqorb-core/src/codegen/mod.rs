//! A request written out as source code: the same call made with curl or
//! from a program in one of a dozen languages.
//!
//! Every language is given the request already worked out: variables
//! filled in, authentication turned into headers, form fields and GraphQL
//! queries turned into the body that is sent. What is left for each is how
//! its own HTTP client spells that.

mod compiled;
mod dotnet;
mod javascript;
mod jvm;
mod scripts;
mod swift;
mod text;

#[cfg(test)]
mod tests;

use serde_json::Value;

use crate::formats::util::basic_auth;
use crate::{AuthKind, BodyMode, Error, FormField, Header, Request, Variable, resolve, to_curl};

/// A language, and the HTTP client in it, that a request can be written for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CodeTarget {
    Curl,
    Fetch,
    Axios,
    TypeScript,
    Python,
    Go,
    Rust,
    Java,
    Kotlin,
    Swift,
    Cpp,
    CSharp,
    Php,
    Ruby,
    Dart,
    PowerShell,
}

impl CodeTarget {
    pub const ALL: [CodeTarget; 16] = [
        CodeTarget::Curl,
        CodeTarget::Fetch,
        CodeTarget::Axios,
        CodeTarget::TypeScript,
        CodeTarget::Python,
        CodeTarget::Go,
        CodeTarget::Rust,
        CodeTarget::Java,
        CodeTarget::Kotlin,
        CodeTarget::Swift,
        CodeTarget::Cpp,
        CodeTarget::CSharp,
        CodeTarget::Php,
        CodeTarget::Ruby,
        CodeTarget::Dart,
        CodeTarget::PowerShell,
    ];

    /// The name used on the command line.
    pub fn id(self) -> &'static str {
        match self {
            CodeTarget::Curl => "curl",
            CodeTarget::Fetch => "fetch",
            CodeTarget::Axios => "axios",
            CodeTarget::TypeScript => "typescript",
            CodeTarget::Python => "python",
            CodeTarget::Go => "go",
            CodeTarget::Rust => "rust",
            CodeTarget::Java => "java",
            CodeTarget::Kotlin => "kotlin",
            CodeTarget::Swift => "swift",
            CodeTarget::Cpp => "cpp",
            CodeTarget::CSharp => "csharp",
            CodeTarget::Php => "php",
            CodeTarget::Ruby => "ruby",
            CodeTarget::Dart => "dart",
            CodeTarget::PowerShell => "powershell",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        let id = match id.to_lowercase().as_str() {
            "js" | "javascript" | "node" => "fetch".to_string(),
            "ts" => "typescript".to_string(),
            "py" => "python".to_string(),
            "golang" => "go".to_string(),
            "rs" => "rust".to_string(),
            "kt" => "kotlin".to_string(),
            "c++" | "cxx" => "cpp".to_string(),
            "c#" | "cs" | "dotnet" => "csharp".to_string(),
            "rb" => "ruby".to_string(),
            "ps" | "ps1" | "pwsh" => "powershell".to_string(),
            "sh" | "shell" | "bash" => "curl".to_string(),
            other => other.to_string(),
        };
        Self::ALL.into_iter().find(|target| target.id() == id)
    }

    /// The language, and the client used where a language has several.
    pub fn label(self) -> &'static str {
        match self {
            CodeTarget::Curl => "curl",
            CodeTarget::Fetch => "JavaScript · fetch",
            CodeTarget::Axios => "JavaScript · axios",
            CodeTarget::TypeScript => "TypeScript · fetch",
            CodeTarget::Python => "Python · requests",
            CodeTarget::Go => "Go · net/http",
            CodeTarget::Rust => "Rust · reqwest",
            CodeTarget::Java => "Java · HttpClient",
            CodeTarget::Kotlin => "Kotlin · OkHttp",
            CodeTarget::Swift => "Swift · URLSession",
            CodeTarget::Cpp => "C++ · libcurl",
            CodeTarget::CSharp => "C# · HttpClient",
            CodeTarget::Php => "PHP · cURL",
            CodeTarget::Ruby => "Ruby · Net::HTTP",
            CodeTarget::Dart => "Dart · http",
            CodeTarget::PowerShell => "PowerShell",
        }
    }

    /// Conventional file extension for code in this language.
    pub fn extension(self) -> &'static str {
        match self {
            CodeTarget::Curl => "sh",
            CodeTarget::Fetch | CodeTarget::Axios => "js",
            CodeTarget::TypeScript => "ts",
            CodeTarget::Python => "py",
            CodeTarget::Go => "go",
            CodeTarget::Rust => "rs",
            CodeTarget::Java => "java",
            CodeTarget::Kotlin => "kt",
            CodeTarget::Swift => "swift",
            CodeTarget::Cpp => "cpp",
            CodeTarget::CSharp => "cs",
            CodeTarget::Php => "php",
            CodeTarget::Ruby => "rb",
            CodeTarget::Dart => "dart",
            CodeTarget::PowerShell => "ps1",
        }
    }

    /// What starts a comment that runs to the end of the line.
    fn comment(self) -> &'static str {
        match self {
            CodeTarget::Curl | CodeTarget::Python | CodeTarget::Ruby | CodeTarget::PowerShell => {
                "#"
            }
            _ => "//",
        }
    }
}

/// Writes the request as code for `target`, with `variables` (highest
/// priority first) filled in. Variables without a value stay as written
/// and are pointed out in a comment, as is authentication that only
/// reqorb can compute.
pub fn generate_code(
    request: &Request,
    variables: &[Variable],
    target: CodeTarget,
) -> Result<String, Error> {
    if ["WS", "GRPC"].contains(&request.method.to_uppercase().as_str()) {
        return Err(Error::Format(
            "code can be generated for HTTP requests only".into(),
        ));
    }
    let resolved = resolve(request, variables);
    let mut notes = Vec::new();
    if !resolved.unresolved.is_empty() {
        let names: Vec<String> = resolved
            .unresolved
            .iter()
            .map(|name| format!("{{{{{name}}}}}"))
            .collect();
        notes.push(format!(
            "No value is set for {}; replace {} before running.",
            names.join(", "),
            if names.len() == 1 { "it" } else { "them" }
        ));
    }

    let code = if target == CodeTarget::Curl {
        // curl has options of its own for most kinds of authentication.
        to_curl(&resolved.request)
    } else {
        let prepared = prepare(&resolved.request, &mut notes);
        match target {
            CodeTarget::Curl => unreachable!("handled above"),
            CodeTarget::Fetch => javascript::fetch(&prepared, false),
            CodeTarget::TypeScript => javascript::fetch(&prepared, true),
            CodeTarget::Axios => javascript::axios(&prepared),
            CodeTarget::Python => scripts::python(&prepared),
            CodeTarget::Ruby => scripts::ruby(&prepared),
            CodeTarget::Php => scripts::php(&prepared),
            CodeTarget::PowerShell => scripts::powershell(&prepared),
            CodeTarget::Go => compiled::go(&prepared),
            CodeTarget::Rust => compiled::rust(&prepared),
            CodeTarget::Cpp => compiled::cpp(&prepared),
            CodeTarget::Dart => compiled::dart(&prepared),
            CodeTarget::Java => jvm::java(&prepared, &mut notes),
            CodeTarget::Kotlin => jvm::kotlin(&prepared),
            CodeTarget::Swift => swift::swift(&prepared),
            CodeTarget::CSharp => dotnet::csharp(&prepared),
        }
    };

    let comment = target.comment();
    let mut out = String::new();
    // PHP reads nothing before its opening tag as code.
    let (head, code) = match code.strip_prefix("<?php\n") {
        Some(rest) if !notes.is_empty() => ("<?php\n", rest),
        _ => ("", code.as_str()),
    };
    out.push_str(head);
    for note in &notes {
        out.push_str(&format!("{comment} {note}\n"));
    }
    out.push_str(code);
    if !out.ends_with('\n') {
        out.push('\n');
    }
    Ok(out)
}

/// What the request sends as its body.
#[derive(Debug, Clone, PartialEq)]
enum Body {
    None,
    Text(String),
    /// `multipart/form-data` fields, some of them files.
    Form(Vec<FormField>),
    /// The contents of the file at this path.
    File(String),
}

/// A request with nothing left to work out.
#[derive(Debug, Clone)]
struct Prepared {
    /// In capitals.
    method: String,
    url: String,
    headers: Vec<Header>,
    body: Body,
    timeout_ms: Option<u64>,
}

impl Prepared {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|h| h.name.eq_ignore_ascii_case(name))
            .map(|h| h.value.as_str())
    }

    /// The headers with one entry to a name, for clients that take a map.
    /// Values sharing a name are joined the way HTTP itself joins them.
    fn merged_headers(&self) -> Vec<Header> {
        let mut merged: Vec<Header> = Vec::new();
        for header in &self.headers {
            match merged
                .iter_mut()
                .find(|h| h.name.eq_ignore_ascii_case(&header.name))
            {
                Some(first) => {
                    first.value.push_str(", ");
                    first.value.push_str(&header.value);
                }
                None => merged.push(header.clone()),
            }
        }
        merged
    }

    /// The body as JSON, when it is JSON and says so.
    fn json(&self) -> Option<Value> {
        let Body::Text(text) = &self.body else {
            return None;
        };
        if !self.header("content-type")?.to_lowercase().contains("json") {
            return None;
        }
        serde_json::from_str(text).ok()
    }

    fn text(&self) -> Option<&str> {
        match &self.body {
            Body::Text(text) => Some(text),
            _ => None,
        }
    }

    fn form(&self) -> &[FormField] {
        match &self.body {
            Body::Form(fields) => fields,
            _ => &[],
        }
    }

    fn file(&self) -> Option<&str> {
        match &self.body {
            Body::File(path) => Some(path),
            _ => None,
        }
    }

    fn has_files(&self) -> bool {
        self.form().iter().any(|field| field.file)
    }

    fn has_body(&self) -> bool {
        self.body != Body::None
    }

    /// The timeout in seconds, as short as it can be written.
    fn timeout_secs(&self) -> Option<String> {
        self.timeout_ms.map(|ms| format!("{}", ms as f64 / 1000.0))
    }
}

fn prepare(request: &Request, notes: &mut Vec<String>) -> Prepared {
    let mut request = request.clone();
    if let Some(auth) = request.auth.take() {
        let get = |key: &str| auth.get(key);
        match auth.kind {
            AuthKind::None => {}
            AuthKind::Basic => request.add_header(
                "Authorization",
                basic_auth(&get("username"), &get("password")),
            ),
            AuthKind::Bearer => {
                request.add_header("Authorization", format!("Bearer {}", get("token")))
            }
            AuthKind::OAuth2 if !get("accessToken").is_empty() => {
                let value = format!("{} {}", get("headerPrefix"), get("accessToken"));
                request.add_header("Authorization", value.trim().to_string());
            }
            AuthKind::ApiKey if get("in") == "query" => {
                let separator = if request.url.contains('?') { '&' } else { '?' };
                request.url = format!("{}{separator}{}={}", request.url, get("key"), get("value"));
            }
            AuthKind::ApiKey => request.add_header(&get("key"), get("value")),
            kind => notes.push(format!(
                "{} is computed by reqorb when sending and is not part of this code.",
                kind.label()
            )),
        }
    }
    request.materialize();
    let body = match (request.effective_body_mode(), request.body.take()) {
        (BodyMode::FormData, _) if !request.form.is_empty() => {
            // The client writes this header itself, with the boundary in it.
            request
                .headers
                .retain(|h| !h.name.eq_ignore_ascii_case("content-type"));
            Body::Form(std::mem::take(&mut request.form))
        }
        (BodyMode::Binary, Some(path)) if !path.is_empty() => Body::File(path),
        (BodyMode::Raw | BodyMode::UrlEncoded, Some(text)) if !text.is_empty() => Body::Text(text),
        _ => Body::None,
    };
    Prepared {
        method: request.method.trim().to_uppercase(),
        url: request.url.trim().to_string(),
        headers: request.headers,
        body,
        timeout_ms: request.timeout_ms,
    }
}

/// The last part of a path, which is the name a file is uploaded under.
fn file_name(path: &str) -> &str {
    path.rsplit(['/', '\\']).next().unwrap_or(path)
}

/// A field or file name as it goes inside the quotes of a multipart
/// `Content-Disposition`, for the clients that leave writing it to us.
fn disposition(name: &str) -> String {
    name.replace('"', "%22")
        .replace('\r', "%0D")
        .replace('\n', "%0A")
}
