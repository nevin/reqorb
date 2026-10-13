//! GraphQL over HTTP: a request's query and variables become the JSON the
//! server expects, a response's `errors` are read back out, and a server's
//! schema is fetched through introspection.

use graphql_parser::query::{Definition, OperationDefinition, parse_query};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::formats::util::{append_query, form_encode, str_field};
use crate::http::send_with;
use crate::{BodyMode, Cookie, Error, Request, SendOptions, Variable};

/// What a query's text holds, read without contacting a server.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct GraphQlQuery {
    /// The named operations, in the order written.
    pub operations: Vec<String>,
    /// Why the text is not a valid query; empty when it is.
    pub problem: String,
}

/// A server's schema, as far as writing queries against it needs.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct GraphQlSchema {
    /// The type whose fields are the queries; empty when there is none, as
    /// for `mutation_type` and `subscription_type`.
    pub query_type: String,
    pub mutation_type: String,
    pub subscription_type: String,
    /// Every type the schema defines, by name. Introspection's own types,
    /// whose names start with `__`, are left out.
    pub types: Vec<GraphQlType>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct GraphQlType {
    pub name: String,
    /// `OBJECT`, `INTERFACE`, `UNION`, `ENUM`, `INPUT_OBJECT` or `SCALAR`.
    pub kind: String,
    pub description: String,
    /// The fields of an object, interface or input object, and the values
    /// of an enum, which have no type.
    pub fields: Vec<GraphQlField>,
    /// The types a union or interface may turn out to be.
    pub members: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct GraphQlField {
    pub name: String,
    pub description: String,
    /// The type as written in a schema, such as `[User!]!`.
    pub type_name: String,
    /// The type with its list and non-null wrapping removed, such as `User`.
    pub named_type: String,
    pub args: Vec<GraphQlArg>,
    pub deprecated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct GraphQlArg {
    pub name: String,
    pub description: String,
    pub type_name: String,
    /// The default as written in the schema; empty when there is none.
    pub default_value: String,
}

/// A query written from the schema, ready to edit and send.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct GraphQlDraft {
    pub query: String,
    /// The variables the query declares, as JSON with empty values.
    pub variables: String,
    pub operation: String,
}

impl GraphQlSchema {
    pub fn find(&self, name: &str) -> Option<&GraphQlType> {
        self.types.iter().find(|t| t.name == name)
    }
}

impl GraphQlSchema {
    /// The schema in GraphQL's own schema language.
    pub fn to_sdl(&self) -> String {
        const BUILT_IN: [&str; 5] = ["String", "Int", "Float", "Boolean", "ID"];
        let described = |out: &mut String, indent: &str, description: &str| {
            if !description.is_empty() {
                out.push_str(&format!("{indent}\"\"\"{description}\"\"\"\n"));
            }
        };
        let mut out = String::new();
        let roots = [
            ("query", &self.query_type, "Query"),
            ("mutation", &self.mutation_type, "Mutation"),
            ("subscription", &self.subscription_type, "Subscription"),
        ];
        // Only root types with names of their own need saying.
        if roots
            .iter()
            .any(|(_, name, usual)| !name.is_empty() && name != usual)
        {
            out.push_str("schema {\n");
            for (kind, name, _) in roots.iter().filter(|(_, name, _)| !name.is_empty()) {
                out.push_str(&format!("  {kind}: {name}\n"));
            }
            out.push_str("}\n\n");
        }
        for t in &self.types {
            let keyword = match t.kind.as_str() {
                "OBJECT" => "type",
                "INTERFACE" => "interface",
                "INPUT_OBJECT" => "input",
                "ENUM" => "enum",
                "UNION" => "union",
                "SCALAR" if BUILT_IN.contains(&t.name.as_str()) => continue,
                _ => "scalar",
            };
            described(&mut out, "", &t.description);
            out.push_str(&format!("{keyword} {}", t.name));
            if keyword == "union" {
                out.push_str(&format!(" = {}\n\n", t.members.join(" | ")));
                continue;
            }
            if keyword == "scalar" {
                out.push_str("\n\n");
                continue;
            }
            out.push_str(" {\n");
            for field in &t.fields {
                described(&mut out, "  ", &field.description);
                out.push_str(&format!("  {}", field.name));
                if !field.args.is_empty() {
                    let args: Vec<String> = field
                        .args
                        .iter()
                        .map(|a| match a.default_value.as_str() {
                            "" => format!("{}: {}", a.name, a.type_name),
                            default => format!("{}: {} = {default}", a.name, a.type_name),
                        })
                        .collect();
                    out.push_str(&format!("({})", args.join(", ")));
                }
                if !field.type_name.is_empty() {
                    out.push_str(&format!(": {}", field.type_name));
                }
                if field.deprecated {
                    out.push_str(" @deprecated");
                }
                out.push('\n');
            }
            out.push_str("}\n\n");
        }
        out.truncate(out.trim_end().len());
        out.push('\n');
        out
    }
}

impl GraphQlArg {
    /// Whether a query must supply the argument.
    pub fn required(&self) -> bool {
        self.type_name.ends_with('!') && self.default_value.is_empty()
    }
}

// ------------------------------------------------------------ the envelope

/// The JSON a GraphQL server expects. `variables` is spliced in as written,
/// so `{{placeholders}}` in it survive until they are filled.
fn envelope(query: &str, variables: &str, operation: &str) -> String {
    let quoted = |text: &str| Value::from(text).to_string();
    let mut out = format!("{{\"query\":{}", quoted(query));
    if !variables.is_empty() {
        out.push_str(",\"variables\":");
        out.push_str(variables);
    }
    if !operation.is_empty() {
        out.push_str(",\"operationName\":");
        out.push_str(&quoted(operation));
    }
    out.push('}');
    out
}

/// Turns a GraphQL request into the plain HTTP request that carries it: a
/// JSON body, or query parameters when the method is GET.
pub(crate) fn materialize(request: &mut Request) {
    let query = request.body.take().unwrap_or_default();
    let variables = request.graphql_variables.take().unwrap_or_default();
    let variables = variables.trim();
    let operation = request.graphql_operation.take().unwrap_or_default();
    let operation = operation.trim();

    if request.method.eq_ignore_ascii_case("GET") {
        let mut pairs = vec![format!("query={}", form_encode(&query))];
        if !variables.is_empty() {
            // Without the line breaks and indentation, when it is JSON yet.
            let compact = serde_json::from_str::<Value>(variables)
                .map(|v| v.to_string())
                .unwrap_or_else(|_| variables.to_string());
            pairs.push(format!("variables={}", form_encode(&compact)));
        }
        if !operation.is_empty() {
            pairs.push(format!("operationName={}", form_encode(operation)));
        }
        append_query(&mut request.url, &pairs.join("&"));
        request.body_mode = Some(BodyMode::None);
        return;
    }
    request.body = Some(envelope(&query, variables, operation));
    request.body_mode = Some(BodyMode::Raw);
    if !request.has_header("content-type") {
        request.add_header("Content-Type", "application/json");
    }
}

/// Checks that a GraphQL request can be sent as it stands, with its
/// variables already filled in.
pub(crate) fn check(request: &Request) -> Result<(), Error> {
    if request.effective_body_mode() != BodyMode::GraphQl {
        return Ok(());
    }
    if request.body.as_deref().unwrap_or("").trim().is_empty() {
        return Err(Error::Format("the GraphQL query is empty".into()));
    }
    let variables = request.graphql_variables.as_deref().unwrap_or("").trim();
    if variables.is_empty() {
        return Ok(());
    }
    match serde_json::from_str::<Value>(variables) {
        Ok(Value::Object(_)) => Ok(()),
        Ok(_) => Err(Error::Format(
            "GraphQL variables must be a JSON object, such as {\"id\": 1}".into(),
        )),
        Err(e) => Err(Error::Format(format!(
            "GraphQL variables are not valid JSON: {e}"
        ))),
    }
}

/// Recognises a raw JSON body that is really a GraphQL request, as found
/// in recordings and pasted commands, and makes the request a GraphQL one.
pub(crate) fn detect(request: &mut Request) -> bool {
    if request.effective_body_mode() != BodyMode::Raw {
        return false;
    }
    let Some(Ok(Value::Object(body))) = request.body.as_deref().map(serde_json::from_str) else {
        return false;
    };
    let known = ["query", "variables", "operationName", "extensions"];
    // Extensions have nowhere to go, so a body using them stays as it is.
    if body.keys().any(|k| !known.contains(&k.as_str()))
        || body.get("extensions").is_some_and(|e| !e.is_null())
    {
        return false;
    }
    let Some(query) = body.get("query").and_then(Value::as_str) else {
        return false;
    };
    // Plenty of APIs take a `query` that is a search phrase.
    if parse_query::<&str>(query).is_err() {
        return false;
    }
    let variables = match body.get("variables") {
        Some(Value::Object(map)) if !map.is_empty() => {
            serde_json::to_string_pretty(map).expect("variables serialise")
        }
        Some(Value::Object(_)) | Some(Value::Null) | None => String::new(),
        Some(_) => return false,
    };
    request.body_mode = Some(BodyMode::GraphQl);
    request.body = Some(query.to_string());
    request.graphql_variables = (!variables.is_empty()).then_some(variables);
    request.graphql_operation = body
        .get("operationName")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
        .map(str::to_string);
    true
}

/// The operation a GraphQL-over-HTTP body runs: its `operationName`, or
/// the name of the first operation in the query. `None` when the body is
/// not a GraphQL request.
pub(crate) fn operation_of(body: &str) -> Option<String> {
    let mut request = Request::new("POST", "");
    request.body = Some(body.to_string());
    if !detect(&mut request) {
        return None;
    }
    let query = request.body.as_deref().unwrap_or("");
    let kind = if query.trim_start().starts_with("mutation") {
        "mutation"
    } else if query.trim_start().starts_with("subscription") {
        "subscription"
    } else {
        "query"
    };
    let name = request
        .graphql_operation
        .or_else(|| graphql_inspect(query).operations.into_iter().next());
    Some(match name {
        Some(name) => format!("{kind} {name}"),
        None => kind.to_string(),
    })
}

// ------------------------------------------------------- reading a query

/// Swaps each `{{placeholder}}` for a name GraphQL accepts, returning the
/// placeholders so they can be put back.
fn mask_placeholders(query: &str) -> (String, Vec<String>) {
    let mut out = String::with_capacity(query.len());
    let mut found = Vec::new();
    let mut rest = query;
    while let Some(start) = rest.find("{{") {
        let Some(len) = rest[start..].find("}}") else {
            break;
        };
        out.push_str(&rest[..start]);
        out.push_str(&format!("REQORB_PLACEHOLDER_{}_", found.len()));
        found.push(rest[start..start + len + 2].to_string());
        rest = &rest[start + len + 2..];
    }
    out.push_str(rest);
    (out, found)
}

fn parse_problem(error: &impl std::fmt::Display) -> String {
    // The parser's message opens with what it is, which the caller knows.
    let text = error.to_string();
    let text = text.strip_prefix("query parse error: ").unwrap_or(&text);
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(": ")
}

/// Lists a query's operations and says what is wrong with its syntax, if
/// anything. `{{placeholders}}` are allowed wherever a value or name is.
pub fn graphql_inspect(query: &str) -> GraphQlQuery {
    if query.trim().is_empty() {
        return GraphQlQuery::default();
    }
    let (masked, _) = mask_placeholders(query);
    match parse_query::<String>(&masked) {
        Ok(document) => GraphQlQuery {
            operations: document
                .definitions
                .into_iter()
                .filter_map(|definition| match definition {
                    Definition::Operation(OperationDefinition::Query(q)) => q.name,
                    Definition::Operation(OperationDefinition::Mutation(m)) => m.name,
                    Definition::Operation(OperationDefinition::Subscription(s)) => s.name,
                    _ => None,
                })
                .collect(),
            problem: String::new(),
        },
        Err(e) => GraphQlQuery {
            operations: Vec::new(),
            problem: parse_problem(&e),
        },
    }
}

/// Rewrites a query with consistent indentation and spacing.
pub fn graphql_format(query: &str) -> Result<String, Error> {
    let (masked, placeholders) = mask_placeholders(query);
    let document = parse_query::<String>(&masked)
        .map_err(|e| Error::Format(format!("cannot format the query: {}", parse_problem(&e))))?;
    let mut out = document.to_string();
    // Last first, so that placeholder 1 does not match inside placeholder 10.
    for (index, placeholder) in placeholders.iter().enumerate().rev() {
        out = out.replace(&format!("REQORB_PLACEHOLDER_{index}_"), placeholder);
    }
    Ok(out.trim_end().to_string())
}

// ------------------------------------------------------ reading a response

/// The errors a GraphQL response reports, one line each. A GraphQL server
/// answers 200 whether or not the query worked, so this is how to tell.
pub fn graphql_errors(body: &str) -> Vec<String> {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return Vec::new();
    };
    value["errors"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|error| {
            let mut line = str_field(error, "message")
                .map(str::to_string)
                .unwrap_or_else(|| error.to_string());
            let path: Vec<String> = error["path"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|step| match step {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                })
                .collect();
            if !path.is_empty() {
                line.push_str(&format!(" (at {})", path.join(".")));
            } else if let (Some(row), Some(column)) = (
                error["locations"][0]["line"].as_u64(),
                error["locations"][0]["column"].as_u64(),
            ) {
                line.push_str(&format!(" (line {row}, column {column})"));
            }
            line
        })
        .collect()
}

