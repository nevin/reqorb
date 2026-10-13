//! Converts between formats: `import` and `export`.

use std::process::ExitCode;

use anyhow::{Result, anyhow, bail};
use reqorb_core::ExportFormat;

use crate::cli::{ExportArgs, ImportArgs};
use crate::input::load_source;
use crate::output::write_output;

pub(crate) async fn import(args: ImportArgs) -> Result<ExitCode> {
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

pub(crate) async fn export(args: ExportArgs) -> Result<ExitCode> {
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
        ([collection], []) if args.redact => {
            reqorb_core::export_collection(&reqorb_core::redact_collection(collection), format)?
        }
        ([], [environment]) if args.redact => {
            reqorb_core::export_environment(&reqorb_core::redact_environment(environment), format)?
        }
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
