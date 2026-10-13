# reqorb

A fast, native API client for HTTP, WebSocket and gRPC: a desktop app, an iPad app and a
command-line tool on a shared Rust core.

reqorb is an API client in the spirit of Postman, built as a native app rather than a web
view. One Rust core does the networking and powers all three front ends.

## Features

- **HTTP:** five body types (form-data, url-encoded, raw, binary, none), 12 authorization
  types, cookies, redirects and per-request settings.
- **WebSocket:** connect, send messages and watch a timestamped log.
- **gRPC:** load methods by server reflection or from a `.proto` file and call them with
  JSON messages, including streaming methods.
- **Tests and chaining:** check each response with one-line tests, and capture values
  from it to use in later requests.
- **Collections and environments:** `{{variables}}`, folders and standalone requests.
- **Import:** Postman, OpenAPI / Swagger (file or URL), HAR, curl and `.env`.
- **Export:** Postman, Bruno, curl, `.env`, and the session as a HAR file.
- **HAR analysis:** totals, a timeline and findings (failures, slow or oversized
  responses, credentials in URLs) for any HAR file or the current session.
- **Redaction:** one checkbox on any export replaces tokens, passwords, cookies and
  keys with `[REDACTED]`.
- **CLI:** send requests, run whole collections, and convert between formats.

## Status

Built and tested on macOS and the iPad simulator. Windows and Linux are targets, but the
app has not been built on either yet.

## Requirements

- Rust 1.99 or later
- Flutter 3.47 or later, for the app
- Xcode, for the macOS and iPad builds
- `cargo install flutter_rust_bridge_codegen`, only if you change the bridge in
  `app/rust/src/api`

## Getting started

Run the desktop app:

```bash
cd app && flutter run -d macos
```

Run it on an iPad simulator:

```bash
cd app && flutter run -d "iPad Pro 11-inch (M4)"
```

Build and try the CLI:

```bash
cargo run -p reqorb-cli -- GET httpbin.org/get -i
```

Install the CLI as `reqorb`:

```bash
cargo install --path crates/reqorb-cli
```

## CLI examples

```bash
reqorb GET httpbin.org/get -i
reqorb GET '{{base}}/get' -e dev.env --var base=https://httpbin.org
reqorb POST https://httpbin.org/post --json '{"n": 1}'
reqorb GET httpbin.org/get --test 'status == 200' --test 'body.url exists'
reqorb GET httpbin.org/get --har session.har             # save the exchanges as HAR
reqorb GET httpbin.org/get --har session.har --redact    # the same, without credentials

reqorb import shop.postman_collection.json -o shop.reqorb.json
reqorb import https://petstore.swagger.io/v2/swagger.json -o petstore.reqorb.json
reqorb run shop.reqorb.json -e dev.env                   # or one request by name
reqorb export shop.reqorb.json -f bruno                  # reqorb | postman | bruno | curl | dotenv
reqorb export shop.reqorb.json -f postman --redact       # safe to share
reqorb import session.har -o session.reqorb.json         # a HAR from reqorb or a browser
reqorb analyze session.har                               # totals, slowest requests and findings

reqorb ws wss://echo.websocket.org -m hello -n 2
reqorb grpc grpcb.in:9000                                # list methods
reqorb grpc grpcb.in:9000 hello.HelloService/SayHello -d '{"greeting":"hi"}'
```

`reqorb --help` and `reqorb <command> --help` list every option.

## Variables and formats

`{{name}}` is substituted in the URL, headers and body. Priority is `--var`, then the
environment, then the collection's own variables.

| Format | Import | Export |
| --- | --- | --- |
| reqorb JSON | collections, environments | collections, environments |
| Postman v2.0/v2.1 | collections, environments | collections (v2.1), environments |
| OpenAPI 3.x / Swagger 2.0 (JSON or YAML, file or URL) | collection | – |
| Bruno (collection JSON) | – | collections |
| HAR 1.2 | collection, one request per entry | the session's exchanges |
| curl | one command | one command per request |
| `.env` | environment | environment |

## Tests and chaining

A request can carry tests and captures, written one per line in the **Tests** tab or
in the request's `tests` and `captures` lists in a reqorb file.

```text
status == 200
time < 500
header content-type contains json
body.items[0].name == Widget
body.user.email exists
```

A test reads `status`, `time` (ms), `size` (bytes), `header NAME`, `body`, or a field
of a JSON body such as `body.user.id` or `body.items[0]`, and compares it with `==`,
`!=`, `<`, `<=`, `>`, `>=`, `contains`, `exists` or `missing`. Values compare as numbers
when both sides are numbers, and may use `{{variables}}`.

```text
token = body.access_token
requestId = header x-request-id
```

A capture keeps a value from the response as a variable. Captured variables take
priority over the environment and the collection: in the app they last until the
session is cleared or the app quits, and in `reqorb run` they pass from each request
to the ones after it, which is how a login request hands its token on.