// ------------------------------------------------------------- the schema

/// Asks for everything about the schema that queries are written from.
/// Types are nested up to seven deep, which covers `[[T!]!]!` and beyond.
const INTROSPECTION: &str = "query IntrospectionQuery {
  __schema {
    queryType { name }
    mutationType { name }
    subscriptionType { name }
    types {
      kind
      name
      description
      fields(includeDeprecated: true) {
        name
        description
        args { ...Input }
        type { ...TypeRef }
        isDeprecated
      }
      inputFields { ...Input }
      enumValues(includeDeprecated: true) { name description isDeprecated }
      possibleTypes { name }
    }
  }
}

fragment Input on __InputValue {
  name
  description
  type { ...TypeRef }
  defaultValue
}

fragment TypeRef on __Type {
  kind name
  ofType { kind name
    ofType { kind name
      ofType { kind name
        ofType { kind name
          ofType { kind name
            ofType { kind name
              ofType { kind name } } } } } } }
}";

/// Fetches the schema of the server `request` points at, sending the
/// request's own headers and authorization along.
pub async fn graphql_schema(
    request: &Request,
    variables: &[Variable],
    options: &SendOptions,
    cookies: &[Cookie],
) -> Result<GraphQlSchema, Error> {
    let mut ask = request.clone();
    // Introspection is a query like any other, but always worth a POST:
    // it is too long for some servers' URL limits.
    ask.method = "POST".into();
    ask.body_mode = Some(BodyMode::GraphQl);
    ask.body = Some(INTROSPECTION.into());
    ask.graphql_variables = None;
    ask.graphql_operation = Some("IntrospectionQuery".into());
    ask.form.clear();
    ask.tests.clear();
    ask.captures.clear();
    ask.headers
        .retain(|h| !h.name.eq_ignore_ascii_case("content-type"));

    let sent = send_with(&ask, variables, options, cookies).await?;
    let response = sent.response;
    schema_from(&response.body).map_err(|why| {
        Error::Format(if response.status >= 400 {
            format!(
                "the server answered {} {} when asked for its schema",
                response.status, response.status_text
            )
        } else {
            why
        })
    })
}

