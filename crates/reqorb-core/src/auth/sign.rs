//! Authorization worked out from the request alone: a header or a query
//! parameter computed from what is being sent.

use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use hmac::{Hmac, KeyInit, Mac};
use sha1::Sha1;
use sha2::{Digest, Sha256};
use url::Url;

use super::{Auth, AuthKind};
use crate::{Error, Request};

type HmacSha1 = Hmac<Sha1>;

type HmacSha256 = Hmac<Sha256>;

fn hmac_sha1(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha1::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

pub(super) fn sha256(data: &[u8]) -> Vec<u8> {
    Sha256::digest(data).to_vec()
}

/// Percent-encodes everything except RFC 3986 unreserved characters.
pub(super) fn encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Random lowercase hex, for nonces. Uniqueness matters here, not secrecy.
pub(super) fn random_hex(len: usize) -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut out = String::new();
    while out.len() < len {
        let bits = std::collections::hash_map::RandomState::new()
            .build_hasher()
            .finish();
        out.push_str(&format!("{bits:016x}"));
    }
    out.truncate(len);
    out
}

/// The moment a request is signed. Tests pin both values.
pub(crate) struct Clock {
    pub unix: u64,
    pub nonce: String,
}

impl Clock {
    pub fn now() -> Self {
        Self {
            unix: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_secs()),
            nonce: random_hex(32),
        }
    }

    /// (year, month, day, hour, minute, second) in UTC.
    fn utc(&self) -> (i64, u64, u64, u64, u64, u64) {
        let days = (self.unix / 86_400) as i64;
        let rest = self.unix % 86_400;
        // Civil-from-days, after Howard Hinnant's date algorithms.
        let z = days + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z.rem_euclid(146_097) as u64;
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = doy - (153 * mp + 2) / 5 + 1;
        let month = if mp < 10 { mp + 3 } else { mp - 9 };
        let year = yoe as i64 + era * 400 + i64::from(month <= 2);
        (year, month, day, rest / 3600, rest % 3600 / 60, rest % 60)
    }
}

pub(super) fn parse_url(request: &Request) -> Result<Url, Error> {
    Url::parse(&request.url).map_err(|e| Error::InvalidUrl {
        url: request.url.clone(),
        reason: e.to_string(),
    })
}

/// Sets a header, replacing one the request already has by that name.
pub(super) fn set_header(request: &mut Request, name: &str, value: impl Into<String>) {
    request
        .headers
        .retain(|h| !h.name.eq_ignore_ascii_case(name));
    request.add_header(name, value);
}

pub(super) fn add_query(request: &mut Request, name: &str, value: &str) {
    let (base, fragment) = match request.url.split_once('#') {
        Some((base, fragment)) => (base.to_string(), Some(fragment.to_string())),
        None => (request.url.clone(), None),
    };
    let separator = if base.contains('?') { '&' } else { '?' };
    request.url = format!("{base}{separator}{}={}", encode(name), encode(value));
    if let Some(fragment) = fragment {
        request.url.push('#');
        request.url.push_str(&fragment);
    }
}

pub(super) fn header_value<'a>(request: &'a Request, name: &str) -> &'a str {
    request
        .headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case(name))
        .map_or("", |h| h.value.as_str())
}

/// `host` or `host:port`, as it appears in a Host header.
fn host_header(url: &Url) -> String {
    match (url.host_str(), url.port()) {
        (Some(host), Some(port)) => format!("{host}:{port}"),
        (Some(host), None) => host.to_string(),
        _ => String::new(),
    }
}

pub(super) fn path_and_query(url: &Url) -> String {
    match url.query() {
        Some(query) => format!("{}?{query}", url.path()),
        None => url.path().to_string(),
    }
}

// ------------------------------------------------- types signed in one step

