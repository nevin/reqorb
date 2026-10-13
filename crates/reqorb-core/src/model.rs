use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::{Auth, Cookie, Error, FileAccess};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Header {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Request {
    pub method: String,
    pub url: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub headers: Vec<Header>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<u64>,
    /// How the request authenticates; `None` sends it as written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth: Option<Auth>,
    /// Transport options for this request alone; `None` means the defaults.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub settings: Option<RequestSettings>,
    /// What kind of body the request has. `None` works it out from `body`,
    /// which is how requests saved before body types existed still load.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body_mode: Option<BodyMode>,
    /// Fields for the form-data and url-encoded body types.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub form: Vec<FormField>,
    /// For a gRPC request, the method to call as `package.Service/Method`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grpc_method: Option<String>,
    /// For a gRPC request, the `.proto` file describing the service; `None`
    /// asks the server through reflection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proto_path: Option<String>,
    /// For a GraphQL request, its variables as a JSON object.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub graphql_variables: Option<String>,
    /// For a GraphQL request, which of the query's operations to run;
    /// needed only when it holds several.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub graphql_operation: Option<String>,
    /// Checks the response must pass, one per line, such as `status == 200`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tests: Vec<String>,
    /// Values to keep from the response for later requests, one per line,
    /// such as `token = body.access_token`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub captures: Vec<String>,
    /// JavaScript run before the request is sent, which may change it and
    /// set variables.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pre_script: Option<String>,
    /// JavaScript run after the response arrives, to test it and to keep
    /// values from it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub post_script: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BodyMode {
    None,
    /// `multipart/form-data`, built from `form`; fields may be files.
    FormData,
    /// `application/x-www-form-urlencoded`, built from `form`.
    UrlEncoded,
    /// `body` sent as written.
    Raw,
    /// The contents of the file whose path is in `body`.
    Binary,
    /// A GraphQL query in `body`, sent as JSON along with the request's
    /// `graphql_variables`; in the URL instead when the method is GET.
    #[serde(rename = "graphql")]
    GraphQl,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct FormField {
    pub key: String,
    /// The text to send, or the path of the file when `file` is set.
    pub value: String,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub file: bool,
}

impl FormField {
    pub fn text(key: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            key: key.into(),
            value: value.into(),
            file: false,
        }
    }

    pub fn file(key: impl Into<String>, path: impl Into<String>) -> Self {
        Self {
            key: key.into(),
            value: path.into(),
            file: true,
        }
    }
}

/// A TLS version a request refuses to negotiate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DisabledTls {
    #[default]
    None,
    Tls12,
    Tls13,
}

/// How one request is carried out. The defaults match what a browser or
/// Postman does out of the box.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct RequestSettings {
    /// `None` uses the app-wide HTTP version.
    pub http_mode: Option<HttpMode>,
    /// Reject servers whose certificate cannot be verified.
    pub verify_ssl: bool,
    pub follow_redirects: bool,
    /// Redirect with the original method and body instead of switching to GET.
    pub follow_original_method: bool,
    /// Keep the Authorization header when a redirect leaves the original host.
    pub follow_auth_header: bool,
    /// Do not send a Referer header on redirected requests.
    pub remove_referer: bool,
    /// Reject responses with malformed headers instead of tolerating them.
    pub strict_http_parser: bool,
    /// Neither send cookies from the jar nor store the ones received.
    pub disable_cookie_jar: bool,
    pub max_redirects: u32,
    pub disabled_tls: DisabledTls,
}

impl Default for RequestSettings {
    fn default() -> Self {
        Self {
            http_mode: None,
            verify_ssl: true,
            follow_redirects: true,
            follow_original_method: false,
            follow_auth_header: false,
            remove_referer: false,
            strict_http_parser: false,
            disable_cookie_jar: false,
            max_redirects: 10,
            disabled_tls: DisabledTls::None,
        }
    }
}

impl Request {
    pub fn new(method: impl Into<String>, url: impl Into<String>) -> Self {
        Self {
            method: method.into(),
            url: url.into(),
            ..Self::default()
        }
    }

    pub fn has_header(&self, name: &str) -> bool {
        self.headers
            .iter()
            .any(|h| h.name.eq_ignore_ascii_case(name))
    }

    /// The body type, worked out from the content when not set explicitly.
    pub fn effective_body_mode(&self) -> BodyMode {
        match (self.body_mode, &self.body) {
            (Some(mode), _) => mode,
            (None, None) => BodyMode::None,
            (None, Some(_)) => BodyMode::Raw,
        }
    }

    /// Turns url-encoded form fields and GraphQL queries into body text and
    /// a Content-Type header, leaving `{{variables}}` readable. Everything
    /// that signs, sends or exports a request can then treat it as plain
    /// text.
    pub fn materialize(&mut self) {
        if self.effective_body_mode() == BodyMode::GraphQl {
            return crate::graphql::materialize(self);
        }
        if self.effective_body_mode() != BodyMode::UrlEncoded || self.form.is_empty() {
            return;
        }
        let pairs: Vec<String> = std::mem::take(&mut self.form)
            .iter()
            .map(|f| {
                format!(
                    "{}={}",
                    crate::formats::util::form_encode(&f.key),
                    crate::formats::util::form_encode(&f.value)
                )
            })
            .collect();
        self.body = Some(pairs.join("&"));
        if !self.has_header("content-type") {
            self.add_header("Content-Type", "application/x-www-form-urlencoded");
        }
    }

