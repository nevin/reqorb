//! gRPC calls without generated code: the service's schema comes from the
//! server's reflection service or a `.proto` file, and messages are JSON.

use std::path::Path;
use std::time::{Duration, Instant};

use prost::Message as _;
use prost_reflect::{DescriptorPool, DynamicMessage, MessageDescriptor, SerializeOptions};
use serde::{Deserialize, Serialize};
use tonic::codec::{Codec, DecodeBuf, Decoder, EncodeBuf, Encoder};
use tonic::metadata::{KeyAndValueRef, MetadataKey, MetadataMap, MetadataValue};
use tonic::transport::{Channel, ClientTlsConfig, Endpoint};
use tonic::{Code, Status};

use crate::http::Cancel;
use crate::{Auth, Error, Header, Request, Variable, auth, vars};

/// A method a gRPC server offers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GrpcMethod {
    /// `package.Service/Method`, which is how a call names it.
    pub path: String,
    pub client_streaming: bool,
    pub server_streaming: bool,
    /// The request message with every field at its default, as JSON to
    /// start editing from.
    pub example: String,
}

/// What is known about a server's services.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct GrpcSchema {
    pub methods: Vec<GrpcMethod>,
    /// The descriptors, encoded, to pass back when making a call.
    pub descriptors: Vec<u8>,
}

/// One call to make.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct GrpcCall {
    /// `host:port`, or with `http://`, `https://`, `grpc://` or `grpcs://`.
    /// Without a scheme the connection is not encrypted.
    pub url: String,
    /// `package.Service/Method`.
    pub method: String,
    /// Request messages as JSON; more than one for a client stream.
    pub messages: Vec<String>,
    pub metadata: Vec<Header>,
    pub auth: Option<Auth>,
    /// From [`GrpcSchema::descriptors`].
    pub descriptors: Vec<u8>,
    pub timeout_ms: Option<u64>,
}

/// How a call went.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GrpcReply {
    /// The gRPC status code; 0 is OK.
    pub code: i32,
    /// The name of the code, such as `OK` or `NOT_FOUND`.
    pub status: String,
    /// The server's explanation when the call failed.
    pub message: String,
    /// Response messages as JSON; more than one for a server stream.
    pub messages: Vec<String>,
    pub headers: Vec<Header>,
    pub trailers: Vec<Header>,
    pub elapsed_ms: u64,
}

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

fn grpc_error(what: &str, status: &Status) -> Error {
    Error::Http(format!(
        "{what}: {} {}",
        code_name(status.code()),
        status.message()
    ))
}

/// The conventional upper-case name of a status code.
fn code_name(code: Code) -> &'static str {
    match code {
        Code::Ok => "OK",
        Code::Cancelled => "CANCELLED",
        Code::Unknown => "UNKNOWN",
        Code::InvalidArgument => "INVALID_ARGUMENT",
        Code::DeadlineExceeded => "DEADLINE_EXCEEDED",
        Code::NotFound => "NOT_FOUND",
        Code::AlreadyExists => "ALREADY_EXISTS",
        Code::PermissionDenied => "PERMISSION_DENIED",
        Code::ResourceExhausted => "RESOURCE_EXHAUSTED",
        Code::FailedPrecondition => "FAILED_PRECONDITION",
        Code::Aborted => "ABORTED",
        Code::OutOfRange => "OUT_OF_RANGE",
        Code::Unimplemented => "UNIMPLEMENTED",
        Code::Internal => "INTERNAL",
        Code::Unavailable => "UNAVAILABLE",
        Code::DataLoss => "DATA_LOSS",
        Code::Unauthenticated => "UNAUTHENTICATED",
    }
}

async fn connect(url: &str, timeout: Duration) -> Result<Channel, Error> {
    connect_for(url, timeout, Some(timeout)).await
}