/// Applies an auth type that only needs the request itself. Returns false
/// for the types that need a conversation with the server first.
pub(crate) fn sign(request: &mut Request, auth: &Auth, clock: &Clock) -> Result<bool, Error> {
    match auth.kind {
        AuthKind::None => {}
        AuthKind::ApiKey => {
            let key = auth.require("key")?;
            let value = auth.get("value");
            if auth.get("in") == "query" {
                add_query(request, &key, &value);
            } else {
                set_header(request, &key, value);
            }
        }
        AuthKind::Bearer => {
            set_header(
                request,
                "Authorization",
                format!("Bearer {}", auth.require("token")?),
            );
        }
        AuthKind::Basic => {
            let credentials = format!("{}:{}", auth.get("username"), auth.get("password"));
            set_header(
                request,
                "Authorization",
                format!("Basic {}", BASE64.encode(credentials)),
            );
        }
        AuthKind::Jwt => jwt(request, auth)?,
        AuthKind::OAuth1 => oauth1(request, auth, clock)?,
        AuthKind::Hawk => hawk(request, auth, clock)?,
        AuthKind::AwsV4 => aws_v4(request, auth, clock)?,
        AuthKind::EdgeGrid => edgegrid(request, auth, clock)?,
        AuthKind::Digest | AuthKind::Ntlm | AuthKind::OAuth2 => return Ok(false),
    }
    Ok(true)
}

pub(super) fn jwt(request: &mut Request, auth: &Auth) -> Result<(), Error> {
    use jsonwebtoken::{Algorithm, EncodingKey, Header};

    let bad = |what: &str, e: &dyn std::fmt::Display| Error::Auth(format!("JWT {what}: {e}"));
    let algorithm: Algorithm = auth
        .get("algorithm")
        .parse()
        .map_err(|e| bad("algorithm", &e))?;
    let payload: serde_json::Value =
        serde_json::from_str(&auth.get("payload")).map_err(|e| bad("payload is not JSON", &e))?;
    if !payload.is_object() {
        return Err(Error::Auth("JWT payload must be a JSON object".into()));
    }

    let key = match algorithm {
        Algorithm::HS256 | Algorithm::HS384 | Algorithm::HS512 => {
            let secret = auth.require("secret")?;
            if auth.get("isSecretBase64Encoded") == "true" {
                EncodingKey::from_base64_secret(&secret).map_err(|e| bad("secret", &e))?
            } else {
                EncodingKey::from_secret(secret.as_bytes())
            }
        }
        Algorithm::ES256 | Algorithm::ES384 => {
            EncodingKey::from_ec_pem(auth.require("privateKey")?.as_bytes())
                .map_err(|e| bad("private key", &e))?
        }
        _ => EncodingKey::from_rsa_pem(auth.require("privateKey")?.as_bytes())
            .map_err(|e| bad("private key", &e))?,
    };
    let token = jsonwebtoken::encode(&Header::new(algorithm), &payload, &key)
        .map_err(|e| bad("signing failed", &e))?;

    if auth.get("addTokenTo") == "queryParam" {
        add_query(request, &auth.get("queryParamKey"), &token);
    } else {
        let prefix = auth.get("headerPrefix");
        set_header(
            request,
            "Authorization",
            format!("{prefix} {token}").trim().to_string(),
        );
    }
    Ok(())
}

pub(super) fn oauth1(request: &mut Request, auth: &Auth, clock: &Clock) -> Result<(), Error> {
    let url = parse_url(request)?;
    let method = auth.get("signatureMethod");
    let or = |value: String, fallback: String| if value.is_empty() { fallback } else { value };

    let mut oauth = vec![
        (
            "oauth_consumer_key".to_string(),
            auth.require("consumerKey")?,
        ),
        (
            "oauth_nonce".to_string(),
            or(auth.get("nonce"), clock.nonce.clone()),
        ),
        ("oauth_signature_method".to_string(), method.clone()),
        (
            "oauth_timestamp".to_string(),
            or(auth.get("timestamp"), clock.unix.to_string()),
        ),
        ("oauth_version".to_string(), "1.0".to_string()),
    ];
    let token = auth.get("token");
    if !token.is_empty() {
        oauth.push(("oauth_token".to_string(), token));
    }

    // Everything the request carries as a parameter is signed: the query,
    // a form body, and the OAuth fields themselves.
    let mut signed: Vec<(String, String)> = url
        .query_pairs()
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    if header_value(request, "content-type").contains("x-www-form-urlencoded") {
        let body = request.body.as_deref().unwrap_or("");
        signed.extend(
            url::form_urlencoded::parse(body.as_bytes())
                .map(|(k, v)| (k.into_owned(), v.into_owned())),
        );
    }
    signed.extend(oauth.iter().cloned());
    let mut pairs: Vec<(String, String)> =
        signed.iter().map(|(k, v)| (encode(k), encode(v))).collect();
    pairs.sort();
    let parameters = pairs
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("&");

    let base_url = format!("{}://{}{}", url.scheme(), host_header(&url), url.path());
    let base = format!(
        "{}&{}&{}",
        request.method.to_uppercase(),
        encode(&base_url),
        encode(&parameters)
    );
    let key = format!(
        "{}&{}",
        encode(&auth.get("consumerSecret")),
        encode(&auth.get("tokenSecret"))
    );
    let signature = match method.as_str() {
        "PLAINTEXT" => key,
        "HMAC-SHA256" => BASE64.encode(hmac_sha256(key.as_bytes(), base.as_bytes())),
        _ => BASE64.encode(hmac_sha1(key.as_bytes(), base.as_bytes())),
    };
    oauth.push(("oauth_signature".to_string(), signature));
    oauth.sort();

    if auth.get("addParamsToHeader") == "query" {
        for (name, value) in &oauth {
            add_query(request, name, value);
        }
    } else {
        let mut fields = Vec::new();
        let realm = auth.get("realm");
        if !realm.is_empty() {
            fields.push(format!("realm=\"{realm}\""));
        }
        fields.extend(oauth.iter().map(|(k, v)| format!("{k}=\"{}\"", encode(v))));
        set_header(
            request,
            "Authorization",
            format!("OAuth {}", fields.join(", ")),
        );
    }
    Ok(())
}