`reqorb run` prints each test under its request and exits with 1 if any failed. A
request with tests passes or fails by them alone, so `status == 404` can be a pass.
Tests and captures are kept in reqorb's own format; Postman, Bruno and curl exports
leave them out.

## Authorization

A request can carry one of: API key, bearer token, JWT bearer, basic, digest, OAuth 1.0,
OAuth 2.0 (client credentials, password, or a pasted token), Hawk, AWS Signature v4, NTLM
or Akamai EdgeGrid. Field names match Postman's, and values may use `{{variables}}`.

```bash
reqorb GET https://httpbin.org/basic-auth/me/pw -u me:pw
reqorb GET https://httpbin.org/digest-auth/auth/me/pw --digest -u me:pw
reqorb GET https://httpbin.org/bearer --bearer abc123
reqorb GET https://api.example.com --auth awsv4 \
    --auth-param accessKey=AKIA... --auth-param secretKey=... --auth-param service=execute-api
```

## Request bodies

A request body is one of: none, form-data (multipart, with text or file fields),
x-www-form-urlencoded, raw text, or binary (a file's bytes).

```bash
reqorb POST https://httpbin.org/post -F title=Hi -F doc=@notes.txt
reqorb POST https://httpbin.org/post --binary photo.png
```

## HAR, WebSocket and gRPC

- **HAR:** every HTTP exchange is recorded, including redirects and authorization round
  trips. The app exports the session from the response pane or the sidebar; the CLI
  writes it with `--har FILE` on a send or a `run`. Importing a HAR file, from reqorb
  or from a browser's developer tools, makes a collection with one request per entry;
  the recorded responses are not kept.
- **WebSocket:** choose `WS` where the HTTP method goes. Headers and header-based
  authorization go with the handshake; `http(s)://` addresses are read as `ws(s)://`.
- **gRPC:** choose `GRPC`. Methods come from server reflection or a `.proto` file, and
  messages are written as JSON. A call sends all its messages and then collects every
  response, which covers unary and all three streaming kinds; separate the messages of
  a client stream with a line of `---`. An address without a scheme is not encrypted;
  use `https://` or `grpcs://` for TLS.

WebSocket and gRPC requests are saved in reqorb's own format only; Postman, Bruno and
curl exports leave them out.

## Analysing a HAR file

In the app, choose **Analyse HAR file…** from the import menu, or click the **Session**
row in the sidebar to analyse what you have sent so far. `reqorb analyze FILE` prints
the same report, and `--json` gives it as JSON for scripts. The report has:

- totals: requests, failures, bytes transferred, and the time from first to last
- requests grouped by status, host and kind of content
- every request with its status, size and time, on a timeline in the app
- findings, most serious first: requests with no response, 5xx and 4xx errors,
  requests of a second or longer, responses over 1 MB, credentials in URLs, plain
  `http://` to a remote host, cookies without `Secure` or `HttpOnly`, uncompressed
  text over 10 KB, redirects and repeated requests

In the app, clicking a finding narrows the request table to the requests it is about,
and the filter box narrows it by address, method, status or kind. Clicking a request
shows its headers, bodies and timing phases. **Import as collection** keeps the ticked
requests, which is how to pick the API calls out of a browser archive. The compression check is
skipped for archives reqorb recorded itself, as it stores responses decompressed.

## Redacting exports

Every export in the app opens a short dialog with a **Redact sensitive data** checkbox;
the CLI has `--redact` on `export` and alongside `--har`. Redaction replaces these with
`[REDACTED]`:

- `Authorization` credentials (the scheme is kept), cookie values, and headers such as
  `X-Api-Key`
- URL passwords and query parameters such as `api_key` or `access_token`
- JSON and form fields named like a credential (`password`, `client_secret`, `token`…)
- the secret fields of a request's authorization, and variables named like a credential

A value that is only a `{{variable}}` is left alone, so a redacted collection still
works once the variables are filled in. Values are found by the name they are stored
under, so a secret in free text or under an unrelated name is not caught: look the
file over before sharing it.

## Project layout

- `crates/reqorb-core`: the request engine (reqwest, tonic, tokio-tungstenite), used by
  everything else
- `crates/reqorb-cli`: the `reqorb` command
- `app`: the Flutter UI
- `app/rust`: the bridge crate exposing the core to Dart through flutter_rust_bridge

## Development

```bash
cargo test                                           # core tests
cargo clippy --workspace --all-targets
cd app && flutter analyze
cd app && caffeinate -d flutter test integration_test -d macos
cd app && flutter_rust_bridge_codegen generate       # after changing app/rust/src/api
```

The app tests drive the real UI and wait for screen frames, so they stall if the display
goes to sleep; `caffeinate -d` keeps it awake for the run.

## License

MIT. See [LICENSE](LICENSE).
