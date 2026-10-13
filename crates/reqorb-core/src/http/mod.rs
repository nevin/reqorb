//! Sending HTTP requests: authorization, cookies, redirects and the record
//! of every exchange made along the way.

mod client;
pub(crate) mod cookies;
mod exchange;

#[cfg(test)]
mod tests;

use std::sync::Arc;
use std::time::Instant;

use self::client::client_for;

pub(crate) use exchange::{Transport, execute};

use crate::auth::{self, AuthKind};
use crate::checks::{TestResult, capture, run_tests};
use crate::vars::resolve;
use crate::{
    Cookie, Error, Exchange, HttpMode, Request, RequestSettings, Response, SendOptions, Variable,
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
    let mut jar = cookies.to_vec();
    let (response, exchanges) = send_logged(resolved.request, options, &mut jar).await?;
    let tests = run_tests(&request.tests, &response, variables);
    let (captured, capture_problems) = capture(&request.captures, &response);
    Ok(Sent {
        response,
        unresolved: resolved.unresolved,
        cookies: jar,
        exchanges,
        tests,
        captured,
        capture_problems,
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
    Ok(send_logged(request, options, cookies).await?.0)
}

/// Like [`send_opts`], also returning each exchange that took place.
pub(super) async fn send_logged(
    mut request: Request,
    options: &SendOptions,
    cookies: &mut Vec<Cookie>,
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