/// Connects within `timeout`. Each call on the channel is given `each` to
/// finish in, or as long as it takes when that is `None`.
async fn connect_for(
    url: &str,
    timeout: Duration,
    each: Option<Duration>,
) -> Result<Channel, Error> {
    let url = url.trim();
    let invalid = |reason: String| Error::InvalidUrl {
        url: url.to_string(),
        reason,
    };
    let address = match url.split_once("://") {
        Some(("grpc", rest)) => format!("http://{rest}"),
        Some(("grpcs", rest)) => format!("https://{rest}"),
        Some(("http" | "https", _)) => url.to_string(),
        Some((other, _)) => return Err(invalid(format!("`{other}` is not a gRPC scheme"))),
        None => format!("http://{url}"),
    };
    let mut endpoint = Endpoint::from_shared(address.clone())
        .map_err(|e| invalid(e.to_string()))?
        .connect_timeout(timeout);
    if let Some(each) = each {
        endpoint = endpoint.timeout(each);
    }
    if address.starts_with("https://") {
        endpoint = endpoint
            .tls_config(ClientTlsConfig::new().with_native_roots())
            .map_err(|e| Error::Connect(format!("TLS setup failed: {e}")))?;
    }
    endpoint.connect().await.map_err(|e| {
        // The useful part is usually the innermost cause.
        let mut cause: &dyn std::error::Error = &e;
        while let Some(next) = cause.source() {
            cause = next;
        }
        Error::Connect(format!("cannot reach {url}: {cause}"))
    })
}

/// Call metadata from headers and header-based authorization.
fn metadata(
    url: &str,
    headers: &[Header],
    auth: Option<&Auth>,
    variables: &[Variable],
) -> Result<MetadataMap, Error> {
    let mut carrier = Request::new("POST", format!("http://{url}"));
    carrier.headers = headers
        .iter()
        .map(|h| Header {
            name: vars::fill(&h.name, variables),
            value: vars::fill(&h.value, variables),
        })
        .collect();
    if let Some(auth) = auth {
        let mut auth = auth.clone();
        for param in &mut auth.params {
            param.value = vars::fill(&param.value, variables);
        }
        if !auth::sign(&mut carrier, &auth, &auth::Clock::now())? {
            return Err(Error::Auth(
                "this authorization type needs extra HTTP round trips, which a gRPC call \
                 cannot make; use a header-based type instead"
                    .into(),
            ));
        }
    }
    let mut map = MetadataMap::new();
    for header in &carrier.headers {
        let bad = || Error::Http(format!("`{}` cannot be sent as metadata", header.name));
        let key = MetadataKey::from_bytes(header.name.to_ascii_lowercase().as_bytes())
            .map_err(|_| bad())?;
        let value: MetadataValue<_> = header.value.parse().map_err(|_| bad())?;
        map.append(key, value);
    }
    Ok(map)
}

fn headers_of(map: &MetadataMap) -> Vec<Header> {
    map.iter()
        .map(|entry| match entry {
            KeyAndValueRef::Ascii(key, value) => Header {
                name: key.to_string(),
                value: value.to_str().unwrap_or_default().to_string(),
            },
            KeyAndValueRef::Binary(key, value) => Header {
                name: key.to_string(),
                value: format!("{value:?}"),
            },
        })
        .collect()
}

// ------------------------------------------------------------------ schema

fn schema(pool: &DescriptorPool) -> GrpcSchema {
    let options = SerializeOptions::new().skip_default_fields(false);
    let mut methods = Vec::new();
    for service in pool.services() {
        // The reflection service describes others; it is not one to test.
        if service.full_name().starts_with("grpc.reflection.") {
            continue;
        }
        for method in service.methods() {
            let blank = DynamicMessage::new(method.input());
            let mut example = Vec::new();
            let mut writer = serde_json::Serializer::pretty(&mut example);
            let _ = blank.serialize_with_options(&mut writer, &options);
            methods.push(GrpcMethod {
                path: format!("{}/{}", service.full_name(), method.name()),
                client_streaming: method.is_client_streaming(),
                server_streaming: method.is_server_streaming(),
                example: String::from_utf8(example).unwrap_or_else(|_| "{}".into()),
            });
        }
    }
    methods.sort_by(|a, b| a.path.cmp(&b.path));
    GrpcSchema {
        methods,
        descriptors: pool.encode_to_vec(),
    }
}

