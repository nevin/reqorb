//! Request authorization: the model, the form each type needs, and the code
//! that turns credentials into headers or query parameters at send time.
//!
//! Parameter keys follow Postman's, so collections move between the two
//! without translation.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use hmac::{Hmac, KeyInit, Mac};
use md5::Md5;
use serde::{Deserialize, Serialize};
use sha1::Sha1;
use sha2::{Digest, Sha256};
use url::Url;

use crate::{Error, Request, Response};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub enum AuthKind {
    #[default]
    #[serde(rename = "noauth")]
    None,
    #[serde(rename = "apikey")]
    ApiKey,
    #[serde(rename = "bearer")]
    Bearer,
    #[serde(rename = "jwt")]
    Jwt,
    #[serde(rename = "basic")]
    Basic,
    #[serde(rename = "digest")]
    Digest,
    #[serde(rename = "oauth1")]
    OAuth1,
    #[serde(rename = "oauth2")]
    OAuth2,
    #[serde(rename = "hawk")]
    Hawk,
    #[serde(rename = "awsv4")]
    AwsV4,
    #[serde(rename = "ntlm")]
    Ntlm,
    #[serde(rename = "edgegrid")]
    EdgeGrid,
}

impl AuthKind {
    pub const ALL: [AuthKind; 12] = [
        AuthKind::None,
        AuthKind::ApiKey,
        AuthKind::Bearer,
        AuthKind::Jwt,
        AuthKind::Basic,
        AuthKind::Digest,
        AuthKind::OAuth1,
        AuthKind::OAuth2,
        AuthKind::Hawk,
        AuthKind::AwsV4,
        AuthKind::Ntlm,
        AuthKind::EdgeGrid,
    ];

