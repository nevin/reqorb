//! Reports on a HAR archive.

use std::process::ExitCode;

use anyhow::{Context, Result};

use crate::cli::AnalyzeArgs;
use crate::input::read_input;
use crate::output::{human_bytes, human_ms};

pub(crate) fn analyze(args: AnalyzeArgs) -> Result<ExitCode> {
    let report = reqorb_core::analyze_har(&read_input(&args.file)?)
        .with_context(|| format!("analysing {}", args.file.display()))?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(ExitCode::SUCCESS);
    }

    println!(
        "{} request(s), {} failed, {} transferred, {} from first to last ({} added up)",
        report.entries.len(),
        report.failed,
        human_bytes(report.total_bytes),
        human_ms(report.span_ms),
        human_ms(report.total_time_ms),
    );
    if !report.creator.is_empty() {
        println!("recorded by {}", report.creator);
    }
    for (title, counts) in [
        ("Status", &report.statuses),
        ("Hosts", &report.hosts),
        ("Content", &report.kinds),
    ] {
        if counts.is_empty() {
            continue;
        }
        println!("\n{title}");
        for count in counts.iter().take(10) {
            println!(
                "  {:<32} {:>5}  {:>10}  {:>9}",
                count.name,
                count.count,
                human_bytes(count.bytes),
                human_ms(count.time_ms),
            );
        }
        if counts.len() > 10 {
            println!("  and {} more", counts.len() - 10);
        }
    }

    let mut slowest: Vec<_> = report.entries.iter().collect();
    slowest.sort_by_key(|e| std::cmp::Reverse(e.time_ms));
    if args.top > 0 && !slowest.is_empty() {
        println!("\nSlowest");
        for entry in slowest.iter().take(args.top) {
            println!(
                "  {:>9}  {:>10}  {:>3}  {} {}",
                human_ms(entry.time_ms),
                human_bytes(entry.size_bytes),
                entry.status,
                entry.method,
                entry.url,
            );
        }
    }

    if report.findings.is_empty() {
        println!("\nNothing stands out.");
    } else {
        println!("\nFindings");
    }
    for finding in &report.findings {
        let mark = match finding.severity {
            reqorb_core::HarSeverity::Error => "✗",
            reqorb_core::HarSeverity::Warning => "!",
            reqorb_core::HarSeverity::Info => "·",
        };
        println!("{mark} {}", finding.title);
        for line in finding.detail.lines() {
            println!("    {line}");
        }
    }
    Ok(ExitCode::SUCCESS)
}