pub(super) fn hawk(request: &mut Request, auth: &Auth, clock: &Clock) -> Result<(), Error> {
    let url = parse_url(request)?;
    let id = auth.require("authId")?;
    let key = auth.require("authKey")?;
    let sha1 = auth.get("algorithm") == "sha1";
    let or = |value: String, fallback: String| if value.is_empty() { fallback } else { value };
    let timestamp = or(auth.get("timestamp"), clock.unix.to_string());
    let nonce = or(auth.get("nonce"), clock.nonce.chars().take(8).collect());
    let (ext, app, dlg) = (
        auth.get("extraData"),
        auth.get("app"),
        auth.get("delegation"),
    );

    let hash = if auth.get("includePayloadHash") == "true" {
        let content_type = header_value(request, "content-type")
            .split(';')
            .next()
            .unwrap_or("")
            .trim()
            .to_ascii_lowercase();
        let payload = format!(
            "hawk.1.payload\n{content_type}\n{}\n",
            request.body.as_deref().unwrap_or("")
        );
        if sha1 {
            BASE64.encode(Sha1::digest(payload.as_bytes()))
        } else {
            BASE64.encode(sha256(payload.as_bytes()))
        }
    } else {
        String::new()
    };

    let port = url.port_or_known_default().unwrap_or(80);
    let mut normalized = format!(
        "hawk.1.header\n{timestamp}\n{nonce}\n{}\n{}\n{}\n{port}\n{hash}\n{ext}\n",
        request.method.to_uppercase(),
        path_and_query(&url),
        url.host_str().unwrap_or("")
    );
    if !app.is_empty() {
        normalized.push_str(&format!("{app}\n{dlg}\n"));
    }
    let mac = if sha1 {
        BASE64.encode(hmac_sha1(key.as_bytes(), normalized.as_bytes()))
    } else {
        BASE64.encode(hmac_sha256(key.as_bytes(), normalized.as_bytes()))
    };

    let mut header = format!("Hawk id=\"{id}\", ts=\"{timestamp}\", nonce=\"{nonce}\"");
    for (name, value) in [("hash", &hash), ("ext", &ext)] {
        if !value.is_empty() {
            header.push_str(&format!(", {name}=\"{value}\""));
        }
    }
    header.push_str(&format!(", mac=\"{mac}\""));
    if !app.is_empty() {
        header.push_str(&format!(", app=\"{app}\""));
        if !dlg.is_empty() {
            header.push_str(&format!(", dlg=\"{dlg}\""));
        }
    }
    set_header(request, "Authorization", header);
    Ok(())
}

