//! The HTTP clients, shared between sends so that connections are reused.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use crate::{DisabledTls, Error, HttpMode, RequestSettings};

/// What makes one HTTP client differ from another.
#[derive(Clone, PartialEq, Eq, Hash)]
struct ClientKey {
    /// A client's connections belong to the runtime that opened them.
    runtime: tokio::runtime::Id,
    verify_ssl: bool,
    strict_http_parser: bool,
    disabled_tls: DisabledTls,
    http_mode: HttpMode,
}

/// Clients already built, so that sends with the same settings share
/// connections instead of each paying for a new handshake.
static CLIENTS: LazyLock<Mutex<HashMap<ClientKey, reqwest::Client>>> =
    LazyLock::new(Default::default);

/// The client for these settings, built on first use.
pub(super) fn client_for(
    settings: &RequestSettings,
    http_mode: HttpMode,
    own_connection: bool,
) -> Result<reqwest::Client, Error> {
    let key = ClientKey {
        runtime: tokio::runtime::Handle::current().id(),
        verify_ssl: settings.verify_ssl,
        strict_http_parser: settings.strict_http_parser,
        disabled_tls: settings.disabled_tls,
        http_mode,
    };
    if !own_connection && let Some(client) = CLIENTS.lock().unwrap().get(&key) {
        return Ok(client.clone());
    }

    // Headers the client would add are set on each request instead, so that
    // what is recorded as sent is what was sent. Redirects and cookies are
    // handled by `execute`, which knows the request's rules.
    let mut builder = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .danger_accept_invalid_certs(!settings.verify_ssl);
    if !settings.strict_http_parser {
        builder = builder
            .http1_ignore_invalid_headers_in_responses(true)
            .http1_allow_obsolete_multiline_headers_in_responses(true)
            .http1_allow_spaces_after_header_name_in_responses(true);
    }
    builder = match settings.disabled_tls {
        DisabledTls::None => builder,
        DisabledTls::Tls12 => builder.min_tls_version(reqwest::tls::Version::TLS_1_3),
        DisabledTls::Tls13 => builder.max_tls_version(reqwest::tls::Version::TLS_1_2),
    };
    builder = match http_mode {
        HttpMode::Auto => builder,
        HttpMode::Http1 => builder.http1_only(),
        // Speaks HTTP/2 from the first byte, with no fallback to HTTP/1.1.
        HttpMode::Http2 => builder.http2_prior_knowledge(),
    };
    if own_connection {
        // NTLM authenticates a connection, so every step must reuse the same
        // one, and no other send may be handed it afterwards.
        return Ok(builder.pool_max_idle_per_host(1).build()?);
    }
    let client = builder.build()?;
    CLIENTS.lock().unwrap().insert(key, client.clone());
    Ok(client)
}
