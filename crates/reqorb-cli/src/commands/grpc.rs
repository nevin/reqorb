//! Lists a gRPC server's methods, or calls one.

use std::process::ExitCode;

use anyhow::Result;

use crate::cli::GrpcArgs;
use crate::input::{load_variables, parse_header, read_body};

pub(crate) async fn grpc(args: GrpcArgs) -> Result<ExitCode> {
    let variables = load_variables(&args.vars).await?;
    let mut metadata = Vec::new();
    for raw in &args.headers {
        metadata.push(parse_header(raw)?);
    }
    let schema = match &args.proto {
        Some(path) => reqorb_core::grpc_load_proto(path)?,
        None => reqorb_core::grpc_reflect(&args.address, &metadata, None, &variables).await?,
    };
    let Some(method) = args.method else {
        for method in &schema.methods {
            let kind = match (method.client_streaming, method.server_streaming) {
                (false, false) => "unary",
                (true, false) => "client stream",
                (false, true) => "server stream",
                (true, true) => "two-way stream",
            };
            println!("{}  ({kind})", method.path);
        }
        return Ok(ExitCode::SUCCESS);
    };
    let mut messages = Vec::new();
    for message in &args.messages {
        messages.push(read_body(message)?);
    }
    let call = reqorb_core::GrpcCall {
        url: args.address,
        method,
        messages,
        metadata,
        auth: None,
        descriptors: schema.descriptors,
        timeout_ms: args.timeout.map(|s| (s * 1000.0) as u64),
    };
    let reply = reqorb_core::grpc_call(&call, &variables).await?;
    if args.include {
        for header in &reply.headers {
            eprintln!("{}: {}", header.name, header.value);
        }
    }
    for message in &reply.messages {
        println!("{message}");
    }
    if args.include {
        for trailer in &reply.trailers {
            eprintln!("{}: {}", trailer.name, trailer.value);
        }
    }
    eprintln!(
        "{} {}  {} ms",
        reply.status, reply.message, reply.elapsed_ms
    );
    Ok(if reply.code == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    })
}
