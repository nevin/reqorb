//! Java and Kotlin.

use std::collections::BTreeSet;

use super::text::{Escapes, double, quoted};
use super::{Body, Prepared, disposition, file_name};

/// Headers Java's client sets itself and refuses to be given.
const JAVA_RESTRICTED: [&str; 5] = ["connection", "content-length", "expect", "host", "upgrade"];

pub(super) fn java(p: &Prepared, notes: &mut Vec<String>) -> String {
    let mut imports = BTreeSet::from([
        "java.net.URI",
        "java.net.http.HttpClient",
        "java.net.http.HttpRequest",
        "java.net.http.HttpResponse",
    ]);
    let mut main = String::new();
    let publisher = match &p.body {
        Body::None => "HttpRequest.BodyPublishers.noBody()".to_string(),
        Body::Text(text) => format!("HttpRequest.BodyPublishers.ofString({})", double(text)),
        Body::File(path) => {
            imports.insert("java.nio.file.Path");
            format!(
                "HttpRequest.BodyPublishers.ofFile(Path.of({}))",
                double(path)
            )
        }
        Body::Form(fields) => {
            imports.extend([
                "java.io.ByteArrayOutputStream",
                "java.nio.charset.StandardCharsets",
                "java.util.UUID",
            ]);
            main.push_str("        String boundary = \"reqorb-\" + UUID.randomUUID();\n");
            main.push_str("        ByteArrayOutputStream form = new ByteArrayOutputStream();\n");
            let write = |text: String| {
                format!(
                    "        form.write((\"--\" + boundary + {}).getBytes(StandardCharsets.UTF_8));\n",
                    double(&text)
                )
            };
            for field in fields {
                let name = disposition(&field.key);
                if field.file {
                    imports.extend(["java.nio.file.Files", "java.nio.file.Path"]);
                    main.push_str(&write(format!(
                        "\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{}\"\r\nContent-Type: application/octet-stream\r\n\r\n",
                        disposition(file_name(&field.value))
                    )));
                    main.push_str(&format!(
                        "        form.write(Files.readAllBytes(Path.of({})));\n",
                        double(&field.value)
                    ));
                    main.push_str(
                        "        form.write(\"\\r\\n\".getBytes(StandardCharsets.UTF_8));\n",
                    );
                } else {
                    main.push_str(&write(format!(
                        "\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{}\r\n",
                        field.value
                    )));
                }
            }
            main.push_str(&write("--\r\n".to_string()));
            main.push('\n');
            "HttpRequest.BodyPublishers.ofByteArray(form.toByteArray())".to_string()
        }
    };

    main.push_str("        HttpRequest request = HttpRequest.newBuilder()\n");
    main.push_str(&format!(
        "            .uri(URI.create({}))\n",
        double(&p.url)
    ));
    main.push_str(&format!(
        "            .method({}, {publisher})\n",
        double(&p.method)
    ));
    let mut dropped = Vec::new();
    for h in &p.headers {
        if JAVA_RESTRICTED.contains(&h.name.to_lowercase().as_str()) {
            dropped.push(h.name.clone());
            continue;
        }
        main.push_str(&format!(
            "            .header({}, {})\n",
            double(&h.name),
            double(&h.value)
        ));
    }
    if !dropped.is_empty() {
        notes.push(format!(
            "Java's HttpClient sets {} itself, so it is left out.",
            dropped.join(", ")
        ));
    }
    if !p.form().is_empty() {
        main.push_str(
            "            .header(\"Content-Type\", \"multipart/form-data; boundary=\" + boundary)\n",
        );
    }
    if let Some(ms) = p.timeout_ms {
        imports.insert("java.time.Duration");
        main.push_str(&format!("            .timeout(Duration.ofMillis({ms}))\n"));
    }
    main.push_str(concat!(
        "            .build();\n\n",
        "        HttpResponse<String> response = HttpClient.newHttpClient()\n",
        "            .send(request, HttpResponse.BodyHandlers.ofString());\n",
        "        System.out.println(response.statusCode());\n",
        "        System.out.println(response.body());\n",
    ));

    let mut out = String::new();
    for import in &imports {
        out.push_str(&format!("import {import};\n"));
    }
    out.push_str(
        "\npublic class Main {\n    public static void main(String[] args) throws Exception {\n",
    );
    out.push_str(&main);
    out.push_str("    }\n}\n");
    out
}

