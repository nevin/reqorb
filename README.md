# reqorb

A fast, native API client for HTTP, GraphQL, WebSocket and gRPC: a desktop app, an iPad app and a
command-line tool on a shared Rust core.

reqorb is an API client in the spirit of Postman, built as a native app rather than a web
view. One Rust core does the networking and powers all three front ends.

## Features

- **HTTP:** six body types (form-data, url-encoded, raw, binary, GraphQL, none), 12
  authorization types, cookies, redirects and per-request settings.
- **Streaming:** a response is shown as it arrives, Server-Sent Events are listed one
  by one, and a send can be stopped part way, keeping what came.
- **GraphQL:** a query and variables editor, the server's schema to browse and write
  queries from, the errors a `200` response hides, and subscriptions over WebSocket
  or Server-Sent Events.
- **Tabs:** several requests open at once, each keeping its own edits and response.
- **Find anything:** `⌘K` finds a saved request, an open tab, an environment or an
  action by a few letters of its name.
- **Code editor:** bodies, GraphQL queries, messages, tests, variables and responses are
  coloured by language, with line numbers, bracket matching, find and replace, folding of
  responses, and completion of `{{variables}}` and GraphQL fields.
- **WebSocket:** connect, send messages and watch a timestamped log.
- **gRPC:** load methods by server reflection or from a `.proto` file and call them with
  JSON messages, including streaming methods, whose responses are shown as they arrive.
- **Tests and chaining:** check each response with one-line tests, and capture values
  from it to use in later requests.
- **Scripts:** JavaScript before a request, to prepare it, and on its response, to test
  it; scripts written for Postman with `pm.*` run as they are.
- **Collections and environments:** `{{variables}}`, folders and standalone requests.
- **Collections as files:** keep a collection in a folder, one file for each request,
  to put under version control and share; credentials stay out of the files.
- **Runner:** run a collection or a folder and see how each request came out, once or
  once for each row of a CSV or JSON data file.
- **Import:** Postman, OpenAPI / Swagger (file or URL), HAR, curl and `.env`.
- **Export:** Postman, Bruno, curl, `.env`, and the session as a HAR file.
- **Code generation:** any request as code to copy or save: curl, JavaScript,
  TypeScript, Python, Go, Rust, Java, Kotlin, Swift, C++, C#, PHP, Ruby, Dart or
  PowerShell.
- **HAR analysis:** totals, a timeline and findings (failures, slow or oversized
  responses, credentials in URLs) for any HAR file or the current session.
- **History:** every request sent is kept with its response, searchable, and opens
  again as it was written.
- **Credentials at rest:** saved passwords, tokens and cookies are encrypted with a key
  kept in the system keychain.
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
reqorb GET httpbin.org/get --post-script "test('ok', () => expect(response.status).toBe(200))"
reqorb GET httpbin.org/get --har session.har             # save the exchanges as HAR
reqorb GET httpbin.org/get --har session.har --redact    # the same, without credentials

reqorb POST https://countries.trevorblades.com/graphql \
  --graphql 'query ($code: ID!) { country(code: $code) { name } }' --variables '{"code": "IN"}'
reqorb POST https://countries.trevorblades.com/graphql --schema   # the server's schema

reqorb import shop.postman_collection.json -o shop.reqorb.json
reqorb import https://petstore.swagger.io/v2/swagger.json -o petstore.reqorb.json
reqorb run shop.reqorb.json -e dev.env                   # or one request by name
reqorb run shop.reqorb.json --data users.csv --bail      # once per row, stop at a failure
reqorb export shop.reqorb.json -f folder -o shop/        # one file per request, for git
reqorb run shop/                                         # a folder runs like a file
reqorb export shop.reqorb.json -f bruno                  # reqorb | postman | bruno | curl | dotenv
reqorb export shop.reqorb.json -f postman --redact       # safe to share
reqorb import session.har -o session.reqorb.json         # a HAR from reqorb or a browser
reqorb analyze session.har                               # totals, slowest requests and findings

