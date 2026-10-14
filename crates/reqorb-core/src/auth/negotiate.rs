//! Authorization that needs the server's answer first: a challenge to
//! respond to, or a token to fetch.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use md5::Md5;
use sha2::Digest;

use super::sign::{add_query, parse_url, path_and_query, random_hex, set_header, sha256};
use super::{Auth, AuthKind};
use crate::http::{Transport, execute};
use crate::{Error, Request, Response};

type Sender<'a> = &'a Transport;

/// Sends a request whose auth needs more than one round trip.
pub(crate) async fn negotiate(
    client: Sender<'_>,
    mut request: Request,
    auth: &Auth,
) -> Result<Response, Error> {
    match auth.kind {
        AuthKind::OAuth2 => {
            let token = oauth2_token(client, auth).await?;
            if auth.get("addTokenTo") == "queryParams" {
                add_query(&mut request, "access_token", &token);
            } else {
                let prefix = auth.get("headerPrefix");
                set_header(
                    &mut request,
                    "Authorization",
                    format!("{prefix} {token}").trim().to_string(),
                );
            }
            execute(client, &request).await
        }
        AuthKind::Digest => {
            let first = execute(client, &request).await?;
            let Some(challenge) = challenge(&first, "digest") else {
                return Ok(first);
            };
            let url = parse_url(&request)?;
            let header = digest_header(
                &challenge,
                &request.method.to_uppercase(),
                &path_and_query(&url),
                &auth.get("username"),
                &auth.get("password"),
                &random_hex(16),
            )?;
            set_header(&mut request, "Authorization", header);
            execute(client, &request).await
        }
        AuthKind::Ntlm => ntlm(client, request, auth).await,
        _ => execute(client, &request).await,
    }
}

/// The `WWW-Authenticate` challenge for `scheme` on a 401 response.
pub(super) fn challenge(response: &Response, scheme: &str) -> Option<String> {
    if response.status != 401 {
        return None;
    }
    response
        .headers
        .iter()
        .filter(|h| h.name.eq_ignore_ascii_case("www-authenticate"))
        .find_map(|h| {
            let (name, rest) = h.value.split_once(' ').unwrap_or((h.value.as_str(), ""));
            name.eq_ignore_ascii_case(scheme)
                .then(|| rest.trim().to_string())
        })
}

/// Splits `key="value", key=value` lists, where values may contain commas.
pub(super) fn challenge_params(challenge: &str) -> HashMap<String, String> {
    let mut params = HashMap::new();
    let mut rest = challenge;
    while let Some((key, after)) = rest.split_once('=') {
        let key = key
            .trim()
            .trim_start_matches(',')
            .trim()
            .to_ascii_lowercase();
        let after = after.trim_start();
        let (value, remaining) = match after.strip_prefix('"') {
            Some(quoted) => match quoted.split_once('"') {
                Some((value, remaining)) => (value, remaining),
                None => (quoted, ""),
            },
            None => after.split_once(',').unwrap_or((after, "")),
        };
        params.insert(key, value.trim().to_string());
        rest = remaining;
    }
    params
}

pub(super) fn digest_header(
    challenge: &str,
    method: &str,
    uri: &str,
    username: &str,
    password: &str,
    cnonce: &str,
) -> Result<String, Error> {
    let params = challenge_params(challenge);
    let get = |key: &str| params.get(key).map(String::as_str).unwrap_or("");
    let (realm, nonce) = (get("realm"), get("nonce"));
    if nonce.is_empty() {
        return Err(Error::Auth(
            "the server's digest challenge has no nonce".into(),
        ));
    }
    let algorithm = if get("algorithm").is_empty() {
        "MD5"
    } else {
        get("algorithm")
    };
    let upper = algorithm.to_ascii_uppercase();
    let hash = |input: String| -> String {
        if upper.starts_with("SHA-256") {
            hex::encode(sha256(input.as_bytes()))
        } else {
            hex::encode(Md5::digest(input.as_bytes()))
        }
    };
    if !upper.starts_with("SHA-256") && !upper.starts_with("MD5") {
        return Err(Error::Auth(format!(
            "digest algorithm {algorithm} is not supported"
        )));
    }

    let mut ha1 = hash(format!("{username}:{realm}:{password}"));
    if upper.ends_with("-SESS") {
        ha1 = hash(format!("{ha1}:{nonce}:{cnonce}"));
    }
    let ha2 = hash(format!("{method}:{uri}"));
    let qop_auth = get("qop").split(',').any(|q| q.trim() == "auth");
    let nc = "00000001";
    let response = if qop_auth {
        hash(format!("{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}"))
    } else {
        hash(format!("{ha1}:{nonce}:{ha2}"))
    };

    let mut header = format!(
        "Digest username=\"{username}\", realm=\"{realm}\", nonce=\"{nonce}\", uri=\"{uri}\", algorithm={algorithm}, response=\"{response}\""
    );
    if qop_auth {
        header.push_str(&format!(", qop=auth, nc={nc}, cnonce=\"{cnonce}\""));
    }
    if !get("opaque").is_empty() {
        header.push_str(&format!(", opaque=\"{}\"", get("opaque")));
    }
    Ok(header)
}

/// Tokens fetched for OAuth 2.0, kept until shortly before they expire.
fn token_cache() -> &'static Mutex<HashMap<String, (String, Instant)>> {
    static CACHE: OnceLock<Mutex<HashMap<String, (String, Instant)>>> = OnceLock::new();
    CACHE.get_or_init(Default::default)
}

