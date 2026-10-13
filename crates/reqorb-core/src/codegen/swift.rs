//! Swift, with Foundation's URLSession.

use super::text::{Escapes, quoted};
use super::{Body, Prepared, disposition, file_name};

fn string(text: &str) -> String {
    quoted(text, '"', Escapes::Braced)
}

/// The text escaped as inside a string, without the quotes around it.
fn inner(text: &str) -> String {
    let quoted = string(text);
    quoted[1..quoted.len() - 1].to_string()
}

pub(super) fn swift(p: &Prepared) -> String {
    let mut out = String::from("import Foundation\n\n");
    out.push_str(&format!(
        "var request = URLRequest(url: URL(string: {})!)\n",
        string(&p.url)
    ));
    out.push_str(&format!("request.httpMethod = {}\n", string(&p.method)));
    if let Some(secs) = p.timeout_secs() {
        out.push_str(&format!("request.timeoutInterval = {secs}\n"));
    }
    for h in &p.headers {
        out.push_str(&format!(
            "request.addValue({}, forHTTPHeaderField: {})\n",
            string(&h.value),
            string(&h.name)
        ));
    }
    match &p.body {
        Body::None => {}
        Body::Text(text) => {
            out.push_str(&format!("request.httpBody = Data({}.utf8)\n", string(text)))
        }
        Body::File(path) => out.push_str(&format!(
            "request.httpBody = try Data(contentsOf: URL(fileURLWithPath: {}))\n",
            string(path)
        )),
        Body::Form(fields) => {
            out.push_str("\nlet boundary = \"reqorb-\\(UUID().uuidString)\"\nvar form = Data()\n");
            let part = |text: String| {
                format!(
                    "form.append(Data(\"--\\(boundary){}\".utf8))\n",
                    inner(&text)
                )
            };
            for field in fields {
                let name = disposition(&field.key);
                if field.file {
                    out.push_str(&part(format!(
                        "\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{}\"\r\nContent-Type: application/octet-stream\r\n\r\n",
                        disposition(file_name(&field.value))
                    )));
                    out.push_str(&format!(
                        "form.append(try Data(contentsOf: URL(fileURLWithPath: {})))\n",
                        string(&field.value)
                    ));
                    out.push_str("form.append(Data(\"\\r\\n\".utf8))\n");
                } else {
                    out.push_str(&part(format!(
                        "\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{}\r\n",
                        field.value
                    )));
                }
            }
            out.push_str(&part("--\r\n".to_string()));
            out.push_str(concat!(
                "request.setValue(\"multipart/form-data; boundary=\\(boundary)\", ",
                "forHTTPHeaderField: \"Content-Type\")\n",
                "request.httpBody = form\n",
            ));
        }
    }
    out.push_str(concat!(
        "\nlet (data, response) = try await URLSession.shared.data(for: request)\n",
        "if let http = response as? HTTPURLResponse {\n",
        "    print(http.statusCode)\n",
        "}\n",
        "print(String(decoding: data, as: UTF8.self))\n",
    ));
    out
}
