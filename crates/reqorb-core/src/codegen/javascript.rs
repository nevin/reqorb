//! JavaScript and TypeScript, with `fetch` and with axios.

use super::text::{double, hang, pretty_json};
use super::{Body, Prepared, file_name};

/// The lines that build a `FormData`, and whether anything reads a file.
fn setup(p: &Prepared) -> String {
    let mut out = String::new();
    if p.has_files() || p.file().is_some() {
        out.push_str("import fs from \"node:fs\";\n\n");
    }
    if !p.form().is_empty() {
        out.push_str("const form = new FormData();\n");
        for field in p.form() {
            if field.file {
                out.push_str(&format!(
                    "form.append({}, await fs.openAsBlob({}), {});\n",
                    double(&field.key),
                    double(&field.value),
                    double(file_name(&field.value))
                ));
            } else {
                out.push_str(&format!(
                    "form.append({}, {});\n",
                    double(&field.key),
                    double(&field.value)
                ));
            }
        }
        out.push('\n');
    }
    out
}

fn headers(p: &Prepared) -> String {
    let headers = p.merged_headers();
    if headers.is_empty() {
        return String::new();
    }
    let mut out = String::from("  headers: {\n");
    for h in &headers {
        out.push_str(&format!("    {}: {},\n", double(&h.name), double(&h.value)));
    }
    out.push_str("  },\n");
    out
}

pub(super) fn fetch(p: &Prepared, typed: bool) -> String {
    let mut options = format!("  method: {},\n", double(&p.method));
    options.push_str(&headers(p));
    let body = match &p.body {
        Body::None => None,
        Body::Text(text) => Some(match p.json() {
            Some(json) => format!("JSON.stringify({})", hang(&pretty_json(&json), "  ")),
            None => double(text),
        }),
        Body::Form(_) => Some("form".to_string()),
        Body::File(path) => Some(format!("await fs.openAsBlob({})", double(path))),
    };
    if let Some(body) = body {
        options.push_str(&format!("  body: {body},\n"));
    }
    if let Some(ms) = p.timeout_ms {
        options.push_str(&format!("  signal: AbortSignal.timeout({ms}),\n"));
    }

    let mut out = setup(p);
    if typed {
        out.push_str(&format!(
            "const options: RequestInit = {{\n{options}}};\n\n"
        ));
        out.push_str(&format!(
            "const response: Response = await fetch({}, options);\n",
            double(&p.url)
        ));
        out.push_str("const text: string = await response.text();\n\n");
        out.push_str("console.log(response.status);\nconsole.log(text);\n");
        if !out.starts_with("import") {
            // Makes the file a module, where `await` may stand on its own.
            out.push_str("\nexport {};\n");
        }
    } else {
        out.push_str(&format!(
            "const response = await fetch({}, {{\n{options}}});\n\n",
            double(&p.url)
        ));
        out.push_str("console.log(response.status);\nconsole.log(await response.text());\n");
    }
    out
}

pub(super) fn axios(p: &Prepared) -> String {
    let mut out = String::from("import axios from \"axios\";\n");
    let setup = setup(p);
    if !setup.starts_with("import") {
        out.push('\n');
    }
    out.push_str(&setup);

    out.push_str("const response = await axios({\n");
    out.push_str(&format!("  method: {},\n", double(&p.method)));
    out.push_str(&format!("  url: {},\n", double(&p.url)));
    out.push_str(&headers(p));
    let data = match &p.body {
        Body::None => None,
        Body::Text(text) => Some(match p.json() {
            // axios turns an object into JSON itself.
            Some(json) if json.is_object() || json.is_array() => hang(&pretty_json(&json), "  "),
            _ => double(text),
        }),
        Body::Form(_) => Some("form".to_string()),
        Body::File(path) => Some(format!("fs.createReadStream({})", double(path))),
    };
    if let Some(data) = data {
        out.push_str(&format!("  data: {data},\n"));
    }
    if let Some(ms) = p.timeout_ms {
        out.push_str(&format!("  timeout: {ms},\n"));
    }
    out.push_str("});\n\nconsole.log(response.status);\nconsole.log(response.data);\n");
    out
}
