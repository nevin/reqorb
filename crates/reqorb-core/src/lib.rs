//! Request engine shared by the reqorb CLI and desktop/iPad app.
//!
//! - `model`: the data everything else works on: requests, collections,
//!   environments, the workspace.
//! - `http`, `ws`, `grpc`: sending, one module per protocol.
//! - `graphql`: queries carried over `http`, and the schema behind them.
//! - `subscribe`: GraphQL subscriptions carried over `ws`.
//! - `auth`: authorization, applied by all three.
//! - `formats`: import and export, one module per format.
//! - `vars`, `checks`, `redact`, `analyze`, `data`: work done on requests
//!   and responses without touching the network.
//! - `document`: text of any size, up to a gigabyte, for the editor.
//! - `spill`: response bodies too big to hold, written to files.
//! - `vault`, `history`: what is kept on disk: the workspace, with its
//!   credentials encrypted, and the requests sent.

mod analyze;
mod auth;
mod checks;
mod codegen;
mod data;
mod document;
mod error;
mod files;
mod formats;
mod graphql;
mod grpc;
mod history;
mod http;
mod model;
mod redact;
mod script;
mod spill;
mod subscribe;
mod time;
mod vars;
mod vault;
mod ws;

pub use analyze::{HarCount, HarEntry, HarFinding, HarPhase, HarReport, HarSeverity, analyze_har};
pub use auth::{Auth, AuthField, AuthKind, AuthParam, auth_fields};
pub use checks::{TestResult, capture, run_tests};
pub use codegen::{CodeTarget, generate_code};
pub use data::parse_run_data;
pub use document::{
    Change, Document, Found, Indexing, JsonKind, JsonNode, JsonPage, MAX_KEPT, Query, Quoting,
    ROW_BYTES, Row, Snapshot,
};
pub use error::Error;
pub use files::{DirAccess, FileAccess, check_directory};
pub use formats::{
    ExportFormat, ImportResult, collection_dir_stamp, export_collection, export_environment,
    export_native, import, import_har, import_url, is_collection_dir, read_collection_dir,
    read_environments_dir, to_curl, to_har, write_collection_dir, write_environments_dir,
};
pub use graphql::{
    GraphQlArg, GraphQlDraft, GraphQlField, GraphQlQuery, GraphQlSchema, GraphQlType,
    graphql_draft, graphql_errors, graphql_format, graphql_inspect, graphql_schema,
};
pub use grpc::{
    GrpcCall, GrpcMethod, GrpcReply, GrpcSchema, grpc_call, grpc_call_watched, grpc_load_proto,
    grpc_reflect,
};
pub use history::{History, HistoryEntry, append_history, clear_history, load_history};
pub use http::cookies::{Cookie, cookie_header, store_set_cookie};
pub use http::{Cancel, SendEvent, Sent, Watch, send, send_opts, send_watched, send_with};
pub use model::{
    AppTheme, BodyMode, Collection, DisabledTls, Environment, Exchange, FolderLink, FormField,
    Header, HttpMode, Indent, Item, Layout, Proxy, ProxyMode, Request, RequestSettings, Response,
    SendOptions, Settings, Variable, Workspace,
};
pub use redact::{REDACTED, redact_collection, redact_environment, redact_exchanges, redact_text};
pub use spill::{
    PREVIEW_BYTES, READ_LIMIT, SPILL_BYTES, clean_spilled, io_problem, new_spill_file,
    read_spilled, set_spill_bytes, spill_bytes, spill_dir,
};
pub use vars::{Resolved, resolve};
pub use vault::{
    KeyStore, Keychain, LOCKED, Loaded, check_keys, load_workspace, locked_secrets, save_workspace,
};
pub use ws::{WsEvent, WsEventKind, WsHandle, ws_connect};

// Tests run with the allocator the programs use, which holds scripts to
// their memory limit.
#[cfg(test)]
#[global_allocator]
static ALLOCATOR: reqorb_alloc::Counting = reqorb_alloc::Counting;