/// Reads the services a `.proto` file defines. Imports are looked for
/// beside the file.
pub fn grpc_load_proto(path: &str) -> Result<GrpcSchema, Error> {
    let file = Path::new(path.trim());
    let folder = file.parent().filter(|p| !p.as_os_str().is_empty());
    let name = file
        .file_name()
        .ok_or_else(|| Error::Io(format!("`{path}` is not a file")))?;
    let set = protox::compile([name], [folder.unwrap_or(Path::new("."))])
        .map_err(|e| Error::Format(format!("{}: {e}", file.display())))?;
    let pool = DescriptorPool::from_file_descriptor_set(set)
        .map_err(|e| Error::Format(format!("{}: {e}", file.display())))?;
    let found = schema(&pool);
    if found.methods.is_empty() {
        return Err(Error::Format(format!(
            "{} defines no services",
            file.display()
        )));
    }
    Ok(found)
}

/// Generates a reflection client for one version of the reflection
/// protocol; the two versions differ only in their package name.
macro_rules! reflection_client {
    ($name:ident, $pb:path) => {
        async fn $name(
            channel: Channel,
            metadata: &MetadataMap,
        ) -> Result<Vec<prost_types::FileDescriptorProto>, Status> {
            use pb::server_reflection_request::MessageRequest;
            use pb::server_reflection_response::MessageResponse;
            use $pb as pb;

            let mut client = pb::server_reflection_client::ServerReflectionClient::new(channel);
            let mut ask = async |question: MessageRequest| -> Result<MessageResponse, Status> {
                let mut request =
                    tonic::Request::new(tokio_stream::once(pb::ServerReflectionRequest {
                        host: String::new(),
                        message_request: Some(question),
                    }));
                *request.metadata_mut() = metadata.clone();
                let mut answers = client.server_reflection_info(request).await?.into_inner();
                match answers.message().await?.and_then(|a| a.message_response) {
                    Some(MessageResponse::ErrorResponse(e)) => {
                        Err(Status::new(Code::from_i32(e.error_code), e.error_message))
                    }
                    Some(answer) => Ok(answer),
                    None => Err(Status::unknown("the server sent no reflection answer")),
                }
            };

            let MessageResponse::ListServicesResponse(listed) =
                ask(MessageRequest::ListServices(String::new())).await?
            else {
                return Err(Status::unknown("unexpected reflection answer"));
            };
            let mut files: Vec<prost_types::FileDescriptorProto> = Vec::new();
            let mut wanted: Vec<MessageRequest> = listed
                .service
                .into_iter()
                .map(|s| MessageRequest::FileContainingSymbol(s.name))
                .collect();
            while let Some(question) = wanted.pop() {
                if let MessageRequest::FileByFilename(name) = &question
                    && files.iter().any(|f| f.name() == name)
                {
                    continue;
                }
                let MessageResponse::FileDescriptorResponse(answer) = ask(question).await? else {
                    return Err(Status::unknown("unexpected reflection answer"));
                };
                for bytes in answer.file_descriptor_proto {
                    let file = prost_types::FileDescriptorProto::decode(bytes.as_slice())
                        .map_err(|e| Status::data_loss(e.to_string()))?;
                    if files.iter().any(|f| f.name() == file.name()) {
                        continue;
                    }
                    // Whatever the file imports is needed as well.
                    for dependency in &file.dependency {
                        wanted.push(MessageRequest::FileByFilename(dependency.clone()));
                    }
                    files.push(file);
                }
            }
            Ok(files)
        }
    };
}

reflection_client!(reflect_v1, tonic_reflection::pb::v1);
reflection_client!(reflect_v1alpha, tonic_reflection::pb::v1alpha);

