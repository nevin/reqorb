//! Printing results and writing files.

use std::io::{IsTerminal, Write};
use std::path::Path;

use anyhow::{Context, Result};
use reqorb_core::Response;

use crate::cli::OutputArgs;

/// Writes the session's exchanges as a HAR file when `--har` was given.
pub(crate) fn write_har(output: &OutputArgs, exchanges: &[reqorb_core::Exchange]) -> Result<()> {
    if let Some(path) = &output.har {
        let har = if output.redact {
            reqorb_core::to_har(&reqorb_core::redact_exchanges(exchanges))
        } else {
            reqorb_core::to_har(exchanges)
        };
        std::fs::write(path, har).with_context(|| format!("cannot write {}", path.display()))?;
        eprintln!(
            "wrote {} exchange(s) to {}",
            exchanges.len(),
            path.display()
        );
    }
    Ok(())
}

pub(crate) fn write_output(path: Option<&Path>, text: &str) -> Result<()> {
    match path {
        Some(path) => {
            std::fs::write(path, text).with_context(|| format!("writing {}", path.display()))
        }
        None => Ok(std::io::stdout().write_all(text.as_bytes())?),
    }
}

/// Prints a response the way `curl -i` would, with metadata on stderr so
/// stdout stays pipeable.
pub(crate) fn print_response(response: &Response, output: &OutputArgs) -> Result<()> {
    print_response_parts(response, output, true)
}

/// Prints the response, leaving out the body when `body` is false because
/// it was already printed as it arrived.
pub(crate) fn print_response_parts(
    response: &Response,
    output: &OutputArgs,
    body: bool,
) -> Result<()> {
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
    match &response.bytes {
        _ if !body => {}
        // Binary is written as it is when piped or redirected, but would
        // only garble a terminal.
        Some(bytes) if out.is_terminal() => writeln!(
            err,
            "binary body, {} bytes: redirect the output to a file to keep it",
            bytes.len()
        )?,
        Some(bytes) => out.write_all(bytes)?,
        None => {
            out.write_all(response.body.as_bytes())?;
            if out.is_terminal() && !response.body.ends_with('\n') {
                writeln!(out)?;
            }
        }
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

pub(crate) fn warn_unresolved(unresolved: &[String]) {
    if !unresolved.is_empty() {
        eprintln!("warning: unresolved variable(s): {}", unresolved.join(", "));
    }
}

/// Prints how each test came out and returns how many failed.
pub(crate) fn report_tests(sent: &reqorb_core::Sent, indent: &str) -> usize {
    for result in &sent.tests {
        if result.passed {
            eprintln!("{indent}✓ {}", result.test);
        } else {
            eprintln!("{indent}✗ {}  ({})", result.test, result.detail);
        }
    }
    for error in &sent.graphql_errors {
        eprintln!("{indent}graphql error: {error}");
    }
    for problem in &sent.capture_problems {
        eprintln!("{indent}warning: nothing captured for {problem}");
    }
    sent.tests.iter().filter(|t| !t.passed).count()
}

/// Whether a send counts as a success: its tests decide when it has any,
/// otherwise the status does, along with the errors of a GraphQL response.
pub(crate) fn succeeded(sent: &reqorb_core::Sent) -> bool {
    if sent.tests.is_empty() {
        sent.response.status < 400 && sent.graphql_errors.is_empty()
    } else {
        sent.tests.iter().all(|t| t.passed)
    }
}

pub(crate) fn human_bytes(bytes: u64) -> String {
    match bytes {
        b if b >= 1 << 20 => format!("{:.1} MB", b as f64 / (1 << 20) as f64),
        b if b >= 1 << 10 => format!("{:.1} KB", b as f64 / (1 << 10) as f64),
        b => format!("{b} B"),
    }
}

pub(crate) fn human_ms(ms: u64) -> String {
    if ms >= 1000 {
        format!("{:.2} s", ms as f64 / 1000.0)
    } else {
        format!("{ms} ms")
    }
}
