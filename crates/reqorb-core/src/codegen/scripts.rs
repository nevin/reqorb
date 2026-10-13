//! The scripting languages: Python, Ruby, PHP and PowerShell.

use super::text::{double, needs_escapes, php_string, python_literal, ruby_string};
use super::{Body, Prepared};

pub(super) fn python(p: &Prepared) -> String {
    let mut out = String::from("import requests\n\n");
    out.push_str(&format!("url = {}\n", double(&p.url)));
    let mut arguments = vec![double(&p.method), "url".to_string()];

    let headers = p.merged_headers();
    if !headers.is_empty() {
        out.push_str("headers = {\n");
        for h in &headers {
            out.push_str(&format!("    {}: {},\n", double(&h.name), double(&h.value)));
        }
        out.push_str("}\n");
        arguments.push("headers=headers".into());
    }
    match &p.body {
        Body::None => {}
        Body::Text(text) => match p.json() {
            // Anything else `requests` would not send as it is written.
            Some(json) if json.is_object() || json.is_array() => {
                out.push_str(&format!("payload = {}\n", python_literal(&json, 0)));
                arguments.push("json=payload".into());
            }
            _ => {
                out.push_str(&format!("payload = {}\n", double(text)));
                arguments.push("data=payload.encode(\"utf-8\")".into());
            }
        },
        Body::Form(fields) => {
            out.push_str("files = [\n");
            for field in fields {
                let value = if field.file {
                    format!("open({}, \"rb\")", double(&field.value))
                } else {
                    format!("(None, {})", double(&field.value))
                };
                out.push_str(&format!("    ({}, {value}),\n", double(&field.key)));
            }
            out.push_str("]\n");
            arguments.push("files=files".into());
        }
        Body::File(path) => arguments.push(format!("data=open({}, \"rb\")", double(path))),
    }
    if let Some(secs) = p.timeout_secs() {
        arguments.push(format!("timeout={secs}"));
    }

    out.push_str("\nresponse = requests.request(\n");
    for argument in arguments {
        out.push_str(&format!("    {argument},\n"));
    }
    out.push_str(")\n\nprint(response.status_code)\nprint(response.text)\n");
    out
}

pub(super) fn ruby(p: &Prepared) -> String {
    let mut out = String::from("require 'net/http'\nrequire 'uri'\n\n");
    out.push_str(&format!("uri = URI({})\n", ruby_string(&p.url)));
    out.push_str("http = Net::HTTP.new(uri.host, uri.port)\n");
    out.push_str("http.use_ssl = uri.scheme == 'https'\n");
    if let Some(secs) = p.timeout_secs() {
        out.push_str(&format!("http.open_timeout = {secs}\n"));
        out.push_str(&format!("http.read_timeout = {secs}\n"));
    }
    out.push('\n');

    let class = match p.method.as_str() {
        "GET" => Some("Get"),
        "POST" => Some("Post"),
        "PUT" => Some("Put"),
        "PATCH" => Some("Patch"),
        "DELETE" => Some("Delete"),
        "HEAD" => Some("Head"),
        "OPTIONS" => Some("Options"),
        _ => None,
    };
    match class {
        Some(class) => out.push_str(&format!("request = Net::HTTP::{class}.new(uri)\n")),
        // A method Net::HTTP has no class for.
        None => out.push_str(&format!(
            "request = Net::HTTPGenericRequest.new({}, {}, true, uri)\n",
            ruby_string(&p.method),
            p.has_body()
        )),
    }
    for h in p.merged_headers() {
        out.push_str(&format!(
            "request[{}] = {}\n",
            ruby_string(&h.name),
            ruby_string(&h.value)
        ));
    }
    match &p.body {
        Body::None => {}
        Body::Text(text) => out.push_str(&format!("request.body = {}\n", ruby_string(text))),
        Body::Form(fields) => {
            out.push_str("request.set_form([\n");
            for field in fields {
                let value = if field.file {
                    format!("File.open({})", ruby_string(&field.value))
                } else {
                    ruby_string(&field.value)
                };
                out.push_str(&format!("  [{}, {value}],\n", ruby_string(&field.key)));
            }
            out.push_str("], 'multipart/form-data')\n");
        }
        Body::File(path) => out.push_str(&format!(
            "request.body = File.binread({})\n",
            ruby_string(path)
        )),
    }
    out.push_str("\nresponse = http.request(request)\nputs response.code\nputs response.body\n");
    out
}

