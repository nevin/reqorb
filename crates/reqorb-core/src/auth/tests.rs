use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;

use super::negotiate::*;
use super::sign::*;
use super::*;
use crate::Request;

pub(super) fn clock(unix: u64, nonce: &str) -> Clock {
    Clock {
        unix,
        nonce: nonce.into(),
    }
}

pub(super) fn signed(request: &mut Request, auth: &Auth, clock: &Clock) {
    assert!(sign(request, auth, clock).unwrap());
}

pub(super) fn header<'a>(request: &'a Request, name: &str) -> &'a str {
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
    request.body =
        Some("status=Hello%20Ladies%20%2B%20Gentlemen%2C%20a%20signed%20OAuth%20request%21".into());
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
        header(&request, "Authorization").contains("timestamp=20150830T12:36:00+0000;nonce=n1;")
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
