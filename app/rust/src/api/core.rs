//! Exposes `reqorb_core` to Dart. The `_Name` structs only describe the
//! shape of the core types so the bridge can generate matching Dart classes.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{LazyLock, Mutex};

use flutter_rust_bridge::frb;

use crate::frb_generated::StreamSink;
use reqorb_core::Keychain;
pub use reqorb_core::{
    AppTheme, Auth, AuthField, AuthKind, AuthParam, BodyMode, CodeTarget, Collection, Cookie,
    DirAccess, DisabledTls, Environment, Exchange, ExportFormat, FormField, GraphQlArg,
    GraphQlDraft, GraphQlField, GraphQlQuery, GraphQlSchema, GraphQlType, GrpcCall, GrpcMethod,
    GrpcReply, GrpcSchema, HarCount, HarEntry, HarFinding, HarPhase, HarReport, HarSeverity,
    Header, HistoryEntry, HttpMode, ImportResult, Indent, Item, Layout, ProxyMode, Request,
    RequestSettings, Response, Sent, Settings, TestResult, Variable, Workspace, WsEvent,
    WsEventKind,
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
    GraphQl,
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
    pub max_response_mb: u32,
    pub verify_ssl: bool,
    pub follow_redirects: bool,
    pub send_no_cache: bool,
    pub confirm_discard: bool,
    pub layout: Layout,
    pub font_size: u32,
    pub indent: Indent,
    pub proxy: ProxyMode,
    pub proxy_url: String,
    pub working_dir: String,
    pub working_dir_grant: String,
    pub allow_outside_working_dir: bool,
    pub protect_secrets: bool,
    pub history_limit: u32,
}

#[frb(mirror(DirAccess))]
pub struct _DirAccess {
    pub exists: bool,
    pub readable: bool,
    pub writable: bool,
}

/// Tries a folder out as the working directory: whether it is there, can
/// be listed, and can be written to.
#[frb(sync)]
pub fn check_directory(path: String) -> DirAccess {
    reqorb_core::check_directory(&path)
}

#[frb(mirror(Layout))]
pub enum _Layout {
    Auto,
    SideBySide,
    Stacked,
}

#[frb(mirror(Indent))]
pub enum _Indent {
    TwoSpaces,
    FourSpaces,
    Tab,
}

#[frb(mirror(ProxyMode))]
pub enum _ProxyMode {
    System,
    None,
    Custom,
}

/// The settings a new workspace starts with.
#[frb(sync)]
pub fn default_settings() -> Settings {
    Settings::default()
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
    pub grpc_method: Option<String>,
    pub proto_path: Option<String>,
    pub graphql_variables: Option<String>,
    pub graphql_operation: Option<String>,
    pub tests: Vec<String>,
    pub captures: Vec<String>,
}

#[frb(mirror(Response))]
pub struct _Response {
    pub status: u16,
    pub status_text: String,
    pub http_version: String,
    pub headers: Vec<Header>,
    pub body: String,
    pub bytes: Option<Vec<u8>>,
    pub size_bytes: u64,
    pub elapsed_ms: u64,
}

#[frb(mirror(Sent))]
pub struct _Sent {
    pub response: Response,
    pub unresolved: Vec<String>,
    pub cookies: Vec<Cookie>,
    pub exchanges: Vec<Exchange>,
    pub tests: Vec<TestResult>,
    pub captured: Vec<Variable>,
    pub capture_problems: Vec<String>,
    pub graphql_errors: Vec<String>,
}

#[frb(mirror(TestResult))]
pub struct _TestResult {
    pub test: String,
    pub passed: bool,
    pub detail: String,
}

#[frb(mirror(Exchange))]
pub struct _Exchange {
    pub started_ms: u64,
    pub request: Request,
    pub response: Response,
}

