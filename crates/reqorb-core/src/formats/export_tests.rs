use serde_json::Value;

use crate::*;

pub(super) fn sample() -> Collection {
    let mut create = Request::new("POST", "{{base}}/orders?x=it's");
    create.headers.push(Header {
        name: "Content-Type".into(),
        value: "application/json".into(),
    });
    create.body = Some("{\"sku\": \"a'b\"}".into());
    create.timeout_ms = Some(1500);
    Collection {
        name: "Shop".into(),
        variables: vec![
            Variable::new("base", "https://shop.test"),
            Variable {
                key: "off".into(),
                value: "1".into(),
                enabled: false,
            },
        ],
        items: vec![
            Item {
                name: "Orders".into(),
                request: None,
                items: vec![Item {
                    name: "Create".into(),
                    request: Some(create),
                    items: Vec::new(),
                }],
            },
            Item {
                name: "Ping".into(),
                request: Some(Request::new("GET", "{{base}}/ping")),
                items: Vec::new(),
            },
        ],
    }
}

fn sample_env() -> Environment {
    Environment {
        name: "Staging".into(),
        variables: vec![
            Variable::new("base", "https://staging.test"),
            Variable::new("note", "two words # \"quoted\""),
            Variable {
                key: "debug".into(),
                value: "1".into(),
                enabled: false,
            },
        ],
    }
}

#[test]
fn native_round_trip() {
    let text = export_native(&[sample()], &[sample_env()]);
    let back = import(&text, "x").unwrap();
    assert_eq!(back.source, "reqorb");
    assert_eq!(back.collections, [sample()]);
    assert_eq!(back.environments, [sample_env()]);
}

#[test]
fn postman_round_trip() {
    let text = export_collection(&sample(), ExportFormat::Postman).unwrap();
    let back = import(&text, "x").unwrap();
    assert_eq!(back.source, "postman-collection");
    assert!(back.warnings.is_empty());
    // Postman has no per-request timeout, so that field is lost.
    let mut expected = sample();
    expected.items[0].items[0]
        .request
        .as_mut()
        .unwrap()
        .timeout_ms = None;
    assert_eq!(back.collections, [expected]);

    let text = export_environment(&sample_env(), ExportFormat::Postman).unwrap();
    let back = import(&text, "x").unwrap();
    assert_eq!(back.environments, [sample_env()]);
}

