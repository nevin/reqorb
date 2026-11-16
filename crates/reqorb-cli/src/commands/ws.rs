//! Opens a WebSocket, sends messages and prints what arrives.

use std::process::ExitCode;

use std::sync::{Arc, Mutex, PoisonError};

use anyhow::{Context, Result};
use reqorb_core::{Request, WsEvent, WsLine};

use crate::cli::WsArgs;
use crate::input::{load_variables, parse_header};

pub(crate) async fn ws(args: WsArgs) -> Result<ExitCode> {
    use reqorb_core::WsEventKind;
    use tokio::io::AsyncBufReadExt;

    let url = if args.url.contains("://") || args.url.starts_with("{{") {
        args.url.clone()
    } else {
        format!("ws://{}", args.url)
    };
    let mut request = Request::new("GET", url);
    for raw in &args.headers {
        request.headers.push(parse_header(raw)?);
    }
    if args.insecure {
        request.settings = Some(reqorb_core::RequestSettings {
            verify_ssl: false,
            ..Default::default()
        });
    }
    let variables = load_variables(&args.vars).await?;
    let (handle, mut events) = reqorb_core::ws_connect(&request, &variables).await?;
    // The conversation, kept only when it is going to be saved.
    let log = Arc::new(Mutex::new(Vec::new()));
    let keep = args.har.is_some();
    let record = move |log: &Mutex<Vec<WsLine>>, sent: bool, event: WsEvent| {
        if keep {
            log.lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(WsLine { sent, event });
        }
    };
    let send = move |handle: &reqorb_core::WsHandle, log: &Mutex<Vec<WsLine>>, text: String| {
        let sent = handle.send_text(text.clone());
        if sent {
            record(log, true, WsEvent::sent(text));
        }
        sent
    };
    for message in &args.messages {
        send(&handle, &log, message.clone());
    }

    // Lines typed, or piped in, are sent as they arrive.
    let (typed, typed_log) = (handle.clone(), log.clone());
    tokio::spawn(async move {
        let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if !send(&typed, &typed_log, line) {
                break;
            }
        }
    });
    let deadline = args.timeout.map(std::time::Duration::from_secs_f64);
    let give_up = async {
        match deadline {
            Some(after) => tokio::time::sleep(after).await,
            None => std::future::pending().await,
        }
    };
    tokio::pin!(give_up);

    let mut received = 0;
    let mut failed = false;
    loop {
        let event = tokio::select! {
            event = events.recv() => event,
            () = &mut give_up => {
                handle.close();
                // Keep reading so the close is acknowledged and reported.
                deadline_passed(&mut events).await
            }
        };
        let Some(event) = event else { break };
        record(&log, false, event.clone());
        match event.kind {
            WsEventKind::Open => eprintln!("connected ({} {})", event.code, event.text),
            WsEventKind::Text => {
                println!("{}", event.text);
                received += 1;
            }
            WsEventKind::Binary => {
                println!("[{} bytes of binary data]", event.data.len());
                received += 1;
            }
            WsEventKind::Ping | WsEventKind::Pong => {}
            WsEventKind::Closed => {
                eprintln!("closed: {}", event.text);
                break;
            }
            WsEventKind::Error => {
                eprintln!("reqorb: {}", event.text);
                failed = true;
                break;
            }
        }
        if args.exit_after.is_some_and(|n| received >= n) {
            handle.close();
        }
    }
    if let Some(path) = &args.har {
        let mut lines = log.lock().unwrap_or_else(PoisonError::into_inner).clone();
        // Messages typed while others arrived were noted out of turn.
        lines.sort_by_key(|line| line.event.at_ms);
        let har = reqorb_core::ws_to_har(&request, &variables, &lines, args.redact);
        std::fs::write(path, har).with_context(|| format!("writing {}", path.display()))?;
    }
    Ok(if failed {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    })
}

/// After asking to close, waits for the event that ends the connection.
pub(crate) async fn deadline_passed(
    events: &mut tokio::sync::mpsc::UnboundedReceiver<reqorb_core::WsEvent>,
) -> Option<reqorb_core::WsEvent> {
    while let Some(event) = events.recv().await {
        if matches!(
            event.kind,
            reqorb_core::WsEventKind::Closed | reqorb_core::WsEventKind::Error
        ) {
            return Some(event);
        }
    }
    None
}
