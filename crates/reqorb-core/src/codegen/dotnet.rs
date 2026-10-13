//! C#, with .NET's HttpClient.

use super::text::double;
use super::{Body, Prepared, file_name};

/// Headers .NET keeps with the body rather than with the request.
fn of_content(name: &str) -> bool {
    let name = name.to_lowercase();
    name.starts_with("content-") || ["allow", "expires", "last-modified"].contains(&name.as_str())
}

pub(super) fn csharp(p: &Prepared) -> String {
    let (content_headers, headers): (Vec<_>, Vec<_>) =
        p.headers.iter().partition(|h| of_content(&h.name));
    let reads_files = p.file().is_some() || p.has_files();

    let mut out = String::from("using System;\n");
    if reads_files {
        out.push_str("using System.IO;\n");
    }
    out.push_str("using System.Net.Http;\n");
    if p.text().is_some() {
        out.push_str("using System.Text;\n");
    }
    out.push_str("\nusing var client = new HttpClient();\n");
    if let Some(ms) = p.timeout_ms {
        out.push_str(&format!(
            "client.Timeout = TimeSpan.FromMilliseconds({ms});\n"
        ));
    }
    out.push_str(&format!(
        "\nusing var request = new HttpRequestMessage(new HttpMethod({}), {});\n",
        double(&p.method),
        double(&p.url)
    ));
    for h in headers {
        out.push_str(&format!(
            "request.Headers.TryAddWithoutValidation({}, {});\n",
            double(&h.name),
            double(&h.value)
        ));
    }

    let content = match &p.body {
        Body::None if content_headers.is_empty() => None,
        Body::None => Some("new ByteArrayContent(Array.Empty<byte>())".to_string()),
        Body::Text(text) => Some(format!(
            "new ByteArrayContent(Encoding.UTF8.GetBytes({}))",
            double(text)
        )),
        Body::File(path) => Some(format!(
            "new ByteArrayContent(File.ReadAllBytes({}))",
            double(path)
        )),
        Body::Form(fields) => {
            out.push_str("\nvar form = new MultipartFormDataContent();\n");
            for field in fields {
                if field.file {
                    out.push_str(&format!(
                        "form.Add(new ByteArrayContent(File.ReadAllBytes({})), {}, {});\n",
                        double(&field.value),
                        double(&field.key),
                        double(file_name(&field.value))
                    ));
                } else {
                    out.push_str(&format!(
                        "form.Add(new StringContent({}), {});\n",
                        double(&field.value),
                        double(&field.key)
                    ));
                }
            }
            Some("form".to_string())
        }
    };
    if let Some(content) = content {
        out.push_str(&format!("\nrequest.Content = {content};\n"));
        for h in content_headers {
            out.push_str(&format!(
                "request.Content.Headers.TryAddWithoutValidation({}, {});\n",
                double(&h.name),
                double(&h.value)
            ));
        }
    }
    out.push_str(concat!(
        "\nusing var response = await client.SendAsync(request);\n",
        "Console.WriteLine((int)response.StatusCode);\n",
        "Console.WriteLine(await response.Content.ReadAsStringAsync());\n",
    ));
    out
}
