//! The command line: every command, argument and option.

use std::path::PathBuf;

use anyhow::{Result, bail};
use clap::{Args, Parser, Subcommand, ValueEnum};
use reqorb_core::{ExportFormat, HttpMode, Request, SendOptions};

/// Send HTTP requests, run saved collections, and convert between formats.
///
/// With no subcommand, sends one request: `reqorb GET https://example.com`.
#[derive(Parser)]
#[command(name = "reqorb", version, args_conflicts_with_subcommands = true)]
pub(crate) struct Cli {
    #[command(subcommand)]
    pub(crate) command: Option<Command>,

    #[command(flatten)]
    pub(crate) send: SendArgs,
}

#[derive(Subcommand)]
pub(crate) enum Command {
    /// Run requests from a collection (reqorb, Postman, OpenAPI/Swagger, HAR or curl)
    Run(RunArgs),
    /// Convert Postman, OpenAPI/Swagger, HAR, curl or .env input to reqorb JSON
    Import(ImportArgs),
    /// Convert a collection or environment file to another format
    Export(ExportArgs),
    /// Report on a HAR archive: totals, slow and failed requests, and risks
    Analyze(AnalyzeArgs),
    /// Open a WebSocket, send messages and print what arrives
    Ws(WsArgs),
    /// List a gRPC server's methods, or call one with JSON messages
    Grpc(GrpcArgs),
}

#[derive(Args)]
pub(crate) struct AnalyzeArgs {
    /// HAR file to analyse; `-` reads stdin
    pub(crate) file: PathBuf,

    /// Print the whole report as JSON
    #[arg(long)]
    pub(crate) json: bool,

    /// How many of the slowest requests to list
    #[arg(short = 'n', long, value_name = "N", default_value_t = 5)]
    pub(crate) top: usize,
}

#[derive(Args)]
pub(crate) struct GrpcArgs {
    /// Server address, such as localhost:50051 or https://api.example.com
    pub(crate) address: String,

    /// Method to call as `package.Service/Method`; omit to list the methods
    pub(crate) method: Option<String>,

    /// Request message as JSON, or `@file` (repeat for a client stream)
    #[arg(short = 'd', long = "data", value_name = "JSON")]
    pub(crate) messages: Vec<String>,

    /// Read the services from this .proto file instead of asking the server
    #[arg(long, value_name = "FILE")]
    pub(crate) proto: Option<String>,

    /// Metadata as `name: value` (repeatable)
    #[arg(short = 'H', long = "header", value_name = "METADATA")]
    pub(crate) headers: Vec<String>,

    /// Give up after this many seconds
    #[arg(short, long, value_name = "SECS")]
    pub(crate) timeout: Option<f64>,

    /// Print the response metadata and trailers
    #[arg(short, long)]
    pub(crate) include: bool,

    #[command(flatten)]
    pub(crate) vars: VarArgs,
}

#[derive(Args)]
pub(crate) struct WsArgs {
    /// Address to connect to, such as wss://echo.example.com
    pub(crate) url: String,

    /// Handshake header as `Name: value` (repeatable)
    #[arg(short = 'H', long = "header", value_name = "HEADER")]
    pub(crate) headers: Vec<String>,

    /// Message to send once connected (repeatable); lines typed on standard
    /// input are sent as well
    #[arg(short, long = "message", value_name = "TEXT")]
    pub(crate) messages: Vec<String>,

    /// Disconnect after this many messages have arrived
    #[arg(short = 'n', long, value_name = "N")]
    pub(crate) exit_after: Option<usize>,

    /// Disconnect after this many seconds
    #[arg(short, long, value_name = "SECS")]
    pub(crate) timeout: Option<f64>,

    /// Accept a server certificate that cannot be verified
    #[arg(short = 'k', long)]
    pub(crate) insecure: bool,

    #[command(flatten)]
    pub(crate) vars: VarArgs,
}

#[derive(Args)]
pub(crate) struct SendArgs {
    /// HTTP method (GET, POST, PUT, ...)
    pub(crate) method: Option<String>,

    /// Request URL; `http://` is assumed when no scheme is given
    pub(crate) url: Option<String>,

    /// Request header as `Name: value` (repeatable)
    #[arg(short = 'H', long = "header", value_name = "HEADER")]
    pub(crate) headers: Vec<String>,

    /// Check the response, e.g. `status == 200` or `body.id exists` (repeatable)
    #[arg(long = "test", value_name = "TEST")]
    pub(crate) tests: Vec<String>,

    /// Request body; `@file` reads a file, `@-` reads stdin
    #[arg(short, long, value_name = "DATA")]
    pub(crate) data: Option<String>,

    /// Shorthand for `--data` with `Content-Type: application/json`
    #[arg(short, long, value_name = "JSON", conflicts_with = "data")]
    pub(crate) json: Option<String>,

    /// Multipart form field as `name=value`, or `name=@file` to upload (repeatable)
    #[arg(short = 'F', long = "form", value_name = "FIELD", conflicts_with_all = ["data", "json", "binary"])]
    pub(crate) form: Vec<String>,

    /// Send a file's bytes as the body
    #[arg(long, value_name = "FILE", conflicts_with_all = ["data", "json"])]
    pub(crate) binary: Option<String>,

    /// Timeout in seconds
    #[arg(short, long, value_name = "SECS")]
    pub(crate) timeout: Option<f64>,

    /// Basic auth credentials as `user:password`
    #[arg(short, long, value_name = "USER:PASS")]
    pub(crate) user: Option<String>,

    /// Use digest auth with the `--user` credentials
    #[arg(long, requires = "user")]
    pub(crate) digest: bool,

