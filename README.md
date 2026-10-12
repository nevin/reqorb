# reqorb

An API client with a shared Rust core, a CLI, and a Flutter app for macOS, Windows, Linux and iPad.

## Layout

- `crates/reqorb-core` — request engine (reqwest + rustls), used by everything else
- `crates/reqorb-cli` — the `reqorb` command
- `app` — Flutter UI
- `app/rust` — bridge crate exposing the core to Dart through flutter_rust_bridge

## Commands

```bash
cargo test                                   # core tests
cargo run -p reqorb-cli -- GET httpbin.org/get -i
cargo run -p reqorb-cli -- GET '{{base}}/get' -e dev.env --var base=https://httpbin.org
cargo run -p reqorb-cli -- import shop.postman_collection.json -o shop.reqorb.json
cargo run -p reqorb-cli -- import https://petstore.swagger.io/v2/swagger.json -o petstore.reqorb.json
cargo run -p reqorb-cli -- run shop.reqorb.json -e dev.env        # or one request by name
cargo run -p reqorb-cli -- export shop.reqorb.json -f bruno       # reqorb | postman | bruno | curl | dotenv
cd app && flutter run -d macos               # desktop app
cd app && flutter run -d "iPad Pro 11-inch (M4)"
cd app && flutter test integration_test -d macos
cd app && flutter_rust_bridge_codegen generate   # after changing app/rust/src/api
```

## Variables and formats

`{{name}}` is substituted in the URL, headers and body. Priority is `--var`, then the
environment, then the collection's own variables.

| Format | Import | Export |
| --- | --- | --- |
| reqorb JSON | collections, environments | collections, environments |
| Postman v2.0/v2.1 | collections, environments | collections (v2.1), environments |
| OpenAPI 3.x / Swagger 2.0 (JSON or YAML, file or URL) | collection | – |
| Bruno (collection JSON) | – | collections |
| curl | one command | one command per request |
| `.env` | environment | environment |

## Authorization

A request can carry one of: API key, bearer token, JWT bearer, basic, digest, OAuth 1.0,
OAuth 2.0 (client credentials, password, or a pasted token), Hawk, AWS Signature v4, NTLM
or Akamai EdgeGrid. Field names match Postman's, and values may use `{{variables}}`.

```bash
cargo run -p reqorb-cli -- GET https://httpbin.org/basic-auth/me/pw -u me:pw
cargo run -p reqorb-cli -- GET https://httpbin.org/digest-auth/auth/me/pw --digest -u me:pw
cargo run -p reqorb-cli -- GET https://httpbin.org/bearer --bearer abc123
cargo run -p reqorb-cli -- GET https://api.example.com --auth awsv4 \
    --auth-param accessKey=AKIA... --auth-param secretKey=... --auth-param service=execute-api
```

## Request bodies

A request body is one of: none, form-data (multipart, with text or file fields),
x-www-form-urlencoded, raw text, or binary (a file's bytes).

```bash
cargo run -p reqorb-cli -- POST https://httpbin.org/post -F title=Hi -F doc=@notes.txt
cargo run -p reqorb-cli -- POST https://httpbin.org/post --binary photo.png
```
