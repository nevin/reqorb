//! Builds a collection from a Swagger 2.0 or OpenAPI 3.x document.

use serde_json::{Map, Value, json};
use url::Url;

use crate::import::{append_query, form_encode, loose_string, str_field};
use crate::{Collection, Item, Request, Variable};

const METHODS: [&str; 8] = [
    "get", "post", "put", "patch", "delete", "head", "options", "trace",
];

/// How deep generated example bodies follow nested and recursive schemas.
const MAX_DEPTH: u8 = 6;

pub(crate) fn is_spec(value: &Value) -> bool {
    (value.get("openapi").is_some() || value.get("swagger").is_some())
        && value.get("paths").is_some_and(Value::is_object)
}

/// Converts the document. `origin` is the URL it was downloaded from, used
/// when the document does not say where the API lives.
pub(crate) fn collection(
    spec: &Value,
    name_hint: &str,
    origin: Option<&Url>,
    warnings: &mut Vec<String>,
) -> Collection {
    let mut ctx = Ctx {
        spec,
        v2: spec.get("swagger").is_some(),
        variables: Vec::new(),
        warnings: Vec::new(),
        unsupported_bodies: 0,
        external_refs: 0,
    };
    let base_url = ctx.base_url(origin);
    ctx.variables.push(Variable::new("baseUrl", base_url));

    // Folders follow the document's tag list, then first use.
    let mut folders: Vec<(String, Vec<Item>)> = spec["tags"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|t| Some((str_field(t, "name")?.to_string(), Vec::new())))
        .collect();
    let mut untagged = Vec::new();

    for (path, path_item) in spec["paths"].as_object().into_iter().flatten() {
        let path_item = ctx.deref(path_item);
        for method in METHODS {
            let Some(operation) = path_item.get(method).filter(|o| o.is_object()) else {
                continue;
            };
            let item = ctx.operation(method, path, path_item, operation);
            match operation["tags"].get(0).and_then(Value::as_str) {
                Some(tag) => match folders.iter_mut().find(|(name, _)| name == tag) {
                    Some((_, items)) => items.push(item),
                    None => folders.push((tag.to_string(), vec![item])),
                },
                None => untagged.push(item),
            }
        }
    }

    let mut items: Vec<Item> = folders
        .into_iter()
        .filter(|(_, items)| !items.is_empty())
        .map(|(name, items)| Item {
            name,
            request: None,
            items,
        })
        .collect();
    items.extend(untagged);

    if ctx.unsupported_bodies > 0 {
        ctx.warnings.push(format!(
            "{} operation(s) take multipart or binary bodies, which are not supported yet",
            ctx.unsupported_bodies
        ));
    }
    if ctx.external_refs > 0 {
        ctx.warnings.push(format!(
            "{} reference(s) to other files were not followed",
            ctx.external_refs
        ));
    }
    warnings.append(&mut ctx.warnings);

    Collection {
        name: str_field(&spec["info"], "title")
            .filter(|t| !t.trim().is_empty())
            .unwrap_or(name_hint)
            .to_string(),
        variables: ctx.variables,
        items,
    }
}

struct Ctx<'a> {
    spec: &'a Value,
    /// Swagger 2.0 rather than OpenAPI 3.
    v2: bool,
    variables: Vec<Variable>,
    warnings: Vec<String>,
    unsupported_bodies: usize,
    external_refs: usize,
}

