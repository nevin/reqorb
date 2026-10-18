//! GraphQL subscriptions over a WebSocket, reported in the shape of an
//! event stream so that they read the same as one carried by Server-Sent
//! Events: an event for each result, and the stream ends when the server
//! completes the subscription or the send is stopped.

use std::time::Instant;

use graphql_parser::query::{Definition, OperationDefinition, parse_query};
use serde_json::{Value, json};

use crate::http::{SendEvent, Watch};
use crate::time::now_ms;
use crate::ws::{WsEventKind, ws_connect};
use crate::{BodyMode, Error, Exchange, Header, Request, Response};

/// The protocol of the `graphql-ws` library, which most servers speak.
const MODERN: &str = "graphql-transport-ws";
/// The older protocol of `subscriptions-transport-ws`.
const LEGACY: &str = "graphql-ws";

/// Whether sending this request starts a subscription: it is a GraphQL
/// request, and the operation it runs is one.
pub(crate) fn is_subscription(request: &Request) -> bool {
    if request.effective_body_mode() != BodyMode::GraphQl {
        return false;
    }
    let query = request.body.as_deref().unwrap_or("");
    let wanted = request.graphql_operation.as_deref().unwrap_or("").trim();
    let Ok(document) = parse_query::<String>(query) else {
        return false;
    };
    let mut operations = document.definitions.iter().filter_map(|d| match d {
        Definition::Operation(operation) => Some(match operation {
            OperationDefinition::Subscription(s) => (s.name.as_deref(), true),
            OperationDefinition::Query(q) => (q.name.as_deref(), false),
            OperationDefinition::Mutation(m) => (m.name.as_deref(), false),
            OperationDefinition::SelectionSet(_) => (None, false),
        }),
        Definition::Fragment(_) => None,
    });
    let chosen = if wanted.is_empty() {
        operations.next()
    } else {
        operations.find(|(name, _)| *name == Some(wanted))
    };
    chosen.is_some_and(|(_, subscription)| subscription)
}

/// Whether the request names a WebSocket address itself, so that nothing
/// else should be tried when one cannot be opened.
fn names_websocket(request: &Request) -> bool {
    let url = request.url.trim_start().to_ascii_lowercase();
    url.starts_with("ws://") || url.starts_with("wss://")
}

fn event(name: &str, data: &Value) -> String {
    format!("event: {name}\ndata: {data}\n\n")
}

