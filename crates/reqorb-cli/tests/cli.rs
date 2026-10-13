//! Runs the `reqorb` binary against a local server, checking what it
//! prints and how it exits.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Command, Output};

/// Starts a small API and returns its address.
///
/// - `POST /login` answers `{"token":"t-1","id":7}`
/// - `GET /me` answers with the `X-Token` header and the query it was sent
/// - `POST /graphql` answers a GraphQL request: its schema when asked, an
///   error for a query naming `fail`, otherwise what it was sent
/// - `GET /logo.png` answers with bytes that are not text
/// - anything else is a 404
fn serve() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            std::thread::spawn(move || answer(stream));
        }
    });
    address
}

/// Answers every request on one connection until the client closes it.
fn answer(stream: TcpStream) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut stream = stream;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        let mut parts = line.split_whitespace();
        let (method, target) = (
            parts.next().unwrap_or("").to_string(),
            parts.next().unwrap_or("").to_string(),
        );
        let (mut token, mut length) = (String::new(), 0);
        loop {
            let mut header = String::new();
            reader.read_line(&mut header).unwrap();
            let header = header.trim();
            if header.is_empty() {
                break;
            }
            if let Some((name, value)) = header.split_once(':') {
                match name.to_ascii_lowercase().as_str() {
                    "x-token" => token = value.trim().to_string(),
                    "content-length" => length = value.trim().parse().unwrap_or(0),
                    _ => {}
                }
            }
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body).unwrap();

        let (path, query) = target.split_once('?').unwrap_or((&target, ""));
        let (status, kind, body): (&str, &str, Vec<u8>) = match (method.as_str(), path) {
            ("POST", "/login") => (
                "200 OK",
                "application/json",
                br#"{"token":"t-1","id":7}"#.to_vec(),
            ),
            ("GET", "/me") => (
                "200 OK",
                "application/json",
                format!(r#"{{"token":"{token}","query":"{query}"}}"#).into_bytes(),
            ),
            ("POST", "/graphql") => ("200 OK", "application/json", graphql(&body)),
            ("GET", "/logo.png") => ("200 OK", "image/png", vec![0x89, b'P', b'N', b'G', 0xff]),
            _ => ("404 Not Found", "text/plain", b"nothing here".to_vec()),
        };
        write!(
            stream,
            "HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\n\r\n",
            body.len()
        )
        .unwrap();
        stream.write_all(&body).unwrap();
    }
}

fn graphql(body: &[u8]) -> Vec<u8> {
    let sent: serde_json::Value = serde_json::from_slice(body).unwrap_or_default();
    let query = sent["query"].as_str().unwrap_or("");
    let answer = if query.contains("__schema") {
        serde_json::json!({"data": {"__schema": {
            "queryType": {"name": "Query"}, "mutationType": null, "subscriptionType": null,
            "types": [
                {"kind": "OBJECT", "name": "Query", "description": "", "fields": [{
                    "name": "user", "description": "", "isDeprecated": false,
                    "args": [{"name": "id", "description": "", "defaultValue": null,
                        "type": {"kind": "NON_NULL", "name": null,
                            "ofType": {"kind": "SCALAR", "name": "ID"}}}],
                    "type": {"kind": "OBJECT", "name": "User"},
                }]},
                {"kind": "OBJECT", "name": "User", "description": "", "fields": [{
                    "name": "name", "description": "", "isDeprecated": false, "args": [],
                    "type": {"kind": "SCALAR", "name": "String"},
                }]},
                {"kind": "SCALAR", "name": "ID", "description": ""},
                {"kind": "SCALAR", "name": "String", "description": ""},
            ],
        }}})
    } else if query.contains("fail") {
        serde_json::json!({"data": null, "errors": [{"message": "It failed", "path": ["fail"]}]})
    } else {
        serde_json::json!({"data": {
            "variables": sent["variables"], "operation": sent["operationName"],
        }})
    };
    answer.to_string().into_bytes()
}