fn kotlin_string(text: &str) -> String {
    quoted(text, '"', Escapes::Dollar)
}

pub(super) fn kotlin(p: &Prepared) -> String {
    let mut imports = BTreeSet::from(["okhttp3.OkHttpClient", "okhttp3.Request"]);
    let mut main = String::new();
    match p.timeout_ms {
        Some(ms) => {
            imports.insert("java.util.concurrent.TimeUnit");
            main.push_str(&format!(
                "    val client = OkHttpClient.Builder()\n        .callTimeout({ms}, TimeUnit.MILLISECONDS)\n        .build()\n"
            ));
        }
        None => main.push_str("    val client = OkHttpClient()\n"),
    }
    let mut body = "null";
    match &p.body {
        Body::None => {
            // OkHttp will not send these without a body, even an empty one.
            if ["POST", "PUT", "PATCH", "PROPPATCH", "REPORT"].contains(&p.method.as_str()) {
                imports.insert("okhttp3.RequestBody.Companion.toRequestBody");
                main.push_str("    val body = \"\".toRequestBody()\n");
                body = "body";
            }
        }
        Body::Text(text) => {
            imports.insert("okhttp3.RequestBody.Companion.toRequestBody");
            main.push_str(&format!(
                "    val body = {}.toRequestBody()\n",
                kotlin_string(text)
            ));
            body = "body";
        }
        Body::Form(fields) => {
            imports.insert("okhttp3.MultipartBody");
            main.push_str(
                "    val body = MultipartBody.Builder()\n        .setType(MultipartBody.FORM)\n",
            );
            for field in fields {
                if field.file {
                    imports.extend([
                        "java.io.File",
                        "okhttp3.RequestBody.Companion.asRequestBody",
                    ]);
                    main.push_str(&format!(
                        "        .addFormDataPart({}, {}, File({}).asRequestBody())\n",
                        kotlin_string(&field.key),
                        kotlin_string(file_name(&field.value)),
                        kotlin_string(&field.value)
                    ));
                } else {
                    main.push_str(&format!(
                        "        .addFormDataPart({}, {})\n",
                        kotlin_string(&field.key),
                        kotlin_string(&field.value)
                    ));
                }
            }
            main.push_str("        .build()\n");
            body = "body";
        }
        Body::File(path) => {
            imports.extend([
                "java.io.File",
                "okhttp3.RequestBody.Companion.asRequestBody",
            ]);
            main.push_str(&format!(
                "    val body = File({}).asRequestBody()\n",
                kotlin_string(path)
            ));
            body = "body";
        }
    }
    main.push_str("    val request = Request.Builder()\n");
    main.push_str(&format!("        .url({})\n", kotlin_string(&p.url)));
    main.push_str(&format!(
        "        .method({}, {body})\n",
        kotlin_string(&p.method)
    ));
    for h in &p.headers {
        main.push_str(&format!(
            "        .addHeader({}, {})\n",
            kotlin_string(&h.name),
            kotlin_string(&h.value)
        ));
    }
    main.push_str(concat!(
        "        .build()\n\n",
        "    client.newCall(request).execute().use { response ->\n",
        "        println(response.code)\n",
        "        println(response.body?.string())\n",
        "    }\n",
    ));

    let mut out = String::new();
    for import in &imports {
        out.push_str(&format!("import {import}\n"));
    }
    out.push_str(&format!("\nfun main() {{\n{main}}}\n"));
    out
}