#[test]
fn auth_survives_postman_and_reaches_other_formats() {
    let with = |auth: Auth| {
        let mut request = Request::new("GET", "{{base}}/secure?x=1");
        request.auth = Some(auth);
        request
    };
    let cases = [
        with(Auth::new(
            AuthKind::Basic,
            &[("username", "{{user}}"), ("password", "p'w")],
        )),
        with(Auth::new(AuthKind::Bearer, &[("token", "{{token}}")])),
        with(Auth::new(
            AuthKind::ApiKey,
            &[("key", "api_key"), ("value", "{{key}}"), ("in", "query")],
        )),
        with(Auth::new(
            AuthKind::Digest,
            &[("username", "u"), ("password", "p")],
        )),
        with(Auth::new(
            AuthKind::Ntlm,
            &[("username", "u"), ("password", "p"), ("domain", "CORP")],
        )),
        with(Auth::new(
            AuthKind::AwsV4,
            &[("accessKey", "AK"), ("secretKey", "SK"), ("service", "s3")],
        )),
        with(Auth::new(
            AuthKind::OAuth1,
            &[("consumerKey", "ck"), ("addParamsToHeader", "query")],
        )),
        with(Auth::new(
            AuthKind::Hawk,
            &[("authId", "id"), ("authKey", "key")],
        )),
    ];
    let collection = Collection {
        name: "Auth".into(),
        variables: Vec::new(),
        items: cases
            .iter()
            .map(|request| Item {
                name: request.auth.as_ref().unwrap().kind.label().into(),
                request: Some(request.clone()),
                items: Vec::new(),
            })
            .collect(),
    };

    // Postman keeps every type, parameter for parameter.
    let postman = export_collection(&collection, ExportFormat::Postman).unwrap();
    let value: Value = serde_json::from_str(&postman).unwrap();
    assert_eq!(
        value["item"][6]["request"]["auth"]["oauth1"][1]["value"],
        false
    );
    let back = import(&postman, "x").unwrap();
    assert!(back.warnings.is_empty(), "{:?}", back.warnings);
    assert_eq!(back.collections, std::slice::from_ref(&collection));

    let curl: Vec<String> = cases.iter().map(to_curl).collect();
    assert!(curl[0].ends_with("-u '{{user}}:p'\\''w'"), "{}", curl[0]);
    assert!(curl[1].contains("-H 'Authorization: Bearer {{token}}'"));
    assert!(curl[2].contains("'{{base}}/secure?x=1&api_key={{key}}'"));
    assert!(curl[3].ends_with("--digest -u 'u:p'"));
    assert!(curl[4].ends_with("--ntlm -u 'CORP\\u:p'"));
    assert!(curl[5].ends_with("--aws-sigv4 'aws:amz:us-east-1:s3' -u 'AK:SK'"));
    assert!(curl[7].starts_with("# Hawk Authentication is computed by reqorb"));
    assert!(curl[7].contains("\ncurl "));

    let bruno: Value =
        serde_json::from_str(&export_collection(&collection, ExportFormat::Bruno).unwrap())
            .unwrap();
    let auth = |i: usize| &bruno["items"][i]["request"]["auth"];
    assert_eq!(auth(0)["basic"]["username"], "{{user}}");
    assert_eq!(auth(1)["bearer"]["token"], "{{token}}");
    assert_eq!(auth(2)["apikey"]["placement"], "queryparams");
    assert_eq!(auth(3)["mode"], "digest");
    assert_eq!(auth(4)["ntlm"]["domain"], "CORP");
    assert_eq!(auth(5)["awsv4"]["accessKeyId"], "AK");
    assert_eq!(auth(7)["mode"], "none");
}

#[test]
fn body_types_reach_every_format() {
    use crate::FormField;
    let with = |name: &str, change: &dyn Fn(&mut Request)| {
        let mut request = Request::new("POST", "https://api.test/u");
        change(&mut request);
        Item {
            name: name.into(),
            request: Some(request),
            items: Vec::new(),
        }
    };
    let collection = Collection {
        name: "Bodies".into(),
        variables: Vec::new(),
        items: vec![
            with("form", &|r| {
                r.body_mode = Some(BodyMode::FormData);
                r.form = vec![
                    FormField::text("title", "it's {{x}}"),
                    FormField::text("at", "@home"),
                    FormField::file("doc", "/tmp/a b.pdf"),
                ];
            }),
            with("encoded", &|r| {
                r.body_mode = Some(BodyMode::UrlEncoded);
                r.form = vec![FormField::text("q", "a b"), FormField::text("v", "{{v}}")];
            }),
            with("binary", &|r| {
                r.body_mode = Some(BodyMode::Binary);
                r.body = Some("/tmp/data.bin".into());
            }),
            with("none", &|r| r.body_mode = Some(BodyMode::None)),
        ],
    };

    // Postman keeps every type; an explicit "none" comes back as no body.
    let postman = export_collection(&collection, ExportFormat::Postman).unwrap();
    let value: Value = serde_json::from_str(&postman).unwrap();
    assert_eq!(
        value["item"][0]["request"]["body"]["formdata"][2]["src"],
        "/tmp/a b.pdf"
    );
    assert_eq!(
        value["item"][1]["request"]["body"]["urlencoded"][0]["value"],
        "a b"
    );
    assert_eq!(
        value["item"][2]["request"]["body"]["file"]["src"],
        "/tmp/data.bin"
    );
    assert!(value["item"][3]["request"].get("body").is_none());
    let back = import(&postman, "x").unwrap();
    assert_eq!(back.collections[0].items[..3], collection.items[..3]);
    assert_eq!(
        back.collections[0].items[3]
            .request
            .as_ref()
            .unwrap()
            .body_mode,
        None
    );

    // curl uses its own upload options, and they import back the same.
    let requests = collection.requests();
    let form = to_curl(requests[0].1);
    assert!(form.contains("-F 'title=it'\\''s {{x}}'"), "{form}");
    assert!(form.contains("--form-string 'at=@home'"));
    assert!(form.contains("-F 'doc=@/tmp/a b.pdf'"));
    assert!(!form.contains("-X"), "POST is curl's default with a form");
    let back = import(&form, "x").unwrap();
    assert_eq!(
        back.collections[0].items[0].request.as_ref(),
        Some(requests[0].1)
    );

    let encoded = to_curl(requests[1].1);
    assert!(encoded.contains("--data-raw 'q=a+b&v={{v}}'"), "{encoded}");
    assert!(encoded.contains("Content-Type: application/x-www-form-urlencoded"));
    let binary = to_curl(requests[2].1);
    assert!(
        binary.ends_with("--data-binary '@/tmp/data.bin'"),
        "{binary}"
    );
    assert_eq!(
        to_curl(requests[3].1),
        "curl \\\n  -X POST \\\n  'https://api.test/u'"
    );

    let bruno: Value =
        serde_json::from_str(&export_collection(&collection, ExportFormat::Bruno).unwrap())
            .unwrap();
    let body = |i: usize| &bruno["items"][i]["request"]["body"];
    assert_eq!(body(0)["mode"], "multipartForm");
    assert_eq!(body(0)["multipartForm"][0]["value"], "it's {{x}}");
    assert_eq!(body(0)["multipartForm"][2]["type"], "file");
    assert_eq!(body(0)["multipartForm"][2]["value"][0], "/tmp/a b.pdf");
    assert_eq!(body(1)["mode"], "formUrlEncoded");
    assert_eq!(body(1)["formUrlEncoded"][0]["value"], "a b");
    assert_eq!(body(2)["mode"], "none");
    assert_eq!(body(3)["mode"], "none");
}