/// Asks the server which services it offers, through gRPC server
/// reflection. Servers that do not enable reflection need a `.proto` file
/// instead.
pub async fn grpc_reflect(
    url: &str,
    headers: &[Header],
    auth: Option<&Auth>,
    variables: &[Variable],
) -> Result<GrpcSchema, Error> {
    let url = vars::fill(url, variables);
    let metadata = metadata(&url, headers, auth, variables)?;
    let channel = connect(&url, DEFAULT_TIMEOUT).await?;
    let files = match reflect_v1(channel.clone(), &metadata).await {
        // Older servers only speak the earlier version of the protocol.
        Err(status) if status.code() == Code::Unimplemented => {
            reflect_v1alpha(channel, &metadata).await
        }
        other => other,
    }
    .map_err(|status| match status.code() {
        Code::Unimplemented => Error::Http(
            "this server does not offer reflection; choose its .proto file instead".into(),
        ),
        _ => grpc_error("reflection failed", &status),
    })?;

    let set = prost_types::FileDescriptorSet { file: files };
    let pool = DescriptorPool::from_file_descriptor_set(set)
        .map_err(|e| Error::Format(format!("the server's descriptors are not usable: {e}")))?;
    Ok(schema(&pool))
}

// -------------------------------------------------------------------- call

/// Encodes and decodes messages described at run time.
#[derive(Clone)]
struct DynamicCodec(MessageDescriptor);

impl Codec for DynamicCodec {
    type Encode = DynamicMessage;
    type Decode = DynamicMessage;
    type Encoder = Self;
    type Decoder = Self;

    fn encoder(&mut self) -> Self {
        self.clone()
    }

    fn decoder(&mut self) -> Self {
        self.clone()
    }
}

impl Encoder for DynamicCodec {
    type Item = DynamicMessage;
    type Error = Status;

    fn encode(&mut self, item: DynamicMessage, buffer: &mut EncodeBuf<'_>) -> Result<(), Status> {
        item.encode(buffer)
            .map_err(|e| Status::internal(e.to_string()))
    }
}

impl Decoder for DynamicCodec {
    type Item = DynamicMessage;
    type Error = Status;

    fn decode(&mut self, buffer: &mut DecodeBuf<'_>) -> Result<Option<DynamicMessage>, Status> {
        DynamicMessage::decode(self.0.clone(), buffer)
            .map(Some)
            .map_err(|e| Status::internal(format!("cannot decode the response: {e}")))
    }
}

/// Makes a call and waits for it to finish. Every message in the call is
/// sent, then every response is collected, so all four kinds of method
/// work: unary, and client, server or two-way streaming.
pub async fn grpc_call(call: &GrpcCall, variables: &[Variable]) -> Result<GrpcReply, Error> {
    grpc_call_watched(call, variables, &|_| {}, &Cancel::default()).await
}

