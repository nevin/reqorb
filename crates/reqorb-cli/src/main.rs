use std::io::{IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use anyhow::{Context, Result, anyhow, bail};
use clap::{Args, CommandFactory, Parser, Subcommand, ValueEnum};
use reqorb_core::{
    Auth, AuthKind, AuthParam, BodyMode, ExportFormat, FormField, Header, HttpMode, ImportResult,
    Request, Response, SendOptions, Variable,
};

/// Send HTTP requests, run saved collections, and convert between formats.
///
/// With no subcommand, sends one request: `reqorb GET https://example.com`.
#[derive(Parser)]
#[command(name = "reqorb", version, args_conflicts_with_subcommands = true)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    #[command(flatten)]
    send: SendArgs,
}

#[derive(Subcommand)]
enum Command {
    /// Run requests from a collection (reqorb, Postman, OpenAPI/Swagger or curl)
    Run(RunArgs),
    /// Convert Postman, OpenAPI/Swagger, curl or .env input to reqorb JSON
    Import(ImportArgs),
    /// Convert a collection or environment file to another format
    Export(ExportArgs),
}

#[derive(Args)]
struct SendArgs {
    /// HTTP method (GET, POST, PUT, ...)
    method: Option<String>,

    /// Request URL; `http://` is assumed when no scheme is given
    url: Option<String>,

    /// Request header as `Name: value` (repeatable)
    #[arg(short = 'H', long = "header", value_name = "HEADER")]
    headers: Vec<String>,

    /// Request body; `@file` reads a file, `@-` reads stdin
    #[arg(short, long, value_name = "DATA")]
    data: Option<String>,

    /// Shorthand for `--data` with `Content-Type: application/json`
    #[arg(short, long, value_name = "JSON", conflicts_with = "data")]
    json: Option<String>,

    /// Multipart form field as `name=value`, or `name=@file` to upload (repeatable)
    #[arg(short = 'F', long = "form", value_name = "FIELD", conflicts_with_all = ["data", "json", "binary"])]
    form: Vec<String>,

    /// Send a file's bytes as the body
    #[arg(long, value_name = "FILE", conflicts_with_all = ["data", "json"])]
    binary: Option<String>,

    /// Timeout in seconds
    #[arg(short, long, value_name = "SECS")]
    timeout: Option<f64>,

    /// Basic auth credentials as `user:password`
    #[arg(short, long, value_name = "USER:PASS")]
    user: Option<String>,

    /// Use digest auth with the `--user` credentials
    #[arg(long, requires = "user")]
    digest: bool,

    /// Bearer token
    #[arg(long, value_name = "TOKEN", conflicts_with = "user")]
    bearer: Option<String>,

    /// Any auth type: apikey, bearer, jwt, basic, digest, oauth1, oauth2,
    /// hawk, awsv4, ntlm or edgegrid; set its fields with `--auth-param`
    #[arg(long, value_name = "TYPE", conflicts_with_all = ["user", "bearer"])]
    auth: Option<String>,

    /// A field for `--auth` as `key=value` (repeatable), e.g. `accessKey=AKIA...`
    #[arg(long = "auth-param", value_name = "KEY=VALUE", requires = "auth")]
    auth_params: Vec<String>,

    #[command(flatten)]
    vars: VarArgs,

    #[command(flatten)]
    output: OutputArgs,

    #[command(flatten)]
    http: HttpArgs,
}

#[derive(Args)]
struct VarArgs {
    /// Environment file supplying `{{variables}}` (reqorb, Postman or .env)
    #[arg(short, long, value_name = "FILE")]
    env: Option<PathBuf>,

    /// Set or override a variable as `KEY=VALUE` (repeatable)
    #[arg(long = "var", value_name = "KEY=VALUE")]
    vars: Vec<String>,
}

#[derive(Args)]
struct HttpArgs {
    /// HTTP version to use: auto, 1 or 2
    #[arg(long = "http-version", value_name = "VERSION", default_value = "auto")]
    http_version: String,

    /// Skip TLS certificate verification, e.g. for self-signed servers
    #[arg(short = 'k', long)]
    insecure: bool,

    /// Return redirect responses instead of following them
    #[arg(long)]
    no_follow: bool,

    /// Give up after this many redirects
    #[arg(long, value_name = "N")]
    max_redirects: Option<u32>,
}

