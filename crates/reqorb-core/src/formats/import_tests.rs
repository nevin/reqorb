use crate::*;

const POSTMAN: &str = r#"{
  "info": {"name": "Shop", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
  "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "{{token}}"}]},
  "variable": [{"key": "base", "value": "https://shop.test"}, {"key": "old", "value": 1, "disabled": true}],
  "event": [{"listen": "test", "script": {"exec": ["pm.test()"]}}],
  "item": [
    {"name": "Orders", "item": [
      {"name": "List", "request": {"method": "GET", "url": {"raw": "{{base}}/orders?page=1"},
        "header": [{"key": "Accept", "value": "application/json"}, {"key": "X-Off", "value": "1", "disabled": true}]}},
      {"name": "Create", "request": {"method": "POST", "url": "{{base}}/orders",
        "auth": {"type": "basic", "basic": [{"key": "username", "value": "bob"}, {"key": "password", "value": "pw"}]},
        "body": {"mode": "raw", "raw": "{\"sku\": 1}", "options": {"raw": {"language": "json"}}}}}
    ]},
    {"name": "Login", "request": {"method": "POST", "auth": {"type": "noauth"},
      "url": {"protocol": "https", "host": ["shop", "test"], "path": ["login"]},
      "body": {"mode": "urlencoded", "urlencoded": [{"key": "user", "value": "a b"}, {"key": "pw", "value": "{{pw}}"}]}}},
    {"name": "Upload", "request": {"method": "POST", "url": "{{base}}/upload", "body": {"mode": "formdata", "formdata": []}}}
  ]
}"#;

#[test]
fn imports_postman_collection() {
    let result = import(POSTMAN, "hint").unwrap();
    assert_eq!(result.source, "postman-collection");
    let collection = &result.collections[0];
    assert_eq!(collection.name, "Shop");
    assert_eq!(collection.variables.len(), 2);
    assert!(!collection.variables[1].enabled);
    assert_eq!(collection.variables[1].value, "1");

    let requests = collection.requests();
    let paths: Vec<&str> = requests.iter().map(|(p, _)| p.as_str()).collect();
    assert_eq!(paths, ["Orders/List", "Orders/Create", "Login", "Upload"]);

    let list = requests[0].1;
    assert_eq!(list.url, "{{base}}/orders?page=1");
    assert_eq!(list.headers.len(), 1, "disabled header skipped");
    let inherited = list.auth.as_ref().expect("collection auth is inherited");
    assert_eq!(inherited.kind, AuthKind::Bearer);
    assert_eq!(inherited.get("token"), "{{token}}");

    let create = requests[1].1;
    assert_eq!(create.body.as_deref(), Some("{\"sku\": 1}"));
    assert!(create.headers.iter().any(|h| h.value == "application/json"));
    let own = create.auth.as_ref().expect("request auth wins");
    assert_eq!(own.kind, AuthKind::Basic);
    assert_eq!(
        (own.get("username"), own.get("password")),
        ("bob".into(), "pw".into())
    );

    let login = requests[2].1;
    assert_eq!(login.url, "https://shop.test/login");
    assert_eq!(login.body_mode, Some(BodyMode::UrlEncoded));
    assert_eq!(
        login.form,
        [
            FormField::text("user", "a b"),
            FormField::text("pw", "{{pw}}")
        ]
    );
    let mut ready = login.clone();
    ready.materialize();
    assert_eq!(ready.body.as_deref(), Some("user=a+b&pw={{pw}}"));
    assert!(ready.has_header("content-type"));
    assert_eq!(requests[3].1.body_mode, Some(BodyMode::FormData));
    assert_eq!(login.auth, None, "noauth overrides inherited auth");

    // The collection's own script comes with every request in it, and
    // the user is told that scripts came in.
    assert_eq!(result.warnings.len(), 1, "{:?}", result.warnings);
    assert!(
        result.warnings[0].starts_with(&format!("{} request(s) carry scripts", requests.len()))
    );
    for (_, request) in &requests {
        assert_eq!(request.post_script.as_deref(), Some("pm.test()"));
        assert_eq!(request.pre_script, None);
    }
}

