//! WebSocket connections: connect, exchange messages, close.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::{self, Message};
use tokio_tungstenite::{Connector, connect_async_tls_with_config};

use crate::{Error, Header, Request, Variable, auth, resolve};

/// How long to wait for the server to accept the connection.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WsEventKind {
    /// The server accepted the connection.
    Open,
    /// A text message arrived.
    Text,
    /// A binary message arrived.
    Binary,
    Ping,
    Pong,
    /// The connection ended, by either side.
    Closed,
    /// The connection failed.
    Error,
}

/// Something that happened on a connection. Which fields are filled
/// depends on `kind`; the rest are empty.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WsEvent {
    pub kind: WsEventKind,
    /// A text message, the reason given for closing, or an error message.
    pub text: String,
    /// The bytes of a binary message, ping or pong.
    pub data: Vec<u8>,
    /// The HTTP status of the handshake, or the close code.
    pub code: u16,
    /// The handshake response headers, on `Open`.
    pub headers: Vec<Header>,
    /// When it happened, in milliseconds since the Unix epoch.
    pub at_ms: u64,
}

impl WsEvent {
    fn new(kind: WsEventKind) -> Self {
        Self {
            kind,
            text: String::new(),
            data: Vec::new(),
            code: 0,
            headers: Vec::new(),
            at_ms: crate::time::now_ms(),
        }
    }

    /// An `Error` event, for a connection that could not be opened.
    pub fn failed(message: impl Into<String>) -> Self {
        Self::text(WsEventKind::Error, message)
    }

    fn text(kind: WsEventKind, text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            ..Self::new(kind)
        }
    }
}

enum Command {
    Text(String),
    Binary(Vec<u8>),
    Close,
}

/// Sends on an open connection. Dropping every handle closes it.
#[derive(Clone)]
pub struct WsHandle {
    commands: mpsc::UnboundedSender<Command>,
}

impl WsHandle {
    /// Each returns false once the connection has ended.
    pub fn send_text(&self, text: impl Into<String>) -> bool {
        self.commands.send(Command::Text(text.into())).is_ok()
    }

    pub fn send_binary(&self, data: Vec<u8>) -> bool {
        self.commands.send(Command::Binary(data)).is_ok()
    }

    pub fn close(&self) -> bool {
        self.commands.send(Command::Close).is_ok()
    }
}

