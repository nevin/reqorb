//! Authorization: the types a request can use, the fields each one takes,
//! and how each is applied.
//!
//! Types worked out from the request alone are in `sign`; those that need
//! an answer from the server first are in `negotiate`.

mod negotiate;
mod sign;

#[cfg(test)]
mod tests;

use serde::{Deserialize, Serialize};

use crate::Error;

pub(crate) use negotiate::negotiate;
pub(crate) use sign::{Clock, sign};

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

pub(super) fn secret(key: &str, label: &str) -> AuthField {
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