fn reqorb(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_reqorb"))
        .args(args)
        .output()
        .unwrap()
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// A two-request collection where the second uses what the first returned.
fn chain(base: &str, last_test: &str) -> String {
    serde_json::json!({
        "reqorb": 1,
        "collections": [{
            "name": "Chain",
            "variables": [{ "key": "base", "value": base }],
            "items": [
                { "name": "Login", "request": {
                    "method": "POST", "url": "{{base}}/login",
                    "tests": ["status == 200", "body.token exists"],
                    "captures": ["token = body.token", "id = body.id"],
                } },
                { "name": "Me", "request": {
                    "method": "GET", "url": "{{base}}/me?id={{id}}",
                    "headers": [{ "name": "X-Token", "value": "{{token}}" }],
                    "tests": ["body.token == t-1", "body.query == id=7", last_test],
                } },
            ],
        }],
    })
    .to_string()
}

#[test]
fn sends_a_request_and_judges_it_by_its_tests() {
    let base = serve();

    let ok = reqorb(&["GET", &format!("{base}/me"), "-H", "X-Token: abc"]);
    assert!(ok.status.success());
    assert_eq!(stdout(&ok), r#"{"token":"abc","query":""}"#);

    // Without tests a 404 is a failure; with them, they decide.
    let missing = reqorb(&["GET", &format!("{base}/nope")]);
    assert_eq!(missing.status.code(), Some(1));
    let expected = reqorb(&["GET", &format!("{base}/nope"), "--test", "status == 404"]);
    assert!(expected.status.success());
    assert!(stderr(&expected).contains("✓ status == 404"));
    let wrong = reqorb(&["GET", &format!("{base}/me"), "--test", "status == 500"]);
    assert_eq!(wrong.status.code(), Some(1));
    assert!(stderr(&wrong).contains("✗ status == 500  (was 200)"));
}

#[test]
fn writes_binary_bodies_unchanged() {
    let base = serve();
    let output = reqorb(&["GET", &format!("{base}/logo.png")]);
    assert_eq!(output.stdout, [0x89, b'P', b'N', b'G', 0xff]);
}

#[test]
fn runs_a_collection_passing_captured_values_on() {
    let base = serve();
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("chain.reqorb.json");

    std::fs::write(&file, chain(&base, "status == 200")).unwrap();
    let passed = reqorb(&["run", file.to_str().unwrap()]);
    assert!(passed.status.success(), "{}", stderr(&passed));
    assert!(stderr(&passed).contains("2 run, 0 failed"));
    assert!(stderr(&passed).contains("5 test(s), 0 failed"));

    std::fs::write(&file, chain(&base, "status == 201")).unwrap();
    let failed = reqorb(&["run", file.to_str().unwrap()]);
    assert_eq!(failed.status.code(), Some(1));
    assert!(stderr(&failed).contains("✗ status == 201  (was 200)"));
    assert!(stderr(&failed).contains("5 test(s), 1 failed"));
}

#[test]
fn runs_a_collection_once_for_each_row_of_a_data_file() {
    let base = serve();
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("rows.reqorb.json");
    let data = dir.path().join("rows.csv");
    let collection = serde_json::json!({
        "reqorb": 1,
        "collections": [{
            "name": "Rows",
            "items": [
                { "name": "Me", "request": {
                    "method": "GET", "url": format!("{base}/me?{{{{who}}}}"),
                    "tests": ["body.query == {{expect}}"],
                } },
                { "name": "Lost", "request": { "method": "GET", "url": format!("{base}/nope") } },
            ],
        }],
    });
    std::fs::write(&file, collection.to_string()).unwrap();
    std::fs::write(&data, "who,expect\nada,ada\nbob,ada\ncy,cy\n").unwrap();
    let (file, data) = (file.to_str().unwrap(), data.to_str().unwrap());

    // Every row, with the request that fails in each of them.
    let all = reqorb(&["run", file, "Me", "--data", data]);
    assert_eq!(all.status.code(), Some(1));
    assert!(stdout(&all).contains("Iteration 3"), "{}", stdout(&all));
    assert!(stderr(&all).contains("3 run, 1 failed"), "{}", stderr(&all));
    assert!(stderr(&all).contains("(was bob)"), "{}", stderr(&all));

    // Only so many rows, and no further than the first failure.
    let some = reqorb(&["run", file, "--data", data, "-n", "2", "--bail"]);
    assert!(stderr(&some).contains("2 of 4 run, 1 failed; stopped at the first failure"));

    // Without a data file the requests are simply repeated.
    let twice = reqorb(&["run", file, "Lost", "-n", "2"]);
    assert!(
        stderr(&twice).contains("2 run, 2 failed"),
        "{}",
        stderr(&twice)
    );
}

#[test]
fn keeps_a_collection_as_a_folder_and_runs_it_from_there() {
    let base = serve();
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("chain.reqorb.json");
    let folder = dir.path().join("chain");
    std::fs::write(&file, chain(&base, "status == 200")).unwrap();
    let (file, folder_arg) = (file.to_str().unwrap(), folder.to_str().unwrap());

    let written = reqorb(&["export", file, "-f", "folder", "-o", folder_arg]);
    assert!(written.status.success(), "{}", stderr(&written));
    assert!(stderr(&written).contains("wrote 2 request(s)"));
    for name in ["collection.json", "Login.request.json", "Me.request.json"] {
        assert!(folder.join(name).is_file(), "{name} is missing");
    }

    // The folder is run as the file was, in the same order.
    let ran = reqorb(&["run", folder_arg]);
    assert!(ran.status.success(), "{}", stderr(&ran));
    assert!(stderr(&ran).contains("2 run, 0 failed"));
    assert!(stderr(&ran).contains("5 test(s), 0 failed"));

    // And it turns back into a single file.
    let back = reqorb(&["import", folder_arg]);
    assert!(stdout(&back).contains("\"name\": \"Chain\""));

    let unnamed = reqorb(&["export", file, "-f", "folder"]);
    assert!(stderr(&unnamed).contains("--output"));
}

#[test]
fn records_redacts_analyses_and_imports_a_har_file() {
    let base = serve();
    let dir = tempfile::tempdir().unwrap();
    let har = dir.path().join("session.har");
    let har = har.to_str().unwrap();
    let url = format!("{base}/nope?api_key=abc123");

    // The archive holds what was sent, including the client's own headers.
    reqorb(&[
        "GET",
        &url,
        "-H",
        "Authorization: Bearer tok-9",
        "--har",
        har,
    ]);
    let text = std::fs::read_to_string(har).unwrap();
    assert!(text.contains("abc123") && text.contains("tok-9"));
    assert!(text.contains("user-agent"));

    let analysis = reqorb(&["analyze", har]);
    assert!(analysis.status.success());
    let report = stdout(&analysis);
    assert!(report.starts_with("1 request(s), 1 failed"), "{report}");
    assert!(report.contains("1 client error"));
    assert!(report.contains("1 request has a credential in the URL"));
    let json = reqorb(&["analyze", har, "--json"]);
    let json: serde_json::Value = serde_json::from_str(&stdout(&json)).unwrap();
    assert_eq!(json["failed"], 1);
    assert_eq!(json["entries"][0]["status"], 404);

    // Redacted, the same request leaves no credential behind.
    reqorb(&[
        "GET",
        &url,
        "-H",
        "Authorization: Bearer tok-9",
        "--har",
        har,
        "--redact",
    ]);
    let text = std::fs::read_to_string(har).unwrap();
    assert!(!text.contains("abc123") && !text.contains("tok-9"));
    assert!(text.contains("api_key=[REDACTED]"));

    // A HAR file imports as a collection, which exports to other formats.
    let imported = reqorb(&["import", har]);
    let collection: serde_json::Value = serde_json::from_str(&stdout(&imported)).unwrap();
    assert_eq!(collection["collections"][0]["name"], "session");
    assert_eq!(
        collection["collections"][0]["items"][0]["name"],
        "GET /nope"
    );
    let curl = reqorb(&["export", har, "-f", "curl"]);
    assert!(stdout(&curl).contains("/nope?api_key=[REDACTED]"));
    // Importing leaves out the headers the client works out for itself.
    assert!(!stdout(&curl).to_lowercase().contains("accept-encoding"));

    assert!(!reqorb(&["analyze", "Cargo.toml"]).status.success());
}

#[test]
fn keeps_file_bodies_inside_the_working_directory() {
    let base = serve();
    let work = tempfile::tempdir().unwrap();
    let elsewhere = tempfile::tempdir().unwrap();
    std::fs::write(work.path().join("body.bin"), "inside").unwrap();
    let secret = elsewhere.path().join("secret.txt");
    std::fs::write(&secret, "outside").unwrap();
    let (url, dir) = (format!("{base}/login"), work.path().to_str().unwrap());

    // A relative path is looked up in the working directory.
    let inside = reqorb(&["POST", &url, "--binary", "body.bin", "--working-dir", dir]);
    assert!(inside.status.success(), "{}", stderr(&inside));

    // A file outside it is not sent, unless that is asked for.
    let secret = secret.to_str().unwrap();
    let refused = reqorb(&["POST", &url, "--binary", secret, "--working-dir", dir]);
    assert!(!refused.status.success());
    assert!(stderr(&refused).contains("is outside the working directory"));
    let allowed = reqorb(&[
        "POST",
        &url,
        "--binary",
        secret,
        "--working-dir",
        dir,
        "--allow-outside",
    ]);
    assert!(allowed.status.success(), "{}", stderr(&allowed));
}

#[test]
fn sends_graphql_and_prints_a_schema() {
    let base = serve();
    let url = format!("{base}/graphql");

    let sent = reqorb(&[
        "POST",
        &url,
        "--graphql",
        "query User($id: ID!) { user(id: $id) { name } }",
        "--variables",
        r#"{"id": {{id}}}"#,
        "--operation",
        "User",
        "--var",
        "id=7",
    ]);
    assert!(sent.status.success(), "{}", stderr(&sent));
    assert_eq!(
        stdout(&sent),
        r#"{"data":{"variables":{"id":7},"operation":"User"}}"#
    );

    // The server says 200; the errors in the answer make it a failure,
    // unless the request's own tests say what to expect.
    let failed = reqorb(&["POST", &url, "--graphql", "{ fail }"]);
    assert_eq!(failed.status.code(), Some(1));
    assert!(stderr(&failed).contains("graphql error: It failed (at fail)"));
    let expected = reqorb(&[
        "POST",
        &url,
        "--graphql",
        "{ fail }",
        "--test",
        "body.errors[0].message == It failed",
    ]);
    assert!(expected.status.success());

    let broken = reqorb(&["POST", &url, "--graphql", "{ a }", "--variables", "[1]"]);
    assert_eq!(broken.status.code(), Some(2));
    assert!(stderr(&broken).contains("GraphQL variables must be a JSON object"));

    let schema = reqorb(&["POST", &url, "--schema"]);
    assert!(schema.status.success(), "{}", stderr(&schema));
    assert_eq!(
        stdout(&schema),
        "type Query {\n  user(id: ID!): User\n}\n\ntype User {\n  name: String\n}\n"
    );
    let none = reqorb(&["POST", &format!("{base}/login"), "--schema"]);
    assert_eq!(none.status.code(), Some(2));
    assert!(stderr(&none).contains("the answer holds no schema"));
}

#[test]
fn writes_a_request_as_code() {
    // What would be sent, without sending it: nothing listens at this address.
    let python = reqorb(&[
        "POST",
        "{{base}}/items",
        "--var",
        "base=http://127.0.0.1:9",
        "--json",
        r#"{"n": 1}"#,
        "--bearer",
        "t-1",
        "--code",
        "py",
    ]);
    assert!(python.status.success(), "{}", stderr(&python));
    let code = stdout(&python);
    assert!(code.starts_with("import requests\n"), "{code}");
    assert!(
        code.contains("url = \"http://127.0.0.1:9/items\""),
        "{code}"
    );
    assert!(
        code.contains("\"Authorization\": \"Bearer t-1\","),
        "{code}"
    );
    assert!(code.contains("payload = {\n    \"n\": 1,\n}"), "{code}");

    // A saved request by name, with its collection's variables filled in
    // and the one nothing sets pointed out.
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("chain.reqorb.json");
    std::fs::write(&file, chain("https://api.test", "status == 200")).unwrap();
    let file = file.to_str().unwrap();
    let out = dir.path().join("me.go");
    let go = reqorb(&["code", file, "me", "-l", "go", "-o", out.to_str().unwrap()]);
    assert!(go.status.success(), "{}", stderr(&go));
    let code = std::fs::read_to_string(&out).unwrap();
    assert!(
        code.starts_with("// No value is set for {{id}}, {{token}};"),
        "{code}"
    );
    assert!(code.contains("\"https://api.test/me?id={{id}}\""), "{code}");

    let filled = reqorb(&[
        "code", file, "Me", "-l", "curl", "--var", "id=7", "--var", "token=t",
    ]);
    assert_eq!(
        stdout(&filled),
        "curl \\\n  'https://api.test/me?id=7' \\\n  -H 'X-Token: t'\n"
    );

    // Which request has to be said when there are several.
    let vague = reqorb(&["code", file, "-l", "go"]);
    assert_eq!(vague.status.code(), Some(2));
    assert!(stderr(&vague).contains("holds several requests (Login, Me)"));
    let unknown = reqorb(&["code", file, "Me", "-l", "cobol"]);
    assert!(stderr(&unknown).contains("unknown language; use one of curl, fetch"));
}