    pub fn add_header(&mut self, name: &str, value: impl Into<String>) {
        self.headers.push(Header {
            name: name.to_string(),
            value: value.into(),
        });
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub status: u16,
    pub status_text: String,
    pub http_version: String,
    pub headers: Vec<Header>,
    /// Body decoded as text; empty when the body is binary.
    pub body: String,
    /// The body exactly as received, when it is not text: an image, an
    /// archive, a PDF. Text bodies are in `body` alone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes: Option<Vec<u8>>,
    /// Size of the decompressed body in bytes.
    pub size_bytes: u64,
    /// Time from sending the request to receiving the full body.
    pub elapsed_ms: u64,
}

/// One request as it went out and the response that came back. The
/// request's headers are the ones sent, including those the client added.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Exchange {
    /// When the request was sent, in milliseconds since the Unix epoch.
    pub started_ms: u64,
    pub request: Request,
    pub response: Response,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Variable {
    pub key: String,
    pub value: String,
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub enabled: bool,
    /// Holds a credential, whatever its name suggests: its value is
    /// encrypted in the workspace file and always left out of redacted
    /// exports.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub secret: bool,
}

impl Variable {
    pub fn new(key: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            key: key.into(),
            value: value.into(),
            enabled: true,
            secret: false,
        }
    }
}

fn yes() -> bool {
    true
}

fn is_true(b: &bool) -> bool {
    *b
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Environment {
    pub name: String,
    #[serde(default)]
    pub variables: Vec<Variable>,
}

/// A saved request, or a folder when `request` is `None`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Item {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request: Option<Request>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub items: Vec<Item>,
}

/// The folder a collection is also kept in, one file for each request, so
/// that it can be put under version control and shared.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct FolderLink {
    pub path: String,
    /// What lets a sandboxed app open the folder again after a restart;
    /// empty where the platform needs nothing of the kind.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub grant: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Collection {
    pub name: String,
    /// Collection-level variables; an environment's variables take priority.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub variables: Vec<Variable>,
    #[serde(default)]
    pub items: Vec<Item>,
    /// Where the collection is kept as files, if it is. This belongs to
    /// the machine it was set on, and is left out of every export.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<FolderLink>,
}

impl Collection {
    /// Every request in the collection, depth first, with its `Folder/Name` path.
    pub fn requests(&self) -> Vec<(String, &Request)> {
        fn walk<'a>(items: &'a [Item], prefix: &str, out: &mut Vec<(String, &'a Request)>) {
            for item in items {
                let path = if prefix.is_empty() {
                    item.name.clone()
                } else {
                    format!("{prefix}/{}", item.name)
                };
                if let Some(request) = &item.request {
                    out.push((path.clone(), request));
                }
                walk(&item.items, &path, out);
            }
        }
        let mut out = Vec::new();
        walk(&self.items, "", &mut out);
        out
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AppTheme {
    /// Follow the operating system's light or dark setting.
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HttpMode {
    /// Let the client and server agree, preferring HTTP/2 over TLS.
    #[default]
    Auto,
    Http1,
    Http2,
}

/// How the request and its response are arranged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Layout {
    /// Side by side in a wide window, stacked in a narrow one.
    #[default]
    Auto,
    SideBySide,
    Stacked,
}

/// What formatted JSON is indented with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Indent {
    #[default]
    TwoSpaces,
    FourSpaces,
    Tab,
}

/// Which proxy requests go through.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProxyMode {
    /// The one the operating system or the environment is set up with.
    #[default]
    System,
    /// Straight to the server, whatever the system says.
    None,
    /// The address in the settings' `proxy_url`.
    Custom,
}

