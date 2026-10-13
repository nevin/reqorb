//! Sends one request written on the command line.

use std::io::Write;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Result, bail};
use clap::CommandFactory;
use reqorb_core::{BodyMode, Cancel, FormField, Request, SendEvent, Watch};

use crate::cli::{Cli, SendArgs};
use crate::input::{load_variables, parse_auth, parse_header, read_body};
use crate::output::{print_response_parts, report_tests, succeeded, warn_unresolved, write_har};

pub(crate) async fn send(args: SendArgs) -> Result<ExitCode> {
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
    } else if let Some(query) = &args.graphql {
        request.body_mode = Some(BodyMode::GraphQl);
        request.body = Some(read_body(query)?);
        request.graphql_variables = args.variables.as_deref().map(read_body).transpose()?;
        request.graphql_operation = args.operation.clone();
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
    request.tests = args.tests.clone();
    let request = args.http.apply(&request);

    let variables = load_variables(&args.vars).await?;
    if let Some(target) = args.code {
        print!(
            "{}",
            reqorb_core::generate_code(&request, &variables, target)?
        );
        return Ok(ExitCode::SUCCESS);
    }
    if args.schema {
        let schema =
            reqorb_core::graphql_schema(&request, &variables, &args.http.options()?, &[]).await?;
        print!("{}", schema.to_sdl());
        return Ok(ExitCode::SUCCESS);
    }
    // A stream is printed as it arrives, since it may never end. Ctrl-C
    // stops it and keeps what came, for the summary and the HAR file.
    let streamed = Arc::new(AtomicBool::new(false));
    let cancel = Cancel::default();
    let watch = Watch::new(
        {
            let streamed = streamed.clone();
            move |event| match event {
                SendEvent::Head { headers, .. } => streamed.store(
                    headers.iter().any(|h| {
                        h.name.eq_ignore_ascii_case("content-type") && is_stream(&h.value)
                    }),
                    Ordering::SeqCst,
                ),
                SendEvent::Body { text, .. } if streamed.load(Ordering::SeqCst) => {
                    let mut out = std::io::stdout().lock();
                    let _ = out.write_all(text.as_bytes()).and_then(|()| out.flush());
                }
                SendEvent::Body { .. } => {}
            }
        },
        cancel.clone(),
    );
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            cancel.cancel();
        }
    });
    let sent =
        reqorb_core::send_watched(&request, &variables, &args.http.options()?, &[], &watch).await?;
    warn_unresolved(&sent.unresolved);
    print_response_parts(
        &sent.response,
        &args.output,
        !streamed.load(Ordering::SeqCst),
    )?;
    write_har(&args.output, &sent.exchanges)?;
    report_tests(&sent, "");

    Ok(if succeeded(&sent) {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    })
}

/// Whether a response of this type is read as it arrives.
fn is_stream(content_type: &str) -> bool {
    let mime = content_type.split(';').next().unwrap_or("").trim();
    [
        "text/event-stream",
        "application/x-ndjson",
        "application/ndjson",
        "application/jsonl",
        "application/stream+json",
    ]
    .iter()
    .any(|kind| mime.eq_ignore_ascii_case(kind))
}
