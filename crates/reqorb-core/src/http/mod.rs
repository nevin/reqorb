//! Sending HTTP requests: authorization, cookies, redirects and the record
//! of every exchange made along the way.

mod client;
pub(crate) mod cookies;
mod exchange;
mod watch;

#[cfg(test)]
mod tests;

use std::sync::Arc;
use std::time::Instant;

use self::client::client_for;

pub(crate) use exchange::{Transport, execute};
pub use watch::{Cancel, SendEvent, Watch};

use crate::auth::{self, AuthKind};
use crate::checks::{TestResult, capture, run_tests};
use crate::graphql::{self, graphql_errors};
use crate::script;
use crate::subscribe;
use crate::vars::resolve;
use crate::vault::LOCKED;
use crate::{
    BodyMode, Cookie, Error, Exchange, HttpMode, Request, RequestSettings, Response, SendOptions,
    Variable,
};

/// A response plus the variables that were referenced but not defined.
#[derive(Debug, Clone)]
pub struct Sent {
    pub response: Response,
    pub unresolved: Vec<String>,
    /// The cookie jar after the exchange, including anything the server set.
    pub cookies: Vec<Cookie>,
    /// Every HTTP exchange the send made, oldest first: redirects and
    /// authorization round trips as well as the final one.
    pub exchanges: Vec<Exchange>,
    /// How each of the request's tests came out.
    pub tests: Vec<TestResult>,
    /// Variables the request captured from the response, for later requests.
    pub captured: Vec<Variable>,
    /// Captures that found nothing, and why.
    pub capture_problems: Vec<String>,
    /// For a GraphQL request, the errors the response reports. A GraphQL
    /// server answers 200 even when the query failed.
    pub graphql_errors: Vec<String>,
    /// What the request's scripts printed with `console.log`.
    pub console: Vec<String>,
}

/// Substitutes `variables` into the request and sends it. Undefined
/// variables are sent as written, unless they leave the URL unusable, in
/// which case naming them is more helpful than a URL parse error.
pub async fn send_with(
    request: &Request,
    variables: &[Variable],
    options: &SendOptions,
    cookies: &[Cookie],
) -> Result<Sent, Error> {
    send_watched(request, variables, options, cookies, &Watch::default()).await
}

/// Like [`send_with`], reporting the response to `watch` as it arrives and
/// stopping when it says so.
pub async fn send_watched(
    request: &Request,
    variables: &[Variable],
    options: &SendOptions,
    cookies: &[Cookie],
    watch: &Watch,
) -> Result<Sent, Error> {
    // The script that prepares the request sees it as written, so that
    // what it sets can be used by the variables in it.
    let mut request = request.clone();
    let prepared = script::before(&mut request, variables)?;
    let variables: Vec<Variable> = prepared
        .set
        .iter()
        .chain(
            variables
                .iter()
                .filter(|v| !prepared.unset.contains(&v.key)),
        )
        .cloned()
        .collect();
    let (request, variables) = (&request, variables.as_slice());
    let resolved = resolve(request, variables);
    let unusable = match reqwest::Url::parse(&resolved.request.url) {
        Ok(url) => url
            .host_str()
            .is_some_and(|h| h.contains("{{") || h.contains("%7B%7B")),
        Err(_) => true,
    };
    if unusable && !resolved.unresolved.is_empty() {
        return Err(Error::UnresolvedVariables(resolved.unresolved));
    }
    // Sending the encrypted form of a credential would help nobody.
    let sent = &resolved.request;
    let locked = sent.url.contains(LOCKED)
        || sent.headers.iter().any(|h| h.value.contains(LOCKED))
        || sent.body.as_deref().is_some_and(|b| b.contains(LOCKED))
        || sent
            .auth
            .iter()
            .flat_map(|a| &a.params)
            .any(|p| p.value.contains(LOCKED));
    if locked {
        return Err(Error::Auth(
            "this request uses a credential that is still locked: its key could not be read \
             from the system keychain. Enter the value again, or open Settings to see why."
                .into(),
        ));
    }
    let mut jar: Vec<Cookie> = cookies
        .iter()
        .filter(|c| !c.value.starts_with(LOCKED))
        .cloned()
        .collect();
    let as_sent = resolved.request.clone();
    let (response, exchanges) = send_logged(resolved.request, options, &mut jar, watch).await?;
    let mut tests = run_tests(&request.tests, &response, variables);
    let (mut captured, capture_problems) = capture(&request.captures, &response);
    // The script that follows sees what the captures kept, and its own
    // tests and values come after theirs.
    let known: Vec<Variable> = captured.iter().chain(variables).cloned().collect();
    let judged = script::after(&as_sent, &response, &known);
    tests.extend(judged.tests);
    // What either script set is kept as a capture is; the last word on a
    // name is the one that stands.
    for variable in prepared.set.into_iter().rev().chain(judged.set) {
        captured.retain(|v| v.key != variable.key);
        captured.push(variable);
    }
    let console: Vec<String> = prepared.console.into_iter().chain(judged.console).collect();
    let graphql_errors = if request.effective_body_mode() == BodyMode::GraphQl {
        graphql_errors(&response.body)
    } else {
        Vec::new()
    };
    Ok(Sent {
        response,
        unresolved: resolved.unresolved,
        cookies: jar,
        exchanges,
        tests,
        captured,
        capture_problems,
        graphql_errors,
        console,
    })
}