#[test]
fn request_settings_survive_postman() {
    let mut request = Request::new("GET", "https://api.test/");
    request.settings = Some(RequestSettings {
        http_mode: Some(HttpMode::Http1),
        verify_ssl: false,
        follow_redirects: false,
        follow_original_method: true,
        follow_auth_header: true,
        remove_referer: true,
        strict_http_parser: true,
        disable_cookie_jar: true,
        max_redirects: 3,
        disabled_tls: DisabledTls::Tls12,
    });
    let collection = Collection {
        name: "S".into(),
        variables: Vec::new(),
        items: vec![
            Item {
                name: "custom".into(),
                request: Some(request),
                items: Vec::new(),
            },
            Item {
                name: "plain".into(),
                request: Some(Request::new("GET", "https://api.test/")),
                items: Vec::new(),
            },
        ],
    };
    let text = export_collection(&collection, ExportFormat::Postman).unwrap();
    let value: Value = serde_json::from_str(&text).unwrap();
    let profile = &value["item"][0]["protocolProfileBehavior"];
    assert_eq!(profile["strictSSL"], false);
    assert_eq!(profile["insecureHTTPParser"], false);
    assert_eq!(profile["protocolVersion"], "http1");
    assert_eq!(profile["tlsDisabledProtocols"][0], "TLSv1_2");
    assert_eq!(profile["maxRedirects"], 3);
    assert!(value["item"][1].get("protocolProfileBehavior").is_none());

    let back = import(&text, "x").unwrap();
    assert_eq!(back.collections, std::slice::from_ref(&collection));
}