    /// The identifier used in saved files, which is also Postman's.
    pub fn id(self) -> &'static str {
        match self {
            AuthKind::None => "noauth",
            AuthKind::ApiKey => "apikey",
            AuthKind::Bearer => "bearer",
            AuthKind::Jwt => "jwt",
            AuthKind::Basic => "basic",
            AuthKind::Digest => "digest",
            AuthKind::OAuth1 => "oauth1",
            AuthKind::OAuth2 => "oauth2",
            AuthKind::Hawk => "hawk",
            AuthKind::AwsV4 => "awsv4",
            AuthKind::Ntlm => "ntlm",
            AuthKind::EdgeGrid => "edgegrid",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.id() == id)
    }

    pub fn label(self) -> &'static str {
        match self {
            AuthKind::None => "No Auth",
            AuthKind::ApiKey => "API Key",
            AuthKind::Bearer => "Bearer Token",
            AuthKind::Jwt => "JWT Bearer",
            AuthKind::Basic => "Basic Auth",
            AuthKind::Digest => "Digest Auth",
            AuthKind::OAuth1 => "OAuth 1.0",
            AuthKind::OAuth2 => "OAuth 2.0",
            AuthKind::Hawk => "Hawk Authentication",
            AuthKind::AwsV4 => "AWS Signature",
            AuthKind::Ntlm => "NTLM Authentication",
            AuthKind::EdgeGrid => "Akamai EdgeGrid",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthParam {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Auth {
    pub kind: AuthKind,
    #[serde(default)]
    pub params: Vec<AuthParam>,
}

impl Auth {
    pub fn new(kind: AuthKind, params: &[(&str, &str)]) -> Self {
        Self {
            kind,
            params: params
                .iter()
                .map(|(key, value)| AuthParam {
                    key: key.to_string(),
                    value: value.to_string(),
                })
                .collect(),
        }
    }

    /// The value set for `key`, or that field's default when unset or empty.
    pub fn get(&self, key: &str) -> String {
        self.params
            .iter()
            .find(|p| p.key == key && !p.value.is_empty())
            .map(|p| p.value.clone())
            .or_else(|| {
                auth_fields(self.kind)
                    .into_iter()
                    .find(|f| f.key == key)
                    .map(|f| f.default_value)
            })
            .unwrap_or_default()
    }

    fn require(&self, key: &str) -> Result<String, Error> {
        let value = self.get(key);
        if value.is_empty() {
            let label = auth_fields(self.kind)
                .into_iter()
                .find(|f| f.key == key)
                .map_or_else(|| key.to_string(), |f| f.label);
            return Err(Error::Auth(format!(
                "{} needs a value for \"{label}\"",
                self.kind.label()
            )));
        }
        Ok(value)
    }
}

/// One input on the form for an auth type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthField {
    pub key: String,
    pub label: String,
    /// Holds a credential, so a form may want to mask it.
    pub secret: bool,
    pub multiline: bool,
    /// Allowed values; empty for free text.
    pub options: Vec<String>,
    pub default_value: String,
    pub hint: String,
}

fn text(key: &str, label: &str) -> AuthField {
    AuthField {
        key: key.into(),
        label: label.into(),
        secret: false,
        multiline: false,
        options: Vec::new(),
        default_value: String::new(),
        hint: String::new(),
    }
}

fn secret(key: &str, label: &str) -> AuthField {
    AuthField {
        secret: true,
        ..text(key, label)
    }
}

fn choice(key: &str, label: &str, options: &[&str]) -> AuthField {
    AuthField {
        options: options.iter().map(|o| o.to_string()).collect(),
        default_value: options[0].to_string(),
        ..text(key, label)
    }
}

impl AuthField {
    fn default(mut self, value: &str) -> Self {
        self.default_value = value.into();
        self
    }

    fn hint(mut self, hint: &str) -> Self {
        self.hint = hint.into();
        self
    }

    fn multiline(mut self) -> Self {
        self.multiline = true;
        self
    }
}

/// The inputs an auth type needs, in display order.
pub fn auth_fields(kind: AuthKind) -> Vec<AuthField> {
    match kind {
        AuthKind::None => Vec::new(),
        AuthKind::ApiKey => vec![
            text("key", "Key").hint("X-API-Key"),
            secret("value", "Value"),
            choice("in", "Add to", &["header", "query"]),
        ],
        AuthKind::Bearer => vec![secret("token", "Token")],
        AuthKind::Jwt => vec![
            choice(
                "algorithm",
                "Algorithm",
                &[
                    "HS256", "HS384", "HS512", "RS256", "RS384", "RS512", "PS256", "PS384",
                    "PS512", "ES256", "ES384",
                ],
            ),
            secret("secret", "Secret").hint("For HS algorithms"),
            choice(
                "isSecretBase64Encoded",
                "Secret is base64 encoded",
                &["false", "true"],
            ),
            secret("privateKey", "Private key")
                .multiline()
                .hint("PEM, for RS, PS and ES algorithms"),
            text("payload", "Payload")
                .multiline()
                .default("{}")
                .hint("{\"sub\": \"user-1\"}"),
            choice("addTokenTo", "Add token to", &["header", "queryParam"]),
            text("headerPrefix", "Header prefix").default("Bearer"),
            text("queryParamKey", "Query parameter name").default("token"),
        ],
        AuthKind::Basic => vec![text("username", "Username"), secret("password", "Password")],
        AuthKind::Digest => vec![text("username", "Username"), secret("password", "Password")],
        AuthKind::OAuth1 => vec![
            choice(
                "signatureMethod",
                "Signature method",
                &["HMAC-SHA1", "HMAC-SHA256", "PLAINTEXT"],
            ),
            text("consumerKey", "Consumer key"),
            secret("consumerSecret", "Consumer secret"),
            text("token", "Access token"),
            secret("tokenSecret", "Token secret"),
            choice(
                "addParamsToHeader",
                "Add auth data to",
                &["header", "query"],
            ),
            text("realm", "Realm"),
            text("timestamp", "Timestamp").hint("Generated when empty"),
            text("nonce", "Nonce").hint("Generated when empty"),
        ],
        AuthKind::OAuth2 => vec![
            secret("accessToken", "Access token").hint("Leave empty to request one below"),
            text("headerPrefix", "Header prefix").default("Bearer"),
            choice("addTokenTo", "Add token to", &["header", "queryParams"]),
            choice(
                "grant_type",
                "Grant type",
                &["client_credentials", "password_credentials"],
            ),
            text("accessTokenUrl", "Access token URL"),
            text("clientId", "Client ID"),
            secret("clientSecret", "Client secret"),
            text("scope", "Scope"),
            text("username", "Username").hint("Password grant only"),
            secret("password", "Password").hint("Password grant only"),
            choice(
                "client_authentication",
                "Send client credentials in",
                &["header", "body"],
            ),
        ],
        AuthKind::Hawk => vec![
            text("authId", "Hawk auth ID"),
            secret("authKey", "Hawk auth key"),
            choice("algorithm", "Algorithm", &["sha256", "sha1"]),
            text("extraData", "Extra data (ext)"),
            text("app", "App ID"),
            text("delegation", "Delegated by (dlg)"),
            choice(
                "includePayloadHash",
                "Include payload hash",
                &["false", "true"],
            ),
            text("timestamp", "Timestamp").hint("Generated when empty"),
            text("nonce", "Nonce").hint("Generated when empty"),
        ],
        AuthKind::AwsV4 => vec![
            text("accessKey", "Access key"),
            secret("secretKey", "Secret key"),
            text("region", "AWS region").default("us-east-1"),
            text("service", "Service name").hint("execute-api, s3, ..."),
            secret("sessionToken", "Session token"),
        ],
        AuthKind::Ntlm => vec![
            text("username", "Username"),
            secret("password", "Password"),
            text("domain", "Domain"),
            text("workstation", "Workstation"),
        ],
        AuthKind::EdgeGrid => vec![
            secret("accessToken", "Access token"),
            secret("clientToken", "Client token"),
            secret("clientSecret", "Client secret"),
            text("maxBodySize", "Max body size").default("131072"),
            text("timestamp", "Timestamp").hint("Generated when empty"),
            text("nonce", "Nonce").hint("Generated when empty"),
        ],
    }
}

// ----------------------------------------------------------------- helpers

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

fn sha256(data: &[u8]) -> Vec<u8> {
    Sha256::digest(data).to_vec()
}

/// Percent-encodes everything except RFC 3986 unreserved characters.
fn encode(s: &str) -> String {
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
fn random_hex(len: usize) -> String {
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

fn parse_url(request: &Request) -> Result<Url, Error> {
    Url::parse(&request.url).map_err(|e| Error::InvalidUrl {
        url: request.url.clone(),
        reason: e.to_string(),
    })
}

/// Sets a header, replacing one the request already has by that name.
fn set_header(request: &mut Request, name: &str, value: impl Into<String>) {
    request
        .headers
        .retain(|h| !h.name.eq_ignore_ascii_case(name));
    request.add_header(name, value);
}

fn add_query(request: &mut Request, name: &str, value: &str) {
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

fn header_value<'a>(request: &'a Request, name: &str) -> &'a str {
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

fn path_and_query(url: &Url) -> String {
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

fn jwt(request: &mut Request, auth: &Auth) -> Result<(), Error> {
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

fn oauth1(request: &mut Request, auth: &Auth, clock: &Clock) -> Result<(), Error> {
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

fn hawk(request: &mut Request, auth: &Auth, clock: &Clock) -> Result<(), Error> {
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

fn edgegrid(request: &mut Request, auth: &Auth, clock: &Clock) -> Result<(), Error> {
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

type Sender<'a> = &'a crate::Transport;

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
            crate::execute(client, &request).await
        }
        AuthKind::Digest => {
            let first = crate::execute(client, &request).await?;
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
            crate::execute(client, &request).await
        }
        AuthKind::Ntlm => ntlm(client, request, auth).await,
        _ => crate::execute(client, &request).await,
    }
}

/// The `WWW-Authenticate` challenge for `scheme` on a 401 response.
fn challenge(response: &Response, scheme: &str) -> Option<String> {
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
fn challenge_params(challenge: &str) -> HashMap<String, String> {
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

fn digest_header(
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
    let cached = token_cache().lock().unwrap().get(&cache_key).cloned();
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

    let response = crate::execute(client, &request).await?;
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
        .unwrap()
        .insert(cache_key, (token.to_string(), expires));
    Ok(token.to_string())
}

async fn ntlm(client: Sender<'_>, mut request: Request, auth: &Auth) -> Result<Response, Error> {
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

    let first = crate::execute(client, &request).await?;
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
    crate::execute(client, &request).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clock(unix: u64, nonce: &str) -> Clock {
        Clock {
            unix,
            nonce: nonce.into(),
        }
    }

    fn signed(request: &mut Request, auth: &Auth, clock: &Clock) {
        assert!(sign(request, auth, clock).unwrap());
    }

    fn header<'a>(request: &'a Request, name: &str) -> &'a str {
        header_value(request, name)
    }

    #[test]
    fn simple_types() {
        let mut request = Request::new("GET", "https://api.test/x?a=1#frag");
        request.add_header("authorization", "old");

        signed(
            &mut request,
            &Auth::new(AuthKind::Bearer, &[("token", "t0k")]),
            &Clock::now(),
        );
        assert_eq!(header(&request, "Authorization"), "Bearer t0k");
        assert_eq!(
            request.headers.len(),
            1,
            "replaces a header the request already had"
        );

        let basic = Auth::new(
            AuthKind::Basic,
            &[("username", "Aladdin"), ("password", "open sesame")],
        );
        signed(&mut request, &basic, &Clock::now());
        assert_eq!(
            header(&request, "Authorization"),
            "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ=="
        );

        let key = Auth::new(AuthKind::ApiKey, &[("key", "X-Key"), ("value", "k 1")]);
        signed(&mut request, &key, &Clock::now());
        assert_eq!(header(&request, "X-Key"), "k 1");

        let query = Auth::new(
            AuthKind::ApiKey,
            &[("key", "api key"), ("value", "k&1"), ("in", "query")],
        );
        signed(&mut request, &query, &Clock::now());
        assert_eq!(request.url, "https://api.test/x?a=1&api%20key=k%261#frag");

        let missing = sign(
            &mut request,
            &Auth::new(AuthKind::Bearer, &[]),
            &Clock::now(),
        );
        assert!(matches!(missing, Err(Error::Auth(m)) if m.contains("Token")));
    }

    #[test]
    fn every_kind_has_a_label_and_round_trips_its_id() {
        for kind in AuthKind::ALL {
            assert!(!kind.label().is_empty());
            assert_eq!(AuthKind::from_id(kind.id()), Some(kind));
            let json = serde_json::to_string(&kind).unwrap();
            assert_eq!(json, format!("\"{}\"", kind.id()));
            for field in auth_fields(kind) {
                assert!(field.options.is_empty() || field.options.contains(&field.default_value));
            }
        }
    }

    #[test]
    fn jwt_signs_and_verifies() {
        use jsonwebtoken::{Algorithm, DecodingKey, Validation};

        let auth = Auth::new(
            AuthKind::Jwt,
            &[
                ("algorithm", "HS384"),
                ("secret", "s3cret"),
                ("payload", r#"{"sub": "user-1", "admin": true}"#),
            ],
        );
        let mut request = Request::new("GET", "https://api.test/");
        signed(&mut request, &auth, &Clock::now());
        let token = header(&request, "Authorization")
            .strip_prefix("Bearer ")
            .unwrap()
            .to_string();

        let mut validation = Validation::new(Algorithm::HS384);
        validation.required_spec_claims.clear();
        validation.validate_exp = false;
        let decoded = jsonwebtoken::decode::<serde_json::Value>(
            &token,
            &DecodingKey::from_secret(b"s3cret"),
            &validation,
        )
        .unwrap();
        assert_eq!(decoded.claims["sub"], "user-1");
        assert_eq!(decoded.claims["admin"], true);

        let mut in_query = auth.clone();
        in_query.params.push(AuthParam {
            key: "addTokenTo".into(),
            value: "queryParam".into(),
        });
        let mut request = Request::new("GET", "https://api.test/");
        signed(&mut request, &in_query, &Clock::now());
        assert!(request.url.starts_with("https://api.test/?token=ey"));

        let mut bad = Auth::new(AuthKind::Jwt, &[("secret", "x"), ("payload", "[1]")]);
        assert!(sign(&mut request, &bad, &Clock::now()).is_err());
        bad.params[1].value = "{}".into();
        bad.params.push(AuthParam {
            key: "algorithm".into(),
            value: "RS256".into(),
        });
        assert!(
            sign(&mut request, &bad, &Clock::now()).is_err(),
            "RS256 needs a private key"
        );
    }

    /// The worked example from Twitter's "Creating a signature" guide.
    #[test]
    fn oauth1_matches_the_published_example() {
        let mut request = Request::new(
            "post",
            "https://api.twitter.com/1.1/statuses/update.json?include_entities=true",
        );
        request.add_header("Content-Type", "application/x-www-form-urlencoded");
        request.body = Some(
            "status=Hello%20Ladies%20%2B%20Gentlemen%2C%20a%20signed%20OAuth%20request%21".into(),
        );
        let auth = Auth::new(
            AuthKind::OAuth1,
            &[
                ("consumerKey", "xvz1evFS4wEEPTGEFPHBog"),
                (
                    "consumerSecret",
                    "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw",
                ),
                (
                    "token",
                    "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb",
                ),
                ("tokenSecret", "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE"),
                ("nonce", "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg"),
                ("timestamp", "1318622958"),
            ],
        );
        signed(&mut request, &auth, &Clock::now());
        let value = header(&request, "Authorization");
        assert!(
            value.starts_with("OAuth oauth_consumer_key=\"xvz1evFS4wEEPTGEFPHBog\""),
            "{value}"
        );
        assert!(
            value.contains("oauth_signature=\"hCtSmYh%2BiHYCEqBWrE7C7hYmtUk%3D\""),
            "{value}"
        );

        // PLAINTEXT sends the key itself, and query placement leaves headers alone.
        let mut plain = auth.clone();
        plain.params.extend(
            Auth::new(
                AuthKind::OAuth1,
                &[
                    ("signatureMethod", "PLAINTEXT"),
                    ("addParamsToHeader", "query"),
                ],
            )
            .params,
        );
        let mut request = Request::new("GET", "https://api.test/");
        signed(&mut request, &plain, &Clock::now());
        assert_eq!(header(&request, "Authorization"), "");
        assert!(request.url.contains(
            "oauth_signature=kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw%26LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE"
        ));
    }

    /// The example from the Hawk specification's readme.
    #[test]
    fn hawk_matches_the_specification_example() {
        let mut request = Request::new("GET", "http://example.com:8000/resource/1?b=1&a=2");
        let auth = Auth::new(
            AuthKind::Hawk,
            &[
                ("authId", "dh37fgj492je"),
                ("authKey", "werxhqb98rpaxn39848xrunpaw3489ruxnpa98w4rxn"),
                ("extraData", "some-app-ext-data"),
            ],
        );
        let mut pinned = auth.clone();
        pinned.params.push(AuthParam {
            key: "nonce".into(),
            value: "j4h3g2".into(),
        });
        signed(&mut request, &pinned, &clock(1353832234, "unused-nonce"));
        assert_eq!(
            header(&request, "Authorization"),
            "Hawk id=\"dh37fgj492je\", ts=\"1353832234\", nonce=\"j4h3g2\", ext=\"some-app-ext-data\", mac=\"6R4rV5iE+NPoym+WwjeHzjAGXUtLNIxmo1vpMofpLAE=\""
        );
    }

    /// `get-vanilla` from the AWS Signature Version 4 test suite.
    #[test]
    fn aws_v4_matches_the_test_suite() {
        let mut request = Request::new("GET", "https://example.amazonaws.com/");
        let auth = Auth::new(
            AuthKind::AwsV4,
            &[
                ("accessKey", "AKIDEXAMPLE"),
                ("secretKey", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                ("service", "service"),
            ],
        );
        // 2015-08-30T12:36:00Z
        signed(&mut request, &auth, &clock(1_440_938_160, ""));
        assert_eq!(header(&request, "X-Amz-Date"), "20150830T123600Z");
        assert_eq!(
            header(&request, "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        );
    }

    /// The example from RFC 2617 section 3.5.
    #[test]
    fn digest_matches_the_rfc_example() {
        let challenge = r#"realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#;
        let header = digest_header(
            challenge,
            "GET",
            "/dir/index.html",
            "Mufasa",
            "Circle Of Life",
            "0a4f113b",
        )
        .unwrap();
        assert!(
            header.contains("response=\"6629fae49393a05397450978507c4ef1\""),
            "{header}"
        );
        assert!(header.contains("qop=auth, nc=00000001, cnonce=\"0a4f113b\""));
        assert!(header.contains("opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""));

        assert!(digest_header("realm=\"x\"", "GET", "/", "u", "p", "c").is_err());
    }

    #[test]
    fn edgegrid_builds_a_well_formed_header() {
        let auth = Auth::new(
            AuthKind::EdgeGrid,
            &[
                ("clientToken", "akab-client"),
                ("accessToken", "akab-access"),
                ("clientSecret", "secret"),
                ("timestamp", "20140321T19:34:21+0000"),
                ("nonce", "nonce-xx"),
            ],
        );
        let mut request = Request::new(
            "POST",
            "https://akaa-host.luna.akamaiapis.net/testapi/v1/t3",
        );
        request.body = Some("datadatadata".into());
        signed(&mut request, &auth, &Clock::now());
        let with_body = header(&request, "Authorization").to_string();
        assert!(with_body.starts_with(
            "EG1-HMAC-SHA256 client_token=akab-client;access_token=akab-access;timestamp=20140321T19:34:21+0000;nonce=nonce-xx;signature="
        ));
        let signature = with_body.rsplit_once("signature=").unwrap().1;
        assert_eq!(BASE64.decode(signature).unwrap().len(), 32);

        // Signing is deterministic, and the body is part of what is signed.
        signed(&mut request, &auth, &Clock::now());
        assert_eq!(header(&request, "Authorization"), with_body);
        request.body = Some("other".into());
        signed(&mut request, &auth, &Clock::now());
        assert_ne!(header(&request, "Authorization"), with_body);

        // Generated timestamps use Akamai's format.
        let generated = Auth::new(
            AuthKind::EdgeGrid,
            &[
                ("clientToken", "c"),
                ("accessToken", "a"),
                ("clientSecret", "s"),
            ],
        );
        signed(&mut request, &generated, &clock(1_440_938_160, "n1"));
        assert!(
            header(&request, "Authorization")
                .contains("timestamp=20150830T12:36:00+0000;nonce=n1;")
        );
    }

    #[test]
    fn parses_challenges_with_commas_in_quotes() {
        let params = challenge_params(r#"realm="a, b", qop=auth, nonce="n1",algorithm=MD5-sess"#);
        assert_eq!(params["realm"], "a, b");
        assert_eq!(params["qop"], "auth");
        assert_eq!(params["nonce"], "n1");
        assert_eq!(params["algorithm"], "MD5-sess");
    }
}
