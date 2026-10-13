use super::*;
use crate::Auth;

fn code(request: &Request, target: CodeTarget) -> String {
    generate_code(request, &[], target).unwrap()
}

fn json_post() -> Request {
    let mut request = Request::new("post", "https://api.test/items?x=1");
    request.add_header("Content-Type", "application/json");
    request.add_header("X-Quote", "say \"hi\" for $5");
    request.body = Some("{\n  \"name\": \"Zoë\",\n  \"ok\": true,\n  \"none\": null\n}".into());
    request.timeout_ms = Some(2500);
    request
}

#[test]
fn every_language_writes_the_whole_request() {
    let request = json_post();
    for target in CodeTarget::ALL {
        let code = code(&request, target);
        assert!(
            code.contains("https://api.test/items?x=1"),
            "{target:?}\n{code}"
        );
        // POST is what curl does anyway, given a body; Ruby has a class for it.
        assert!(
            code.to_uppercase().contains("POST") || target == CodeTarget::Curl,
            "{target:?}\n{code}"
        );
        assert!(code.contains("X-Quote"), "{target:?}\n{code}");
        assert!(code.contains("Zoë"), "{target:?}\n{code}");
        assert!(
            code.ends_with('\n') && !code.ends_with("\n\n"),
            "{target:?}"
        );
        assert_eq!(CodeTarget::from_id(target.id()), Some(target));
    }
}

#[test]
fn languages_are_found_by_their_usual_short_names() {
    assert_eq!(CodeTarget::from_id("JS"), Some(CodeTarget::Fetch));
    assert_eq!(CodeTarget::from_id("py"), Some(CodeTarget::Python));
    assert_eq!(CodeTarget::from_id("c++"), Some(CodeTarget::Cpp));
    assert_eq!(CodeTarget::from_id("c#"), Some(CodeTarget::CSharp));
    assert_eq!(CodeTarget::from_id("cobol"), None);
}

#[test]
fn each_language_escapes_in_its_own_way() {
    let request = json_post();
    let header = |target| {
        let code = code(&request, target);
        code.lines()
            .find(|line| line.contains("X-Quote"))
            .unwrap()
            .trim()
            .to_string()
    };
    assert_eq!(
        header(CodeTarget::Fetch),
        r#""X-Quote": "say \"hi\" for $5","#
    );
    assert_eq!(
        header(CodeTarget::Kotlin),
        r#".addHeader("X-Quote", "say \"hi\" for \$5")"#
    );
    assert_eq!(
        header(CodeTarget::Dart),
        r#"'X-Quote': 'say "hi" for \$5',"#
    );
    assert_eq!(
        header(CodeTarget::Rust),
        r##".header("X-Quote", r#"say "hi" for $5"#)"##
    );
    assert_eq!(
        header(CodeTarget::Ruby),
        r#"request['X-Quote'] = 'say "hi" for $5'"#
    );
    assert_eq!(
        header(CodeTarget::PowerShell),
        r#"'X-Quote' = 'say "hi" for $5'"#
    );
    assert_eq!(
        header(CodeTarget::Cpp),
        r#"headers = curl_slist_append(headers, "X-Quote: say \"hi\" for $5");"#
    );
}

#[test]
fn characters_that_cannot_be_seen_are_escaped() {
    let mut request = Request::new("PUT", "http://h.test");
    request.body = Some("a\u{1}b\r\n#{c} $d `e`".into());
    let body = |target, marker: &str| {
        let code = code(&request, target);
        let line = code.lines().find(|line| line.contains(marker)).unwrap();
        line[line.find(marker).unwrap() + marker.len()..].to_string()
    };
    assert_eq!(
        body(CodeTarget::Go, "NewReader("),
        r#""a\u0001b\r\n#{c} $d `e`")"#
    );
    assert_eq!(
        body(CodeTarget::Swift, "Data("),
        r#""a\u{1}b\r\n#{c} $d `e`".utf8)"#
    );
    assert_eq!(
        body(CodeTarget::Cpp, "body = "),
        r#""a\001b\r\n#{c} $d `e`";"#
    );
    assert_eq!(
        body(CodeTarget::Ruby, "request.body = "),
        r#""a\u0001b\r\n\#{c} $d `e`""#
    );
    assert_eq!(
        body(CodeTarget::Php, "POSTFIELDS => "),
        r#""a\u{1}b\r\n#{c} \$d `e`","#
    );
    assert_eq!(
        body(CodeTarget::PowerShell, "GetBytes("),
        "\"a`u{1}b`r`n#{c} `$d ``e``\")"
    );
}

