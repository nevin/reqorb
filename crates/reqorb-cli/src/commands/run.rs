//! Runs the requests of a collection, passing captured values on.

use std::process::ExitCode;
use std::time::Duration;

use anyhow::{Context, Result, bail};
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

    // One set of variables for each time through: a row of the data file,
    // or nothing when the requests are only repeated.
    let rows: Vec<Vec<Variable>> = match &args.data {
        Some(path) => {
            let text =
                std::fs::read_to_string(path).with_context(|| format!("could not read {path}"))?;
            let mut rows = reqorb_core::parse_run_data(path, &text)?;
            if let Some(count) = args.iterations {
                rows.truncate(count as usize);
            }
            rows
        }
        None => vec![Vec::new(); args.iterations.unwrap_or(1) as usize],
    };

    // A single request prints its body; several print one summary line each.
    if let ([(_, request, variables)], [row]) = (selected.as_slice(), rows.as_slice()) {
        let request = &args.http.apply(request);
        let variables: Vec<Variable> = row.iter().chain(variables).cloned().collect();
        let sent = reqorb_core::send_with(request, &variables, &options, &[]).await?;
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
    let (mut run, mut failed) = (0, 0);
    let (mut tests, mut tests_failed) = (0, 0);
    // What earlier requests captured, newest first so it wins over the
    // collection's and the environment's variables.
    let mut captured: Vec<Variable> = Vec::new();
    'rows: for (iteration, row) in rows.iter().enumerate() {
        if rows.len() > 1 {
            println!(
                "{}Iteration {}",
                if iteration > 0 { "\n" } else { "" },
                iteration + 1
            );
        }
        for (path, request, variables) in &selected {
            if run > 0 && args.delay > 0 {
                tokio::time::sleep(Duration::from_millis(args.delay)).await;
            }
            run += 1;
            let request = &args.http.apply(request);
            // A captured value wins over the row, and the row over the rest.
            let variables: Vec<Variable> = captured
                .iter()
                .chain(row)
                .chain(variables)
                .cloned()
                .collect();
            let ok = match reqorb_core::send_with(request, &variables, &options, &cookies).await {
                Ok(sent) => {
                    let ok = succeeded(&sent);
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
                    ok
                }
                Err(e) => {
                    println!("✗ error: {e}  {} {path}", request.method);
                    false
                }
            };
            failed += usize::from(!ok);
            if !ok && args.bail {
                break 'rows;
            }
        }
    }
    write_har(&args.output, &exchanges)?;
    let total = selected.len() * rows.len();
    if run < total {
        eprintln!("\n{run} of {total} run, {failed} failed; stopped at the first failure");
    } else {
        eprintln!("\n{run} run, {failed} failed");
    }
    if tests > 0 {
        eprintln!("{tests} test(s), {tests_failed} failed");
    }
    Ok(if failed > 0 {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    })
}