#[test]
fn postman_scripts_come_in_and_go_back_out() {
    let text = r#"{
      "info": {"name": "Scripted", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
      "event": [{"listen": "prerequest", "script": {"exec": ["const all = 1;"]}}],
      "item": [{"name": "Folder",
        "event": [{"listen": "test", "script": {"exec": "pm.sendRequest('x');"}}],
        "item": [{"name": "Get",
          "event": [
            {"listen": "prerequest", "script": {"exec": ["pm.variables.set('a', all);", "// done"]}},
            {"listen": "test", "script": {"exec": ["pm.test('ok', () => {});"]}}
          ],
          "request": {"method": "GET", "url": "https://x.test"}}]}]
    }"#;
    let result = import(text, "").unwrap();
    let collection = &result.collections[0];
    let get = collection.requests()[0].1.clone();
    assert_eq!(
        get.pre_script.as_deref(),
        Some("const all = 1;\n\npm.variables.set('a', all);\n// done")
    );
    assert_eq!(
        get.post_script.as_deref(),
        Some("pm.sendRequest('x');\n\npm.test('ok', () => {});")
    );
    // That scripts came in at all, and that some reach for what is missing.
    assert_eq!(result.warnings.len(), 2, "{:?}", result.warnings);
    assert!(result.warnings[0].contains("carry scripts, which run each time"));
    assert!(result.warnings[1].contains("pm.sendRequest"));
    // They wait to be allowed, wherever they come from.
    assert!(result.collections[0].unreviewed);

    let exported = export_collection(collection, ExportFormat::Postman).unwrap();
    let again = import(&exported, "").unwrap();
    assert_eq!(again.collections[0].requests()[0].1, &get);
}

#[test]
fn imports_postman_environment() {
    let text = r#"{"name": "Staging", "_postman_variable_scope": "environment",
      "values": [{"key": "base", "value": "https://staging.test", "enabled": true},
                 {"key": "debug", "value": "1", "enabled": false}]}"#;
    let result = import(text, "hint").unwrap();
    assert_eq!(result.source, "postman-environment");
    let env = &result.environments[0];
    assert_eq!(env.name, "Staging");
    assert_eq!(
        env.variables[0],
        Variable::new("base", "https://staging.test")
    );
    assert!(!env.variables[1].enabled);
}

#[test]
fn imports_curl() {
    let text = "curl -sSL -X PUT 'https://api.test/items/1?x=1' \\\n  -H 'Accept: text/plain' \\\n  -u bob:pw --json '{\"a\": \"it'\\''s\"}' --max-time 2.5 --compressed";
    let result = import(text, "Pasted").unwrap();
    assert_eq!(result.source, "curl");
    let collection = &result.collections[0];
    assert_eq!(collection.name, "Pasted");
    assert_eq!(collection.items[0].name, "PUT /items/1");
    let request = collection.items[0].request.as_ref().unwrap();
    assert_eq!(request.method, "PUT");
    assert_eq!(request.url, "https://api.test/items/1?x=1");
    assert_eq!(request.body.as_deref(), Some("{\"a\": \"it's\"}"));
    assert_eq!(request.timeout_ms, Some(2500));
    let header = |name: &str| {
        request
            .headers
            .iter()
            .find(|h| h.name.eq_ignore_ascii_case(name))
            .map(|h| h.value.as_str())
    };
    assert_eq!(header("accept"), Some("text/plain"));
    assert_eq!(header("authorization"), Some("Basic Ym9iOnB3"));
    assert_eq!(header("content-type"), Some("application/json"));
}