impl<'a> Ctx<'a> {
    /// Follows `$ref` pointers within the document.
    fn deref(&mut self, mut value: &'a Value) -> &'a Value {
        for _ in 0..16 {
            let Some(reference) = str_field(value, "$ref") else {
                break;
            };
            match reference
                .strip_prefix('#')
                .and_then(|pointer| self.spec.pointer(pointer))
            {
                Some(target) => value = target,
                None => {
                    self.external_refs += 1;
                    break;
                }
            }
        }
        value
    }

    fn base_url(&mut self, origin: Option<&Url>) -> String {
        let spec = self.spec;
        let origin_root = origin.map(|o| o.origin().ascii_serialization());
        let mut guessed = false;
        let base = if self.v2 {
            let scheme = spec["schemes"]
                .get(0)
                .and_then(Value::as_str)
                .or(origin.map(Url::scheme))
                .unwrap_or("https");
            let base_path = str_field(spec, "basePath").unwrap_or("");
            match (str_field(spec, "host"), &origin_root) {
                (Some(host), _) => format!("{scheme}://{host}{base_path}"),
                (None, Some(root)) => format!("{root}{base_path}"),
                (None, None) => {
                    guessed = true;
                    format!("{scheme}://localhost{base_path}")
                }
            }
        } else {
            let server = &spec["servers"][0];
            let mut url = str_field(server, "url").unwrap_or("").to_string();
            for (name, variable) in server["variables"].as_object().into_iter().flatten() {
                let default = variable
                    .get("default")
                    .map(loose_string)
                    .unwrap_or_default();
                url = url.replace(&format!("{{{name}}}"), &default);
            }
            if url.contains("://") {
                url
            } else {
                // A relative server URL is relative to where the document lives.
                match (origin.and_then(|o| o.join(&url).ok()), &origin_root) {
                    (Some(joined), _) if !url.is_empty() => joined.to_string(),
                    (_, Some(root)) => format!("{root}{url}"),
                    (_, None) => {
                        guessed = true;
                        format!("http://localhost{url}")
                    }
                }
            }
        };
        if guessed {
            self.warnings.push(
                "the document does not say where the API is hosted; set `baseUrl` in an environment"
                    .into(),
            );
        }
        base.trim_end_matches('/').to_string()
    }

    fn operation(
        &mut self,
        method: &str,
        path: &str,
        path_item: &'a Value,
        operation: &'a Value,
    ) -> Item {
        let method = method.to_uppercase();
        let name = ["summary", "operationId"]
            .iter()
            .filter_map(|key| str_field(operation, key))
            .map(str::trim)
            .find(|s| !s.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| format!("{method} {path}"));

        // `/pets/{id}` becomes `/pets/{{id}}` so it resolves like any variable.
        let url_path = path.replace('{', "{{").replace('}', "}}");
        let mut request = Request::new(method, format!("{{{{baseUrl}}}}{url_path}"));

        // Operation parameters override path-level ones with the same name and place.
        let mut parameters: Vec<&'a Value> = Vec::new();
        for source in [path_item, operation] {
            for parameter in source["parameters"].as_array().into_iter().flatten() {
                let parameter = self.deref(parameter);
                let key = |p: &Value| {
                    (str_field(p, "name") == str_field(parameter, "name"))
                        && (str_field(p, "in") == str_field(parameter, "in"))
                };
                parameters.retain(|p| !key(p));
                parameters.push(parameter);
            }
        }

        let mut query = Vec::new();
        let mut form = Vec::new();
        let mut has_file = false;
        for parameter in parameters {
            let Some(param_name) = str_field(parameter, "name") else {
                continue;
            };
            let example = self.parameter_example(parameter);
            let required = parameter.get("required").and_then(Value::as_bool) == Some(true);
            match str_field(parameter, "in") {
                Some("path") => {
                    if let Some(value) = example
                        && !self.variables.iter().any(|v| v.key == param_name)
                    {
                        self.variables.push(Variable::new(param_name, value));
                    }
                }
                Some("query") if required => query.push(format!(
                    "{}={}",
                    form_encode(param_name),
                    form_encode(&example.unwrap_or_default())
                )),
                Some("header") if required => {
                    // OpenAPI says these three are described elsewhere.
                    let reserved = ["accept", "content-type", "authorization"];
                    if !reserved.contains(&param_name.to_ascii_lowercase().as_str()) {
                        request.add_header(param_name, example.unwrap_or_default());
                    }
                }
                Some("body") => {
                    let sample = self.sample(&parameter["schema"], 0);
                    request.body = Some(pretty(&sample));
                }
                Some("formData") => {
                    has_file |= str_field(parameter, "type") == Some("file");
                    form.push(format!(
                        "{}={}",
                        form_encode(param_name),
                        form_encode(&example.unwrap_or_default())
                    ));
                }
                _ => {}
            }
        }
        append_query(&mut request.url, &query.join("&"));

        if self.v2 {
            let consumes = self.media_types(operation, "consumes");
            if !form.is_empty() {
                if has_file || consumes.iter().any(|c| c.contains("multipart")) {
                    self.unsupported_bodies += 1;
                } else {
                    request.body = Some(form.join("&"));
                    request.add_header("Content-Type", "application/x-www-form-urlencoded");
                }
            } else if request.body.is_some() {
                let content_type = consumes
                    .iter()
                    .find(|c| c.contains("json"))
                    .cloned()
                    .unwrap_or_else(|| "application/json".into());
                request.add_header("Content-Type", content_type);
            }
            if self
                .media_types(operation, "produces")
                .iter()
                .any(|p| p.contains("json"))
            {
                request.add_header("Accept", "application/json");
            }
        } else {
            let body = self.deref(&operation["requestBody"]);
            self.request_body(&body["content"], &mut request);
            let wants_json = operation["responses"]
                .as_object()
                .into_iter()
                .flatten()
                .any(|(_, response)| {
                    self.deref(response)["content"]
                        .as_object()
                        .is_some_and(|c| c.keys().any(|k| k.contains("json")))
                });
            if wants_json {
                request.add_header("Accept", "application/json");
            }
        }

        self.security(operation, &mut request);
        Item {
            name,
            request: Some(request),
            items: Vec::new(),
        }
    }

    /// Swagger 2 `consumes`/`produces`, falling back to the document level.
    fn media_types(&self, operation: &Value, key: &str) -> Vec<String> {
        operation
            .get(key)
            .or(self.spec.get(key))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect()
    }

    /// OpenAPI 3 request body: prefers JSON, then form encoding.
    fn request_body(&mut self, content: &'a Value, request: &mut Request) {
        let Some(content) = content.as_object().filter(|c| !c.is_empty()) else {
            return;
        };
        let pick = |wanted: &str| content.iter().find(|(k, _)| k.contains(wanted));
        if let Some((media_type, media)) = pick("json") {
            let sample = self.media_example(media);
            request.body = Some(pretty(&sample));
            request.add_header("Content-Type", media_type.as_str());
        } else if let Some((media_type, media)) = pick("x-www-form-urlencoded") {
            let sample = self.media_example(media);
            let pairs: Vec<String> = sample
                .as_object()
                .into_iter()
                .flatten()
                .map(|(k, v)| format!("{}={}", form_encode(k), form_encode(&loose_string(v))))
                .collect();
            request.body = Some(pairs.join("&"));
            request.add_header("Content-Type", media_type.as_str());
        } else if let Some((media_type, media)) = content
            .iter()
            .find(|(k, _)| k.starts_with("text/") || k.contains("xml"))
        {
            // Without a schema-to-XML mapping, only a literal example is usable.
            if let Value::String(text) = self.media_example(media) {
                request.body = Some(text);
            }
            request.add_header("Content-Type", media_type.as_str());
        } else {
            self.unsupported_bodies += 1;
        }
    }

    fn media_example(&mut self, media: &'a Value) -> Value {
        if let Some(example) = media.get("example") {
            return example.clone();
        }
        if let Some(first) = media["examples"]
            .as_object()
            .and_then(|e| e.values().next())
            && let Some(value) = self.deref(first).get("value")
        {
            return value.clone();
        }
        self.sample(&media["schema"], 0)
    }

    /// An example value for a parameter, if the document offers one.
    fn parameter_example(&mut self, parameter: &'a Value) -> Option<String> {
        if let Some(example) = parameter.get("example").or(parameter.get("x-example")) {
            return Some(loose_string(example));
        }
        if let Some(first) = parameter["examples"]
            .as_object()
            .and_then(|e| e.values().next())
            && let Some(value) = self.deref(first).get("value")
        {
            return Some(loose_string(value));
        }
        // Swagger 2 puts the schema keywords on the parameter itself.
        let schema = match parameter.get("schema") {
            Some(schema) => self.deref(schema),
            None => parameter,
        };
        ["example", "default"]
            .iter()
            .find_map(|key| schema.get(*key))
            .or_else(|| schema["enum"].get(0))
            .map(loose_string)
    }

    /// Generates an example value from a JSON schema.
    fn sample(&mut self, schema: &'a Value, depth: u8) -> Value {
        let schema = self.deref(schema);
        if depth > MAX_DEPTH || !schema.is_object() {
            return Value::Null;
        }
        if let Some(given) = ["example", "default"].iter().find_map(|k| schema.get(*k)) {
            return given.clone();
        }
        if let Some(first) = schema["examples"].get(0).or(schema["enum"].get(0)) {
            return first.clone();
        }
        if let Some(parts) = schema["allOf"].as_array() {
            let mut merged = Map::new();
            for part in parts {
                if let Value::Object(fields) = self.sample(part, depth + 1) {
                    merged.extend(fields);
                }
            }
            return Value::Object(merged);
        }
        if let Some(first) = schema["oneOf"].get(0).or(schema["anyOf"].get(0)) {
            return self.sample(first, depth + 1);
        }

        // OpenAPI 3.1 allows `"type": ["string", "null"]`.
        let kind = match &schema["type"] {
            Value::String(kind) => Some(kind.as_str()),
            Value::Array(kinds) => kinds
                .iter()
                .filter_map(Value::as_str)
                .find(|k| *k != "null"),
            _ => None,
        };
        match kind {
            Some("object") | None => {
                let mut out = Map::new();
                for (name, property) in schema["properties"].as_object().into_iter().flatten() {
                    let property = self.deref(property);
                    if property.get("readOnly").and_then(Value::as_bool) == Some(true) {
                        continue;
                    }
                    out.insert(name.clone(), self.sample(property, depth + 1));
                }
                Value::Object(out)
            }
            Some("array") => json!([self.sample(&schema["items"], depth + 1)]),
            Some("string") => json!(match str_field(schema, "format") {
                Some("date-time") => "2024-01-01T00:00:00Z",
                Some("date") => "2024-01-01",
                Some("uuid") => "00000000-0000-0000-0000-000000000000",
                Some("email") => "user@example.com",
                Some("uri" | "url") => "https://example.com",
                _ => "string",
            }),
            Some("integer" | "number") => json!(0),
            Some("boolean") => json!(false),
            Some(_) => Value::Null,
        }
    }

    /// Adds the credentials the operation asks for, as variables to fill in.
    fn security(&mut self, operation: &'a Value, request: &mut Request) {
        // An operation-level list, even an empty one, replaces the global list.
        let spec = self.spec;
        let requirements = operation.get("security").unwrap_or(&spec["security"]);
        let Some(first) = requirements.get(0).and_then(Value::as_object) else {
            return;
        };
        let schemes = if self.v2 {
            &spec["securityDefinitions"]
        } else {
            &spec["components"]["securitySchemes"]
        };
        for name in first.keys() {
            let scheme = self.deref(&schemes[name.as_str()]);
            let variable = format!("{{{{{name}}}}}");
            let http_scheme = str_field(scheme, "scheme").map(str::to_ascii_lowercase);
            match (str_field(scheme, "type"), http_scheme.as_deref()) {
                (Some("apiKey"), _) => {
                    let key = str_field(scheme, "name").unwrap_or(name);
                    match str_field(scheme, "in") {
                        Some("query") => append_query(
                            &mut request.url,
                            &format!("{}={variable}", form_encode(key)),
                        ),
                        Some("cookie") => request.add_header("Cookie", format!("{key}={variable}")),
                        _ => request.add_header(key, variable),
                    }
                }
                (Some("basic"), _) | (Some("http"), Some("basic")) => {
                    request.add_header("Authorization", format!("Basic {variable}"));
                    let warning =
                        format!("basic auth: set `{name}` to the base64 of `user:password`");
                    if !self.warnings.contains(&warning) {
                        self.warnings.push(warning);
                    }
                }
                (Some("http" | "oauth2" | "openIdConnect"), _) => {
                    request.add_header("Authorization", format!("Bearer {variable}"));
                }
                _ => {}
            }
        }
    }
}

fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).expect("valid JSON")
}