#[test]
fn bruno_export() {
    let mut collection = sample();
    let mut login = Request::new("post", "{{base}}/login?next=%2Fhome&debug#top");
    login.add_header("Content-Type", "application/x-www-form-urlencoded");
    login.body = Some("user=a+b&pw={{pw}}".into());
    collection.items.push(Item {
        name: "Login".into(),
        request: Some(login),
        items: Vec::new(),
    });

    let text = export_collection(&collection, ExportFormat::Bruno).unwrap();
    let bruno: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(bruno["name"], "Shop");
    assert_eq!(bruno["version"], "1");
    assert_eq!(bruno["root"]["request"]["vars"]["req"][0]["name"], "base");
    assert_eq!(bruno["root"]["request"]["vars"]["req"][1]["enabled"], false);

    let folder = &bruno["items"][0];
    assert_eq!(folder["type"], "folder");
    let create = &folder["items"][0];
    assert_eq!(create["type"], "http-request");
    assert_eq!(create["seq"], 1);
    assert_eq!(create["settings"]["timeout"], 1500);
    assert_eq!(create["request"]["method"], "POST");
    assert_eq!(create["request"]["body"]["mode"], "json");
    assert_eq!(create["request"]["body"]["json"], "{\"sku\": \"a'b\"}");
    assert_eq!(create["request"]["params"][0]["name"], "x");
    assert_eq!(create["request"]["params"][0]["type"], "query");

    assert_eq!(bruno["items"][1]["request"]["body"]["mode"], "none");

    let login = &bruno["items"][2]["request"];
    assert_eq!(login["params"].as_array().unwrap().len(), 2);
    assert_eq!(login["params"][1]["name"], "debug");
    assert_eq!(login["body"]["mode"], "formUrlEncoded");
    assert_eq!(login["body"]["formUrlEncoded"][0]["value"], "a b");
    assert_eq!(login["body"]["formUrlEncoded"][1]["value"], "{{pw}}");

    // Every id is present, well formed and distinct.
    let mut uids = Vec::new();
    fn collect(value: &Value, uids: &mut Vec<String>) {
        match value {
            Value::Object(map) => {
                for (key, child) in map {
                    if key == "uid" {
                        uids.push(child.as_str().unwrap().to_string());
                    }
                    collect(child, uids);
                }
            }
            Value::Array(list) => list.iter().for_each(|v| collect(v, uids)),
            _ => {}
        }
    }
    collect(&bruno, &mut uids);
    assert!(uids.len() > 10);
    assert!(
        uids.iter()
            .all(|u| u.len() == 21 && u.chars().all(|c| c.is_ascii_alphanumeric()))
    );
    let unique: std::collections::HashSet<_> = uids.iter().collect();
    assert_eq!(unique.len(), uids.len());

    assert!(export_environment(&sample_env(), ExportFormat::Bruno).is_err());
}

#[test]
fn curl_round_trip() {
    let collection = sample();
    let (_, request) = collection.requests()[0].clone();
    let command = to_curl(request);
    assert!(command.starts_with("curl \\\n  '{{base}}/orders?x=it'\\''s'"));
    let back = import(&command, "x").unwrap();
    assert_eq!(back.collections[0].items[0].request.as_ref(), Some(request));

    let script = export_collection(&collection, ExportFormat::Curl).unwrap();
    assert!(script.contains("# Orders/Create\ncurl"));
    assert!(script.contains("# Ping\ncurl \\\n  '{{base}}/ping'"));
}

#[test]
fn other_tools_formats_leave_out_websocket_and_grpc_requests() {
    let item = |name: &str, method: &str| Item {
        name: name.into(),
        request: Some(Request::new(method, "example.com:50051")),
        items: vec![],
    };
    let collection = Collection {
        name: "Mixed".into(),
        variables: vec![],
        items: vec![
            item("Ping", "GET"),
            item("Feed", "WS"),
            item("Call", "GRPC"),
        ],
    };
    for format in [
        ExportFormat::Postman,
        ExportFormat::Bruno,
        ExportFormat::Curl,
    ] {
        let out = export_collection(&collection, format).unwrap();
        assert!(out.contains("Ping"), "{out}");
        assert!(!out.contains("Feed") && !out.contains("Call"), "{out}");
    }
    // reqorb's own format keeps everything.
    let native = export_collection(&collection, ExportFormat::Reqorb).unwrap();
    assert!(native.contains("Feed") && native.contains("GRPC"));
}

#[test]
fn dotenv_export() {
    let text = export_environment(&sample_env(), ExportFormat::Dotenv).unwrap();
    assert_eq!(
        text,
        "base=https://staging.test\nnote=\"two words # \\\"quoted\\\"\"\n# debug=1\n"
    );
    let back = import(&text, "Staging").unwrap();
    // Disabled variables become comments, so only the enabled ones return.
    assert_eq!(back.environments[0].variables, sample_env().variables[..2]);

    assert!(export_collection(&sample(), ExportFormat::Dotenv).is_err());
    assert!(export_environment(&sample_env(), ExportFormat::Curl).is_err());
}