/// Preferences that apply to the whole app rather than one request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub theme: AppTheme,
    pub http_mode: HttpMode,
    /// Timeout in seconds for requests that do not set their own; 0 leaves
    /// the default, which is to wait as long as the server takes.
    pub timeout_secs: u32,
    /// The largest response to download, in megabytes; 0 means any size.
    pub max_response_mb: u32,
    /// Whether requests refuse a server whose certificate cannot be
    /// verified. A request's own settings take priority, as they do for
    /// `follow_redirects`.
    pub verify_ssl: bool,
    pub follow_redirects: bool,
    /// Adds `Cache-Control: no-cache` to requests that do not set it.
    pub send_no_cache: bool,
    /// Ask before unsaved edits to a request are thrown away.
    pub confirm_discard: bool,
    pub layout: Layout,
    /// Size of the text in editors and responses, in logical pixels.
    pub font_size: u32,
    pub indent: Indent,
    pub proxy: ProxyMode,
    /// Used when `proxy` is `Custom`, such as `http://127.0.0.1:8080`.
    pub proxy_url: String,
    /// The folder holding the files requests send; empty when none is set.
    /// Relative file paths are looked up in it.
    pub working_dir: String,
    /// What the platform handed over when the folder was chosen, which lets
    /// a sandboxed app open it again after a restart. Opaque to the core.
    pub working_dir_grant: String,
    /// Whether requests may read files outside the working directory.
    pub allow_outside_working_dir: bool,
    /// Encrypt credentials in the workspace file with a key kept in the
    /// system keychain.
    pub protect_secrets: bool,
    /// How many sent requests are kept, with their responses, from one
    /// launch to the next; 0 keeps none.
    pub history_limit: u32,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            theme: AppTheme::default(),
            http_mode: HttpMode::default(),
            timeout_secs: 0,
            max_response_mb: 0,
            verify_ssl: true,
            follow_redirects: true,
            send_no_cache: false,
            confirm_discard: true,
            layout: Layout::default(),
            font_size: 13,
            indent: Indent::default(),
            proxy: ProxyMode::default(),
            proxy_url: String::new(),
            working_dir: String::new(),
            working_dir_grant: String::new(),
            allow_outside_working_dir: false,
            protect_secrets: true,
            history_limit: 500,
        }
    }
}

impl Settings {
    pub fn send_options(&self) -> SendOptions {
        SendOptions {
            http_mode: self.http_mode,
            timeout_ms: (self.timeout_secs > 0).then(|| u64::from(self.timeout_secs) * 1000),
            verify_ssl: self.verify_ssl,
            follow_redirects: self.follow_redirects,
            no_cache: self.send_no_cache,
            max_response_bytes: (self.max_response_mb > 0)
                .then(|| u64::from(self.max_response_mb) * 1024 * 1024),
            proxy: match self.proxy {
                ProxyMode::System => Proxy::System,
                ProxyMode::None => Proxy::None,
                // An empty address is no address: fall back to the system's.
                ProxyMode::Custom if self.proxy_url.trim().is_empty() => Proxy::System,
                ProxyMode::Custom => Proxy::Custom(self.proxy_url.trim().to_string()),
            },
            files: FileAccess {
                root: (!self.working_dir.trim().is_empty()).then(|| self.working_dir.trim().into()),
                allow_outside: self.allow_outside_working_dir,
            },
        }
    }
}

/// The proxy a send goes through.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub enum Proxy {
    #[default]
    System,
    None,
    /// A proxy address, such as `http://127.0.0.1:8080`.
    Custom(String),
}

/// How requests are sent, beyond what each request says itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendOptions {
    pub http_mode: HttpMode,
    /// Used when the request has no timeout of its own.
    pub timeout_ms: Option<u64>,
    /// Used, like `follow_redirects`, by requests with no settings of
    /// their own.
    pub verify_ssl: bool,
    pub follow_redirects: bool,
    /// Adds `Cache-Control: no-cache` to requests that do not set it.
    pub no_cache: bool,
    /// Responses larger than this are abandoned.
    pub max_response_bytes: Option<u64>,
    pub proxy: Proxy,
    /// Which files requests may send.
    pub files: FileAccess,
}

impl Default for SendOptions {
    fn default() -> Self {
        Self {
            http_mode: HttpMode::default(),
            timeout_ms: None,
            verify_ssl: true,
            follow_redirects: true,
            no_cache: false,
            max_response_bytes: None,
            proxy: Proxy::default(),
            files: FileAccess::default(),
        }
    }
}

/// Everything the app persists between launches.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Workspace {
    #[serde(default)]
    pub collections: Vec<Collection>,
    /// Saved requests that do not belong to a collection.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub requests: Vec<Item>,
    #[serde(default)]
    pub environments: Vec<Environment>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_environment: Option<String>,
    #[serde(default)]
    pub settings: Settings,
    /// The cookie jar shared by every request.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cookies: Vec<Cookie>,
}

impl Workspace {
    /// Loads the workspace; a missing file is an empty workspace.
    pub fn load(path: &Path) -> Result<Self, Error> {
        match std::fs::read_to_string(path) {
            Ok(text) => serde_json::from_str(&text)
                .map_err(|e| Error::Format(format!("{}: {e}", path.display()))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(Error::Io(format!("{}: {e}", path.display()))),
        }
    }

    pub fn save(&self, path: &Path) -> Result<(), Error> {
        let io = |e: std::io::Error| Error::Io(format!("{}: {e}", path.display()));
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(io)?;
        }
        let text = serde_json::to_string_pretty(self).expect("workspace serialises");
        // Write then rename so a crash mid-write cannot corrupt the workspace.
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, text).map_err(io)?;
        std::fs::rename(&tmp, path).map_err(io)
    }

    pub fn active_variables(&self) -> &[Variable] {
        self.active_environment
            .as_ref()
            .and_then(|name| self.environments.iter().find(|e| &e.name == name))
            .map(|e| e.variables.as_slice())
            .unwrap_or(&[])
    }
}
