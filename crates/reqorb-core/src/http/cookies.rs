//! The cookie jar: what servers set, what goes back to them, and when.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use url::Url;

use crate::time::now;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cookie {
    pub name: String,
    pub value: String,
    /// Host the cookie belongs to, without a leading dot.
    pub domain: String,
    pub path: String,
    /// Unix time the cookie expires; `None` for a session cookie.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires: Option<i64>,
    /// Only sent over HTTPS.
    #[serde(default)]
    pub secure: bool,
    #[serde(default)]
    pub http_only: bool,
    /// Sent to `domain` only, not to its subdomains.
    #[serde(default)]
    pub host_only: bool,
}

impl Cookie {
    fn is_expired(&self, now: i64) -> bool {
        self.expires.is_some_and(|at| at <= now)
    }

    fn matches(&self, url: &Url, now: i64) -> bool {
        let host = url.host_str().unwrap_or("").to_ascii_lowercase();
        let domain = self.domain.to_ascii_lowercase();
        let host_ok = host == domain || (!self.host_only && host.ends_with(&format!(".{domain}")));
        let path = url.path();
        let path_ok = path == self.path
            || (path.starts_with(&self.path)
                && (self.path.ends_with('/') || path[self.path.len()..].starts_with('/')));
        host_ok && path_ok && (!self.secure || url.scheme() == "https") && !self.is_expired(now)
    }
}

/// Whether `domain` is one under which anyone may register a name, such as
/// `com` or `co.uk`, by the Public Suffix List.
fn is_public_suffix(domain: &str) -> bool {
    psl::suffix_str(domain).is_some_and(|suffix| suffix.eq_ignore_ascii_case(domain))
}

/// Applies one `Set-Cookie` header received from `url`. Cookies for a
/// domain the response does not belong to are ignored.
pub fn store_set_cookie(jar: &mut Vec<Cookie>, header: &str, url: &Url, now: i64) {
    let Ok(parsed) = cookie::Cookie::parse(header.to_string()) else {
        return;
    };
    let host = url.host_str().unwrap_or("").to_ascii_lowercase();
    // Only a page reached securely may set a cookie kept for secure pages.
    if parsed.secure() == Some(true) && url.scheme() != "https" {
        return;
    }
    let (domain, host_only) = match parsed.domain().map(|d| d.trim_start_matches('.')) {
        Some(domain) if !domain.is_empty() => {
            let domain = domain.to_ascii_lowercase();
            if domain == host {
                // A cookie for exactly this host, but which a public suffix
                // such as `localhost` must not share with others under it.
                (domain.clone(), is_public_suffix(&domain))
            } else if matches!(url.host(), Some(url::Host::Domain(_)))
                && host.ends_with(&format!(".{domain}"))
                // Otherwise `evil.com` could set a cookie that every site
                // under `.com` would be sent.
                && !is_public_suffix(&domain)
            {
                (domain, false)
            } else {
                return;
            }
        }
        _ => (host, true),
    };
    let path = match parsed.path() {
        Some(path) if path.starts_with('/') => path.to_string(),
        // The default is the directory of the request path.
        _ => match url.path().rfind('/') {
            Some(0) | None => "/".to_string(),
            Some(last) => url.path()[..last].to_string(),
        },
    };
    let expires = match parsed.max_age() {
        Some(age) => Some(now + age.whole_seconds()),
        None => parsed.expires_datetime().map(|at| at.unix_timestamp()),
    };

    let new = Cookie {
        name: parsed.name().to_string(),
        value: parsed.value().to_string(),
        domain,
        path,
        expires,
        secure: parsed.secure().unwrap_or(false),
        http_only: parsed.http_only().unwrap_or(false),
        host_only,
    };
    jar.retain(|c| !(c.name == new.name && c.domain == new.domain && c.path == new.path));
    // A cookie that arrives already expired is the server deleting it.
    if !new.is_expired(now) {
        jar.push(new);
    }
}

/// The `Cookie` header value for a request to `url`, most specific path first.
pub fn cookie_header(jar: &[Cookie], url: &Url, now: i64) -> Option<String> {
    let mut matching: Vec<&Cookie> = jar.iter().filter(|c| c.matches(url, now)).collect();
    matching.sort_by_key(|c| std::cmp::Reverse(c.path.len()));
    (!matching.is_empty()).then(|| {
        matching
            .iter()
            .map(|c| format!("{}={}", c.name, c.value))
            .collect::<Vec<_>>()
            .join("; ")
    })
}

/// The jar for one send, shared by every exchange it makes so that cookies
/// also flow through redirects and multi-step authentication.
pub(crate) struct Jar(Mutex<Vec<Cookie>>);

impl Jar {
    pub fn new(cookies: &[Cookie]) -> Self {
        let now = now();
        Self(Mutex::new(
            cookies
                .iter()
                .filter(|c| !c.is_expired(now))
                .cloned()
                .collect(),
        ))
    }