impl HttpArgs {
    /// Applies the options to a request, on top of any settings it carries.
    fn apply(&self, request: &Request) -> Request {
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

    fn options(&self) -> Result<SendOptions> {
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
struct OutputArgs {
    /// Print the status line and response headers
    #[arg(short, long)]
    include: bool,
}

#[derive(Args)]
struct RunArgs {
    /// Collection file, or the URL of a served swagger.json
    file: String,

    /// Only run requests with this name or `Folder/Name` path
    name: Option<String>,

    #[command(flatten)]
    vars: VarArgs,

    #[command(flatten)]
    output: OutputArgs,

    #[command(flatten)]
    http: HttpArgs,
}

#[derive(Args)]
struct ImportArgs {
    /// File or URL to import; `-` reads stdin
    file: String,

    /// Name for the imported collection, instead of the one in the source
    #[arg(short, long)]
    name: Option<String>,

    /// Write the result here instead of stdout
    #[arg(short, long, value_name = "FILE")]
    output: Option<PathBuf>,
}

#[derive(Args)]
struct ExportArgs {
    /// Collection or environment file or URL (reqorb, Postman, OpenAPI/Swagger, curl or .env)
    file: String,

    /// Target format
    #[arg(short, long, value_enum)]
    format: Format,

    /// Which collection or environment to export when the file holds several
    #[arg(short, long)]
    name: Option<String>,

    /// Write the result here instead of stdout
    #[arg(short, long, value_name = "FILE")]
    output: Option<PathBuf>,
}

#[derive(Clone, Copy, ValueEnum)]
enum Format {
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

/// Builds the request's auth from whichever auth options were given.
fn parse_auth(args: &SendArgs) -> Result<Option<Auth>> {
    if let Some(credentials) = &args.user {
        let (user, password) = credentials.split_once(':').unwrap_or((credentials, ""));
        let kind = if args.digest {
            AuthKind::Digest
        } else {
            AuthKind::Basic
        };
        return Ok(Some(Auth::new(
            kind,
            &[("username", user), ("password", password)],
        )));
    }
    if let Some(token) = &args.bearer {
        return Ok(Some(Auth::new(AuthKind::Bearer, &[("token", token)])));
    }
    let Some(id) = &args.auth else {
        return Ok(None);
    };
    let Some(kind) = AuthKind::from_id(&id.to_lowercase()) else {
        let known: Vec<&str> = AuthKind::ALL.iter().skip(1).map(|k| k.id()).collect();
        bail!("unknown auth type `{id}`; use one of {}", known.join(", "));
    };
    let fields = reqorb_core::auth_fields(kind);
    let mut auth = Auth::new(kind, &[]);
    for raw in &args.auth_params {
        let Some((key, value)) = raw.split_once('=') else {
            bail!("auth parameter `{raw}` must look like `key=value`");
        };
        if !fields.iter().any(|f| f.key == key) {
            let known: Vec<&str> = fields.iter().map(|f| f.key.as_str()).collect();
            bail!(
                "{} has no field `{key}`; its fields are {}",
                kind.label(),
                known.join(", ")
            );
        }
        auth.params.push(AuthParam {
            key: key.to_string(),
            value: value.to_string(),
        });
    }
    Ok(Some(auth))
}

fn parse_header(raw: &str) -> Result<Header> {
    let Some((name, value)) = raw.split_once(':') else {
        bail!("header `{raw}` must look like `Name: value`");
    };
    Ok(Header {
        name: name.trim().to_string(),
        value: value.trim().to_string(),
    })
}

fn read_body(arg: &str) -> Result<String> {
    match arg.strip_prefix('@') {
        Some("-") => read_input(Path::new("-")),
        Some(path) => read_input(Path::new(path)),
        None => Ok(arg.to_string()),
    }
}

fn read_input(path: &Path) -> Result<String> {
    if path == Path::new("-") {
        let mut buf = String::new();
        std::io::stdin().read_to_string(&mut buf)?;
        Ok(buf)
    } else {
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))
    }
}

/// Reads any importable file or `http(s)` URL, printing what could not be
/// carried over.
async fn load_source(source: &str) -> Result<ImportResult> {
    let result = if source.starts_with("http://") || source.starts_with("https://") {
        reqorb_core::import_url(source).await
    } else {
        let path = Path::new(source);
        let hint = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        let hint = hint.strip_suffix(".postman_collection").unwrap_or(hint);
        let hint = hint.strip_suffix(".postman_environment").unwrap_or(hint);
        reqorb_core::import(&read_input(path)?, hint)
    }
    .with_context(|| format!("importing {source}"))?;
    for warning in &result.warnings {
        eprintln!("warning: {warning}");
    }
    Ok(result)
}

fn write_output(path: Option<&Path>, text: &str) -> Result<()> {
    match path {
        Some(path) => {
            std::fs::write(path, text).with_context(|| format!("writing {}", path.display()))
        }
        None => Ok(std::io::stdout().write_all(text.as_bytes())?),
    }
}

/// Variables in priority order: `--var` first, then the `--env` file.
async fn load_variables(args: &VarArgs) -> Result<Vec<Variable>> {
    let mut variables = Vec::new();
    for raw in &args.vars {
        let Some((key, value)) = raw.split_once('=') else {
            bail!("variable `{raw}` must look like `KEY=VALUE`");
        };
        variables.push(Variable::new(key.trim(), value));
    }
    if let Some(path) = &args.env {
        let imported = load_source(&path.to_string_lossy()).await?;
        if imported.environments.is_empty() {
            bail!("{} does not contain an environment", path.display());
        }
        for environment in imported.environments {
            variables.extend(environment.variables);
        }
    }
    Ok(variables)
}

/// Prints a response the way `curl -i` would, with metadata on stderr so
/// stdout stays pipeable.
fn print_response(response: &Response, output: &OutputArgs) -> Result<()> {
    let mut err = std::io::stderr().lock();
    if output.include {
        writeln!(
            err,
            "{} {} {}",
            response.http_version, response.status, response.status_text
        )?;
        for h in &response.headers {
            writeln!(err, "{}: {}", h.name, h.value)?;
        }
        writeln!(err)?;
    }

    let mut out = std::io::stdout().lock();
    out.write_all(response.body.as_bytes())?;
    if out.is_terminal() && !response.body.ends_with('\n') {
        writeln!(out)?;
    }
    out.flush()?;

    if std::io::stderr().is_terminal() {
        writeln!(
            err,
            "\n{} {} · {} ms · {} bytes",
            response.status, response.status_text, response.elapsed_ms, response.size_bytes
        )?;
    }
    Ok(())
}

fn warn_unresolved(unresolved: &[String]) {
    if !unresolved.is_empty() {
        eprintln!("warning: unresolved variable(s): {}", unresolved.join(", "));
    }
}

async fn send(args: SendArgs) -> Result<ExitCode> {
    let auth = parse_auth(&args)?;
    let (Some(method), Some(url)) = (args.method, args.url) else {
        Cli::command().print_help()?;
        return Ok(ExitCode::from(2));
    };
    let url = if url.contains("://") || url.starts_with("{{") {
        url
    } else {
        format!("http://{url}")
    };

    let mut request = Request::new(method, url);
    for raw in &args.headers {
        request.headers.push(parse_header(raw)?);
    }
    if let Some(json) = &args.json {
        request.body = Some(read_body(json)?);
        if !request.has_header("content-type") {
            request.add_header("Content-Type", "application/json");
        }
    } else if let Some(data) = &args.data {
        request.body = Some(read_body(data)?);
    } else if let Some(path) = &args.binary {
        request.body_mode = Some(BodyMode::Binary);
        request.body = Some(path.clone());
    } else if !args.form.is_empty() {
        request.body_mode = Some(BodyMode::FormData);
        for raw in &args.form {
            let Some((key, value)) = raw.split_once('=') else {
                bail!("form field `{raw}` must look like `name=value` or `name=@file`");
            };
            request.form.push(match value.strip_prefix('@') {
                Some(path) => FormField::file(key, path),
                None => FormField::text(key, value),
            });
        }
    }
    request.timeout_ms = args.timeout.map(|s| (s * 1000.0) as u64);
    request.auth = auth;
    let request = args.http.apply(&request);

    let variables = load_variables(&args.vars).await?;
    let sent = reqorb_core::send_with(&request, &variables, &args.http.options()?, &[]).await?;
    warn_unresolved(&sent.unresolved);
    print_response(&sent.response, &args.output)?;

    Ok(if sent.response.status >= 400 {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    })
}

async fn run(args: RunArgs) -> Result<ExitCode> {
    let imported = load_source(&args.file).await?;
    let overrides = load_variables(&args.vars).await?;
    let options = args.http.options()?;

    // Each request is paired with its own collection's variables.
    let mut selected: Vec<(String, &Request, Vec<Variable>)> = Vec::new();
    for collection in &imported.collections {
        let mut variables = overrides.clone();
        variables.extend(collection.variables.iter().cloned());
        for (path, request) in collection.requests() {
            let wanted = args.name.as_ref().is_none_or(|name| {
                path.eq_ignore_ascii_case(name)
                    || path
                        .rsplit('/')
                        .next()
                        .is_some_and(|leaf| leaf.eq_ignore_ascii_case(name))
            });
            if wanted {
                selected.push((path, request, variables.clone()));
            }
        }
    }
    if selected.is_empty() {
        match &args.name {
            Some(name) => bail!("no request named `{name}` in {}", args.file),
            None => bail!("{} contains no requests", args.file),
        }
    }

    // A single request prints its body; several print one summary line each.
    if let [(_, request, variables)] = selected.as_slice() {
        let request = &args.http.apply(request);
        let sent = reqorb_core::send_with(request, variables, &options, &[]).await?;
        warn_unresolved(&sent.unresolved);
        print_response(&sent.response, &args.output)?;
        return Ok(if sent.response.status >= 400 {
            ExitCode::from(1)
        } else {
            ExitCode::SUCCESS
        });
    }

    // Cookies carry over from one request to the next, as in a browser session.
    let mut cookies = Vec::new();
    let mut failed = 0;
    for (path, request, variables) in &selected {
        let request = &args.http.apply(request);
        match reqorb_core::send_with(request, variables, &options, &cookies).await {
            Ok(sent) => {
                cookies = sent.cookies;
                let ok = sent.response.status < 400;
                failed += usize::from(!ok);
                println!(
                    "{} {} {:<22} {:>6} ms  {} {path}",
                    if ok { "✓" } else { "✗" },
                    sent.response.status,
                    sent.response.status_text,
                    sent.response.elapsed_ms,
                    request.method,
                );
                warn_unresolved(&sent.unresolved);
            }
            Err(e) => {
                failed += 1;
                println!("✗ error: {e}  {} {path}", request.method);
            }
        }
    }
    eprintln!("\n{} run, {failed} failed", selected.len());
    Ok(if failed > 0 {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    })
}

async fn import(args: ImportArgs) -> Result<ExitCode> {
    let mut imported = load_source(&args.file).await?;
    if let Some(name) = &args.name {
        match imported.collections.as_mut_slice() {
            [collection] => collection.name = name.clone(),
            _ => bail!("--name needs a source holding exactly one collection"),
        }
    }
    let text = reqorb_core::export_native(&imported.collections, &imported.environments);
    write_output(args.output.as_deref(), &text)?;
    if args.output.is_some() {
        eprintln!(
            "imported {} collection(s) and {} environment(s) from {}",
            imported.collections.len(),
            imported.environments.len(),
            imported.source
        );
    }
    Ok(ExitCode::SUCCESS)
}

async fn export(args: ExportArgs) -> Result<ExitCode> {
    let imported = load_source(&args.file).await?;
    let format = ExportFormat::from(args.format);
    let by_name = |name: &str| {
        args.name
            .as_ref()
            .is_none_or(|n| n.eq_ignore_ascii_case(name))
    };

    let collections: Vec<_> = imported
        .collections
        .iter()
        .filter(|c| by_name(&c.name))
        .collect();
    let environments: Vec<_> = imported
        .environments
        .iter()
        .filter(|e| by_name(&e.name))
        .collect();

    let text = match (collections.as_slice(), environments.as_slice()) {
        ([collection], []) => reqorb_core::export_collection(collection, format)?,
        ([], [environment]) => reqorb_core::export_environment(environment, format)?,
        ([], []) => bail!("nothing to export in {}", args.file),
        _ => {
            let names: Vec<&str> = collections
                .iter()
                .map(|c| c.name.as_str())
                .chain(environments.iter().map(|e| e.name.as_str()))
                .collect();
            return Err(anyhow!(
                "{} holds several items ({}); pick one with --name",
                args.file,
                names.join(", ")
            ));
        }
    };
    write_output(args.output.as_deref(), &text)?;
    Ok(ExitCode::SUCCESS)
}

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    let result = match cli.command {
        Some(Command::Run(args)) => run(args).await,
        Some(Command::Import(args)) => import(args).await,
        Some(Command::Export(args)) => export(args).await,
        None => send(cli.send).await,
    };
    match result {
        Ok(code) => code,
        Err(e) => {
            eprintln!("reqorb: {e:#}");
            ExitCode::from(2)
        }
    }
}