#[test]
fn curl_defaults_and_get_data() {
    let post = import("curl api.test/login -d user=a -d pw=b", "x").unwrap();
    let request = post.collections[0].items[0].request.clone().unwrap();
    assert_eq!(request.method, "POST");
    assert_eq!(request.url, "http://api.test/login");
    assert_eq!(request.body.as_deref(), Some("user=a&pw=b"));
    assert!(request.has_header("content-type"));

    let get = import(
        "curl -G https://api.test/s --data-urlencode 'q=a b' -I",
        "x",
    )
    .unwrap();
    let request = get.collections[0].items[0].request.clone().unwrap();
    assert_eq!(request.method, "HEAD");
    assert_eq!(request.url, "https://api.test/s?q=a+b");
    assert_eq!(request.body, None);

    let browser = import("curl 'https://api.test/' --data-raw $'line1\\nline2'", "x").unwrap();
    let request = browser.collections[0].items[0].request.clone().unwrap();
    assert_eq!(request.body.as_deref(), Some("line1\nline2"));
}

#[test]
fn curl_uploads_become_body_types() {
    let form = import("curl https://api.test/u -F title=Hi -F 'doc=@/tmp/a b.pdf;type=application/pdf' --form-string 'raw=@x'", "x").unwrap();
    let request = form.collections[0].items[0].request.clone().unwrap();
    assert_eq!(request.method, "POST");
    assert_eq!(request.body_mode, Some(BodyMode::FormData));
    assert_eq!(
        request.form,
        [
            FormField::text("title", "Hi"),
            FormField::file("doc", "/tmp/a b.pdf"),
            FormField::text("raw", "@x"),
        ]
    );
    assert!(form.warnings.is_empty());

    let binary = import("curl https://api.test/u --data-binary @/tmp/data.bin", "x").unwrap();
    let request = binary.collections[0].items[0].request.clone().unwrap();
    assert_eq!(request.method, "POST");
    assert_eq!(request.body_mode, Some(BodyMode::Binary));
    assert_eq!(request.body.as_deref(), Some("/tmp/data.bin"));
    assert!(!request.has_header("content-type"));

    let put = import("curl -T /tmp/up.txt https://api.test/u", "x").unwrap();
    let request = put.collections[0].items[0].request.clone().unwrap();
    assert_eq!(request.method, "PUT");
    assert_eq!(request.body_mode, Some(BodyMode::Binary));
}

#[test]
fn imports_dotenv_and_rejects_noise() {
    let text = "# comment\nexport BASE=https://api.test\nTOKEN=\"a b\"\nEMPTY=\n";
    let result = import(text, "local").unwrap();
    assert_eq!(result.source, "dotenv");
    let env = &result.environments[0];
    assert_eq!(env.name, "local");
    assert_eq!(env.variables[0], Variable::new("BASE", "https://api.test"));
    assert_eq!(env.variables[1], Variable::new("TOKEN", "a b"));
    assert_eq!(env.variables[2], Variable::new("EMPTY", ""));

    assert!(import("just some prose", "x").is_err());
    assert!(import("{\"foo\": 1}", "x").is_err());
    assert!(import("curl", "x").is_err());
}

#[test]
fn a_collection_that_reads_files_waits_to_be_reviewed() {
    let with_file = r#"{
        "info": {"name": "Up", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
        "item": [{"name": "Upload", "request": {"method": "POST", "url": "https://api.test",
            "body": {"mode": "formdata", "formdata": [
                {"key": "f", "type": "file", "src": "/home/me/.ssh/id_rsa"}]}}}]
    }"#;
    let result = import(with_file, "").unwrap();
    let collection = &result.collections[0];
    assert!(collection.unreviewed);
    assert_eq!(
        collection.files(),
        [("Upload".to_string(), "/home/me/.ssh/id_rsa")]
    );
    assert!(
        result.warnings[0].starts_with("1 file(s) are read"),
        "{:?}",
        result.warnings
    );

    // Nothing to run and nothing to read: nothing to review.
    let plain = with_file.replace(r#""type": "file", "src""#, r#""type": "text", "value""#);
    let result = import(&plain, "").unwrap();
    assert!(!result.collections[0].unreviewed);
    assert!(result.warnings.is_empty(), "{:?}", result.warnings);
}
