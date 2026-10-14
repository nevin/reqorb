# File formats

reqorb writes three kinds of file that people read, review and generate: a **reqorb
file**, which holds collections and environments in one JSON document; a **collection
folder**, one file per request for version control; and the app's own **workspace**,
which is not meant to be shared. All are JSON, written pretty-printed with a trailing
newline. They share one set of types, defined in `crates/reqorb-core/src/model.rs`.

## Conventions

- **Field names are `snake_case`.**
- **Optional fields are left out** when they are empty or at their default, and read as
  their default when missing. A request with no headers has no `headers` field.
- **Unknown fields are ignored** when reading, so a file written by a newer reqorb still
  opens in an older one, losing only the fields the older one does not know. An unknown
  *value* in a known field, such as an auth `kind` added later, is an error.
- **Every file that stands alone carries a version** in a `reqorb` field, currently `1`.
  It changes only if the format changes in a way that older versions would misread.

## A reqorb file

What **Export › reqorb** and `reqorb export --format reqorb` write, and the most complete
way to move collections between machines. `formats/native.rs` writes it.

```json
{
  "reqorb": 1,
  "collections": [ { "name": "Shop", "variables": [], "items": [] } ],
  "environments": [ { "name": "Staging", "variables": [] } ]
}
```

| Field | Type | |
|---|---|---|
| `reqorb` | number | The format version; its presence is how the file is recognised |
| `collections` | [Collection](#collection)[] | Optional |
| `environments` | [Environment](#environment)[] | Optional |

Exports leave out what belongs to one machine: a collection's `link` and `unreviewed`,
and an environment's `folder`. With **Redact** ticked, credentials are replaced with
`[REDACTED]`.

## A collection folder

What **Keep in a folder…** and `reqorb export --format folder` write. `formats/tree.rs`
reads and writes it.

```text
shop/
  collection.json                the name, the variables, the order of things
  Login.request.json             a request
  Orders/
    folder.json                  the folder's name and order
    List orders.request.json
  environments/
    Staging.env.json             an environment kept with the collection
```

### `collection.json`

| Field | Type | |
|---|---|---|
| `reqorb` | number | The format version |
| `name` | string | The collection's name |
| `variables` | [Variable](#variable)[] | Optional |
| `order` | string[] | The file and folder names beside it, in the order they are shown. Optional |

### `folder.json`

In each folder of requests. A folder without one is not part of the collection.

| Field | Type | |
|---|---|---|
| `name` | string | The folder's name as shown, which may differ from its folder name on disk |
| `order` | string[] | As in `collection.json`. Optional |

### `*.request.json`

| Field | Type | |
|---|---|---|
| `name` | string | The request's name as shown |
| `request` | [Request](#request) | |

### `environments/*.env.json`

| Field | Type | |
|---|---|---|
| `name` | string | The environment's name |
| `variables` | [Variable](#variable)[] | Optional |

### Rules

- **File names come from names.** Characters a file system refuses (`/ \ : * ? " < > |`
  and control characters) become `_`, leading and trailing dots and spaces are dropped,
  and names are cut at 80 characters. Names that would collide, compared without case,
  get ` 2`, ` 3` and so on. The real name is kept inside the file, so renaming a file
  by hand does not rename the request.
- **Order.** Items named in `order` come first, in that order; files that are present but
  not named there (one just added by hand, say) follow, sorted by name. Names in `order`
  with no file are skipped.
- **Credentials are blank.** The values of secret variables, variables named like a
  credential, credential headers such as `Authorization`, and secret auth fields are
  written as `""`, unless the value is only a reference such as `{{token}}`. The app puts
  its own values back when it reads the folder, matching each by the request's place and
  name, or failing that by its method and URL.
- **Symbolic links are not followed**, and hidden folders are skipped, so a folder cannot
  make reqorb read a file outside it.
- **Changes are detected by content.** The app keeps a SHA-256 of the folder's files and
  their names, so it can tell when a pull or an edit changed them.

## Types

### Collection

| Field | Type | |
|---|---|---|
| `name` | string | |
| `variables` | [Variable](#variable)[] | Collection variables; an environment's take priority. Optional |
| `items` | [Item](#item)[] | Requests and folders, in order |
| `link` | object | Workspace only: the folder it is kept in, `{ "path", "grant" }` |
| `unreviewed` | bool | Workspace only: it has scripts or files that have not been allowed yet |

### Item

A request, or a folder of items.

| Field | Type | |
|---|---|---|
| `name` | string | |
| `request` | [Request](#request) | Present for a request, absent for a folder |
| `items` | Item[] | A folder's contents. Optional |

### Request

Only `method` and `url` are required.

| Field | Type | |
|---|---|---|
| `method` | string | An HTTP method, or `WS` for a WebSocket and `GRPC` for a gRPC call |
| `url` | string | May contain `{{variables}}` |
| `headers` | [Header](#header)[] | |
| `body` | string | The body as written. For `binary`, the path of the file to send; for `graphql`, the query |
| `body_mode` | string | `none`, `formdata`, `urlencoded`, `raw`, `binary` or `graphql`. Missing means: worked out from `body` |
| `form` | `{ "key", "value", "file" }`[] | Fields for `formdata` and `urlencoded`. With `"file": true`, `value` is a path |
| `auth` | [Auth](#auth) | Missing means: sent as written |
| `settings` | [RequestSettings](#requestsettings) | Missing means: the defaults |
| `timeout_ms` | number | Overrides the timeout in Settings |
| `graphql_variables` | string | A JSON object, as text |
| `graphql_operation` | string | Which operation to run, when the query has several |
| `grpc_method` | string | `package.Service/Method` |
| `proto_path` | string | The `.proto` file; missing means: ask the server by reflection |
| `tests` | string[] | One-line tests, such as `status == 200`. See [Tests and chaining](../README.md#tests-and-chaining) |
| `captures` | string[] | One-line captures, such as `token = body.access_token` |
| `pre_script` | string | JavaScript run before sending. See [Scripts](../README.md#scripts) |
| `post_script` | string | JavaScript run on the response |

### Header

`{ "name": "Accept", "value": "application/json" }`

### Variable

| Field | Type | |
|---|---|---|
| `key` | string | Used as `{{key}}` |
| `value` | string | |
| `enabled` | bool | Defaults to `true`; written only when `false` |
| `secret` | bool | A credential whatever its name says: encrypted in the workspace, blank in collection folders, redacted on export. Written only when `true` |

### Environment

| Field | Type | |
|---|---|---|
| `name` | string | |
| `variables` | [Variable](#variable)[] | |
| `folder` | string | Workspace only: the collection folder it is kept beside |

### Auth

```json
{ "kind": "bearer", "params": [ { "key": "token", "value": "{{token}}" } ] }
```

`kind` is one of `noauth`, `apikey`, `bearer`, `jwt`, `basic`, `digest`, `oauth1`,
`oauth2`, `hawk`, `awsv4`, `ntlm` and `edgegrid` (Akamai EdgeGrid), the names Postman
uses. `params` holds
the fields that kind takes, as key–value pairs. `auth_fields` in
`crates/reqorb-core/src/auth/mod.rs` lists them for each kind.

### RequestSettings

Every field is optional when read and defaults to what a browser does. When reqorb
writes `settings`, it writes every field, with `"http_mode": null` for the app-wide
setting.

| Field | Type | Default |
|---|---|---|
| `http_mode` | `auto`, `http1` or `http2` | The setting in Settings |
| `verify_ssl` | bool | `true` |
| `follow_redirects` | bool | `true` |
| `follow_original_method` | bool | `false`: a redirect switches to GET |
| `follow_auth_header` | bool | `false`: `Authorization` is dropped when a redirect leaves the host |
| `remove_referer` | bool | `false` |
| `strict_http_parser` | bool | `false` |
| `disable_cookie_jar` | bool | `false` |
| `max_redirects` | number | `10` |
| `disabled_tls` | `none`, `tls12` or `tls13` | `none` |

## The workspace

`workspace.json` is the app's own state: everything above, plus settings, cookies, the
active environment and standalone requests. It is written by `vault::save_workspace`,
with every credential encrypted, and is not meant to be edited, shared or generated. Its
shape may change between versions without notice. To move work between machines, export
a reqorb file or keep collections in folders.