/// Reads a schema out of an introspection result.
pub(crate) fn schema_from(body: &str) -> Result<GraphQlSchema, String> {
    let value: Value = serde_json::from_str(body)
        .map_err(|_| "the server did not answer with JSON; is this a GraphQL endpoint?")?;
    let schema = &value["data"]["__schema"];
    if !schema.is_object() {
        return Err(match graphql_errors(body).first() {
            Some(error) => format!("the server would not describe its schema: {error}"),
            None => "the answer holds no schema; is this a GraphQL endpoint?".into(),
        });
    }
    let root = |key: &str| str_field(&schema[key], "name").unwrap_or("").to_string();
    let text = |value: &Value, key: &str| str_field(value, key).unwrap_or("").trim().to_string();
    let list = |value: &Value| -> Vec<Value> { value.as_array().cloned().unwrap_or_default() };
    let arg = |value: &Value| GraphQlArg {
        name: text(value, "name"),
        description: text(value, "description"),
        type_name: type_name(&value["type"]),
        default_value: text(value, "defaultValue"),
    };

    let mut types: Vec<GraphQlType> = list(&schema["types"])
        .iter()
        .filter(|t| !text(t, "name").starts_with("__"))
        .map(|t| {
            let mut fields: Vec<GraphQlField> = list(&t["fields"])
                .iter()
                .map(|f| GraphQlField {
                    name: text(f, "name"),
                    description: text(f, "description"),
                    type_name: type_name(&f["type"]),
                    named_type: named_type(&f["type"]),
                    args: list(&f["args"]).iter().map(arg).collect(),
                    deprecated: f["isDeprecated"].as_bool().unwrap_or(false),
                })
                .collect();
            fields.extend(list(&t["inputFields"]).iter().map(|f| {
                let default = text(f, "defaultValue");
                GraphQlField {
                    name: text(f, "name"),
                    description: text(f, "description"),
                    type_name: if default.is_empty() {
                        type_name(&f["type"])
                    } else {
                        format!("{} = {default}", type_name(&f["type"]))
                    },
                    named_type: named_type(&f["type"]),
                    ..GraphQlField::default()
                }
            }));
            fields.extend(list(&t["enumValues"]).iter().map(|v| GraphQlField {
                name: text(v, "name"),
                description: text(v, "description"),
                deprecated: v["isDeprecated"].as_bool().unwrap_or(false),
                ..GraphQlField::default()
            }));
            GraphQlType {
                name: text(t, "name"),
                kind: text(t, "kind"),
                description: text(t, "description"),
                fields,
                members: list(&t["possibleTypes"])
                    .iter()
                    .map(|m| text(m, "name"))
                    .collect(),
            }
        })
        .collect();
    types.sort_by(|a, b| a.name.cmp(&b.name));

    Ok(GraphQlSchema {
        query_type: root("queryType"),
        mutation_type: root("mutationType"),
        subscription_type: root("subscriptionType"),
        types,
    })
}

/// Writes an introspection type reference the way a schema does.
fn type_name(reference: &Value) -> String {
    match str_field(reference, "kind") {
        Some("NON_NULL") => format!("{}!", type_name(&reference["ofType"])),
        Some("LIST") => format!("[{}]", type_name(&reference["ofType"])),
        _ => str_field(reference, "name").unwrap_or("").to_string(),
    }
}

fn named_type(reference: &Value) -> String {
    match str_field(reference, "kind") {
        Some("NON_NULL" | "LIST") => named_type(&reference["ofType"]),
        _ => str_field(reference, "name").unwrap_or("").to_string(),
    }
}

