//! Exposes `reqorb_core` to Dart. The `_Name` structs only describe the
//! shape of the core types so the bridge can generate matching Dart classes.

use std::path::Path;

use flutter_rust_bridge::frb;
pub use reqorb_core::{
    AppTheme, Auth, AuthField, AuthKind, AuthParam, BodyMode, Collection, Cookie, DisabledTls,
    Environment, ExportFormat, FormField, Header, HttpMode, ImportResult, Item, Request,
    RequestSettings, Response, Sent, Settings, Variable, Workspace,
};

#[frb(mirror(AppTheme))]
pub enum _AppTheme {
    System,
    Light,
    Dark,
}

#[frb(mirror(HttpMode))]
pub enum _HttpMode {
    Auto,
    Http1,
    Http2,
}

#[frb(mirror(BodyMode))]
pub enum _BodyMode {
    None,
    FormData,
    UrlEncoded,
    Raw,
    Binary,
}

#[frb(mirror(FormField))]
pub struct _FormField {
    pub key: String,
    pub value: String,
    pub file: bool,
}

#[frb(mirror(DisabledTls))]
pub enum _DisabledTls {
    None,
    Tls12,
    Tls13,
}

#[frb(mirror(RequestSettings))]
pub struct _RequestSettings {
    pub http_mode: Option<HttpMode>,
    pub verify_ssl: bool,
    pub follow_redirects: bool,
    pub follow_original_method: bool,
    pub follow_auth_header: bool,
    pub remove_referer: bool,
    pub strict_http_parser: bool,
    pub disable_cookie_jar: bool,
    pub max_redirects: u32,
    pub disabled_tls: DisabledTls,
}

/// The settings a request has when it sets none of its own.
#[frb(sync)]
pub fn default_request_settings() -> RequestSettings {
    RequestSettings::default()
}

#[frb(mirror(Cookie))]
pub struct _Cookie {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
    pub expires: Option<i64>,
    pub secure: bool,
    pub http_only: bool,
    pub host_only: bool,
}

#[frb(mirror(Settings))]
pub struct _Settings {
    pub theme: AppTheme,
    pub http_mode: HttpMode,
    pub timeout_secs: u32,
}

#[frb(mirror(AuthKind))]
pub enum _AuthKind {
    None,
    ApiKey,
    Bearer,
    Jwt,
    Basic,
    Digest,
    OAuth1,
    OAuth2,
    Hawk,
    AwsV4,
    Ntlm,
    EdgeGrid,
}

#[frb(mirror(AuthParam))]
pub struct _AuthParam {
    pub key: String,
    pub value: String,
}

#[frb(mirror(Auth))]
pub struct _Auth {
    pub kind: AuthKind,
    pub params: Vec<AuthParam>,
}

#[frb(mirror(AuthField))]
pub struct _AuthField {
    pub key: String,
    pub label: String,
    pub secret: bool,
    pub multiline: bool,
    pub options: Vec<String>,
    pub default_value: String,
    pub hint: String,
}

/// An auth type with the name to show for it.
pub struct AuthChoice {
    pub kind: AuthKind,
    pub label: String,
}

/// Every auth type, in the order a picker should list them.
#[frb(sync)]
pub fn auth_choices() -> Vec<AuthChoice> {
    AuthKind::ALL
        .into_iter()
        .map(|kind| AuthChoice {
            kind,
            label: kind.label().to_string(),
        })
        .collect()
}

/// The inputs an auth type needs, in display order.
#[frb(sync)]
pub fn auth_fields(kind: AuthKind) -> Vec<AuthField> {
    reqorb_core::auth_fields(kind)
}

#[frb(mirror(Header))]
pub struct _Header {
    pub name: String,
    pub value: String,
}

#[frb(mirror(Request))]
pub struct _Request {
    pub method: String,
    pub url: String,
    pub headers: Vec<Header>,
    pub body: Option<String>,
    pub timeout_ms: Option<u64>,
    pub auth: Option<Auth>,
    pub settings: Option<RequestSettings>,
    pub body_mode: Option<BodyMode>,
    pub form: Vec<FormField>,
}

#[frb(mirror(Response))]
pub struct _Response {
    pub status: u16,
    pub status_text: String,
    pub http_version: String,
    pub headers: Vec<Header>,
    pub body: String,
    pub size_bytes: u64,
    pub elapsed_ms: u64,
}

#[frb(mirror(Sent))]
pub struct _Sent {
    pub response: Response,
    pub unresolved: Vec<String>,
    pub cookies: Vec<Cookie>,
}

#[frb(mirror(Variable))]
pub struct _Variable {
    pub key: String,
    pub value: String,
    pub enabled: bool,
}

#[frb(mirror(Environment))]
pub struct _Environment {
    pub name: String,
    pub variables: Vec<Variable>,
}

#[frb(mirror(Item))]
pub struct _Item {
    pub name: String,
    pub request: Option<Request>,
    pub items: Vec<Item>,
}

#[frb(mirror(Collection))]
pub struct _Collection {
    pub name: String,
    pub variables: Vec<Variable>,
    pub items: Vec<Item>,
}

#[frb(mirror(Workspace))]
pub struct _Workspace {
    pub collections: Vec<Collection>,
    pub requests: Vec<Item>,
    pub environments: Vec<Environment>,
    pub active_environment: Option<String>,
    pub settings: Settings,
    pub cookies: Vec<Cookie>,
}

#[frb(mirror(ImportResult))]
pub struct _ImportResult {
    pub source: String,
    pub collections: Vec<Collection>,
    pub environments: Vec<Environment>,
    pub warnings: Vec<String>,
}

#[frb(mirror(ExportFormat))]
pub enum _ExportFormat {
    Reqorb,
    Postman,
    Bruno,
    Curl,
    Dotenv,
}

// Errors cross the bridge as strings that are ready to show to the user.

/// Substitutes `variables` (highest priority first) and sends the request.
pub async fn send_request(
    request: Request,
    variables: Vec<Variable>,
    settings: Settings,
    cookies: Vec<Cookie>,
) -> Result<Sent, String> {
    reqorb_core::send_with(&request, &variables, &settings.send_options(), &cookies)
        .await
        .map_err(|e| e.to_string())
}

pub fn load_workspace(path: String) -> Result<Workspace, String> {
    Workspace::load(Path::new(&path)).map_err(|e| e.to_string())
}

pub fn save_workspace(path: String, workspace: Workspace) -> Result<(), String> {
    workspace.save(Path::new(&path)).map_err(|e| e.to_string())
}

/// Imports reqorb, Postman or OpenAPI/Swagger documents, a curl command,
/// or a `.env` file.
pub fn import_text(text: String, name_hint: String) -> Result<ImportResult, String> {
    reqorb_core::import(&text, &name_hint).map_err(|e| e.to_string())
}

/// Downloads and imports a document, typically a served `swagger.json`.
pub async fn import_url(url: String) -> Result<ImportResult, String> {
    reqorb_core::import_url(&url)
        .await
        .map_err(|e| e.to_string())
}

pub fn export_collection(collection: Collection, format: ExportFormat) -> Result<String, String> {
    reqorb_core::export_collection(&collection, format).map_err(|e| e.to_string())
}

pub fn export_environment(
    environment: Environment,
    format: ExportFormat,
) -> Result<String, String> {
    reqorb_core::export_environment(&environment, format).map_err(|e| e.to_string())
}

#[frb(sync)]
pub fn export_extension(format: ExportFormat) -> String {
    format.extension().to_string()
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