fn aws_v4(request: &mut Request, auth: &Auth, clock: &Clock) -> Result<(), Error> {
    let url = parse_url(request)?;
    let access_key = auth.require("accessKey")?;
    let secret_key = auth.require("secretKey")?;
    let region = auth.get("region");
    let service = auth.require("service")?;
    let session_token = auth.get("sessionToken");

    let (year, month, day, hour, minute, second) = clock.utc();
    let date = format!("{year:04}{month:02}{day:02}");
    let amz_date = format!("{date}T{hour:02}{minute:02}{second:02}Z");
    let payload_hash = hex::encode(sha256(request.body.as_deref().unwrap_or("").as_bytes()));
    let is_s3 = service == "s3";

    // Lowercase names in sorted order, as the canonical form requires.
    let mut headers = vec![
        ("host".to_string(), host_header(&url)),
        ("x-amz-date".to_string(), amz_date.clone()),
    ];
    if is_s3 {
        headers.push(("x-amz-content-sha256".to_string(), payload_hash.clone()));
    }
    if !session_token.is_empty() {
        headers.push(("x-amz-security-token".to_string(), session_token.clone()));
    }
    headers.sort();
    let canonical_headers: String = headers
        .iter()
        .map(|(name, value)| format!("{name}:{}\n", value.trim()))
        .collect();
    let signed_headers = headers
        .iter()
        .map(|(name, _)| name.as_str())
        .collect::<Vec<_>>()
        .join(";");

    // Every service but S3 expects the already-encoded path encoded again.
    let canonical_path = if is_s3 {
        url.path().to_string()
    } else {
        url.path()
            .split('/')
            .map(encode)
            .collect::<Vec<_>>()
            .join("/")
    };
    let mut query: Vec<(String, String)> = url
        .query_pairs()
        .map(|(k, v)| (encode(&k), encode(&v)))
        .collect();
    query.sort();
    let canonical_query = query
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("&");

    let canonical_request = format!(
        "{}\n{canonical_path}\n{canonical_query}\n{canonical_headers}\n{signed_headers}\n{payload_hash}",
        request.method.to_uppercase()
    );
    let scope = format!("{date}/{region}/{service}/aws4_request");
    let string_to_sign = format!(
        "AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{}",
        hex::encode(sha256(canonical_request.as_bytes()))
    );
    let mut key = hmac_sha256(format!("AWS4{secret_key}").as_bytes(), date.as_bytes());
    for part in [region.as_str(), service.as_str(), "aws4_request"] {
        key = hmac_sha256(&key, part.as_bytes());
    }
    let signature = hex::encode(hmac_sha256(&key, string_to_sign.as_bytes()));

    set_header(request, "X-Amz-Date", amz_date);
    if is_s3 {
        set_header(request, "X-Amz-Content-Sha256", payload_hash);
    }
    if !session_token.is_empty() {
        set_header(request, "X-Amz-Security-Token", session_token);
    }
    set_header(
        request,
        "Authorization",
        format!(
            "AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed_headers}, Signature={signature}"
        ),
    );
    Ok(())
}

pub(super) fn edgegrid(request: &mut Request, auth: &Auth, clock: &Clock) -> Result<(), Error> {
    let url = parse_url(request)?;
    let client_token = auth.require("clientToken")?;
    let access_token = auth.require("accessToken")?;
    let client_secret = auth.require("clientSecret")?;
    let max_body: usize = auth.get("maxBodySize").parse().unwrap_or(131_072);

    let timestamp = match auth.get("timestamp") {
        given if !given.is_empty() => given,
        _ => {
            let (year, month, day, hour, minute, second) = clock.utc();
            format!("{year:04}{month:02}{day:02}T{hour:02}:{minute:02}:{second:02}+0000")
        }
    };
    let nonce = match auth.get("nonce") {
        given if !given.is_empty() => given,
        _ => clock.nonce.clone(),
    };

    let unsigned = format!(
        "EG1-HMAC-SHA256 client_token={client_token};access_token={access_token};timestamp={timestamp};nonce={nonce};"
    );
    // Only POST bodies are part of the signature, and only up to the limit.
    let method = request.method.to_uppercase();
    let content_hash = match request.body.as_deref() {
        Some(body) if method == "POST" && !body.is_empty() => {
            let bytes = body.as_bytes();
            BASE64.encode(sha256(&bytes[..bytes.len().min(max_body)]))
        }
        _ => String::new(),
    };
    let data = [
        method.as_str(),
        url.scheme(),
        &host_header(&url),
        &path_and_query(&url),
        "",
        &content_hash,
        &unsigned,
    ]
    .join("\t");

    let signing_key = BASE64.encode(hmac_sha256(client_secret.as_bytes(), timestamp.as_bytes()));
    let signature = BASE64.encode(hmac_sha256(signing_key.as_bytes(), data.as_bytes()));
    set_header(
        request,
        "Authorization",
        format!("{unsigned}signature={signature}"),
    );
    Ok(())
}

// ------------------------------------------ types that talk to the server