reqorb POST https://httpbin.org/post --json '{"n": 1}' --code python   # print code, send nothing
reqorb code shop.reqorb.json 'Orders/Create' -l go -e dev.env -o create.go

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

## Settings

The app's Settings (bottom of the sidebar) apply to every request and are saved with the
workspace.

| Setting | What it does |
| --- | --- |
| Working directory | The folder holding the files requests send; see below |
| HTTP version | Auto, HTTP/1 or HTTP/2 |
| Request timeout | Seconds to wait for a response; 0 waits as long as it takes |
| Max response size | A larger response is abandoned part way; 0 means any size |
| SSL certificate verification | Refuse servers whose certificate cannot be verified |
| Automatically follow redirects | When off, a redirect is shown as the response |
| Send no-cache header | Adds `Cache-Control: no-cache` unless the request sets its own |
| Ask before discarding unsaved changes | When off, opening another request drops the edits |
| Layout | Response beside the request, below it, or decided by the window's width |
| Font size, indentation | For URLs, headers and bodies; and for formatted JSON |
| Proxy | The system's, none, or an `http://`, `https://` or `socks5://` address |

SSL verification and redirects are defaults: a request that changes anything on its own
Settings tab keeps its own choices. The proxy applies to HTTP requests only. The CLI has
the same controls as flags: `-k`, `--no-follow`, `--max-size MB`, `-x/--proxy URL`,
`--no-proxy`, `--working-dir DIR` and `--allow-outside`.

### History

Every HTTP request you send is recorded with its response and kept between launches.
**History** in the sidebar lists them newest first, grouped by day; search by address,
method, status or name, or turn on **Bodies** to search headers and bodies as well, with
a line from each match shown under it ("which response had this ID?"). Opening one puts the request back in the editor as it was
written, `{{variables}}` and authorization included, beside the response it got, without
sending anything. The same view can analyse the whole history as a HAR report, or clear
it.

- **How much:** the last 500 requests by default; **Settings › General › History**
  changes that, and 0 keeps none and forgets what was kept.
- **What is kept:** redirects and authorization round trips are recorded as well as the
  final answer. Bodies over 512 KB are cut short and binary bodies are left out.
- **Privacy:** responses hold as much that is private as requests do, so with
  **Encrypt saved credentials** on, each entry is encrypted whole. The file,
  `history.jsonl`, sits beside the workspace file.
- WebSocket and gRPC calls are not recorded yet.

### Saved credentials

The workspace is a readable JSON file, so reqorb encrypts the credentials in it before
saving: passwords, tokens and keys on the Auth tab, headers such as `Authorization` and
`X-Api-Key`, every cookie's value, a proxy address with a password in it, and
environment or collection variables that are named like a credential (`token`,
`password`, `api_key`, …) or marked with the word `secret`:

```text
base_url=https://api.example.com
secret session=abc123
```

The key is made on first use and kept in the system keychain, never in the file, so a
copied or backed-up workspace gives nothing away. Everything else in the file stays
readable, and an unchanged workspace saves to an unchanged file.

- **Another machine:** opened without its key, a workspace loads in full except for the
  encrypted values, which stay locked. Settings says how many; a request that uses one
  is stopped before it is sent, and saving does not destroy them.
- **Switching it off:** **Settings › General › Security › Encrypt saved credentials**.
  The next save writes everything as plain text.
- **Where it works:** the Keychain on macOS and iPad, the Credential Manager on
  Windows, and the Secret Service (GNOME Keyring or KWallet) on Linux. Where none is
  running, Settings says so, and credentials are saved as plain text.
- **What it does not cover:** credentials typed into a URL or a request body, and files
  you export; use **Redact** for those.