    /// Bearer token
    #[arg(long, value_name = "TOKEN", conflicts_with = "user")]
    pub(crate) bearer: Option<String>,

    /// Any auth type: apikey, bearer, jwt, basic, digest, oauth1, oauth2,
    /// hawk, awsv4, ntlm or edgegrid; set its fields with `--auth-param`
    #[arg(long, value_name = "TYPE", conflicts_with_all = ["user", "bearer"])]
    pub(crate) auth: Option<String>,

    /// A field for `--auth` as `key=value` (repeatable), e.g. `accessKey=AKIA...`
    #[arg(long = "auth-param", value_name = "KEY=VALUE", requires = "auth")]
    pub(crate) auth_params: Vec<String>,

    #[command(flatten)]
    pub(crate) vars: VarArgs,

    #[command(flatten)]
    pub(crate) output: OutputArgs,

    #[command(flatten)]
    pub(crate) http: HttpArgs,
}

#[derive(Args)]
pub(crate) struct VarArgs {
    /// Environment file supplying `{{variables}}` (reqorb, Postman or .env)
    #[arg(short, long, value_name = "FILE")]
    pub(crate) env: Option<PathBuf>,

    /// Set or override a variable as `KEY=VALUE` (repeatable)
    #[arg(long = "var", value_name = "KEY=VALUE")]
    pub(crate) vars: Vec<String>,
}

#[derive(Args)]
pub(crate) struct HttpArgs {
    /// HTTP version to use: auto, 1 or 2
    #[arg(long = "http-version", value_name = "VERSION", default_value = "auto")]
    pub(crate) http_version: String,

    /// Skip TLS certificate verification, e.g. for self-signed servers
    #[arg(short = 'k', long)]
    pub(crate) insecure: bool,

    /// Return redirect responses instead of following them
    #[arg(long)]
    pub(crate) no_follow: bool,

    /// Give up after this many redirects
    #[arg(long, value_name = "N")]
    pub(crate) max_redirects: Option<u32>,
}

impl HttpArgs {
    /// Applies the options to a request, on top of any settings it carries.
    pub(crate) fn apply(&self, request: &Request) -> Request {
        let mut request = request.clone();
        if self.insecure || self.no_follow || self.max_redirects.is_some() {
            let mut settings = request.settings.take().unwrap_or_default();
            settings.verify_ssl &= !self.insecure;
            settings.follow_redirects &= !self.no_follow;
            if let Some(max) = self.max_redirects {
                settings.max_redirects = max;
            }
            request.settings = Some(settings);
        }
        request
    }

    pub(crate) fn options(&self) -> Result<SendOptions> {
        let http_mode = match self.http_version.as_str() {
            "auto" => HttpMode::Auto,
            "1" | "1.1" | "http1" => HttpMode::Http1,
            "2" | "http2" => HttpMode::Http2,
            other => bail!("unknown HTTP version `{other}`; use auto, 1 or 2"),
        };
        Ok(SendOptions {
            http_mode,
            timeout_ms: None,
        })
    }
}

#[derive(Args)]
pub(crate) struct OutputArgs {
    /// Print the status line and response headers
    #[arg(short, long)]
    pub(crate) include: bool,

    /// Write every HTTP exchange made, redirects included, to a HAR file
    #[arg(long, value_name = "FILE")]
    pub(crate) har: Option<PathBuf>,

    /// Replace tokens, passwords, cookies and keys in the HAR file with [REDACTED]
    #[arg(long, requires = "har")]
    pub(crate) redact: bool,
}

#[derive(Args)]
pub(crate) struct RunArgs {
    /// Collection file, or the URL of a served swagger.json
    pub(crate) file: String,

    /// Only run requests with this name or `Folder/Name` path
    pub(crate) name: Option<String>,

    #[command(flatten)]
    pub(crate) vars: VarArgs,

    #[command(flatten)]
    pub(crate) output: OutputArgs,

    #[command(flatten)]
    pub(crate) http: HttpArgs,
}

#[derive(Args)]
pub(crate) struct ImportArgs {
    /// File or URL to import; `-` reads stdin
    pub(crate) file: String,

    /// Name for the imported collection, instead of the one in the source
    #[arg(short, long)]
    pub(crate) name: Option<String>,

    /// Write the result here instead of stdout
    #[arg(short, long, value_name = "FILE")]
    pub(crate) output: Option<PathBuf>,
}

#[derive(Args)]
pub(crate) struct ExportArgs {
    /// Collection or environment file or URL (reqorb, Postman, OpenAPI/Swagger, HAR, curl or .env)
    pub(crate) file: String,

    /// Target format
    #[arg(short, long, value_enum)]
    pub(crate) format: Format,

    /// Which collection or environment to export when the file holds several
    #[arg(short, long)]
    pub(crate) name: Option<String>,

    /// Write the result here instead of stdout
    #[arg(short, long, value_name = "FILE")]
    pub(crate) output: Option<PathBuf>,

    /// Replace tokens, passwords, cookies and keys with [REDACTED]
    #[arg(long)]
    pub(crate) redact: bool,
}

#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum Format {
    Reqorb,
    Postman,
    Bruno,
    Curl,
    Dotenv,
}

impl From<Format> for ExportFormat {
    fn from(f: Format) -> Self {
        match f {
            Format::Reqorb => ExportFormat::Reqorb,
            Format::Postman => ExportFormat::Postman,
            Format::Bruno => ExportFormat::Bruno,
            Format::Curl => ExportFormat::Curl,
            Format::Dotenv => ExportFormat::Dotenv,
        }
    }
}