async fn oauth2_token(client: Sender<'_>, auth: &Auth) -> Result<String, Error> {
    let given = auth.get("accessToken");
    if !given.is_empty() {
        return Ok(given);
    }
    let grant = auth.get("grant_type");
    if !matches!(
        grant.as_str(),
        "client_credentials" | "password_credentials"
    ) {
        return Err(Error::Auth(format!(
            "the `{grant}` grant needs a browser sign-in, which reqorb cannot do yet; paste an access token instead"
        )));
    }
    let token_url = auth.require("accessTokenUrl")?;
    let client_id = auth.require("clientId")?;
    let client_secret = auth.get("clientSecret");
    let password_grant = auth.get("grant_type") == "password_credentials";

    let cache_key = auth
        .params
        .iter()
        .map(|p| format!("{}={}", p.key, p.value))
        .collect::<Vec<_>>()
        .join("\n");
    let cached = token_cache()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(&cache_key)
        .cloned();
    if let Some((token, expires)) = cached
        && Instant::now() < expires
    {
        return Ok(token);
    }

    // Built in its own scope: the form serializer cannot be held across an await.
    let request = {
        let mut form = url::form_urlencoded::Serializer::new(String::new());
        if password_grant {
            form.append_pair("grant_type", "password");
            form.append_pair("username", &auth.get("username"));
            form.append_pair("password", &auth.get("password"));
        } else {
            form.append_pair("grant_type", "client_credentials");
        }
        let scope = auth.get("scope");
        if !scope.is_empty() {
            form.append_pair("scope", &scope);
        }
        let mut request = Request::new("POST", token_url.clone());
        request.add_header("Content-Type", "application/x-www-form-urlencoded");
        request.add_header("Accept", "application/json");
        if auth.get("client_authentication") == "body" {
            form.append_pair("client_id", &client_id);
            form.append_pair("client_secret", &client_secret);
        } else {
            let credentials = BASE64.encode(format!("{client_id}:{client_secret}"));
            request.add_header("Authorization", format!("Basic {credentials}"));
        }
        request.body = Some(form.finish());
        request.timeout_ms = Some(30_000);
        request
    };

    let response = execute(client, &request).await?;
    let reply: serde_json::Value = serde_json::from_str(&response.body).unwrap_or_default();
    let Some(token) = reply.get("access_token").and_then(|t| t.as_str()) else {
        let detail = reply
            .get("error_description")
            .or(reply.get("error"))
            .and_then(|e| e.as_str())
            .map(str::to_string)
            .unwrap_or_else(|| response.body.chars().take(200).collect());
        return Err(Error::Auth(format!(
            "the token request to {token_url} failed ({} {}): {detail}",
            response.status, response.status_text
        )));
    };

    let lifetime = reply
        .get("expires_in")
        .and_then(|e| e.as_u64())
        .unwrap_or(300);
    let expires = Instant::now() + Duration::from_secs(lifetime.saturating_sub(30));
    token_cache()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .insert(cache_key, (token.to_string(), expires));
    Ok(token.to_string())
}

pub(super) async fn ntlm(
    client: Sender<'_>,
    mut request: Request,
    auth: &Auth,
) -> Result<Response, Error> {
    use ntlmclient::{Credentials, Flags, Message, NegotiateMessage};

    let fail = |what: &str| Error::Auth(format!("NTLM: {what}"));
    let workstation = auth.get("workstation");
    let negotiate = Message::Negotiate(NegotiateMessage {
        flags: Flags::NEGOTIATE_UNICODE
            | Flags::REQUEST_TARGET
            | Flags::NEGOTIATE_NTLM
            | Flags::NEGOTIATE_WORKSTATION_SUPPLIED,
        supplied_domain: String::new(),
        supplied_workstation: workstation.clone(),
        os_version: Default::default(),
    });
    let bytes = negotiate
        .to_bytes()
        .map_err(|_| fail("could not build the negotiate message"))?;
    set_header(
        &mut request,
        "Authorization",
        format!("NTLM {}", BASE64.encode(bytes)),
    );

    let first = execute(client, &request).await?;
    let Some(reply) = challenge(&first, "ntlm").filter(|c| !c.is_empty()) else {
        return Ok(first);
    };
    let bytes = BASE64
        .decode(reply.trim())
        .map_err(|_| fail("the server's challenge is not valid base64"))?;
    let Ok(Message::Challenge(challenge)) = Message::try_from(bytes.as_slice()) else {
        return Err(fail("the server's challenge could not be read"));
    };
    let target_info: Vec<u8> = challenge
        .target_information
        .iter()
        .flat_map(|entry| entry.to_bytes())
        .collect();

    let credentials = Credentials {
        username: auth.get("username"),
        password: auth.get("password"),
        domain: auth.get("domain"),
    };
    let response = ntlmclient::respond_challenge_ntlm_v2(
        challenge.challenge,
        &target_info,
        ntlmclient::get_ntlm_time(),
        &credentials,
    );
    let message = response.to_message(
        &credentials,
        &workstation,
        Flags::NEGOTIATE_UNICODE | Flags::NEGOTIATE_NTLM,
    );
    let bytes = message
        .to_bytes()
        .map_err(|_| fail("could not build the authenticate message"))?;
    set_header(
        &mut request,
        "Authorization",
        format!("NTLM {}", BASE64.encode(bytes)),
    );
    execute(client, &request).await
}