#[test]
fn a_json_body_is_written_as_a_value_where_the_language_has_one() {
    let python = code(&json_post(), CodeTarget::Python);
    assert!(
        python.contains(
            "payload = {\n    \"name\": \"Zoë\",\n    \"ok\": True,\n    \"none\": None,\n}"
        ),
        "{python}"
    );
    assert!(
        python.contains("    json=payload,\n    timeout=2.5,\n"),
        "{python}"
    );

    let fetch = code(&json_post(), CodeTarget::Fetch);
    assert!(
        fetch.contains("  body: JSON.stringify({\n    \"name\": \"Zoë\",\n    \"ok\": true,"),
        "{fetch}"
    );
    assert!(
        fetch.contains("  signal: AbortSignal.timeout(2500),"),
        "{fetch}"
    );

    // Text that only looks like JSON is sent exactly as written.
    let mut request = json_post();
    request.body = Some("{not json}".into());
    let python = code(&request, CodeTarget::Python);
    assert!(python.contains("payload = \"{not json}\""), "{python}");
    assert!(
        python.contains("data=payload.encode(\"utf-8\")"),
        "{python}"
    );
}

#[test]
fn variables_are_filled_in_and_missing_ones_pointed_out() {
    let mut request = Request::new("GET", "{{base}}/users/{{id}}");
    request.add_header("X-Key", "{{key}}");
    let variables = [Variable::new("base", "https://api.test")];
    let code = generate_code(&request, &variables, CodeTarget::Python).unwrap();
    assert!(
        code.starts_with("# No value is set for {{id}}, {{key}}; replace them before running.\n"),
        "{code}"
    );
    assert!(
        code.contains("url = \"https://api.test/users/{{id}}\""),
        "{code}"
    );

    let curl = generate_code(&request, &variables, CodeTarget::Curl).unwrap();
    assert!(curl.starts_with("# No value is set for"), "{curl}");
    assert!(curl.contains("'https://api.test/users/{{id}}'"), "{curl}");
}

#[test]
fn authentication_becomes_headers_or_a_note() {
    let mut request = Request::new("GET", "https://api.test/me");
    request.auth = Some(Auth::new(
        AuthKind::Basic,
        &[("username", "ann"), ("password", "s3cret")],
    ));
    let go = code(&request, CodeTarget::Go);
    assert!(
        go.contains("req.Header.Add(\"Authorization\", \"Basic YW5uOnMzY3JldA==\")"),
        "{go}"
    );
    // curl is given the name and password, to encode itself.
    assert!(code(&request, CodeTarget::Curl).contains("-u 'ann:s3cret'"));

    request.auth = Some(Auth::new(
        AuthKind::ApiKey,
        &[("key", "api_key"), ("value", "k1"), ("in", "query")],
    ));
    assert!(code(&request, CodeTarget::Swift).contains("\"https://api.test/me?api_key=k1\""));

    request.auth = Some(Auth::new(AuthKind::Hawk, &[]));
    let java = code(&request, CodeTarget::Java);
    assert!(
        java.starts_with("// Hawk Authentication is computed by reqorb when sending"),
        "{java}"
    );
    // PHP takes nothing for code before its opening tag.
    let php = code(&request, CodeTarget::Php);
    assert!(php.starts_with("<?php\n// Hawk Authentication"), "{php}");
}