#[cfg(test)]
mod tests {
    use crate::{Request, import};

    const OPENAPI3: &str = r##"{
      "openapi": "3.0.3",
      "info": {"title": "Pet Store", "version": "1.0"},
      "servers": [{"url": "https://{env}.pets.test/v1/", "variables": {"env": {"default": "api"}}}],
      "tags": [{"name": "pets"}, {"name": "unused"}],
      "security": [{"bearerAuth": []}],
      "paths": {
        "/pets": {
          "get": {"tags": ["pets"], "summary": "List pets",
            "parameters": [
              {"name": "limit", "in": "query", "required": true, "schema": {"type": "integer", "default": 20}},
              {"name": "cursor", "in": "query", "schema": {"type": "string"}},
              {"name": "X-Tenant", "in": "header", "required": true, "example": "acme"}],
            "responses": {"200": {"description": "ok", "content": {"application/json": {}}}}},
          "post": {"tags": ["pets"], "operationId": "createPet", "security": [{"apiKey": []}],
            "requestBody": {"content": {"application/json": {"schema": {"$ref": "#/components/schemas/Pet"}}}},
            "responses": {"201": {"description": "created"}}}
        },
        "/pets/{petId}": {
          "parameters": [{"$ref": "#/components/parameters/petId"}],
          "get": {"tags": ["pets"], "security": [], "responses": {"200": {"description": "ok"}}},
          "delete": {"tags": ["admin"], "summary": "  ", "responses": {"204": {"description": "gone"}}}
        },
        "/login": {
          "post": {"summary": "Log in",
            "requestBody": {"content": {"application/x-www-form-urlencoded": {"schema": {"type": "object",
              "properties": {"user": {"type": "string", "example": "a b"}, "remember": {"type": "boolean"}}}}}},
            "responses": {"200": {"description": "ok"}}}
        },
        "/upload": {
          "post": {"requestBody": {"content": {"multipart/form-data": {"schema": {"type": "object"}}}},
            "responses": {"200": {"description": "ok"}}}
        }
      },
      "components": {
        "parameters": {"petId": {"name": "petId", "in": "path", "required": true, "schema": {"type": "integer", "example": 7}}},
        "securitySchemes": {
          "bearerAuth": {"type": "http", "scheme": "bearer"},
          "apiKey": {"type": "apiKey", "in": "header", "name": "X-API-Key"}},
        "schemas": {
          "Pet": {"type": "object", "properties": {
            "id": {"type": "integer", "readOnly": true},
            "name": {"type": "string"},
            "status": {"type": "string", "enum": ["available", "sold"]},
            "born": {"type": "string", "format": "date"},
            "tags": {"type": "array", "items": {"type": "string"}},
            "parent": {"$ref": "#/components/schemas/Pet"}}}
        }
      }
    }"##;

    fn header<'a>(request: &'a Request, name: &str) -> Option<&'a str> {
        request
            .headers
            .iter()
            .find(|h| h.name.eq_ignore_ascii_case(name))
            .map(|h| h.value.as_str())
    }

    #[test]
    fn imports_openapi_3() {
        let result = import(OPENAPI3, "hint").unwrap();
        assert_eq!(result.source, "openapi");
        let collection = &result.collections[0];
        assert_eq!(collection.name, "Pet Store");
        assert_eq!(collection.variables[0].key, "baseUrl");
        assert_eq!(collection.variables[0].value, "https://api.pets.test/v1");
        assert_eq!(collection.variables[1].key, "petId");
        assert_eq!(collection.variables[1].value, "7");

        let requests = collection.requests();
        let paths: Vec<&str> = requests.iter().map(|(p, _)| p.as_str()).collect();
        assert_eq!(
            paths,
            [
                "pets/List pets",
                "pets/createPet",
                "pets/GET /pets/{petId}",
                "admin/DELETE /pets/{petId}",
                "Log in",
                "POST /upload"
            ]
        );

        let list = requests[0].1;
        assert_eq!(list.method, "GET");
        assert_eq!(list.url, "{{baseUrl}}/pets?limit=20");
        assert_eq!(header(list, "x-tenant"), Some("acme"));
        assert_eq!(header(list, "accept"), Some("application/json"));
        assert_eq!(header(list, "authorization"), Some("Bearer {{bearerAuth}}"));

        let create = requests[1].1;
        assert_eq!(header(create, "content-type"), Some("application/json"));
        assert_eq!(header(create, "x-api-key"), Some("{{apiKey}}"));
        assert_eq!(header(create, "authorization"), None);
        let body: serde_json::Value = serde_json::from_str(create.body.as_ref().unwrap()).unwrap();
        assert_eq!(body.get("id"), None, "readOnly properties are left out");
        assert_eq!(body["name"], "string");
        assert_eq!(body["status"], "available");
        assert_eq!(body["born"], "2024-01-01");
        assert_eq!(body["tags"][0], "string");
        assert!(body["parent"]["parent"].is_object(), "recursion is bounded");

        let get = requests[2].1;
        assert_eq!(get.url, "{{baseUrl}}/pets/{{petId}}");
        assert_eq!(
            header(get, "authorization"),
            None,
            "empty security opts out"
        );

        let login = requests[4].1;
        assert_eq!(login.body.as_deref(), Some("user=a+b&remember=false"));

        assert_eq!(requests[5].1.body, None);
        assert_eq!(result.warnings.len(), 1, "{:?}", result.warnings);
        assert!(result.warnings[0].contains("multipart"));
    }

    #[test]
    fn imports_swagger_2() {
        let text = r##"{
          "swagger": "2.0", "info": {"title": "Legacy"},
          "host": "legacy.test", "basePath": "/api", "schemes": ["http"],
          "consumes": ["application/json"], "produces": ["application/json"],
          "securityDefinitions": {"key": {"type": "apiKey", "in": "query", "name": "api_key"}},
          "security": [{"key": []}],
          "paths": {
            "/items/{id}": {
              "put": {"summary": "Update item",
                "parameters": [
                  {"name": "id", "in": "path", "required": true, "type": "string"},
                  {"name": "body", "in": "body", "schema": {"$ref": "#/definitions/Item"}}],
                "responses": {"200": {"description": "ok"}}}
            },
            "/token": {
              "post": {"consumes": ["application/x-www-form-urlencoded"],
                "parameters": [{"name": "grant_type", "in": "formData", "type": "string", "default": "password"}],
                "responses": {"200": {"description": "ok"}}}
            }
          },
          "definitions": {"Item": {"type": "object", "properties": {"count": {"type": "integer"}, "on": {"type": "boolean"}}}}
        }"##;
        let result = import(text, "hint").unwrap();
        assert!(result.warnings.is_empty(), "{:?}", result.warnings);
        let collection = &result.collections[0];
        assert_eq!(collection.name, "Legacy");
        assert_eq!(
            collection.variables.len(),
            1,
            "no example for the id path parameter"
        );
        assert_eq!(collection.variables[0].value, "http://legacy.test/api");

        let requests = collection.requests();
        let update = requests[0].1;
        assert_eq!(update.url, "{{baseUrl}}/items/{{id}}?api_key={{key}}");
        assert_eq!(header(update, "content-type"), Some("application/json"));
        assert_eq!(header(update, "accept"), Some("application/json"));
        assert_eq!(
            update.body.as_deref(),
            Some("{\n  \"count\": 0,\n  \"on\": false\n}")
        );

        let token = requests[1].1;
        assert_eq!(token.body.as_deref(), Some("grant_type=password"));
        assert_eq!(
            header(token, "content-type"),
            Some("application/x-www-form-urlencoded")
        );
    }

    #[test]
    fn imports_yaml_and_flags_a_missing_host() {
        let text = "openapi: 3.1.0\ninfo:\n  title: Yaml API\npaths:\n  /ping:\n    get:\n      responses:\n        '200':\n          description: ok\n";
        let result = import(text, "hint").unwrap();
        assert_eq!(result.source, "openapi");
        let collection = &result.collections[0];
        assert_eq!(collection.name, "Yaml API");
        assert_eq!(collection.variables[0].value, "http://localhost");
        assert_eq!(collection.requests()[0].1.url, "{{baseUrl}}/ping");
        assert!(result.warnings[0].contains("baseUrl"));
    }
}
