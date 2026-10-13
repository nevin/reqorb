//! What can go wrong while sending, importing or exporting.

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid HTTP method `{0}`")]
    InvalidMethod(String),
    #[error("invalid URL `{url}`: {reason}")]
    InvalidUrl { url: String, reason: String },
    #[error("request timed out")]
    Timeout,
    #[error("the request was cancelled")]
    Cancelled,
    #[error("could not connect: {0}")]
    Connect(String),
    #[error("{0}")]
    Http(String),
    #[error("unresolved variable(s): {}", .0.join(", "))]
    UnresolvedVariables(Vec<String>),
    #[error("{0}")]
    Format(String),
    #[error("{0}")]
    Auth(String),
    #[error("{0}")]
    Io(String),
    #[error("{0}")]
    Script(String),
}

impl From<reqwest::Error> for Error {
    fn from(e: reqwest::Error) -> Self {
        // reqwest's Display omits the underlying cause, which is the useful part.
        let mut msg = e.to_string();
        let mut source = std::error::Error::source(&e);
        while let Some(s) = source {
            msg = format!("{msg}: {s}");
            source = s.source();
        }
        if e.is_timeout() {
            Error::Timeout
        } else if e.is_connect() {
            Error::Connect(msg)
        } else {
            Error::Http(msg)
        }
    }
}
