//! Runs the requests of a collection, passing captured values on.

use std::process::ExitCode;

use anyhow::{Result, bail};
use reqorb_core::{Request, Variable};

use crate::cli::RunArgs;
use crate::input::{load_source, load_variables};
use crate::output::{print_response, report_tests, succeeded, warn_unresolved, write_har};

pub(crate) async fn run(args: RunArgs) -> Result<ExitCode> {
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
        write_har(&args.output, &sent.exchanges)?;
        report_tests(&sent, "");
        return Ok(if succeeded(&sent) {
            ExitCode::SUCCESS
        } else {
            ExitCode::from(1)
        });
    }

    // Cookies carry over from one request to the next, as in a browser session.
    let mut cookies = Vec::new();
    let mut exchanges = Vec::new();
    let mut failed = 0;
    let (mut tests, mut tests_failed) = (0, 0);
    // What earlier requests captured, newest first so it wins over the
    // collection's and the environment's variables.
    let mut captured: Vec<Variable> = Vec::new();
    for (path, request, variables) in &selected {
        let request = &args.http.apply(request);
        let variables: Vec<Variable> = captured.iter().chain(variables).cloned().collect();
        match reqorb_core::send_with(request, &variables, &options, &cookies).await {
            Ok(sent) => {
                let ok = succeeded(&sent);
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
                tests += sent.tests.len();
                tests_failed += report_tests(&sent, "    ");
                for variable in sent.captured.iter().rev() {
                    captured.retain(|v| v.key != variable.key);
                    captured.insert(0, variable.clone());
                }
                cookies = sent.cookies;
                exchanges.extend(sent.exchanges);
            }
            Err(e) => {
                failed += 1;
                println!("✗ error: {e}  {} {path}", request.method);
            }
        }
    }
    write_har(&args.output, &exchanges)?;
    eprintln!("\n{} run, {failed} failed", selected.len());
    if tests > 0 {
        eprintln!("{tests} test(s), {tests_failed} failed");
    }
    Ok(if failed > 0 {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    })
}