/// Writes a query for one field of a root type: `kind` is `query`,
/// `mutation` or `subscription`. Its required arguments become variables
/// and the plain values it returns are selected.
pub fn graphql_draft(schema: &GraphQlSchema, kind: &str, field: &str) -> Option<GraphQlDraft> {
    let root = match kind {
        "query" => &schema.query_type,
        "mutation" => &schema.mutation_type,
        "subscription" => &schema.subscription_type,
        _ => return None,
    };
    let field = schema.find(root)?.fields.iter().find(|f| f.name == field)?;
    let args: Vec<&GraphQlArg> = field.args.iter().filter(|a| a.required()).collect();

    let mut operation = field.name.clone();
    if let Some(first) = operation.get_mut(..1) {
        first.make_ascii_uppercase();
    }
    let mut query = format!("{kind} {operation}");
    if !args.is_empty() {
        let declared: Vec<String> = args
            .iter()
            .map(|a| format!("${}: {}", a.name, a.type_name))
            .collect();
        query.push_str(&format!("({})", declared.join(", ")));
    }
    query.push_str(&format!(" {{\n  {}", field.name));
    if !args.is_empty() {
        let passed: Vec<String> = args
            .iter()
            .map(|a| format!("{}: ${}", a.name, a.name))
            .collect();
        query.push_str(&format!("({})", passed.join(", ")));
    }
    let leaf = |name: &str| {
        schema
            .find(name)
            .is_none_or(|t| matches!(t.kind.as_str(), "SCALAR" | "ENUM"))
    };
    if !leaf(&field.named_type) {
        // Something must be selected from an object; its plain values are
        // the usual start, and `__typename` exists on everything.
        let mut selected: Vec<&str> = schema
            .find(&field.named_type)
            .filter(|t| t.kind != "UNION")
            .into_iter()
            .flat_map(|t| &t.fields)
            .filter(|f| {
                leaf(&f.named_type) && !f.deprecated && !f.args.iter().any(|a| a.required())
            })
            .map(|f| f.name.as_str())
            .collect();
        if selected.is_empty() {
            selected.push("__typename");
        }
        query.push_str(" {\n");
        for name in selected {
            query.push_str(&format!("    {name}\n"));
        }
        query.push_str("  }");
    }
    query.push_str("\n}");

    let mut variables = serde_json::Map::new();
    for arg in &args {
        let bare = arg.type_name.trim_end_matches('!');
        let empty = match bare {
            _ if bare.starts_with('[') => Value::Array(Vec::new()),
            "String" | "ID" => Value::from(""),
            "Int" | "Float" => Value::from(0),
            "Boolean" => Value::from(false),
            _ => Value::Null,
        };
        variables.insert(arg.name.clone(), empty);
    }
    Some(GraphQlDraft {
        query,
        variables: if variables.is_empty() {
            String::new()
        } else {
            serde_json::to_string_pretty(&variables).expect("variables serialise")
        },
        operation,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn graphql(method: &str, query: &str, variables: &str, operation: &str) -> Request {
        let mut request = Request::new(method, "https://api.test/graphql");
        request.body_mode = Some(BodyMode::GraphQl);
        request.body = Some(query.into());
        request.graphql_variables = (!variables.is_empty()).then(|| variables.to_string());
        request.graphql_operation = (!operation.is_empty()).then(|| operation.to_string());
        request
    }

    #[test]
    fn becomes_a_json_post() {
        let mut request = graphql(
            "POST",
            "query User($id: ID!) {\n  user(id: $id) { name }\n}",
            "{\n  \"id\": \"7\"\n}",
            "User",
        );
        request.materialize();
        assert_eq!(request.body_mode, Some(BodyMode::Raw));
        assert_eq!(request.graphql_variables, None);
        assert_eq!(request.headers[0].value, "application/json");
        let body: Value = serde_json::from_str(request.body.as_deref().unwrap()).unwrap();
        assert_eq!(
            body,
            serde_json::json!({
                "query": "query User($id: ID!) {\n  user(id: $id) { name }\n}",
                "variables": {"id": "7"},
                "operationName": "User",
            })
        );

        // Nothing but the query when that is all there is, and a content
        // type the request sets itself is kept.
        let mut bare = graphql("POST", "{ me { id } }", "  ", "");
        bare.add_header("content-type", "application/graphql-response+json");
        bare.materialize();
        assert_eq!(bare.body.as_deref(), Some(r#"{"query":"{ me { id } }"}"#));
        assert_eq!(bare.headers.len(), 1);
    }

    #[test]
    fn placeholders_survive_until_filled() {
        let mut request = graphql("POST", "{ user(id: 1) { id } }", r#"{"id": {{id}}}"#, "");
        request.materialize();
        assert_eq!(
            request.body.as_deref(),
            Some(r#"{"query":"{ user(id: 1) { id } }","variables":{"id": {{id}}}}"#)
        );
    }

    #[test]
    fn get_carries_the_query_in_the_url() {
        let mut request = graphql("get", "{ user(id: 1) { id } }", "{\n \"a\": 1\n}", "Q");
        request.url.push_str("?v=2");
        request.materialize();
        assert_eq!(
            request.url,
            "https://api.test/graphql?v=2&query=%7B+user%28id%3A+1%29+%7B+id+%7D+%7D&variables=%7B%22a%22%3A1%7D&operationName=Q"
        );
        assert_eq!(request.body, None);
        assert_eq!(request.body_mode, Some(BodyMode::None));
        assert!(request.headers.is_empty());
    }

    #[test]
    fn checks_before_sending() {
        let message = |request: &Request| check(request).unwrap_err().to_string();
        assert!(check(&graphql("POST", "{ me { id } }", "", "")).is_ok());
        assert!(check(&graphql("POST", "{ me { id } }", "{\"a\": [1]}", "")).is_ok());
        assert_eq!(
            message(&graphql("POST", " ", "", "")),
            "the GraphQL query is empty"
        );
        assert_eq!(
            message(&graphql("POST", "{ me { id } }", "[1]", "")),
            "GraphQL variables must be a JSON object, such as {\"id\": 1}"
        );
        assert!(
            message(&graphql("POST", "{ me { id } }", "{\"a\": }", ""))
                .starts_with("GraphQL variables are not valid JSON: ")
        );
        // Other kinds of request are none of its business.
        assert!(check(&Request::new("POST", "https://api.test")).is_ok());
    }

    #[test]
    fn recognises_graphql_in_a_raw_body() {
        let raw = |body: &str| {
            let mut request = Request::new("POST", "https://api.test/graphql");
            request.body = Some(body.into());
            request
        };
        let mut request = raw(
            r#"{"operationName":"User","variables":{"id":7},"query":"query User($id: ID!) { user(id: $id) { name } }"}"#,
        );
        assert!(detect(&mut request));
        assert_eq!(request.body_mode, Some(BodyMode::GraphQl));
        assert_eq!(
            request.body.as_deref(),
            Some("query User($id: ID!) { user(id: $id) { name } }")
        );
        assert_eq!(
            request.graphql_variables.as_deref(),
            Some("{\n  \"id\": 7\n}")
        );
        assert_eq!(request.graphql_operation.as_deref(), Some("User"));

        // Sent again, it is the request it was.
        request.materialize();
        let sent: Value = serde_json::from_str(request.body.as_deref().unwrap()).unwrap();
        assert_eq!(sent["variables"]["id"], 7);
        assert_eq!(sent["operationName"], "User");

        let mut empty = raw(r#"{"query":"{ me { id } }","variables":{}}"#);
        assert!(detect(&mut empty));
        assert_eq!(empty.graphql_variables, None);

        for other in [
            r#"{"query":"red shoes"}"#,
            r#"{"query":"{ me { id } }","page":2}"#,
            r#"{"query":"{ me { id } }","extensions":{"persistedQuery":{}}}"#,
            r#"{"query":"{ me { id } }","variables":[1]}"#,
            r#"{"name":"Ann"}"#,
            "{ me { id } }",
        ] {
            let mut request = raw(other);
            assert!(!detect(&mut request), "{other}");
            assert_eq!(request.body.as_deref(), Some(other));
        }
    }

    #[test]
    fn names_the_operation_of_a_body() {
        let name = |body: &str| operation_of(body);
        assert_eq!(
            name(r#"{"query":"query Users { users { id } }"}"#).as_deref(),
            Some("query Users")
        );
        assert_eq!(
            name(r#"{"query":"mutation Add { add { id } }","operationName":"Add"}"#).as_deref(),
            Some("mutation Add")
        );
        assert_eq!(
            name(r#"{"query":"{ me { id } }"}"#).as_deref(),
            Some("query")
        );
        assert_eq!(name(r#"{"query":"shoes"}"#), None);
    }

    #[test]
    fn inspects_a_query() {
        let found = graphql_inspect(
            "query A { a }\nmutation B($x: Int = {{n}}) { b(x: $x, tag: \"{{tag}}\") }\nfragment F on T { id }\n{ c }",
        );
        assert_eq!(found.operations, ["A", "B"]);
        assert_eq!(found.problem, "");

        assert_eq!(graphql_inspect("  "), GraphQlQuery::default());
        let broken = graphql_inspect("query A {\n  a(\n}");
        assert!(broken.operations.is_empty());
        assert!(
            broken.problem.starts_with("Parse error at 3:1"),
            "{}",
            broken.problem
        );
    }

    #[test]
    fn formats_a_query() {
        assert_eq!(
            graphql_format("query  A($id:ID!){user(id:$id,org:{{org}}){id   name}}").unwrap(),
            "query A($id: ID!) {\n  user(id: $id, org: {{org}}) {\n    id\n    name\n  }\n}"
        );
        assert!(
            graphql_format("query {")
                .unwrap_err()
                .to_string()
                .starts_with("cannot format the query: Parse error at 1:")
        );
    }

    #[test]
    fn reads_errors() {
        assert_eq!(
            graphql_errors(
                r#"{"data":null,"errors":[
                    {"message":"Not found","path":["user",0,"name"]},
                    {"message":"Unknown field","locations":[{"line":2,"column":5}]},
                    {"message":"Plain"},
                    {"code":7}
                ]}"#
            ),
            [
                "Not found (at user.0.name)",
                "Unknown field (line 2, column 5)",
                "Plain",
                r#"{"code":7}"#,
            ]
        );
        assert!(graphql_errors(r#"{"data":{"errors":"none here"}}"#).is_empty());
        assert!(graphql_errors("<html>").is_empty());
    }

    pub(crate) const SCHEMA: &str = r#"{"data":{"__schema":{
        "queryType":{"name":"Query"},"mutationType":{"name":"Mutation"},"subscriptionType":null,
        "types":[
          {"kind":"OBJECT","name":"Query","description":"Where reads start.","fields":[
            {"name":"user","description":"One user.","isDeprecated":false,
             "args":[
               {"name":"id","description":"","defaultValue":null,
                "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"ID"}}},
               {"name":"full","description":"","defaultValue":"false",
                "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"Boolean"}}}],
             "type":{"kind":"OBJECT","name":"User"}},
            {"name":"users","description":null,"isDeprecated":false,
             "args":[{"name":"first","description":"","defaultValue":null,"type":{"kind":"SCALAR","name":"Int"}}],
             "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"LIST","name":null,
               "ofType":{"kind":"NON_NULL","name":null,"ofType":{"kind":"OBJECT","name":"User"}}}}},
            {"name":"version","description":"","isDeprecated":false,"args":[],
             "type":{"kind":"SCALAR","name":"String"}},
            {"name":"search","description":"","isDeprecated":false,"args":[],
             "type":{"kind":"UNION","name":"Result"}}
          ]},
          {"kind":"OBJECT","name":"Mutation","description":"","fields":[
            {"name":"addUser","description":"","isDeprecated":false,
             "args":[
               {"name":"input","description":"","defaultValue":null,
                "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"INPUT_OBJECT","name":"NewUser"}}},
               {"name":"tags","description":"","defaultValue":null,
                "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"LIST","name":null,"ofType":{"kind":"SCALAR","name":"String"}}}},
               {"name":"count","description":"","defaultValue":null,
                "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"Int"}}}],
             "type":{"kind":"OBJECT","name":"User"}}
          ]},
          {"kind":"OBJECT","name":"User","description":"Someone with an account.","fields":[
            {"name":"id","description":"","isDeprecated":false,"args":[],
             "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"ID"}}},
            {"name":"name","description":"","isDeprecated":false,"args":[],"type":{"kind":"SCALAR","name":"String"}},
            {"name":"nick","description":"","isDeprecated":true,"args":[],"type":{"kind":"SCALAR","name":"String"}},
            {"name":"role","description":"","isDeprecated":false,"args":[],"type":{"kind":"ENUM","name":"Role"}},
            {"name":"avatar","description":"","isDeprecated":false,
             "args":[{"name":"size","description":"","defaultValue":null,
               "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"Int"}}}],
             "type":{"kind":"SCALAR","name":"String"}},
            {"name":"friends","description":"","isDeprecated":false,"args":[],
             "type":{"kind":"LIST","name":null,"ofType":{"kind":"OBJECT","name":"User"}}}
          ]},
          {"kind":"INPUT_OBJECT","name":"NewUser","description":"","inputFields":[
            {"name":"name","description":"","defaultValue":null,
             "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String"}}},
            {"name":"role","description":"","defaultValue":"MEMBER","type":{"kind":"ENUM","name":"Role"}}
          ]},
          {"kind":"ENUM","name":"Role","description":"","enumValues":[
            {"name":"ADMIN","description":"Runs the place.","isDeprecated":false},
            {"name":"MEMBER","description":"","isDeprecated":false}
          ]},
          {"kind":"UNION","name":"Result","description":"","possibleTypes":[{"name":"User"}]},
          {"kind":"SCALAR","name":"ID","description":""},
          {"kind":"SCALAR","name":"String","description":""},
          {"kind":"SCALAR","name":"Int","description":""},
          {"kind":"SCALAR","name":"Boolean","description":""},
          {"kind":"OBJECT","name":"__Schema","description":"","fields":[]}
        ]}}}"#;

    #[test]
    fn reads_a_schema() {
        let schema = schema_from(SCHEMA).unwrap();
        assert_eq!(schema.query_type, "Query");
        assert_eq!(schema.mutation_type, "Mutation");
        assert_eq!(schema.subscription_type, "");
        let names: Vec<&str> = schema.types.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "Boolean", "ID", "Int", "Mutation", "NewUser", "Query", "Result", "Role", "String",
                "User"
            ]
        );

        let query = schema.find("Query").unwrap();
        assert_eq!(query.description, "Where reads start.");
        let user = &query.fields[0];
        assert_eq!(
            (user.type_name.as_str(), user.named_type.as_str()),
            ("User", "User")
        );
        assert_eq!(user.args[0].type_name, "ID!");
        assert!(user.args[0].required());
        // A default makes an argument optional, whatever its type.
        assert_eq!(user.args[1].default_value, "false");
        assert!(!user.args[1].required());
        let users = &query.fields[1];
        assert_eq!(
            (users.type_name.as_str(), users.named_type.as_str()),
            ("[User!]!", "User")
        );
        assert_eq!(users.description, "");

        let input = schema.find("NewUser").unwrap();
        assert_eq!(input.kind, "INPUT_OBJECT");
        assert_eq!(input.fields[0].type_name, "String!");
        assert_eq!(input.fields[1].type_name, "Role = MEMBER");
        let role = schema.find("Role").unwrap();
        assert_eq!(role.fields[0].name, "ADMIN");
        assert_eq!(role.fields[0].type_name, "");
        assert_eq!(schema.find("Result").unwrap().members, ["User"]);
        assert!(schema.find("User").unwrap().fields[2].deprecated);
    }

    #[test]
    fn writes_the_schema_language() {
        let sdl = schema_from(SCHEMA).unwrap().to_sdl();
        assert!(sdl.starts_with("type Mutation {\n  addUser(input: NewUser!, tags: [String]!, count: Int!): User\n}\n\ninput NewUser {\n  name: String!\n  role: Role = MEMBER\n}\n\n\"\"\"Where reads start.\"\"\"\ntype Query {\n  \"\"\"One user.\"\"\"\n  user(id: ID!, full: Boolean! = false): User\n"), "{sdl}");
        assert!(sdl.contains("union Result = User\n\nenum Role {\n  \"\"\"Runs the place.\"\"\"\n  ADMIN\n  MEMBER\n}\n"), "{sdl}");
        assert!(sdl.contains("  nick: String @deprecated\n"));
        assert!(!sdl.contains("scalar") && !sdl.contains("schema {"));
        assert!(graphql_parser::parse_schema::<&str>(&sdl).is_ok());

        let mut renamed = schema_from(SCHEMA).unwrap();
        renamed.query_type = "Root".into();
        assert!(
            renamed
                .to_sdl()
                .starts_with("schema {\n  query: Root\n  mutation: Mutation\n}\n\n")
        );
    }

    #[test]
    fn explains_a_missing_schema() {
        assert_eq!(
            schema_from("<html>").unwrap_err(),
            "the server did not answer with JSON; is this a GraphQL endpoint?"
        );
        assert_eq!(
            schema_from(r#"{"users":[]}"#).unwrap_err(),
            "the answer holds no schema; is this a GraphQL endpoint?"
        );
        assert_eq!(
            schema_from(r#"{"errors":[{"message":"Introspection is disabled"}]}"#).unwrap_err(),
            "the server would not describe its schema: Introspection is disabled"
        );
    }

    #[test]
    fn drafts_queries_from_the_schema() {
        let schema = schema_from(SCHEMA).unwrap();
        let user = graphql_draft(&schema, "query", "user").unwrap();
        // Deprecated fields, objects and fields needing arguments are left
        // for the writer to add.
        assert_eq!(
            user.query,
            "query User($id: ID!) {\n  user(id: $id) {\n    id\n    name\n    role\n  }\n}"
        );
        assert_eq!(user.variables, "{\n  \"id\": \"\"\n}");
        assert_eq!(user.operation, "User");
        assert_eq!(graphql_inspect(&user.query).operations, ["User"]);

        let users = graphql_draft(&schema, "query", "users").unwrap();
        assert_eq!(
            users.query,
            "query Users {\n  users {\n    id\n    name\n    role\n  }\n}"
        );
        assert_eq!(users.variables, "");

        assert_eq!(
            graphql_draft(&schema, "query", "version").unwrap().query,
            "query Version {\n  version\n}"
        );
        assert_eq!(
            graphql_draft(&schema, "query", "search").unwrap().query,
            "query Search {\n  search {\n    __typename\n  }\n}"
        );

        let add = graphql_draft(&schema, "mutation", "addUser").unwrap();
        assert!(
            add.query
                .starts_with("mutation AddUser($input: NewUser!, $tags: [String]!, $count: Int!) {\n  addUser(input: $input, tags: $tags, count: $count) {")
        );
        assert_eq!(
            serde_json::from_str::<Value>(&add.variables).unwrap(),
            serde_json::json!({"input": null, "tags": [], "count": 0})
        );

        assert_eq!(graphql_draft(&schema, "query", "nope"), None);
        assert_eq!(graphql_draft(&schema, "subscription", "user"), None);
        assert_eq!(graphql_draft(&schema, "other", "user"), None);
    }

    // ------------------------------------------- over the wire and beyond

    use std::io::{Read, Write};
    use std::net::TcpListener;

    use crate::{
        Collection, ExportFormat, Item, export_collection, import, redact_collection, send_with,
    };

    /// Answers one request with `body` and returns what it received.
    fn serve(status: &str, body: &str) -> (String, std::thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/graphql", listener.local_addr().unwrap());
        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut received = Vec::new();
            let mut buf = [0u8; 8192];
            // Read until the whole body the headers announce has arrived.
            loop {
                let n = stream.read(&mut buf).unwrap();
                received.extend_from_slice(&buf[..n]);
                let text = String::from_utf8_lossy(&received);
                let Some((head, body)) = text.split_once("\r\n\r\n") else {
                    continue;
                };
                let length = head
                    .lines()
                    .find_map(|l| {
                        l.to_lowercase()
                            .strip_prefix("content-length: ")?
                            .parse()
                            .ok()
                    })
                    .unwrap_or(0);
                if n == 0 || body.len() >= length {
                    break;
                }
            }
            stream.write_all(response.as_bytes()).unwrap();
            String::from_utf8_lossy(&received).into_owned()
        });
        (url, handle)
    }

    #[tokio::test]
    async fn sends_a_query_and_reports_its_errors() {
        let (url, server) = serve(
            "200 OK",
            r#"{"data":{"user":null},"errors":[{"message":"No such user","path":["user"]}]}"#,
        );
        let mut request = graphql(
            "POST",
            "query User($id: ID!) { user(id: $id) { name } }",
            r#"{"id": {{id}}, "note": "{{note}}"}"#,
            "User",
        );
        request.url = url;
        request.tests = vec!["status == 200".into(), "body.errors missing".into()];
        let variables = [Variable::new("id", "7"), Variable::new("note", "hi")];
        let sent = send_with(&request, &variables, &SendOptions::default(), &[])
            .await
            .unwrap();

        let raw = server.join().unwrap();
        let (head, body) = raw.split_once("\r\n\r\n").unwrap();
        assert!(head.starts_with("POST /graphql HTTP/1.1"));
        assert!(
            head.to_lowercase()
                .contains("content-type: application/json")
        );
        assert_eq!(
            serde_json::from_str::<Value>(body).unwrap(),
            serde_json::json!({
                "query": "query User($id: ID!) { user(id: $id) { name } }",
                "variables": {"id": 7, "note": "hi"},
                "operationName": "User",
            })
        );
        // The status says all is well; the errors and the test say not.
        assert_eq!(sent.response.status, 200);
        assert_eq!(sent.graphql_errors, ["No such user (at user)"]);
        assert_eq!(
            sent.tests.iter().map(|t| t.passed).collect::<Vec<_>>(),
            [true, false]
        );
        // What was recorded is what went out.
        assert_eq!(sent.exchanges[0].request.body.as_deref(), Some(body));
    }

    #[tokio::test]
    async fn refuses_to_send_broken_variables() {
        let mut request = graphql("POST", "{ me { id } }", r#"{"id": {{id}}}"#, "");
        request.url = "http://127.0.0.1:1/graphql".into();
        let error = send_with(&request, &[], &SendOptions::default(), &[])
            .await
            .unwrap_err();
        assert!(
            error
                .to_string()
                .starts_with("GraphQL variables are not valid JSON: "),
            "{error}"
        );
    }

    #[tokio::test]
    async fn only_graphql_requests_report_graphql_errors() {
        let (url, server) = serve("200 OK", r#"{"errors":[{"message":"validation"}]}"#);
        let mut request = Request::new("POST", url);
        request.body = Some("{}".into());
        let sent = send_with(&request, &[], &SendOptions::default(), &[])
            .await
            .unwrap();
        server.join().unwrap();
        assert!(sent.graphql_errors.is_empty());
    }

    #[tokio::test]
    async fn fetches_the_schema_with_the_requests_own_headers() {
        let (url, server) = serve("200 OK", SCHEMA);
        // Whatever the request is set up to send, the schema is asked for
        // with a POST of the introspection query.
        let mut request = graphql("GET", "{ me { id } }", r#"{"a": 1}"#, "Mine");
        request.url = url;
        request.add_header("Authorization", "Bearer {{token}}");
        request.add_header("Content-Type", "text/plain");
        request.tests = vec!["status == 500".into()];
        let variables = [Variable::new("token", "t0k")];
        let schema = graphql_schema(&request, &variables, &SendOptions::default(), &[])
            .await
            .unwrap();
        assert_eq!(schema.query_type, "Query");
        assert_eq!(schema.types.len(), 10);

        let raw = server.join().unwrap();
        let (head, body) = raw.split_once("\r\n\r\n").unwrap();
        assert!(head.starts_with("POST /graphql HTTP/1.1"), "{head}");
        let head = head.to_lowercase();
        assert!(head.contains("authorization: bearer t0k"));
        assert!(head.contains("content-type: application/json"));
        let body: Value = serde_json::from_str(body).unwrap();
        assert_eq!(body["operationName"], "IntrospectionQuery");
        assert_eq!(body.get("variables"), None);
        let query = body["query"].as_str().unwrap();
        assert_eq!(graphql_inspect(query).problem, "");
        assert_eq!(graphql_inspect(query).operations, ["IntrospectionQuery"]);
    }

    #[tokio::test]
    async fn says_why_there_is_no_schema() {
        let (url, server) = serve("401 Unauthorized", r#"{"message":"who are you"}"#);
        let error = graphql_schema(
            &Request::new("POST", url),
            &[],
            &SendOptions::default(),
            &[],
        )
        .await
        .unwrap_err();
        server.join().unwrap();
        assert_eq!(
            error.to_string(),
            "the server answered 401 Unauthorized when asked for its schema"
        );

        let (url, server) = serve(
            "200 OK",
            r#"{"errors":[{"message":"Introspection is disabled"}]}"#,
        );
        let error = graphql_schema(
            &Request::new("POST", url),
            &[],
            &SendOptions::default(),
            &[],
        )
        .await
        .unwrap_err();
        server.join().unwrap();
        assert_eq!(
            error.to_string(),
            "the server would not describe its schema: Introspection is disabled"
        );
    }

    fn collection(request: Request) -> Collection {
        Collection {
            name: "API".into(),
            variables: Vec::new(),
            items: vec![Item {
                name: "User".into(),
                request: Some(request),
                items: Vec::new(),
            }],
            link: None,
        }
    }

    fn sample() -> Request {
        graphql(
            "POST",
            "query User($id: ID!) {\n  user(id: $id) { name }\n}",
            "{\n  \"id\": {{id}}\n}",
            "User",
        )
    }

    #[test]
    fn is_saved_and_loaded_as_written() {
        let text = export_collection(&collection(sample()), ExportFormat::Reqorb).unwrap();
        let saved: Value = serde_json::from_str(&text).unwrap();
        let request = &saved["collections"][0]["items"][0]["request"];
        assert_eq!(request["body_mode"], "graphql");
        assert_eq!(request["graphql_operation"], "User");
        let back = import(&text, "").unwrap();
        assert_eq!(back.collections[0].items[0].request, Some(sample()));

        // Requests saved before GraphQL existed have none of its fields.
        let plain = export_collection(
            &collection(Request::new("GET", "https://api.test")),
            ExportFormat::Reqorb,
        )
        .unwrap();
        assert!(!plain.contains("graphql"));
    }

    #[test]
    fn survives_postman() {
        let text = export_collection(&collection(sample()), ExportFormat::Postman).unwrap();
        let exported: Value = serde_json::from_str(&text).unwrap();
        let body = &exported["item"][0]["request"]["body"];
        assert_eq!(body["mode"], "graphql");
        assert_eq!(
            body["graphql"],
            serde_json::json!({
                "query": "query User($id: ID!) {\n  user(id: $id) { name }\n}",
                "variables": "{\n  \"id\": {{id}}\n}",
                "operationName": "User",
            })
        );
        let back = import(&text, "").unwrap();
        assert!(back.warnings.is_empty(), "{:?}", back.warnings);
        assert_eq!(back.collections[0].items[0].request, Some(sample()));

        // Postman writes `{}` or nothing for a query without variables.
        let postman = r#"{"info":{"name":"P"},"item":[{"name":"Me","request":{
            "method":"POST","url":"https://api.test/graphql",
            "body":{"mode":"graphql","graphql":{"query":"{ me { id } }","variables":"{ }"}}}}]}"#;
        let request = import(postman, "").unwrap().collections[0].items[0]
            .request
            .clone()
            .unwrap();
        assert_eq!(request.body_mode, Some(BodyMode::GraphQl));
        assert_eq!(request.body.as_deref(), Some("{ me { id } }"));
        assert_eq!(request.graphql_variables, None);
        assert!(request.headers.is_empty());
    }

    #[test]
    fn exports_to_bruno_and_curl() {
        let text = export_collection(&collection(sample()), ExportFormat::Bruno).unwrap();
        let bruno: Value = serde_json::from_str(&text).unwrap();
        let item = &bruno["items"][0];
        assert_eq!(item["type"], "graphql-request");
        assert_eq!(item["request"]["method"], "POST");
        assert_eq!(item["request"]["body"]["mode"], "graphql");
        assert_eq!(
            item["request"]["body"]["graphql"],
            serde_json::json!({
                "query": "query User($id: ID!) {\n  user(id: $id) { name }\n}",
                "variables": "{\n  \"id\": {{id}}\n}",
            })
        );

        // curl has no notion of GraphQL: it gets the JSON, which reads
        // back in as the GraphQL request it was.
        let mut filled = sample();
        filled.graphql_variables = Some("{\n  \"id\": 7\n}".into());
        let curl = crate::to_curl(&filled);
        assert!(curl.contains("Content-Type: application/json"), "{curl}");
        let back = import(&curl, "").unwrap().collections[0].items[0]
            .request
            .clone()
            .unwrap();
        assert_eq!(back.body_mode, Some(BodyMode::GraphQl));
        assert_eq!(back.body, filled.body);
        assert_eq!(back.graphql_variables, filled.graphql_variables);
        assert_eq!(back.graphql_operation.as_deref(), Some("User"));
    }

    #[test]
    fn recordings_import_as_graphql_named_by_operation() {
        let entry = |body: &str| {
            serde_json::json!({
                "startedDateTime": "2026-01-01T00:00:00.000Z", "time": 5,
                "request": {"method": "POST", "url": "https://api.test/graphql",
                    "headers": [{"name": "Content-Type", "value": "application/json"}],
                    "postData": {"mimeType": "application/json", "text": body}},
                "response": {"status": 200, "statusText": "OK", "headers": [],
                    "content": {"mimeType": "application/json", "text": "{}"}},
            })
        };
        let har = serde_json::json!({"log": {"version": "1.2", "entries": [
            entry(r#"{"query":"query Users { users { id } }","variables":{"first":2}}"#),
            entry(r#"{"query":"query Users { users { id } }","variables":{"first":4}}"#),
            entry(r#"{"query":"mutation { add { id } }"}"#),
            entry(r#"{"search":"shoes"}"#),
        ]}})
        .to_string();
        let imported = import(&har, "Recorded").unwrap();
        let items = &imported.collections[0].items;
        let names: Vec<&str> = items.iter().map(|i| i.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "query Users",
                "query Users (2)",
                "POST /graphql",
                "POST /graphql (2)"
            ]
        );
        let first = items[0].request.as_ref().unwrap();
        assert_eq!(first.body_mode, Some(BodyMode::GraphQl));
        assert_eq!(first.body.as_deref(), Some("query Users { users { id } }"));
        assert_eq!(
            first.graphql_variables.as_deref(),
            Some("{\n  \"first\": 2\n}")
        );
        assert_eq!(
            items[2].request.as_ref().unwrap().body_mode,
            Some(BodyMode::GraphQl)
        );
        assert_eq!(items[3].request.as_ref().unwrap().body_mode, None);

        let report = crate::analyze_har(&har).unwrap();
        let operations: Vec<Option<&str>> = report
            .entries
            .iter()
            .map(|e| e.operation.as_deref())
            .collect();
        assert_eq!(
            operations,
            [
                Some("query Users"),
                Some("query Users"),
                Some("mutation"),
                None
            ]
        );
    }

    #[test]
    fn analysis_finds_errors_behind_a_good_status() {
        let entry = |status: u16, answer: &str| {
            serde_json::json!({
                "startedDateTime": "2026-01-01T00:00:00.000Z", "time": 5,
                "request": {"method": "POST", "url": "https://api.test/graphql", "headers": [],
                    "postData": {"mimeType": "application/json",
                        "text": format!(r#"{{"query":"query Q{status} {{ a }}"}}"#)}},
                "response": {"status": status, "statusText": "", "headers": [],
                    "content": {"mimeType": "application/json", "text": answer}},
            })
        };
        let har = serde_json::json!({"log": {"version": "1.2", "entries": [
            entry(200, r#"{"data":{"a":1}}"#),
            entry(201, r#"{"data":null,"errors":[{"message":"boom"}]}"#),
            entry(500, r#"{"errors":[{"message":"down"}]}"#),
        ]}})
        .to_string();
        let report = crate::analyze_har(&har).unwrap();
        let finding = report
            .findings
            .iter()
            .find(|f| f.title.contains("GraphQL"))
            .expect("the finding");
        assert_eq!(
            finding.title,
            "1 GraphQL response reports errors despite a successful status"
        );
        assert_eq!(finding.entries, [1]);
        assert!(
            finding.detail.contains("POST /graphql (query Q201)"),
            "{}",
            finding.detail
        );
    }

    #[test]
    fn redaction_reaches_variables_and_arguments() {
        let request = graphql(
            "POST",
            "mutation {\n  login(user: \"ann\", password: \"hunter2\", note: \"a: b\") { token }\n  reset(apiKey:\"k\\\"1\", secret: $s, docs: \"\"\"password: \"x\" \"\"\")\n}",
            "{\n  \"password\": \"hunter2\",\n  \"user\": \"ann\"\n}",
            "",
        );
        let redacted = redact_collection(&collection(request));
        let request = redacted.items[0].request.as_ref().unwrap();
        assert_eq!(
            request.body.as_deref(),
            Some(
                "mutation {\n  login(user: \"ann\", password: \"[REDACTED]\", note: \"a: b\") { token }\n  reset(apiKey:\"[REDACTED]\", secret: $s, docs: \"\"\"password: \"[REDACTED]\" \"\"\")\n}"
            )
        );
        assert_eq!(
            request.graphql_variables.as_deref(),
            Some("{\n  \"password\": \"[REDACTED]\",\n  \"user\": \"ann\"\n}")
        );
    }
}