#[frb(mirror(Variable))]
pub struct _Variable {
    pub key: String,
    pub value: String,
    pub enabled: bool,
    pub secret: bool,
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

pub enum SendUpdateKind {
    /// A response has begun: `status`, `status_text`, `http_version` and
    /// `headers` are set. Redirects and authorization round trips each
    /// begin one, so the last is the one the body belongs to.
    Head,
    /// More of the body: `text` is the new part, empty when the body is
    /// not text, and `received` counts every byte so far.
    Body,
    /// The send is over, and `sent` is what it came to.
    Done,
    /// The send failed, for the reason in `text`.
    Failed,
}

/// What a watched send reports: the response as it arrives, then how the
/// send ended. Only the fields its kind names are set.
pub struct SendUpdate {
    pub kind: SendUpdateKind,
    pub status: u16,
    pub status_text: String,
    pub http_version: String,
    pub headers: Vec<Header>,
    pub text: String,
    pub received: u64,
    pub sent: Option<Sent>,
}

impl SendUpdate {
    fn of(kind: SendUpdateKind) -> Self {
        Self {
            kind,
            status: 0,
            status_text: String::new(),
            http_version: String::new(),
            headers: Vec::new(),
            text: String::new(),
            received: 0,
            sent: None,
        }
    }
}

/// Sends under way, by the id the app gave each one, so they can be stopped.
static SENDS: LazyLock<Mutex<HashMap<u32, reqorb_core::Cancel>>> = LazyLock::new(Default::default);

/// Like [`send_request`], reporting the response while it arrives. The
/// stream ends with `Done` or `Failed`.
pub async fn send_request_watched(
    id: u32,
    request: Request,
    variables: Vec<Variable>,
    settings: Settings,
    cookies: Vec<Cookie>,
    sink: StreamSink<SendUpdate>,
) {
    let cancel = reqorb_core::Cancel::default();
    SENDS.lock().unwrap().insert(id, cancel.clone());
    let sink = std::sync::Arc::new(sink);
    let progress = sink.clone();
    let watch = reqorb_core::Watch::new(
        move |event| {
            let _ = progress.add(match event {
                reqorb_core::SendEvent::Head {
                    status,
                    status_text,
                    http_version,
                    headers,
                } => SendUpdate {
                    status,
                    status_text,
                    http_version,
                    headers,
                    ..SendUpdate::of(SendUpdateKind::Head)
                },
                reqorb_core::SendEvent::Body { text, received } => SendUpdate {
                    text,
                    received,
                    ..SendUpdate::of(SendUpdateKind::Body)
                },
            });
        },
        cancel,
    );
    let result = reqorb_core::send_watched(
        &request,
        &variables,
        &settings.send_options(),
        &cookies,
        &watch,
    )
    .await;
    SENDS.lock().unwrap().remove(&id);
    let _ = sink.add(match result {
        Ok(sent) => SendUpdate {
            sent: Some(sent),
            ..SendUpdate::of(SendUpdateKind::Done)
        },
        Err(e) => SendUpdate {
            text: e.to_string(),
            ..SendUpdate::of(SendUpdateKind::Failed)
        },
    });
}

/// Stops a watched send; false when it has already ended. One whose body
/// was arriving ends with what had arrived.
#[frb(sync)]
pub fn cancel_send(id: u32) -> bool {
    SENDS
        .lock()
        .unwrap()
        .get(&id)
        .map(|cancel| cancel.cancel())
        .is_some()
}

#[frb(mirror(GraphQlQuery))]
pub struct _GraphQlQuery {
    pub operations: Vec<String>,
    pub problem: String,
}

#[frb(mirror(GraphQlSchema))]
pub struct _GraphQlSchema {
    pub query_type: String,
    pub mutation_type: String,
    pub subscription_type: String,
    pub types: Vec<GraphQlType>,
}

#[frb(mirror(GraphQlType))]
pub struct _GraphQlType {
    pub name: String,
    pub kind: String,
    pub description: String,
    pub fields: Vec<GraphQlField>,
    pub members: Vec<String>,
}

#[frb(mirror(GraphQlField))]
pub struct _GraphQlField {
    pub name: String,
    pub description: String,
    pub type_name: String,
    pub named_type: String,
    pub args: Vec<GraphQlArg>,
    pub deprecated: bool,
}

#[frb(mirror(GraphQlArg))]
pub struct _GraphQlArg {
    pub name: String,
    pub description: String,
    pub type_name: String,
    pub default_value: String,
}

#[frb(mirror(GraphQlDraft))]
pub struct _GraphQlDraft {
    pub query: String,
    pub variables: String,
    pub operation: String,
}

/// Fetches the GraphQL schema of the server the request points at, using
/// the request's own headers and authorization.
pub async fn graphql_schema(
    request: Request,
    variables: Vec<Variable>,
    settings: Settings,
    cookies: Vec<Cookie>,
) -> Result<GraphQlSchema, String> {
    reqorb_core::graphql_schema(&request, &variables, &settings.send_options(), &cookies)
        .await
        .map_err(|e| e.to_string())
}

/// The operations a GraphQL query names and what is wrong with it, if
/// anything.
#[frb(sync)]
pub fn graphql_inspect(query: String) -> GraphQlQuery {
    reqorb_core::graphql_inspect(&query)
}

/// A GraphQL query rewritten with consistent indentation.
#[frb(sync)]
pub fn graphql_format(query: String) -> Result<String, String> {
    reqorb_core::graphql_format(&query).map_err(|e| e.to_string())
}

/// A query for one field of the schema's `query`, `mutation` or
/// `subscription` type, or `None` when the schema has no such field.
#[frb(sync)]
pub fn graphql_draft(schema: GraphQlSchema, kind: String, field: String) -> Option<GraphQlDraft> {
    reqorb_core::graphql_draft(&schema, &kind, &field)
}

/// The exchanges of a session as an HTTP Archive (HAR 1.2) document.
#[frb(sync)]
pub fn export_har(exchanges: Vec<Exchange>) -> String {
    reqorb_core::to_har(&exchanges)
}

#[frb(mirror(WsEventKind))]
pub enum _WsEventKind {
    Open,
    Text,
    Binary,
    Ping,
    Pong,
    Closed,
    Error,
}

#[frb(mirror(WsEvent))]
pub struct _WsEvent {
    pub kind: WsEventKind,
    pub text: String,
    pub data: Vec<u8>,
    pub code: u16,
    pub headers: Vec<Header>,
    pub at_ms: u64,
}

/// Open WebSocket connections, by the id the app gave each one.
static SOCKETS: LazyLock<Mutex<HashMap<u32, reqorb_core::WsHandle>>> =
    LazyLock::new(Default::default);

/// Opens a WebSocket and reports what happens on it until it ends. A
/// connection that cannot be opened ends with a single `Error` event.
pub async fn ws_open(
    id: u32,
    request: Request,
    variables: Vec<Variable>,
    sink: StreamSink<WsEvent>,
) {
    let (handle, mut events) = match reqorb_core::ws_connect(&request, &variables).await {
        Ok(connected) => connected,
        Err(e) => {
            let _ = sink.add(WsEvent::failed(e.to_string()));
            return;
        }
    };
    SOCKETS.lock().unwrap().insert(id, handle);
    while let Some(event) = events.recv().await {
        if sink.add(event).is_err() {
            break;
        }
    }
    SOCKETS.lock().unwrap().remove(&id);
}

/// Sends a text message; false when the connection is not open.
#[frb(sync)]
pub fn ws_send(id: u32, text: String) -> bool {
    SOCKETS
        .lock()
        .unwrap()
        .get(&id)
        .is_some_and(|socket| socket.send_text(text))
}

/// Asks the connection to close; false when it is not open.
#[frb(sync)]
pub fn ws_close(id: u32) -> bool {
    SOCKETS
        .lock()
        .unwrap()
        .get(&id)
        .is_some_and(|socket| socket.close())
}

#[frb(mirror(GrpcMethod))]
pub struct _GrpcMethod {
    pub path: String,
    pub client_streaming: bool,
    pub server_streaming: bool,
    pub example: String,
}

#[frb(mirror(GrpcSchema))]
pub struct _GrpcSchema {
    pub methods: Vec<GrpcMethod>,
    pub descriptors: Vec<u8>,
}

#[frb(mirror(GrpcCall))]
pub struct _GrpcCall {
    pub url: String,
    pub method: String,
    pub messages: Vec<String>,
    pub metadata: Vec<Header>,
    pub auth: Option<Auth>,
    pub descriptors: Vec<u8>,
    pub timeout_ms: Option<u64>,
}

#[frb(mirror(GrpcReply))]
pub struct _GrpcReply {
    pub code: i32,
    pub status: String,
    pub message: String,
    pub messages: Vec<String>,
    pub headers: Vec<Header>,
    pub trailers: Vec<Header>,
    pub elapsed_ms: u64,
}

/// Asks a gRPC server which methods it offers, through server reflection.
pub async fn grpc_reflect(
    url: String,
    metadata: Vec<Header>,
    auth: Option<Auth>,
    variables: Vec<Variable>,
) -> Result<GrpcSchema, String> {
    reqorb_core::grpc_reflect(&url, &metadata, auth.as_ref(), &variables)
        .await
        .map_err(|e| e.to_string())
}

/// Reads the methods a `.proto` file defines.
pub async fn grpc_load_proto(path: String) -> Result<GrpcSchema, String> {
    reqorb_core::grpc_load_proto(&path).map_err(|e| e.to_string())
}

/// Makes a gRPC call and waits for all of its responses.
pub async fn grpc_call(call: GrpcCall, variables: Vec<Variable>) -> Result<GrpcReply, String> {
    reqorb_core::grpc_call(&call, &variables)
        .await
        .map_err(|e| e.to_string())
}

/// What a watched gRPC call reports: each response as it arrives in
/// `message`, and last either the whole `reply` or the `error` that
/// prevented the call.
pub struct GrpcUpdate {
    pub message: Option<String>,
    pub reply: Option<GrpcReply>,
    pub error: Option<String>,
}

/// gRPC calls under way, by the id the app gave each one.
static CALLS: LazyLock<Mutex<HashMap<u32, reqorb_core::Cancel>>> = LazyLock::new(Default::default);

/// Like [`grpc_call`], reporting each response as it arrives.
pub async fn grpc_call_watched(
    id: u32,
    call: GrpcCall,
    variables: Vec<Variable>,
    sink: StreamSink<GrpcUpdate>,
) {
    let cancel = reqorb_core::Cancel::default();
    CALLS.lock().unwrap().insert(id, cancel.clone());
    let sink = std::sync::Arc::new(sink);
    let progress = sink.clone();
    let result = reqorb_core::grpc_call_watched(
        &call,
        &variables,
        &move |message| {
            let _ = progress.add(GrpcUpdate {
                message: Some(message.to_string()),
                reply: None,
                error: None,
            });
        },
        &cancel,
    )
    .await;
    CALLS.lock().unwrap().remove(&id);
    let _ = sink.add(match result {
        Ok(reply) => GrpcUpdate {
            message: None,
            reply: Some(reply),
            error: None,
        },
        Err(e) => GrpcUpdate {
            message: None,
            reply: None,
            error: Some(e.to_string()),
        },
    });
}

/// Stops a watched gRPC call, which ends with the responses it had; false
/// when it has already ended.
#[frb(sync)]
pub fn grpc_cancel(id: u32) -> bool {
    CALLS
        .lock()
        .unwrap()
        .get(&id)
        .map(|cancel| cancel.cancel())
        .is_some()
}

/// A workspace read from disk, and what could not be read with it.
pub struct LoadedWorkspace {
    pub workspace: Workspace,
    /// Credentials left encrypted because their key could not be read.
    pub locked: u32,
    /// Why the key could not be read, when it could not.
    pub problem: Option<String>,
}

/// Loads the workspace, decrypting its credentials with the key in the
/// system keychain.
pub fn load_workspace(path: String) -> Result<LoadedWorkspace, String> {
    let loaded =
        reqorb_core::load_workspace(Path::new(&path), &Keychain).map_err(|e| e.to_string())?;
    Ok(LoadedWorkspace {
        workspace: loaded.workspace,
        locked: loaded.locked,
        problem: loaded.problem,
    })
}

/// Saves the workspace, with its credentials encrypted when its settings
/// ask for that. Returns why they were not, if the keychain could not be
/// used; the workspace is saved either way.
pub fn save_workspace(path: String, workspace: Workspace) -> Result<Option<String>, String> {
    reqorb_core::save_workspace(&workspace, Path::new(&path), &Keychain).map_err(|e| e.to_string())
}

#[frb(mirror(HistoryEntry))]
pub struct _HistoryEntry {
    pub exchange: Exchange,
    pub source: Option<Request>,
    pub name: String,
    pub cut: bool,
}

/// The requests sent before, and how many could not be read.
pub struct LoadedHistory {
    /// Oldest first.
    pub entries: Vec<HistoryEntry>,
    pub unreadable: u32,
}

/// Reads the history kept at `path`; a missing file is an empty history.
pub fn load_history(path: String) -> Result<LoadedHistory, String> {
    let history =
        reqorb_core::load_history(Path::new(&path), &Keychain).map_err(|e| e.to_string())?;
    Ok(LoadedHistory {
        entries: history.entries,
        unreadable: history.unreadable,
    })
}

/// Adds entries to the history at `path`, keeping about `limit` in all,
/// encrypted when `protect` is set and the keychain can be used.
pub fn append_history(
    path: String,
    entries: Vec<HistoryEntry>,
    limit: u32,
    protect: bool,
) -> Result<(), String> {
    reqorb_core::append_history(Path::new(&path), &entries, limit, protect, &Keychain)
        .map_err(|e| e.to_string())
}

pub fn clear_history(path: String) -> Result<(), String> {
    reqorb_core::clear_history(Path::new(&path)).map_err(|e| e.to_string())
}

/// Why credentials cannot be encrypted on this machine, or `None` when
/// they can. Makes the key in the keychain if there is none yet.
pub fn keychain_problem() -> Option<String> {
    reqorb_core::check_keys(&Keychain).err()
}

/// How many values in the workspace are still encrypted.
#[frb(sync)]
pub fn locked_secrets(workspace: Workspace) -> u32 {
    reqorb_core::locked_secrets(&workspace)
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

#[frb(mirror(CodeTarget))]
pub enum _CodeTarget {
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

/// A language a request can be written in, with the name to show for it.
pub struct CodeChoice {
    pub target: CodeTarget,
    pub label: String,
    /// The usual file extension for code in it.
    pub file_extension: String,
}

/// Every language, in the order a picker should list them.
#[frb(sync)]
pub fn code_choices() -> Vec<CodeChoice> {
    CodeTarget::ALL
        .into_iter()
        .map(|target| CodeChoice {
            target,
            label: target.label().to_string(),
            file_extension: target.extension().to_string(),
        })
        .collect()
}

/// The request as code, with `variables` (highest priority first) filled in.
#[frb(sync)]
pub fn generate_code(
    request: Request,
    variables: Vec<Variable>,
    target: CodeTarget,
) -> Result<String, String> {
    reqorb_core::generate_code(&request, &variables, target).map_err(|e| e.to_string())
}

/// The rows of a CSV or JSON data file, each as the variables it sets
/// for one time through a run.
#[frb(sync)]
pub fn parse_run_data(name: String, text: String) -> Result<Vec<Vec<Variable>>, String> {
    reqorb_core::parse_run_data(&name, &text).map_err(|e| e.to_string())
}

#[frb(mirror(HarSeverity))]
pub enum _HarSeverity {
    Error,
    Warning,
    Info,
}

#[frb(mirror(HarFinding))]
pub struct _HarFinding {
    pub severity: HarSeverity,
    pub title: String,
    pub detail: String,
    pub entries: Vec<u32>,
}

#[frb(mirror(HarEntry))]
pub struct _HarEntry {
    pub offset_ms: u64,
    pub method: String,
    pub url: String,
    pub host: String,
    pub status: u16,
    pub kind: String,
    pub size_bytes: u64,
    pub time_ms: u64,
    pub wait_ms: Option<u64>,
    pub status_text: String,
    pub request_headers: Vec<Header>,
    pub response_headers: Vec<Header>,
    pub request_body: Option<String>,
    pub operation: Option<String>,
    pub response_body: Option<String>,
    pub body_note: Option<String>,
    pub phases: Vec<HarPhase>,
}

#[frb(mirror(HarPhase))]
pub struct _HarPhase {
    pub name: String,
    pub ms: u64,
}

#[frb(mirror(HarCount))]
pub struct _HarCount {
    pub name: String,
    pub count: u32,
    pub bytes: u64,
    pub time_ms: u64,
}

#[frb(mirror(HarReport))]
pub struct _HarReport {
    pub creator: String,
    pub entries: Vec<HarEntry>,
    pub failed: u32,
    pub total_bytes: u64,
    pub total_time_ms: u64,
    pub span_ms: u64,
    pub hosts: Vec<HarCount>,
    pub statuses: Vec<HarCount>,
    pub kinds: Vec<HarCount>,
    pub findings: Vec<HarFinding>,
}

/// Reports on the text of a HAR archive: totals, breakdowns and findings.
pub fn analyze_har(text: String) -> Result<HarReport, String> {
    reqorb_core::analyze_har(&text).map_err(|e| e.to_string())
}

/// Imports the entries of a HAR archive at the given positions as a
/// collection called `name`.
pub fn import_har(text: String, name: String, entries: Vec<u32>) -> Result<ImportResult, String> {
    reqorb_core::import_har(&text, &name, &entries).map_err(|e| e.to_string())
}

/// Copies with tokens, passwords, cookies and keys replaced, for exports
/// that are going to be shared.
#[frb(sync)]
pub fn redact_exchanges(exchanges: Vec<Exchange>) -> Vec<Exchange> {
    reqorb_core::redact_exchanges(&exchanges)
}

#[frb(sync)]
pub fn redact_collection(collection: Collection) -> Collection {
    reqorb_core::redact_collection(&collection)
}

#[frb(sync)]
pub fn redact_environment(environment: Environment) -> Environment {
    reqorb_core::redact_environment(&environment)
}

/// Masks the values under sensitive keys of a JSON document; other text is
/// returned unchanged.
#[frb(sync)]
pub fn redact_text(text: String) -> String {
    reqorb_core::redact_text(&text)
}

#[frb(sync)]
pub fn export_extension(format: ExportFormat) -> String {
    format.extension().to_string()
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