/// Like [`grpc_call`], handing each response to `on_message` as it arrives
/// and ending the call when `cancel` says so. A call that is stopped ends
/// with the responses it had, under the status `CANCELLED`. A server
/// stream is given as long as it takes unless the call sets a timeout.
pub async fn grpc_call_watched(
    call: &GrpcCall,
    variables: &[Variable],
    on_message: &(dyn Fn(&str) + Send + Sync),
    cancel: &Cancel,
) -> Result<GrpcReply, Error> {
    let url = vars::fill(&call.url, variables);
    let pool = DescriptorPool::decode(call.descriptors.as_slice())
        .map_err(|_| Error::Format("load the server's methods before making a call".into()))?;
    let (service, name) = call.method.rsplit_once('/').ok_or_else(|| {
        Error::Format(format!(
            "`{}` should look like package.Service/Method",
            call.method
        ))
    })?;
    let method = pool
        .get_service_by_name(service)
        .and_then(|s| s.methods().find(|m| m.name() == name))
        .ok_or_else(|| {
            Error::Format(format!(
                "the loaded methods do not include `{}`; load them again",
                call.method
            ))
        })?;

    let texts: Vec<String> = match call.messages.as_slice() {
        [] => vec!["{}".to_string()],
        given => given.iter().map(|m| vars::fill(m, variables)).collect(),
    };
    if !method.is_client_streaming() && texts.len() > 1 {
        return Err(Error::Format(format!(
            "`{}` takes one message, not {}",
            call.method,
            texts.len()
        )));
    }
    let mut messages = Vec::new();
    for (i, text) in texts.iter().enumerate() {
        let text = if text.trim().is_empty() { "{}" } else { text };
        let mut reader = serde_json::Deserializer::from_str(text);
        let message = DynamicMessage::deserialize(method.input(), &mut reader)
            .and_then(|message| reader.end().map(|()| message))
            .map_err(|e| {
                Error::Format(format!(
                    "message {} does not match {}: {e}",
                    i + 1,
                    method.input().full_name()
                ))
            })?;
        messages.push(message);
    }

    let timeout = call
        .timeout_ms
        .map_or(DEFAULT_TIMEOUT, Duration::from_millis);
    let mut request = tonic::Request::new(tokio_stream::iter(messages));
    *request.metadata_mut() = metadata(&url, &call.metadata, call.auth.as_ref(), variables)?;
    let path = format!("/{}", call.method)
        .parse()
        .map_err(|_| Error::Format(format!("`{}` is not a valid method name", call.method)))?;

    let started = Instant::now();
    let each = match call.timeout_ms {
        None if method.is_server_streaming() => None,
        _ => Some(timeout),
    };
    let channel = connect_for(&url, timeout, each).await?;
    let mut client = tonic::client::Grpc::new(channel);
    client
        .ready()
        .await
        .map_err(|e| Error::Connect(e.to_string()))?;

    let options = SerializeOptions::new().skip_default_fields(false);
    let mut reply = GrpcReply {
        code: 0,
        status: code_name(Code::Ok).to_string(),
        message: String::new(),
        messages: Vec::new(),
        headers: Vec::new(),
        trailers: Vec::new(),
        elapsed_ms: 0,
    };
    let fail = |reply: &mut GrpcReply, status: &Status| {
        reply.code = status.code() as i32;
        reply.status = code_name(status.code()).to_string();
        reply.message = status.message().to_string();
        reply.trailers = headers_of(status.metadata());
    };
    let stopped = Status::cancelled("stopped before the call ended");
    let begun = tokio::select! {
        begun = client.streaming(request, path, DynamicCodec(method.output())) => Some(begun),
        _ = cancel.cancelled() => None,
    };
    match begun {
        None => fail(&mut reply, &stopped),
        Some(Err(status)) => fail(&mut reply, &status),
        Some(Ok(response)) => {
            reply.headers = headers_of(response.metadata());
            let mut stream = response.into_inner();
            loop {
                let next = tokio::select! {
                    next = stream.message() => next,
                    _ = cancel.cancelled() => Err(stopped.clone()),
                };
                match next {
                    Ok(Some(message)) => {
                        let mut json = Vec::new();
                        let mut writer = serde_json::Serializer::pretty(&mut json);
                        message
                            .serialize_with_options(&mut writer, &options)
                            .map_err(|e| Error::Format(e.to_string()))?;
                        let json = String::from_utf8_lossy(&json).into_owned();
                        on_message(&json);
                        reply.messages.push(json);
                    }
                    Ok(None) => {
                        if let Ok(Some(trailers)) = stream.trailers().await {
                            reply.trailers = headers_of(&trailers);
                        }
                        break;
                    }
                    Err(status) => {
                        fail(&mut reply, &status);
                        break;
                    }
                }
            }
        }
    }
    reply.elapsed_ms = started.elapsed().as_millis() as u64;
    Ok(reply)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    use tokio_stream::wrappers::TcpListenerStream;

    /// A server offering the standard health service, with reflection.
    async fn health_server() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap().to_string();
        let (reporter, health) = tonic_health::server::health_reporter();
        reporter
            .set_service_status("db", tonic_health::ServingStatus::NotServing)
            .await;
        let reflection = tonic_reflection::server::Builder::configure()
            .register_encoded_file_descriptor_set(tonic_health::pb::FILE_DESCRIPTOR_SET)
            .build_v1()
            .unwrap();
        tokio::spawn(
            tonic::transport::Server::builder()
                .add_service(health)
                .add_service(reflection)
                .serve_with_incoming(TcpListenerStream::new(listener)),
        );
        address
    }

    #[tokio::test]
    async fn follows_a_server_stream_and_stops_it() {
        let address = health_server().await;
        let schema = grpc_reflect(&address, &[], None, &[]).await.unwrap();
        let call = GrpcCall {
            url: address,
            method: "grpc.health.v1.Health/Watch".into(),
            messages: vec![r#"{"service": "db"}"#.into()],
            descriptors: schema.descriptors,
            ..GrpcCall::default()
        };
        // The stream reports the status now, and then only when it changes.
        let cancel = Cancel::default();
        let stop = cancel.clone();
        let reply = grpc_call_watched(
            &call,
            &[],
            &move |message| {
                assert!(message.contains("NOT_SERVING"));
                stop.cancel();
            },
            &cancel,
        )
        .await
        .unwrap();
        assert_eq!((reply.code, reply.status.as_str()), (1, "CANCELLED"));
        assert_eq!(reply.messages.len(), 1);
    }

    #[tokio::test]
    async fn reflects_and_calls_a_unary_method() {
        let address = health_server().await;
        let schema = grpc_reflect(&address, &[], None, &[]).await.unwrap();
        let paths: Vec<_> = schema.methods.iter().map(|m| m.path.as_str()).collect();
        assert_eq!(
            paths,
            ["grpc.health.v1.Health/Check", "grpc.health.v1.Health/Watch"]
        );
        assert!(!schema.methods[0].server_streaming && schema.methods[1].server_streaming);
        assert!(schema.methods[0].example.contains("\"service\": \"\""));

        let mut call = GrpcCall {
            url: "{{host}}".into(),
            method: "grpc.health.v1.Health/Check".into(),
            messages: vec![r#"{"service": "{{svc}}"}"#.into()],
            descriptors: schema.descriptors.clone(),
            ..GrpcCall::default()
        };
        let variables = [Variable::new("host", &address), Variable::new("svc", "db")];
        let reply = grpc_call(&call, &variables).await.unwrap();
        assert_eq!((reply.code, reply.status.as_str()), (0, "OK"));
        assert!(
            reply.messages[0].contains("NOT_SERVING"),
            "{:?}",
            reply.messages
        );

        // A failure the server reports is a reply, not an error.
        call.messages = vec![r#"{"service": "nope"}"#.into()];
        let reply = grpc_call(&call, &variables).await.unwrap();
        assert_eq!(reply.status, "NOT_FOUND");
        assert!(reply.messages.is_empty());

        // A message that does not fit the method is caught before sending.
        call.messages = vec![r#"{"servce": "db"}"#.into()];
        let error = grpc_call(&call, &variables).await.unwrap_err().to_string();
        assert!(
            error.contains("does not match grpc.health.v1.HealthCheckRequest"),
            "{error}"
        );
    }

    #[tokio::test]
    async fn reads_a_proto_file_and_explains_missing_reflection() {
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join("greeter.proto");
        std::fs::write(
            &file,
            r#"syntax = "proto3";
               package demo;
               message HelloRequest { string name = 1; repeated int32 lucky = 2; }
               message HelloReply { string text = 1; }
               service Greeter {
                 rpc Hello (HelloRequest) returns (HelloReply);
                 rpc Chat (stream HelloRequest) returns (stream HelloReply);
               }"#,
        )
        .unwrap();
        let schema = grpc_load_proto(file.to_str().unwrap()).unwrap();
        assert_eq!(schema.methods[0].path, "demo.Greeter/Chat");
        assert!(schema.methods[0].client_streaming && schema.methods[0].server_streaming);
        assert_eq!(schema.methods[1].path, "demo.Greeter/Hello");
        assert!(schema.methods[1].example.contains("\"lucky\": []"));

        let error = grpc_load_proto("/no/such.proto").unwrap_err().to_string();
        assert!(error.contains("such.proto"), "{error}");

        // The health server here is started without reflection.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap().to_string();
        let (_reporter, health) = tonic_health::server::health_reporter();
        tokio::spawn(
            tonic::transport::Server::builder()
                .add_service(health)
                .serve_with_incoming(TcpListenerStream::new(listener)),
        );
        let error = grpc_reflect(&address, &[], None, &[])
            .await
            .unwrap_err()
            .to_string();
        assert!(error.contains("does not offer reflection"), "{error}");
    }
}