pub(super) fn php(p: &Prepared) -> String {
    let mut out = String::from("<?php\n\n$curl = curl_init();\ncurl_setopt_array($curl, [\n");
    out.push_str(&format!("    CURLOPT_URL => {},\n", php_string(&p.url)));
    out.push_str("    CURLOPT_RETURNTRANSFER => true,\n");
    if p.method == "HEAD" {
        out.push_str("    CURLOPT_NOBODY => true,\n");
    } else {
        out.push_str(&format!(
            "    CURLOPT_CUSTOMREQUEST => {},\n",
            php_string(&p.method)
        ));
    }
    if let Some(ms) = p.timeout_ms {
        out.push_str(&format!("    CURLOPT_TIMEOUT_MS => {ms},\n"));
    }
    if !p.headers.is_empty() {
        out.push_str("    CURLOPT_HTTPHEADER => [\n");
        for h in &p.headers {
            out.push_str(&format!(
                "        {},\n",
                php_string(&format!("{}: {}", h.name, h.value))
            ));
        }
        out.push_str("    ],\n");
    }
    match &p.body {
        Body::None => {}
        Body::Text(text) => out.push_str(&format!(
            "    CURLOPT_POSTFIELDS => {},\n",
            php_string(text)
        )),
        Body::Form(fields) => {
            out.push_str("    CURLOPT_POSTFIELDS => [\n");
            for field in fields {
                let value = if field.file {
                    format!("new CURLFile({})", php_string(&field.value))
                } else {
                    php_string(&field.value)
                };
                out.push_str(&format!("        {} => {value},\n", php_string(&field.key)));
            }
            out.push_str("    ],\n");
        }
        Body::File(path) => out.push_str(&format!(
            "    CURLOPT_POSTFIELDS => file_get_contents({}),\n",
            php_string(path)
        )),
    }
    out.push_str(concat!(
        "]);\n\n",
        "$response = curl_exec($curl);\n",
        "if ($response === false) {\n",
        "    echo 'Error: ' . curl_error($curl) . PHP_EOL;\n",
        "} else {\n",
        "    echo curl_getinfo($curl, CURLINFO_RESPONSE_CODE) . PHP_EOL;\n",
        "    echo $response . PHP_EOL;\n",
        "}\n",
        "curl_close($curl);\n",
    ));
    out
}

/// A single-quoted PowerShell string, where a quote is written twice. The
/// curly quotes count as quotes to PowerShell too. Characters that have to
/// be escaped need double quotes, and the backtick that escapes there.
fn ps(text: &str) -> String {
    if needs_escapes(text) {
        let mut out = String::from("\"");
        for c in text.chars() {
            match c {
                '\n' => out.push_str("`n"),
                '\r' => out.push_str("`r"),
                '\t' => out.push_str("`t"),
                '`' | '$' | '"' | '\u{201c}' | '\u{201d}' | '\u{201e}' => {
                    out.push('`');
                    out.push(c);
                }
                c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                    out.push_str(&format!("`u{{{:x}}}", c as u32))
                }
                c => out.push(c),
            }
        }
        out.push('"');
        return out;
    }
    let mut out = String::from("'");
    for c in text.chars() {
        out.push(c);
        if matches!(c, '\'' | '\u{2018}' | '\u{2019}' | '\u{201a}' | '\u{201b}') {
            out.push(c);
        }
    }
    out.push('\'');
    out
}

pub(super) fn powershell(p: &Prepared) -> String {
    let mut out = String::from("$request = @{\n");
    out.push_str(&format!("    Uri = {}\n", ps(&p.url)));
    let known = [
        "GET", "HEAD", "POST", "PUT", "DELETE", "TRACE", "OPTIONS", "MERGE", "PATCH",
    ];
    let key = if known.contains(&p.method.as_str()) {
        "Method"
    } else {
        "CustomMethod"
    };
    out.push_str(&format!("    {key} = {}\n", ps(&p.method)));

    // The content type is an option of its own, and refused as a header.
    let headers: Vec<_> = p
        .merged_headers()
        .into_iter()
        .filter(|h| !h.name.eq_ignore_ascii_case("content-type"))
        .collect();
    if !headers.is_empty() {
        out.push_str("    Headers = @{\n");
        for h in &headers {
            out.push_str(&format!("        {} = {}\n", ps(&h.name), ps(&h.value)));
        }
        out.push_str("    }\n");
    }
    if let Some(kind) = p.header("content-type") {
        out.push_str(&format!("    ContentType = {}\n", ps(kind)));
    }
    match &p.body {
        Body::None => {}
        Body::Text(text) => out.push_str(&format!(
            "    Body = [System.Text.Encoding]::UTF8.GetBytes({})\n",
            ps(text)
        )),
        Body::Form(fields) => {
            out.push_str("    Form = @{\n");
            for field in fields {
                let value = if field.file {
                    format!("Get-Item -Path {}", ps(&field.value))
                } else {
                    ps(&field.value)
                };
                out.push_str(&format!("        {} = {value}\n", ps(&field.key)));
            }
            out.push_str("    }\n");
        }
        Body::File(path) => out.push_str(&format!("    InFile = {}\n", ps(path))),
    }
    if let Some(ms) = p.timeout_ms {
        out.push_str(&format!("    TimeoutSec = {}\n", ms.div_ceil(1000).max(1)));
    }
    out.push_str(
        "}\n\n$response = Invoke-WebRequest @request\n$response.StatusCode\n$response.Content\n",
    );
    out
}
