//! Writes one request of a collection as code.

use std::process::ExitCode;

use anyhow::{Result, bail};

use crate::cli::CodeArgs;
use crate::input::{load_source, load_variables};
use crate::output::write_output;

pub(crate) async fn code(args: CodeArgs) -> Result<ExitCode> {
    let imported = load_source(&args.file).await?;
    let overrides = load_variables(&args.vars).await?;

    let mut found = Vec::new();
    for collection in &imported.collections {
        for (path, request) in collection.requests() {
            let wanted = args.name.as_ref().is_none_or(|name| {
                path.eq_ignore_ascii_case(name)
                    || path
                        .rsplit('/')
                        .next()
                        .is_some_and(|leaf| leaf.eq_ignore_ascii_case(name))
            });
            if wanted {
                found.push((path, request, &collection.variables));
            }
        }
    }
    let (request, collection_variables) = match found.as_slice() {
        [(_, request, variables)] => (*request, *variables),
        [] => match &args.name {
            Some(name) => bail!("no request named `{name}` in {}", args.file),
            None => bail!("{} contains no requests", args.file),
        },
        several => {
            let paths: Vec<&str> = several.iter().map(|(path, ..)| path.as_str()).collect();
            bail!(
                "{} holds several requests ({}); name the one to write",
                args.file,
                paths.join(", ")
            );
        }
    };

    let mut variables = overrides;
    variables.extend(collection_variables.iter().cloned());
    let text = reqorb_core::generate_code(request, &variables, args.language)?;
    write_output(args.output.as_deref(), &text)?;
    Ok(ExitCode::SUCCESS)
}