#[test]
fn forms_and_files_use_each_client_s_own_means() {
    let mut request = Request::new("POST", "https://api.test/upload");
    request.body_mode = Some(BodyMode::FormData);
    request.add_header("Content-Type", "multipart/form-data");
    request.form = vec![
        FormField::text("title", "Hi"),
        FormField::file("doc", "/tmp/my file.pdf"),
    ];
    for target in CodeTarget::ALL {
        let code = code(&request, target);
        assert!(code.contains("/tmp/my file.pdf"), "{target:?}\n{code}");
        assert!(code.contains("title"), "{target:?}\n{code}");
    }
    // The client writes the header, boundary and all.
    let python = code(&request, CodeTarget::Python);
    assert!(!python.contains("Content-Type"), "{python}");
    assert!(
        python.contains("    (\"doc\", open(\"/tmp/my file.pdf\", \"rb\")),"),
        "{python}"
    );
    let go = code(&request, CodeTarget::Go);
    assert!(
        go.contains("\taddFile(form, \"doc\", \"/tmp/my file.pdf\")"),
        "{go}"
    );
    assert!(go.contains("\t\"path/filepath\"\n"), "{go}");
    let java = code(&request, CodeTarget::Java);
    assert!(java.contains("filename=\\\"my file.pdf\\\""), "{java}");

    let mut binary = Request::new("PUT", "https://api.test/blob");
    binary.body_mode = Some(BodyMode::Binary);
    binary.body = Some("/tmp/data.bin".into());
    assert!(code(&binary, CodeTarget::Rust).contains(".body(std::fs::read(\"/tmp/data.bin\")?)"));
    assert!(code(&binary, CodeTarget::PowerShell).contains("InFile = '/tmp/data.bin'"));
}

#[test]
fn graphql_and_url_encoded_bodies_are_written_as_sent() {
    let mut request = Request::new("POST", "https://api.test/graphql");
    request.body_mode = Some(BodyMode::GraphQl);
    request.body = Some("{ me { id } }".into());
    let ruby = code(&request, CodeTarget::Ruby);
    assert!(
        ruby.contains("request['Content-Type'] = 'application/json'"),
        "{ruby}"
    );
    assert!(ruby.contains("{ me { id } }"), "{ruby}");

    let mut form = Request::new("POST", "https://api.test/login");
    form.body_mode = Some(BodyMode::UrlEncoded);
    form.form = vec![FormField::text("user", "a b"), FormField::text("pw", "x&y")];
    let csharp = code(&form, CodeTarget::CSharp);
    assert!(
        csharp.contains("GetBytes(\"user=a+b&pw=x%26y\")"),
        "{csharp}"
    );
    assert!(
        csharp.contains(
            "request.Content.Headers.TryAddWithoutValidation(\"Content-Type\", \"application/x-www-form-urlencoded\");"
        ),
        "{csharp}"
    );
}

#[test]
fn only_http_requests_can_be_written() {
    for method in ["WS", "grpc"] {
        let request = Request::new(method, "wss://echo.test");
        assert!(generate_code(&request, &[], CodeTarget::Python).is_err());
    }
}

#[test]
fn headers_sharing_a_name_are_joined_for_clients_that_take_a_map() {
    let mut request = Request::new("GET", "https://api.test");
    request.add_header("Accept", "text/plain");
    request.add_header("accept", "text/html");
    let python = code(&request, CodeTarget::Python);
    assert!(
        python.contains("\"Accept\": \"text/plain, text/html\","),
        "{python}"
    );
    let go = code(&request, CodeTarget::Go);
    assert!(
        go.contains("req.Header.Add(\"accept\", \"text/html\")"),
        "{go}"
    );
}

#[test]
fn java_leaves_out_the_headers_its_client_refuses() {
    let mut request = Request::new("GET", "https://api.test");
    request.add_header("Host", "other.test");
    request.add_header("X-A", "1");
    let java = code(&request, CodeTarget::Java);
    assert!(
        java.starts_with("// Java's HttpClient sets Host itself, so it is left out.\n"),
        "{java}"
    );
    assert!(!java.contains(".header(\"Host\""), "{java}");
    assert!(java.contains(".header(\"X-A\", \"1\")"), "{java}");
}