/// Runs the subscription over a WebSocket. `Ok(None)` means the server
/// would not open one at an `http` address, and the subscription should be
/// asked for as an event stream instead.
pub(crate) async fn over_websocket(
    request: &Request,
    watch: &Watch,
) -> Result<Option<(Response, Vec<Exchange>)>, Error> {
    let started = Instant::now();
    let started_ms = now_ms();

    let mut handshake = request.clone();
    handshake.body = None;
    handshake.body_mode = Some(BodyMode::None);
    handshake.graphql_variables = None;
    handshake.graphql_operation = None;
    handshake.headers.retain(|h| {
        !["content-type", "accept", "sec-websocket-protocol"]
            .contains(&h.name.to_ascii_lowercase().as_str())
    });
    handshake.add_header("Sec-WebSocket-Protocol", format!("{MODERN}, {LEGACY}"));

    let connecting = tokio::select! {
        connected = ws_connect(&handshake, &[]) => connected,
        _ = watch.cancel.cancelled() => return Err(Error::Cancelled),
    };
    let (socket, mut events) = match connecting {
        Ok(connected) => connected,
        Err(e) if names_websocket(request) => return Err(e),
        // Not a WebSocket endpoint, or not reachable as one.
        Err(_) => return Ok(None),
    };

    // What the request carries: the query, its variables and its operation.
    let mut carried = request.clone();
    carried.method = "POST".into();
    carried.materialize();
    let payload: Value = serde_json::from_str(carried.body.as_deref().unwrap_or("{}"))
        .map_err(|e| Error::Format(format!("the GraphQL request is not valid JSON: {e}")))?;

    let mut headers = vec![Header {
        name: "content-type".into(),
        value: "text/event-stream".into(),
    }];
    let mut legacy = false;
    let mut body = String::new();
    let mut acknowledged = false;
    // Why the subscription ended badly, when nothing had arrived to show.
    let mut failure: Option<String> = None;

    loop {
        let next = tokio::select! {
            next = events.recv() => next,
            _ = watch.cancel.cancelled() => {
                if acknowledged {
                    let stop = if legacy { "stop" } else { "complete" };
                    socket.send_text(json!({"id": "1", "type": stop}).to_string());
                }
                socket.close();
                break;
            }
        };
        let Some(next) = next else { break };
        match next.kind {
            WsEventKind::Open => {
                legacy = next.headers.iter().any(|h| {
                    h.name.eq_ignore_ascii_case("sec-websocket-protocol")
                        && h.value.trim() == LEGACY
                });
                headers.extend(next.headers);
                // Servers that check credentials here look for them under
                // `headers`, or for the token by its header's name.
                let mut init = serde_json::Map::new();
                let mut sent = serde_json::Map::new();
                for header in &request.headers {
                    sent.insert(header.name.clone(), header.value.clone().into());
                    if header.name.eq_ignore_ascii_case("authorization") {
                        init.insert("Authorization".into(), header.value.clone().into());
                    }
                }
                if !sent.is_empty() {
                    init.insert("headers".into(), sent.into());
                }
                socket.send_text(json!({"type": "connection_init", "payload": init}).to_string());
            }
            WsEventKind::Text => {
                let Ok(message) = serde_json::from_str::<Value>(&next.text) else {
                    continue;
                };
                let payload_of = || message.get("payload").cloned().unwrap_or(Value::Null);
                match message.get("type").and_then(Value::as_str).unwrap_or("") {
                    "connection_ack" => {
                        acknowledged = true;
                        watch.report(SendEvent::Head {
                            status: 101,
                            status_text: "Switching Protocols".into(),
                            http_version: "WebSocket".into(),
                            headers: headers.clone(),
                        });
                        let start = if legacy { "start" } else { "subscribe" };
                        socket.send_text(
                            json!({"id": "1", "type": start, "payload": payload}).to_string(),
                        );
                    }
                    "ping" => {
                        socket.send_text(json!({"type": "pong"}).to_string());
                    }
                    kind @ ("next" | "data" | "error") => {
                        let name = if kind == "error" { "error" } else { "next" };
                        let text = event(name, &payload_of());
                        body.push_str(&text);
                        watch.report(SendEvent::Body {
                            text,
                            received: body.len() as u64,
                        });
                        if kind == "error" {
                            socket.close();
                            break;
                        }
                    }
                    "complete" => {
                        socket.close();
                        break;
                    }
                    "connection_error" => {
                        failure = Some(format!(
                            "the server refused the subscription: {}",
                            payload_of()
                        ));
                        socket.close();
                        break;
                    }
                    // Keep-alives, and anything a later protocol adds.
                    _ => {}
                }
            }
            WsEventKind::Closed => {
                // A server that closes without completing says why here.
                if !acknowledged || next.code != 1000 {
                    failure = Some(format!(
                        "the server closed the connection: {} {}",
                        next.code, next.text
                    ));
                }
                break;
            }
            WsEventKind::Error => {
                failure = Some(next.text);
                break;
            }
            WsEventKind::Binary | WsEventKind::Ping | WsEventKind::Pong => {}
        }
    }

    if let Some(failure) = failure {
        if body.is_empty() {
            return Err(Error::Http(failure));
        }
        // Keep the results that did arrive, and say how it ended.
        let text = event("error", &json!({ "message": failure }));
        body.push_str(&text);
        watch.report(SendEvent::Body {
            text,
            received: body.len() as u64,
        });
    } else if !acknowledged && !watch.cancel.is_cancelled() {
        return Err(Error::Http(
            "the server closed the connection before accepting the subscription".into(),
        ));
    } else if !acknowledged {
        return Err(Error::Cancelled);
    }

    let response = Response {
        status: 101,
        status_text: "Switching Protocols".into(),
        http_version: "WebSocket".into(),
        headers,
        size_bytes: body.len() as u64,
        body,
        bytes: None,
        body_file: None,
        elapsed_ms: started.elapsed().as_millis() as u64,
    };
    let exchange = Exchange {
        started_ms,
        request: Request {
            headers: handshake.headers,
            ..request.clone()
        },
        response: response.clone(),
    };
    Ok(Some((response, vec![exchange])))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::{Cancel, send_watched};
    use crate::{SendOptions, Variable};
    use futures_util::{SinkExt, StreamExt};
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::tungstenite::handshake::server::{
        Request as Hello, Response as Welcome,
    };

    fn subscription(url: &str) -> Request {
        let mut request = Request::new("POST", url);
        request.body_mode = Some(BodyMode::GraphQl);
        request.body = Some("subscription Ticks($n: Int) { tick(times: $n) }".into());
        request.graphql_variables = Some("{\"n\": {{times}}}".into());
        request.add_header("Authorization", "Bearer t0k");
        request
    }

    /// A server that speaks `protocol`: it sends two results and completes,
    /// or with `endless` keeps the subscription open until told to stop.
    /// It hands back every message it was sent.
    #[allow(clippy::result_large_err)]
    async fn server(
        protocol: &'static str,
        endless: bool,
    ) -> (String, tokio::task::JoinHandle<Vec<Value>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/graphql", listener.local_addr().unwrap());
        let legacy = protocol == LEGACY;
        let task = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_hdr_async(
                socket,
                |hello: &Hello, mut welcome: Welcome| {
                    let offered = hello.headers()["sec-websocket-protocol"].to_str().unwrap();
                    assert!(offered.split(", ").any(|p| p == protocol));
                    welcome
                        .headers_mut()
                        .insert("sec-websocket-protocol", protocol.parse().unwrap());
                    Ok(welcome)
                },
            )
            .await
            .unwrap();
            let mut seen = Vec::new();
            while let Some(Ok(message)) = ws.next().await {
                let Message::Text(text) = message else {
                    continue;
                };
                let message: Value = serde_json::from_str(text.as_str()).unwrap();
                let kind = message["type"].as_str().unwrap().to_string();
                seen.push(message);
                let mut say = async |value: Value| ws.send(Message::text(value.to_string())).await;
                match kind.as_str() {
                    "connection_init" => {
                        say(json!({"type": "ping"})).await.unwrap();
                        say(json!({"type": "connection_ack"})).await.unwrap();
                    }
                    "subscribe" | "start" => {
                        let result = if legacy { "data" } else { "next" };
                        for n in 1..=2 {
                            let payload = json!({"data": {"tick": n}});
                            say(json!({"id": "1", "type": result, "payload": payload}))
                                .await
                                .unwrap();
                        }
                        if !endless {
                            say(json!({"id": "1", "type": "complete"})).await.unwrap();
                        }
                    }
                    _ => {}
                }
            }
            seen
        });
        (url, task)
    }

    fn watching() -> (
        Watch,
        Cancel,
        tokio::sync::mpsc::UnboundedReceiver<SendEvent>,
    ) {
        let (events, seen) = tokio::sync::mpsc::unbounded_channel();
        let cancel = Cancel::default();
        let watch = Watch::new(
            move |event| {
                let _ = events.send(event);
            },
            cancel.clone(),
        );
        (watch, cancel, seen)
    }

    #[test]
    fn tells_a_subscription_from_other_operations() {
        let mut request = Request::new("POST", "http://x");
        request.body_mode = Some(BodyMode::GraphQl);
        request.body = Some("query A { a } subscription B { b }".into());
        assert!(!is_subscription(&request));
        request.graphql_operation = Some("B".into());
        assert!(is_subscription(&request));
        request.body = Some("subscription { b }".into());
        request.graphql_operation = None;
        assert!(is_subscription(&request));
        request.body_mode = Some(BodyMode::Raw);
        assert!(!is_subscription(&request));
    }

    #[tokio::test]
    async fn subscribes_over_a_websocket_until_the_server_completes() {
        let (url, server) = server(MODERN, false).await;
        let (watch, _, mut seen) = watching();
        let variables = [Variable::new("times", "2")];
        let sent = send_watched(
            &subscription(&url),
            &variables,
            &SendOptions::default(),
            &[],
            &watch,
        )
        .await
        .unwrap();

        assert_eq!(sent.response.status, 101);
        assert_eq!(
            sent.response.body,
            "event: next\ndata: {\"data\":{\"tick\":1}}\n\n\
             event: next\ndata: {\"data\":{\"tick\":2}}\n\n"
        );
        assert!(
            sent.response
                .headers
                .iter()
                .any(|h| h.value == "text/event-stream")
        );
        assert_eq!(sent.exchanges.len(), 1);
        // The results were reported one by one, after the head.
        assert!(matches!(
            seen.recv().await,
            Some(SendEvent::Head { status: 101, .. })
        ));
        assert!(matches!(
            seen.recv().await,
            Some(SendEvent::Body { received: 39, .. })
        ));

        let messages = server.await.unwrap();
        let kinds: Vec<&str> = messages
            .iter()
            .map(|m| m["type"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, ["connection_init", "pong", "subscribe"]);
        assert_eq!(messages[0]["payload"]["Authorization"], "Bearer t0k");
        assert_eq!(messages[2]["payload"]["variables"], json!({"n": 2}));
        assert!(
            messages[2]["payload"]["query"]
                .as_str()
                .unwrap()
                .contains("tick")
        );
    }

    #[tokio::test]
    async fn speaks_the_older_protocol_and_stops_when_told() {
        let (url, server) = server(LEGACY, true).await;
        let (watch, cancel, mut seen) = watching();
        let request = subscription(&url);
        let variables = [Variable::new("times", "2")];
        let send = tokio::spawn(async move {
            send_watched(&request, &variables, &SendOptions::default(), &[], &watch).await
        });
        let mut results = 0;
        while results < 2 {
            if let SendEvent::Body { .. } = seen.recv().await.unwrap() {
                results += 1;
            }
        }
        assert!(!send.is_finished());
        cancel.cancel();
        let sent = send.await.unwrap().unwrap();
        assert_eq!(sent.response.body.matches("event: next").count(), 2);

        let messages = server.await.unwrap();
        let kinds: Vec<&str> = messages
            .iter()
            .map(|m| m["type"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, ["connection_init", "pong", "start", "stop"]);
    }

    #[tokio::test]
    async fn falls_back_to_an_event_stream_where_there_is_no_websocket() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/graphql", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let mut requests = Vec::new();
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buf = [0u8; 4096];
                let n = stream.read(&mut buf).unwrap();
                let raw = String::from_utf8_lossy(&buf[..n]).to_lowercase();
                let reply = if raw.contains("upgrade: websocket") {
                    "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        .to_string()
                } else {
                    let body = "event: next\ndata: {\"data\":{\"tick\":1}}\n\nevent: complete\n\n";
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\
                         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                };
                stream.write_all(reply.as_bytes()).unwrap();
                requests.push(raw);
            }
            requests
        });
        let variables = [Variable::new("times", "1")];
        let sent = send_watched(
            &subscription(&url),
            &variables,
            &SendOptions::default(),
            &[],
            &Watch::default(),
        )
        .await
        .unwrap();
        assert_eq!(sent.response.status, 200);
        assert!(sent.response.body.starts_with("event: next"));
        let requests = server.join().unwrap();
        assert!(requests[1].starts_with("post /graphql"));
        assert!(requests[1].contains("accept: text/event-stream"));
        assert!(requests[1].contains("\"variables\":{\"n\": 1}"));
    }

    #[tokio::test]
    async fn a_websocket_address_is_not_given_a_second_try() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("ws://{}/graphql", listener.local_addr().unwrap());
        drop(listener);
        let sent = send_watched(
            &subscription(&url),
            &[Variable::new("times", "1")],
            &SendOptions::default(),
            &[],
            &Watch::default(),
        )
        .await;
        assert!(
            matches!(sent, Err(Error::Connect(_) | Error::Http(_))),
            "{sent:?}"
        );
    }
}