/// Sends the request with default options.
pub async fn send(request: Request) -> Result<Response, Error> {
    send_opts(request, &SendOptions::default(), &mut Vec::new()).await
}

/// Sends the request, applying its authorization first. Types that need a
/// challenge from the server or a token take more than one round trip, all
/// of which count towards the reported time.
///
/// Matching cookies from `cookies` are sent, and the jar is updated with
/// whatever the server sets, including on redirects along the way.
pub async fn send_opts(
    request: Request,
    options: &SendOptions,
    cookies: &mut Vec<Cookie>,
) -> Result<Response, Error> {
    Ok(send_logged(request, options, cookies, &Watch::default())
        .await?
        .0)
}

/// Like [`send_opts`], also returning each exchange that took place.
pub(super) async fn send_logged(
    mut request: Request,
    options: &SendOptions,
    cookies: &mut Vec<Cookie>,
    watch: &Watch,
) -> Result<(Response, Vec<Exchange>), Error> {
    let auth = request.auth.take().unwrap_or_default();
    // A request with no settings of its own follows the app's.
    let settings = request.settings.take().unwrap_or_else(|| RequestSettings {
        verify_ssl: options.verify_ssl,
        follow_redirects: options.follow_redirects,
        ..RequestSettings::default()
    });
    request.timeout_ms = request.timeout_ms.or(options.timeout_ms);
    if options.no_cache && !request.has_header("cache-control") {
        request.add_header("Cache-Control", "no-cache");
    }
    graphql::check(&request)?;
    if subscribe::is_subscription(&request) {
        // A WebSocket is tried first, as most servers offer one; failing
        // that the subscription is asked for as a stream of events.
        let mut over_ws = request.clone();
        over_ws.auth = Some(auth.clone());
        over_ws.settings = Some(settings.clone());
        match subscribe::over_websocket(&over_ws, watch).await {
            Ok(Some(done)) => return Ok(done),
            Ok(None) => {}
            // Authorization that a handshake cannot carry.
            Err(Error::Auth(_)) if !request.url.trim_start().starts_with("ws") => {}
            Err(e) => return Err(e),
        }
        if !request.has_header("accept") {
            request.add_header("Accept", "text/event-stream");
        }
    }
    request.materialize();
    let http_mode = settings.http_mode.unwrap_or(options.http_mode);
    let use_jar = !settings.disable_cookie_jar;

    let jar = use_jar.then(|| Arc::new(cookies::Jar::new(cookies)));
    let client = client_for(
        &settings,
        http_mode,
        &options.proxy,
        auth.kind == AuthKind::Ntlm,
    )?;
    let transport = Transport::new(
        client,
        settings,
        jar.clone(),
        options.max_response_bytes,
        options.files.clone(),
        watch.clone(),
    );

    let started = Instant::now();
    let result = if auth::sign(&mut request, &auth, &auth::Clock::now())? {
        execute(&transport, &request).await
    } else {
        auth::negotiate(&transport, request, &auth).await
    };
    if let Some(jar) = jar {
        *cookies = jar.snapshot();
    }
    match result {
        Ok(mut response) => {
            response.elapsed_ms = started.elapsed().as_millis() as u64;
            Ok((response, transport.take_log()))
        }
        // A server that only speaks HTTP/1.1 fails in ways that do not name the cause.
        Err(Error::Http(message)) if http_mode == HttpMode::Http2 => Err(Error::Http(format!(
            "{message} (HTTP/2 is forced in settings; the server may only support HTTP/1.1)"
        ))),
        Err(e) => Err(e),
    }
}