- **The file itself** is readable by your user only, and is written whole or not at
  all. One that cannot be read is kept beside it under a dated name, rather than
  replaced by the new, empty workspace.

[SECURITY.md](SECURITY.md) sets out what reqorb protects and how to report a problem.

### Working directory

Requests can send files: a binary body, or a file field in a form. Choose a working
directory (first in Settings › General) to keep those files in one folder:

- File paths are looked up in it, and a file picked from inside it is saved as a
  relative path, so a shared collection works on any machine that has the folder.
- Requests may read files only from that folder. A path that leads out of it, by an
  absolute path, `..` or a link, stops the request before it is sent. This matters
  for collections from someone else, which could otherwise send any file reqorb can
  read. **Allow reading files outside working directory** turns the limit off.
- Choosing the folder is how the system is asked for permission to use it. On macOS,
  where the app is sandboxed, that permission is kept for the next launch. Settings
  shows whether reqorb can read and write the folder, and offers **Give access** when
  it cannot.

Without a working directory, requests read files from wherever their paths point.

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
leave them out. For anything they cannot express there are [scripts](#scripts).

## Keeping a collection in a folder

A collection can be kept as a folder of files, so that a change to one request is a
change to one file and two people's changes merge as files do.

```text
shop/
  collection.json              the name, the variables and the order of things
  Login.request.json           a request, under the name it goes by
  Orders/
    folder.json                the folder's name and order
    List orders.request.json
```

- **Keep in a folder…** in a collection's menu asks for a folder and writes the
  collection there. From then on every change is written as it is made, touching only
  the files that changed. A small folder icon marks the collection.
- **Open collection folder…** in the import menu opens a folder someone else keeps,
  for instance one you have just cloned.
- **Changes on disk** from a pull, a checkout or an edit by hand are read in when the
  app starts and whenever it comes back to the front, if the collection has not been
  changed in the app since. If both changed, neither is written over the other: the
  collection is marked, and its menu offers **Reload from folder** to take the files or
  **Keep mine, over the folder** to write the app's copy. **Reload from folder** also
  reads the files again at any time.
- **Credentials are not written.** Passwords, tokens, keys, secret variables and
  headers such as `Authorization` are blank in the files, unless the value is only a
  `{{variable}}`. Their values stay in the workspace on your machine and are put back
  when the folder is read, matched by the request's place and name, or failing that
  by its method and address. Someone opening the folder for the first time fills in
  their own.
- **What else is in the folder is left alone:** a README, a `.git` directory, anything
  that is not a request file or a folder reqorb made. Deleting a request deletes its
  file.
- **When the folder cannot be read or written** the icon turns into a warning that
  says why, such as a merge conflict left in a file. The collection is then not
  written over what is there until it reads cleanly again; your changes are still
  saved in the workspace.
- **Stop keeping in folder** leaves the files where they are.
- **Environments** can go with the collection: choose its folder under **Kept in** in
  **Manage environments**. Each is written to `environments/<name>.env.json` with its
  credentials blank, as for requests, and is read back, added or removed when the
  folder changes. Unlinking the collection keeps them in the workspace.

Standalone requests, cookies and history are not kept in folders. A
request that is renamed and given a new address in the same pull comes back without its
credentials. The CLI reads such a folder wherever it reads a collection file, and
writes one with `reqorb export … -f folder -o <dir>`.

## Running a collection

**Run…** in a collection's menu, the arrow beside a folder, or the arrow above the
standalone requests opens the runner. It lists what it will send, each of which can be
unticked, and then sends them in order.

- **Passing values on:** cookies and captured variables go from each request to the
  ones after it, so a login request can hand its token to the rest.
- **Pass or fail:** a request with tests is judged by them alone; one without passes
  on any status below 400. A failed request is shown open, with its tests, the error
  or the start of the response.
- **Iterations** repeats the whole list. **Delay** waits between requests. **Stop at
  the first failure** ends the run there.
- **Data file:** a CSV file with a header row, or a JSON array of objects. The
  requests are gone through once for each row, with the row's columns as variables.
  They outrank the environment's and the collection's; a value captured during the run
  outranks them. With a data file, Iterations says how many of its rows to use.
- **Stop** ends the run once the request in flight has been answered.
- WebSocket and gRPC requests are listed but left out, since a run cannot hold a
  conversation. Everything sent is in the history and the session, like any request.

`reqorb run` does the same from the command line with `--data`, `-n/--iterations`,
`--delay` and `--bail`. In the app the list of results is not kept after the runner is
closed.

## Scripts

The **Scripts** tab holds two pieces of JavaScript: one run before the request is sent,
and one run on its response. They are for what one-line tests and captures cannot say:
a value worked out from another, a loop over a list, a check with an `if` in it.

```js
// Before the request
const stamp = String(Date.now());
vars.set('stamp', stamp);
request.setHeader('X-Stamp', '{{stamp}}');
request.body = { name: vars.get('user'), at: stamp };

// After the response
const order = response.json();
test('is an order', () => {
  expect(response.status).toBe(201);
  expect(order.items).toHaveLength(2);
});
vars.set('orderId', order.id);
console.log('made', order.id);
```

- **Before the request** a script sees `request` as it is written, with its
  `{{variables}}` not yet filled in: `method`, `url`, `body`, `headers`,
  `header(name)`, `setHeader(name, value)` and `removeHeader(name)`. What it sets with
  `vars.set` can be used by those variables. If it fails, nothing is sent and the error
  says which line.
- **After the response** a script sees `response`: `status`, `statusText`, `time`,
  `size`, `body`, `headers`, `header(name)` and `json()`; and the request as it was
  sent. Each `test(name, fn)` passes unless it throws, and is listed with the request's
  other tests. A script that fails outside any test counts as one failed test.
- **`expect(value)`** reads as Jest does (`toBe`, `toEqual`, `toContain`,
  `toHaveProperty`, `toBeGreaterThan`, `toMatch`…) and as Chai does (`to.equal`,
  `to.eql`, `to.include`, `to.be.above`, `to.have.property`, `to.be.a('string')`,
  `not`…). `assert(condition, message)` is there too.
- **Variables:** `vars.get`, `vars.set`, `vars.unset`, `vars.has` and
  `vars.replaceIn(text)`. What a script sets is kept like a capture, for the requests
  that follow, until the session is cleared. Unsetting hides a variable from this
  request only.
- **`console.log`** output is shown under **Console** in the response's Tests tab, and
  by the CLI and the runner.
- **Postman scripts** run as they are for the common part of `pm`: `pm.test`,
  `pm.expect`, `pm.response` (`code`, `json()`, `text()`, `headers.get`,
  `to.have.status`, `to.be.ok`…), `pm.request` (`url`, `method`, `headers.add`,
  `upsert`, `remove`) and `pm.variables`, `pm.environment`, `pm.collectionVariables`
  and `pm.globals`, which here are all the same set of variables. Importing a Postman
  collection brings its scripts along, a folder's in front of each request's inside
  it, and exporting to Postman writes them back.

A script can reach nothing but the request, the response and the variables: no files,
no network, no timers, so `pm.sendRequest`, `require`, `setTimeout` and `fetch` are not
there, and an import says so when a script uses the first two. A script that runs for
more than ten seconds, or holds more than 512 MB of memory, is stopped. A script can read every variable, credentials
included, so scripts that came from elsewhere (an import, a collection folder opened
from disk, or one whose scripts changed in a pull) do not run until you allow them.
The same goes for files such a collection would read from your disk and send. The
first send or run from it shows its scripts and files and asks: allow them from now
on, send without the scripts this time, or cancel. Scripts are not run for WebSocket or gRPC requests, and Bruno
and curl exports leave them out. In the CLI, `--pre-script` and `--post-script` take a
script or `@file`.

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
x-www-form-urlencoded, raw text, binary (a file's bytes), or GraphQL (see below).

```bash
reqorb POST https://httpbin.org/post -F title=Hi -F doc=@notes.txt
reqorb POST https://httpbin.org/post --binary photo.png
```

## Streaming responses

A response is shown from the moment its status and headers are in, and its body as it
arrives, so a slow or endless one does not leave the pane blank.

- **Server-Sent Events:** a `text/event-stream` response gets an **Events** tab that
  lists each event with its type, id and data as it comes, and follows the newest
  unless you scroll up to read. The **Body** tab has the same stream as text.
- **Stop:** while a response is arriving the Send button reads **Stop**. It ends the
  send and keeps what had arrived, marked **Stopped**; tests and captures run on that
  part. Before any answer the button reads **Cancel**, and nothing is kept.
- **Large bodies:** event streams and newline-delimited JSON are always shown as they
  arrive. Any other body is shown live up to 256 KB; past that its size is counted and
  the body appears once it is whole.
- **Timeouts:** a request's timeout covers the whole response, so a stream needs it
  left at none, which is the default.
- **CLI:** `reqorb GET <url>` prints an event stream or newline-delimited JSON line by
  line as it arrives, and Ctrl-C ends it cleanly.

A response that fails part way is reported as an error and what had arrived is not
kept. The runner waits for each response to end, so it is not for endless streams.

## Tabs

Each request opens in a tab of its own, with its own response, so one can be compared
with another or left half-written while a second is sent. A request that is already
open is brought forward rather than opened twice, and a tab nothing has been done in
is reused. A dot marks a tab with unsaved changes to a saved request; closing it asks
whether to save them. `⌘N` opens a tab and `⌘W` closes one (`Ctrl` elsewhere).
`⌘1` to `⌘8` go to a tab by its place and `⌘9` to the last; `Ctrl-Tab` and
`Ctrl-Shift-Tab` (or `⌘⇧]` and `⌘⇧[`) go to the next and previous. `⌘.` stops a send
or a call that is under way. Deleting a request, folder, collection or environment, or
clearing the session, offers **Undo** until the next message replaces it; `⌘Z` outside a
text field does the same.

`⌘K` (or the magnifier beside the environment) opens a box that finds things by a few
letters of their name, in order: `crord` finds "Create order". It lists open tabs,
saved requests with the collection and folder they are in, environments to switch to,
and the app's actions, such as running a collection or importing a file. The arrows
move through the list and Return chooses.

When the request is too narrow for all its sections (Params, Headers, Body and the
rest), a button at the end of their row lists them all.

The line between the request and the response has a grip in the middle: drag it to
give either more room, or double-click it to put it back; it stays where it is left
from one launch to the next. The sidebar's list keeps its
scrollbar on show, so it is plain when there are more requests below.

## The code editor

Raw bodies, GraphQL queries and variables, WebSocket and gRPC messages, tests and
captures, bulk-edited params and headers, environment variables, and response bodies
share one editor.

- **Colouring** for JSON, GraphQL, XML and HTML, and JavaScript. A raw body is coloured
  as its **Type**, or by how it starts when none is chosen; a response by its
  `Content-Type`. `{{variables}}` stand out in any of them. Lines of `name=value` or
  `name: value` show the name, a `#` line that is switched off and the word `secret`
  apart; tests show what they read and how they compare. Text over 200 KB is shown
  plain, so that scrolling stays quick.
- **Line numbers** that stay with their lines when long ones wrap.
- **Brackets:** the partner of the bracket beside the caret is marked. Typing `{`, `[`,
  `(` or `"` adds the closing one, a new line keeps the indentation and goes a level
  deeper after an opening bracket, and `Tab` / `Shift+Tab` indent and outdent the
  selected lines by the indent chosen in Settings.
- **Find and replace:** `⌘F`, or the magnifier in the corner, finds text without regard
  to case; `Enter` and `Shift+Enter` step through the matches. It works in responses
  too. Where the text can be edited, the arrow beside the search (or `⌘⌥F`) adds a
  **Replace with** field: **Replace** changes the match the search is on and moves to
  the next, **All** changes every one as a single edit.
- **Folding:** in a JSON, GraphQL or JavaScript response, an arrow in the gutter beside
  a line that opens a `{`, `[` or `(` folds everything up to its partner into `…`. The
  line numbers keep their places, so a gap shows what is folded. Searching unfolds
  everything. Folding is for responses only, not for text being edited.
- **Completion:** typing `{{` lists the variables in reach: the active environment's,
  the collection's, and those captured this session. In a GraphQL query, once the
  schema has been fetched, the fields of the type being selected from and the
  arguments of the field being called are offered as you type, with their types;
  `Ctrl+Space` asks for the list before anything is typed. Arrow keys and `Enter`
  or a tap pick one, `Esc` dismisses.

## Code generation

The **`</>`** button beside **Send** shows the request as code. Pick a language, then
**Copy** it or **Save to file…**; the language is remembered for the next time.

| Language | Client | Language | Client |
| --- | --- | --- | --- |
| Shell | curl | Kotlin | OkHttp |
| JavaScript | `fetch`, or axios | Swift | URLSession |
| TypeScript | `fetch` | C++ | libcurl |
| Python | requests | C# | HttpClient |
| Go | net/http | PHP | cURL |
| Rust | reqwest | Ruby | Net::HTTP |
| Java | java.net.http | Dart | package:http |
| | | PowerShell | Invoke-WebRequest |

The code is the request as it would be sent now:

- **Variables are filled in** from the active environment, the collection and what
  was captured this session, so that it runs as it stands. A `{{variable}}` with no
  value is left as written and named in a comment on the first line.
- **Authorization** that is a header or a query parameter is written as one: Basic,
  Bearer, API key and an OAuth 2.0 token already fetched. Types reqorb computes for each
  send (Digest, OAuth 1.0, Hawk, AWS, NTLM, EdgeGrid, JWT) are left out, with a comment
  saying so; curl alone has options of its own for Digest, NTLM and AWS.
- **Bodies:** a JSON body is written as a value in JavaScript, TypeScript and Python
  and as text elsewhere; form-data uses each client's own multipart support, with
  files read from the paths in the request; a binary body is read from its file;
  url-encoded fields and GraphQL queries are written as the body they become.
- **The timeout** is carried over. Other per-request settings (redirects, certificate
  checks, HTTP version) and cookies from the jar are not.

Text is escaped for each language, so quotes, `$`, backslashes and line breaks in a
header or body come out as they went in. WebSocket and gRPC requests have no code.

On the command line, `--code <language>` prints a request instead of sending it, and
`reqorb code <file> [name] -l <language>` writes one from a collection. Short names
such as `js`, `py`, `ts`, `c++` and `c#` are understood.

## GraphQL

Choose **GraphQL** on the Body tab. The query and its variables are written separately
and sent as the JSON a GraphQL server expects, with `Content-Type: application/json`.
A new request moves to `POST`; set the method to `GET` to send the query in the URL.

- **Variables** are a JSON object. `{{variables}}` work in both the query and the
  variables, and are filled in before the JSON is checked, so `{"id": {{userId}}}` is
  fine. Variables that are not valid JSON once filled stop the send with the reason.
- **Schema:** **Fetch schema** asks the server to describe itself, using the request's
  own headers and authorization. Browse or search its types and fields, and press
  **Use** on a query or mutation to have it written out: required arguments become
  variables and the plain fields of the result are selected. The schema is kept per
  address for the session; the button beside it fetches it again.
- **Checks as you type:** a syntax error is shown under the query with its line and
  column. When a query holds several operations, a picker chooses the one to run.
  The format button re-indents the query.
- **Errors:** GraphQL servers answer `200` even when a query fails. reqorb lists the
  response's `errors` above the body, and the CLI prints them and exits with 1 unless
  the request has tests of its own to decide. Test them like any other field:
  `body.errors missing`, `body.data.user.id == 7`.
- **Formats:** Postman GraphQL bodies import and export as GraphQL, and Bruno export
  writes a GraphQL request. curl and HAR have no notion of GraphQL, so they carry the
  JSON; importing either turns a body that is a GraphQL request back into one, and
  names requests from a HAR file by their operation. The HAR analyser shows each
  call's operation and flags responses that report errors behind a successful status.

```bash
reqorb POST api.example.com/graphql --graphql @query.graphql --variables @vars.json --operation Users
```

### Subscriptions

Sending a query whose operation is a `subscription` subscribes, at the same address as
any other query. Each result the server sends is listed in the **Events** tab as it
arrives, and **Stop** ends the subscription.

- **WebSocket first:** reqorb opens a WebSocket at the address (`http(s)://` is read as
  `ws(s)://`) and speaks `graphql-transport-ws`, or the older `graphql-ws` if that is
  what the server chooses. The request's headers go with the handshake and again in
  the opening message, where some servers look for the token.
- **Server-Sent Events otherwise:** if the server will not open a WebSocket there, the
  subscription is sent as a POST asking for `text/event-stream`. An address written
  with `ws://` or `wss://` is only ever tried as a WebSocket.
- **What comes back:** each result is an event named `next` holding the JSON the server
  sent, and an `error` event if it ended badly. Over a WebSocket the status reads
  `101 Switching Protocols`; tests and captures see the events as text, not as one
  JSON body.
- **CLI:** `reqorb POST <url> --graphql 'subscription { … }'` prints results as they
  arrive until the server completes or you press Ctrl-C.

Authorization that needs extra round trips (Digest, NTLM, OAuth 1.0 and the like)
cannot go with a WebSocket handshake, so such a request falls back to Server-Sent
Events. The errors of a subscription's results are not picked out under the status
line as they are for a query.

Not supported yet: persisted queries and file uploads.

## HAR, WebSocket and gRPC

- **HAR:** every HTTP exchange is recorded, including redirects and authorization round
  trips. The app exports the session from the response pane or the sidebar; the CLI
  writes it with `--har FILE` on a send or a `run`. Importing a HAR file, from reqorb
  or from a browser's developer tools, makes a collection with one request per entry;
  the recorded responses are not kept.
- **WebSocket:** choose `WS` where the HTTP method goes. Headers and header-based
  authorization go with the handshake; `http(s)://` addresses are read as `ws(s)://`.
- **gRPC:** choose `GRPC`. Methods come from server reflection or a `.proto` file, and
  messages are written as JSON. A call sends all its messages first, which covers
  unary and all three streaming kinds; separate the messages of a client stream with a
  line of `---`. Responses are listed as they arrive, and **Stop** ends a server stream
  that would otherwise go on, keeping what came (the status then reads `CANCELLED`). A
  server stream has no time limit; other calls give up after 30 seconds. Messages cannot
  be added to a client stream once the call has started. An address without a scheme is not encrypted;
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

```text
crates/reqorb-core/src/     the request engine, used by everything else
  lib.rs                    the public API: module list and re-exports only
  model.rs  error.rs        the data types and the error type
  http/                     sending: client cache, one exchange, cookie jar, and
                            following or stopping a send under way
  ws.rs  grpc.rs            the other two protocols
  graphql.rs                GraphQL over HTTP: the request, its errors, the schema
  subscribe.rs              GraphQL subscriptions over a WebSocket
  auth/                     auth types, signing a request, negotiating with a server
  formats/                  one module per format, each with its import and export,
                            and the folder of files a collection can be kept as
  codegen/                  a request as code: one generator per language
  vars.rs  checks.rs        variable substitution; tests and captures
  script.rs                 scripts: the JavaScript run before a request and on its
                            response, and what it can see (script_prelude.js)
  redact.rs  analyze.rs     redaction; the HAR report
  data.rs                   the data file of a run: CSV or JSON rows as variables
  vault.rs  history.rs      what is kept on disk: the workspace, its credentials
                            encrypted, and the requests sent
crates/reqorb-cli/src/      the `reqorb` command
  cli.rs                    every command, argument and option
  input.rs  output.rs       reading what the user gave; printing and writing files
  commands/                 one module per command
crates/reqorb-alloc/        the allocator the CLI and app use, which holds a
                            script to its memory limit
app/lib/                    the Flutter UI, one folder per feature
  bridge/                   Engine: the one interface to the Rust library
  request/                  the main page, the request model, the send session, the
                            editors and the code dialog
  response/  protocols/     the response pane; WebSocket and gRPC sessions and views
  editor/                   the code editor: colouring, typing aids, find and replace,
                            folding, completion
  graphql/                  the GraphQL editor, schema browser and schema session
  runner/  palette/         running a collection; the find-anything box
  sidebar/  environments/  settings/  har/  history/
  transfer/                 import and export actions
  workspace/                the saved workspace and collection actions
  shared/                   theme, messages and small reusable widgets
app/rust/                   the bridge crate exposing the core to Dart
```

In the app, widgets show state and hand actions on; the state lives in models that
notify when they change (`RequestDraft`, `SendSession`, `WsSession`, `GrpcSession`,
`GraphqlSession`, `WorkspaceStore`), and everything that reaches the Rust library goes through `Engine`.
Tests put a stand-in engine in its place, so the whole app runs headlessly.

Dependencies point one way: the CLI and the bridge depend on the core, never the
reverse, and inside the core `model` depends on nothing while the protocol and format
modules depend on it.

## Development

```bash
cargo test --workspace                               # core tests, and the CLI run against a local server
cargo clippy --workspace --all-targets -- -D warnings
cd app && flutter analyze
cd app && flutter test                               # the app against a stand-in engine, no window needed
cd app && caffeinate -d flutter test integration_test -d macos   # the real app, end to end
cd app && flutter_rust_bridge_codegen generate       # after changing app/rust/src/api
scripts/coverage.sh                                  # how much the tests cover; fails below the floor
cd fuzz && cargo +nightly fuzz run import corpus/import seeds/import   # or har, run_data, graphql
```

The parsers that read files from elsewhere are fuzzed for a few minutes a week
(`.github/workflows/fuzz.yml`); `fuzz/seeds` holds the inputs they start from.

GitHub Actions runs all of these on every push (`.github/workflows/ci.yml`), and a
failure in any of them, the end-to-end job included, fails the run.

The end-to-end tests drive the real window and need it to stay in front: they stall if
the display sleeps (`caffeinate -d` prevents that) and taps go astray if another window
takes focus, so do not use the machine while they run. They pass on CI's clean runner;
prefer `flutter test` for everyday work.

### Releasing

Set the same version in `Cargo.toml` and `app/pubspec.yaml`, then push a tag for it:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

`.github/workflows/release.yml` then builds the CLI for macOS (Apple silicon and
Intel), Linux and Windows, and the macOS app, and publishes them as a GitHub release
with a SHA-256 checksum for each and a Homebrew formula (`reqorb.rb`) to put in a tap.
The app is signed with a Developer ID and notarized when the repository has the
secrets the workflow lists at its top; without them it is signed ad hoc, and other Macs
refuse to open it until it is allowed in **System Settings › Privacy & Security**.

The same steps run locally: `scripts/package-cli.sh` and `scripts/package-macos.sh`
write to `dist/`.

## License

MIT. See [LICENSE](LICENSE).