    pub fn snapshot(&self) -> Vec<Cookie> {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

impl Jar {
    /// Stores the `Set-Cookie` headers of a response from `url`.
    pub fn store<'a>(&self, headers: impl Iterator<Item = &'a str>, url: &Url) {
        let mut jar = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let now = now();
        for header in headers {
            store_set_cookie(&mut jar, header, url, now);
        }
    }

    /// The `Cookie` header for a request to `url`. Cookies the request names
    /// itself in `own` win over stored ones of the same name.
    pub fn header_for(&self, url: &Url, own: Option<&str>) -> Option<String> {
        let stored = cookie_header(
            &self
                .0
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            url,
            now(),
        );
        let Some(own) = own else {
            return stored;
        };
        let named: Vec<&str> = own
            .split(';')
            .filter_map(|pair| pair.split('=').next())
            .map(str::trim)
            .collect();
        let stored = stored.unwrap_or_default();
        let extra: Vec<&str> = stored
            .split("; ")
            .filter(|pair| !pair.is_empty())
            .filter(|pair| !named.contains(&pair.split('=').next().unwrap_or("")))
            .collect();
        Some(if extra.is_empty() {
            own.to_string()
        } else {
            format!("{}; {}", own.trim_end_matches([';', ' ']), extra.join("; "))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    #[test]
    fn stores_replaces_and_deletes() {
        let mut jar = Vec::new();
        let from = url("https://app.shop.test/account/login");
        store_set_cookie(&mut jar, "sid=abc; Path=/; HttpOnly; Secure", &from, 100);
        store_set_cookie(
            &mut jar,
            "theme=dark; Domain=.shop.test; Max-Age=60",
            &from,
            100,
        );
        store_set_cookie(&mut jar, "step=1", &from, 100);
        store_set_cookie(&mut jar, "evil=1; Domain=other.test", &from, 100);
        store_set_cookie(
            &mut jar,
            "old=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT",
            &from,
            1_700_000_000,
        );
        assert_eq!(
            jar.len(),
            3,
            "foreign and already-expired cookies are dropped"
        );

        let sid = &jar[0];
        assert_eq!(
            (sid.domain.as_str(), sid.path.as_str()),
            ("app.shop.test", "/")
        );
        assert!(sid.host_only && sid.secure && sid.http_only && sid.expires.is_none());
        let theme = &jar[1];
        assert_eq!(theme.domain, "shop.test");
        assert!(!theme.host_only);
        assert_eq!(theme.expires, Some(160));
        assert_eq!(
            jar[2].path, "/account",
            "defaults to the request's directory"
        );

        store_set_cookie(&mut jar, "sid=xyz; Path=/", &from, 100);
        assert_eq!(jar.iter().filter(|c| c.name == "sid").count(), 1);
        assert_eq!(jar.iter().find(|c| c.name == "sid").unwrap().value, "xyz");

        store_set_cookie(&mut jar, "sid=; Path=/; Max-Age=0", &from, 100);
        assert!(!jar.iter().any(|c| c.name == "sid"));

        let dated = "d=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT";
        store_set_cookie(&mut jar, dated, &from, 0);
        assert_eq!(jar.last().unwrap().expires, Some(1_445_412_480));
    }

    #[test]
    fn refuses_cookies_for_public_suffixes_addresses_and_insecure_pages() {
        let mut jar = Vec::new();
        let at = |s: &str, jar: &mut Vec<Cookie>, header: &str| {
            store_set_cookie(jar, header, &url(s), 100)
        };
        // Every site under these could otherwise be sent the cookie.
        at("https://evil.com/", &mut jar, "a=1; Domain=com");
        at("https://evil.co.uk/", &mut jar, "b=1; Domain=.co.uk");
        // An address is not a name with others under it.
        at("http://10.0.0.1/", &mut jar, "c=1; Domain=0.0.1");
        // A secure cookie from a page that was not.
        at("http://shop.test/", &mut jar, "d=1; Secure");
        assert!(jar.is_empty(), "{jar:?}");

        // Exactly the host is fine, even a public suffix, but for it alone.
        at("http://localhost:8080/", &mut jar, "e=1; Domain=localhost");
        at("http://10.0.0.1/", &mut jar, "f=1; Domain=10.0.0.1");
        at("https://shop.co.uk/", &mut jar, "g=1; Domain=shop.co.uk");
        let kept: Vec<_> = jar.iter().map(|c| (c.name.as_str(), c.host_only)).collect();
        assert_eq!(kept, [("e", true), ("f", false), ("g", false)]);
    }

    #[test]
    fn sends_only_what_matches() {
        let mut jar = Vec::new();
        let from = url("https://app.shop.test/account/login");
        store_set_cookie(&mut jar, "host=1; Path=/", &from, 0);
        store_set_cookie(&mut jar, "wide=1; Domain=shop.test; Path=/", &from, 0);
        store_set_cookie(&mut jar, "deep=1; Path=/account", &from, 0);
        store_set_cookie(&mut jar, "safe=1; Path=/; Secure", &from, 0);
        store_set_cookie(&mut jar, "brief=1; Path=/; Max-Age=10", &from, 0);

        let header = |target: &str, now: i64| cookie_header(&jar, &url(target), now);
        assert_eq!(
            header("https://app.shop.test/account/orders", 5).unwrap(),
            "deep=1; host=1; wide=1; safe=1; brief=1"
        );
        assert_eq!(
            header("https://app.shop.test/accounting", 5).unwrap(),
            "host=1; wide=1; safe=1; brief=1"
        );
        assert_eq!(
            header("https://app.shop.test/", 50).unwrap(),
            "host=1; wide=1; safe=1"
        );
        assert_eq!(
            header("http://app.shop.test/", 50).unwrap(),
            "host=1; wide=1"
        );
        assert_eq!(header("https://api.shop.test/", 50).unwrap(), "wide=1");
        assert_eq!(header("https://notshop.test/", 5), None);
        assert_eq!(header("https://evilshop.test/", 5), None);
    }
}