/// Opens a WebSocket to the request's URL, sending its headers and
/// authorization with the handshake. `http://` and `https://` addresses are
/// read as `ws://` and `wss://`.
///
/// Events arrive on the returned receiver, starting with `Open` and ending
/// with `Closed` or `Error`.
pub async fn ws_connect(
    request: &Request,
    variables: &[Variable],
) -> Result<(WsHandle, mpsc::UnboundedReceiver<WsEvent>), Error> {
    let resolved = resolve(request, variables);
    if !resolved.unresolved.is_empty() && resolved.request.url.contains("{{") {
        return Err(Error::UnresolvedVariables(resolved.unresolved));
    }
    let mut request = resolved.request;
    let verify = request.settings.as_ref().is_none_or(|s| s.verify_ssl);
    let wait = request
        .timeout_ms
        .map_or(CONNECT_TIMEOUT, Duration::from_millis);

    let written = request.url.clone();
    let invalid = |reason: String| Error::InvalidUrl {
        url: written.clone(),
        reason,
    };
    let mut url = reqwest::Url::parse(&request.url).map_err(|e| invalid(e.to_string()))?;
    let scheme = match url.scheme() {
        "ws" | "http" => "ws",
        "wss" | "https" => "wss",
        other => return Err(invalid(format!("`{other}` is not a WebSocket scheme"))),
    };
    // `set_scheme` refuses to move between special and non-special schemes.
    let rest = url.as_str().split_once(':').map_or("", |(_, rest)| rest);
    url = reqwest::Url::parse(&format!("{scheme}:{rest}")).map_err(|e| invalid(e.to_string()))?;
    request.url = url.to_string();

    // Only authorization that is a matter of adding headers or query
    // parameters fits a handshake.
    request.method = "GET".into();
    if let Some(auth) = request.auth.take()
        && !auth::sign(&mut request, &auth, &auth::Clock::now())?
    {
        return Err(Error::Auth(
            "this authorization type needs extra HTTP round trips, which a WebSocket \
             handshake cannot make; use a header-based type instead"
                .into(),
        ));
    }

    let mut handshake = request
        .url
        .as_str()
        .into_client_request()
        .map_err(|e| invalid(e.to_string()))?;
    for header in &request.headers {
        let name = HeaderName::from_bytes(header.name.as_bytes())
            .map_err(|_| Error::Http(format!("`{}` is not a valid header name", header.name)))?;
        let value = HeaderValue::from_str(&header.value)
            .map_err(|_| Error::Http(format!("header `{}` has an invalid value", header.name)))?;
        handshake.headers_mut().append(name, value);
    }

    let connector = if scheme == "wss" {
        Some(Connector::Rustls(Arc::new(tls_config(verify)?)))
    } else {
        None
    };
    let connecting = connect_async_tls_with_config(handshake, None, false, connector);
    let (stream, response) = match tokio::time::timeout(wait, connecting).await {
        Err(_) => return Err(Error::Timeout),
        Ok(Err(e)) => return Err(describe(e)),
        Ok(Ok(connected)) => connected,
    };

    let (commands, mut pending) = mpsc::unbounded_channel();
    let (events, receiver) = mpsc::unbounded_channel();
    let _ = events.send(WsEvent {
        code: response.status().as_u16(),
        text: response
            .status()
            .canonical_reason()
            .unwrap_or_default()
            .to_string(),
        headers: response
            .headers()
            .iter()
            .map(|(name, value)| Header {
                name: name.to_string(),
                value: String::from_utf8_lossy(value.as_bytes()).into_owned(),
            })
            .collect(),
        ..WsEvent::new(WsEventKind::Open)
    });

    tokio::spawn(async move {
        let (mut sink, mut stream) = stream.split();
        let ended = loop {
            tokio::select! {
                command = pending.recv() => {
                    let sent = match command {
                        Some(Command::Text(text)) => sink.send(Message::text(text)).await,
                        Some(Command::Binary(data)) => sink.send(Message::binary(data)).await,
                        // Asked to close, or nobody is left to send anything.
                        Some(Command::Close) | None => {
                            let _ = sink.send(Message::Close(None)).await;
                            // The server's reply, read below, ends the loop.
                            pending.close();
                            Ok(())
                        }
                    };
                    if let Err(e) = sent {
                        break closed_or_error(e);
                    }
                    if pending.is_closed() && pending.is_empty() {
                        // Give the server a moment to acknowledge the close.
                        let reply = tokio::time::timeout(Duration::from_secs(3), async {
                            while let Some(Ok(message)) = stream.next().await {
                                if let Message::Close(frame) = message {
                                    return frame;
                                }
                            }
                            None
                        })
                        .await;
                        break closed(reply.ok().flatten(), "closed by you");
                    }
                }
                message = stream.next() => {
                    let event = match message {
                        Some(Ok(Message::Text(text))) => {
                            WsEvent::text(WsEventKind::Text, text.as_str())
                        }
                        Some(Ok(Message::Binary(data))) => WsEvent {
                            data: data.to_vec(),
                            ..WsEvent::new(WsEventKind::Binary)
                        },
                        Some(Ok(Message::Ping(data))) => WsEvent {
                            data: data.to_vec(),
                            ..WsEvent::new(WsEventKind::Ping)
                        },
                        Some(Ok(Message::Pong(data))) => WsEvent {
                            data: data.to_vec(),
                            ..WsEvent::new(WsEventKind::Pong)
                        },
                        Some(Ok(Message::Close(frame))) => break closed(frame, "closed by the server"),
                        Some(Ok(Message::Frame(_))) => continue,
                        Some(Err(e)) => break closed_or_error(e),
                        None => break closed(None, "the server went away"),
                    };
                    if events.send(event).is_err() {
                        // Nobody is listening any more.
                        let _ = sink.send(Message::Close(None)).await;
                        return;
                    }
                }
            }
        };
        let _ = events.send(ended);
    });

    Ok((WsHandle { commands }, receiver))
}

fn closed(frame: Option<CloseFrame>, fallback: &str) -> WsEvent {
    match frame {
        Some(frame) => WsEvent {
            code: frame.code.into(),
            text: if frame.reason.is_empty() {
                fallback.to_string()
            } else {
                frame.reason.to_string()
            },
            ..WsEvent::new(WsEventKind::Closed)
        },
        None => WsEvent::text(WsEventKind::Closed, fallback),
    }
}

fn closed_or_error(error: tungstenite::Error) -> WsEvent {
    match error {
        tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed => {
            closed(None, "connection closed")
        }
        other => WsEvent::text(WsEventKind::Error, describe(other).to_string()),
    }
}

/// Says what went wrong with a connection in terms of what to check.
fn describe(error: tungstenite::Error) -> Error {
    match error {
        tungstenite::Error::Http(response) => Error::Http(format!(
            "the server answered {} instead of upgrading to a WebSocket; \
             check the address and any headers it requires",
            response.status()
        )),
        tungstenite::Error::Io(e) => Error::Connect(e.to_string()),
        tungstenite::Error::Tls(e) => Error::Connect(format!("TLS failed: {e}")),
        other => Error::Http(other.to_string()),
    }
}

