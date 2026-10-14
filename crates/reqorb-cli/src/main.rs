//! The `reqorb` command.

mod cli;
mod commands;
mod input;
mod output;

use std::process::ExitCode;

use clap::Parser;

use crate::cli::{Cli, Command};

/// The system allocator, which also holds scripts to their memory limit.
#[global_allocator]
static ALLOCATOR: reqorb_alloc::Counting = reqorb_alloc::Counting;
use crate::commands::{analyze, code, export, grpc, import, run, send, ws};

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    let result = match cli.command {
        Some(Command::Run(args)) => run(args).await,
        Some(Command::Import(args)) => import(args).await,
        Some(Command::Export(args)) => export(args).await,
        Some(Command::Code(args)) => code(args).await,
        Some(Command::Analyze(args)) => analyze(args),
        Some(Command::Ws(args)) => ws(args).await,
        Some(Command::Grpc(args)) => grpc(args).await,
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