fn tls_config(verify: bool) -> Result<rustls::ClientConfig, Error> {
    use rustls_platform_verifier::BuilderVerifierExt;

    let failed = |e: rustls::Error| Error::Connect(format!("TLS setup failed: {e}"));
    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let builder = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .map_err(failed)?;
    if verify {
        // The operating system's trust store, as for HTTP requests.
        return Ok(builder
            .with_platform_verifier()
            .map_err(failed)?
            .with_no_client_auth());
    }
    Ok(builder
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyCertificate(provider)))
        .with_no_client_auth())
}

/// Used when certificate verification is switched off for a request.
#[derive(Debug)]
struct AcceptAnyCertificate(Arc<rustls::crypto::CryptoProvider>);

impl rustls::client::danger::ServerCertVerifier for AcceptAnyCertificate {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::AuthKind;
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::handshake::server::{
        Request as Hello, Response as Welcome,
    };

    /// Accepts one connection, reports the handshake headers it saw, and
    /// echoes text back in upper case until the client closes.
    #[allow(clippy::result_large_err)]
    async fn echo_server() -> (String, tokio::task::JoinHandle<Vec<(String, String)>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/chat?room=1", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut seen = Vec::new();
            let mut ws =
                tokio_tungstenite::accept_hdr_async(socket, |hello: &Hello, welcome: Welcome| {
                    seen.push(("path".to_string(), hello.uri().to_string()));
                    for (name, value) in hello.headers() {
                        seen.push((name.to_string(), value.to_str().unwrap_or("").to_string()));
                    }
                    Ok(welcome)
                })
                .await
                .unwrap();
            ws.send(Message::text("welcome")).await.unwrap();
            while let Some(Ok(message)) = ws.next().await {
                match message {
                    Message::Text(text) => {
                        ws.send(Message::text(text.to_uppercase())).await.unwrap();
                    }
                    Message::Binary(data) => ws.send(Message::binary(data)).await.unwrap(),
                    _ => {}
                }
            }
            seen
        });
        (url, server)
    }

    #[tokio::test]
    async fn connects_exchanges_messages_and_closes() {
        let (url, server) = echo_server().await;
        // Typed as an http address with a variable, as it might be saved.
        let mut request = Request::new("GET", url.replacen("ws://", "http://", 1));
        request.add_header("X-Client", "{{who}}");
        request.auth = Some(crate::Auth::new(AuthKind::Bearer, &[("token", "t0k")]));
        let (handle, mut events) = ws_connect(&request, &[Variable::new("who", "reqorb")])
            .await
            .unwrap();

        let open = events.recv().await.unwrap();
        assert_eq!((open.kind, open.code), (WsEventKind::Open, 101));
        assert!(open.headers.iter().any(|h| h.name == "upgrade"));
        assert_eq!(events.recv().await.unwrap().text, "welcome");

        assert!(handle.send_text("hello"));
        let reply = events.recv().await.unwrap();
        assert_eq!(
            (reply.kind, reply.text.as_str()),
            (WsEventKind::Text, "HELLO")
        );
        assert!(handle.send_binary(vec![1, 2, 3]));
        let reply = events.recv().await.unwrap();
        assert_eq!(
            (reply.kind, reply.data),
            (WsEventKind::Binary, vec![1, 2, 3])
        );

        assert!(handle.close());
        let closed = events.recv().await.unwrap();
        assert_eq!(closed.kind, WsEventKind::Closed);
        assert!(events.recv().await.is_none());

        let seen = server.await.unwrap();
        let header = |name: &str| {
            seen.iter()
                .find(|(n, _)| n == name)
                .map(|(_, v)| v.as_str())
        };
        assert_eq!(header("path"), Some("/chat?room=1"));
        assert_eq!(header("x-client"), Some("reqorb"));
        assert_eq!(header("authorization"), Some("Bearer t0k"));
    }

    #[tokio::test]
    async fn explains_a_server_that_is_not_a_websocket() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buffer = [0; 1024];
            let _ = socket.read(&mut buffer).await;
            let _ = socket
                .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
                .await;
        });
        let error = ws_connect(&Request::new("GET", url), &[])
            .await
            .err()
            .unwrap();
        assert!(error.to_string().contains("answered 404"), "{error}");

        let error = ws_connect(&Request::new("GET", "ftp://example.com"), &[])
            .await
            .err()
            .unwrap();
        assert!(
            error.to_string().contains("not a WebSocket scheme"),
            "{error}"
        );
    }
}
