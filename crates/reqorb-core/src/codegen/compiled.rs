//! Go, Rust, C++ and Dart.

use std::collections::BTreeSet;

use super::text::{Escapes, double, quoted};
use super::{Body, Prepared, file_name};

/// A Go string: between backticks when it runs over several lines and
/// they can hold it, which keeps a JSON body readable.
fn go_string(text: &str) -> String {
    if text.contains('\n') && !text.contains(['`', '\r']) {
        format!("`{text}`")
    } else {
        double(text)
    }
}

const GO_ADD_FILE: &str = "\
func addFile(form *multipart.Writer, field, path string) {
	file, err := os.Open(path)
	if err != nil {
		panic(err)
	}
	defer file.Close()
	part, err := form.CreateFormFile(field, filepath.Base(path))
	if err != nil {
		panic(err)
	}
	if _, err := io.Copy(part, file); err != nil {
		panic(err)
	}
}

";

pub(super) fn go(p: &Prepared) -> String {
    let mut imports = BTreeSet::from(["fmt", "io", "net/http"]);
    let mut main = String::new();
    let mut body = "nil";
    match &p.body {
        Body::None => {}
        Body::Text(text) => {
            imports.insert("strings");
            main.push_str(&format!(
                "\tbody := strings.NewReader({})\n",
                go_string(text)
            ));
            body = "body";
        }
        Body::Form(fields) => {
            imports.extend(["bytes", "mime/multipart"]);
            main.push_str("\tbody := &bytes.Buffer{}\n\tform := multipart.NewWriter(body)\n");
            for field in fields {
                let call = if field.file {
                    imports.extend(["os", "path/filepath"]);
                    "addFile(form, "
                } else {
                    "form.WriteField("
                };
                main.push_str(&format!(
                    "\t{call}{}, {})\n",
                    double(&field.key),
                    double(&field.value)
                ));
            }
            main.push_str("\tform.Close()\n\n");
            body = "body";
        }
        Body::File(path) => {
            imports.insert("os");
            main.push_str(&format!(
                "\tbody, err := os.Open({})\n\tif err != nil {{\n\t\tpanic(err)\n\t}}\n\tdefer body.Close()\n\n",
                double(path)
            ));
            body = "body";
        }
    }
    main.push_str(&format!(
        "\treq, err := http.NewRequest({}, {}, {body})\n\tif err != nil {{\n\t\tpanic(err)\n\t}}\n",
        double(&p.method),
        double(&p.url)
    ));
    for h in &p.headers {
        main.push_str(&format!(
            "\treq.Header.Add({}, {})\n",
            double(&h.name),
            double(&h.value)
        ));
    }
    if !p.form().is_empty() {
        main.push_str("\treq.Header.Set(\"Content-Type\", form.FormDataContentType())\n");
    }
    main.push('\n');
    match p.timeout_ms {
        Some(ms) => {
            imports.insert("time");
            main.push_str(&format!(
                "\tclient := &http.Client{{Timeout: {ms} * time.Millisecond}}\n\tres, err := client.Do(req)\n"
            ));
        }
        None => main.push_str("\tres, err := http.DefaultClient.Do(req)\n"),
    }
    main.push_str(concat!(
        "\tif err != nil {\n\t\tpanic(err)\n\t}\n",
        "\tdefer res.Body.Close()\n\n",
        "\tdata, err := io.ReadAll(res.Body)\n",
        "\tif err != nil {\n\t\tpanic(err)\n\t}\n",
        "\tfmt.Println(res.Status)\n",
        "\tfmt.Println(string(data))\n",
    ));

    let mut out = String::from("package main\n\nimport (\n");
    for import in &imports {
        out.push_str(&format!("\t\"{import}\"\n"));
    }
    out.push_str(")\n\n");
    if p.has_files() {
        out.push_str(GO_ADD_FILE);
    }
    out.push_str(&format!("func main() {{\n{main}}}\n"));
    out
}

/// A Rust string: a raw one where that saves escaping quotes and line
/// breaks.
fn rust_string(text: &str) -> String {
    if !text.contains(['\n', '"']) || text.contains('\r') {
        return quoted(text, '"', Escapes::Braced);
    }
    let mut hashes = String::new();
    while text.contains(&format!("\"{hashes}")) {
        hashes.push('#');
    }
    format!("r{hashes}\"{text}\"{hashes}")
}

pub(super) fn rust(p: &Prepared) -> String {
    let features = if p.form().is_empty() {
        "\"0.12\""
    } else {
        "{ version = \"0.12\", features = [\"multipart\"] }"
    };
    let mut out = format!(
        "// Cargo.toml:\n//   reqwest = {features}\n//   tokio = {{ version = \"1\", features = [\"full\"] }}\n\n"
    );
    out.push_str("#[tokio::main]\nasync fn main() -> Result<(), Box<dyn std::error::Error>> {\n");
    if !p.form().is_empty() {
        out.push_str("    let form = reqwest::multipart::Form::new()");
        for field in p.form() {
            if field.file {
                out.push_str(&format!(
                    "\n        .part(\n            {},\n            reqwest::multipart::Part::bytes(std::fs::read({})?)\n                .file_name({}),\n        )",
                    rust_string(&field.key),
                    rust_string(&field.value),
                    rust_string(file_name(&field.value))
                ));
            } else {
                out.push_str(&format!(
                    "\n        .text({}, {})",
                    rust_string(&field.key),
                    rust_string(&field.value)
                ));
            }
        }
        out.push_str(";\n\n");
    }
    let known = [
        "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "CONNECT",
    ];
    let method = if known.contains(&p.method.as_str()) {
        format!("reqwest::Method::{}", p.method)
    } else {
        format!(
            "reqwest::Method::from_bytes({}.as_bytes())?",
            rust_string(&p.method)
        )
    };
    out.push_str("    let client = reqwest::Client::new();\n    let response = client\n");
    out.push_str(&format!(
        "        .request({method}, {})\n",
        rust_string(&p.url)
    ));
    for h in &p.headers {
        out.push_str(&format!(
            "        .header({}, {})\n",
            rust_string(&h.name),
            rust_string(&h.value)
        ));
    }
    match &p.body {
        Body::None => {}
        Body::Text(text) => out.push_str(&format!("        .body({})\n", rust_string(text))),
        Body::Form(_) => out.push_str("        .multipart(form)\n"),
        Body::File(path) => out.push_str(&format!(
            "        .body(std::fs::read({})?)\n",
            rust_string(path)
        )),
    }
    if let Some(ms) = p.timeout_ms {
        out.push_str(&format!(
            "        .timeout(std::time::Duration::from_millis({ms}))\n"
        ));
    }
    out.push_str(concat!(
        "        .send()\n        .await?;\n\n",
        "    println!(\"{}\", response.status());\n",
        "    println!(\"{}\", response.text().await?);\n",
        "    Ok(())\n}\n",
    ));
    out
}

fn cpp_string(text: &str) -> String {
    quoted(text, '"', Escapes::Octal)
}

pub(super) fn cpp(p: &Prepared) -> String {
    let mut out = String::from("#include <curl/curl.h>\n");
    if p.file().is_some() {
        out.push_str("#include <fstream>\n");
    }
    out.push_str("#include <iostream>\n");
    if p.file().is_some() {
        out.push_str("#include <iterator>\n");
    }
    out.push_str(concat!(
        "#include <string>\n\n",
        "static size_t collect(char* data, size_t size, size_t count, void* out) {\n",
        "    static_cast<std::string*>(out)->append(data, size * count);\n",
        "    return size * count;\n",
        "}\n\n",
        "int main() {\n",
        "    curl_global_init(CURL_GLOBAL_DEFAULT);\n",
        "    CURL* curl = curl_easy_init();\n",
        "    if (!curl) return 1;\n\n",
    ));
    out.push_str(&format!(
        "    curl_easy_setopt(curl, CURLOPT_URL, {});\n",
        cpp_string(&p.url)
    ));
    if p.method == "HEAD" {
        out.push_str("    curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);\n");
    } else {
        out.push_str(&format!(
            "    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, {});\n",
            cpp_string(&p.method)
        ));
    }
    if let Some(ms) = p.timeout_ms {
        out.push_str(&format!(
            "    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, {ms}L);\n"
        ));
    }

    out.push_str("\n    struct curl_slist* headers = nullptr;\n");
    for h in &p.headers {
        out.push_str(&format!(
            "    headers = curl_slist_append(headers, {});\n",
            cpp_string(&format!("{}: {}", h.name, h.value))
        ));
    }
    out.push_str("    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);\n\n");

    const SEND_BODY: &str = concat!(
        "    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.data());\n",
        "    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE,\n",
        "                     static_cast<curl_off_t>(body.size()));\n\n",
    );
    match &p.body {
        Body::None => {}
        Body::Text(text) => {
            out.push_str(&format!(
                "    const std::string body = {};\n",
                cpp_string(text)
            ));
            out.push_str(SEND_BODY);
        }
        Body::Form(fields) => {
            out.push_str(
                "    curl_mime* form = curl_mime_init(curl);\n    curl_mimepart* part = nullptr;\n",
            );
            for field in fields {
                out.push_str("    part = curl_mime_addpart(form);\n");
                out.push_str(&format!(
                    "    curl_mime_name(part, {});\n",
                    cpp_string(&field.key)
                ));
                if field.file {
                    out.push_str(&format!(
                        "    curl_mime_filedata(part, {});\n",
                        cpp_string(&field.value)
                    ));
                } else {
                    out.push_str(&format!(
                        "    curl_mime_data(part, {}, CURL_ZERO_TERMINATED);\n",
                        cpp_string(&field.value)
                    ));
                }
            }
            out.push_str("    curl_easy_setopt(curl, CURLOPT_MIMEPOST, form);\n\n");
        }
        Body::File(path) => {
            out.push_str(&format!(
                "    std::ifstream file({}, std::ios::binary);\n",
                cpp_string(path)
            ));
            out.push_str(concat!(
                "    const std::string body((std::istreambuf_iterator<char>(file)),\n",
                "                           std::istreambuf_iterator<char>());\n",
            ));
            out.push_str(SEND_BODY);
        }
    }

    out.push_str(concat!(
        "    std::string response;\n",
        "    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, collect);\n",
        "    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);\n\n",
        "    const CURLcode result = curl_easy_perform(curl);\n",
        "    if (result != CURLE_OK) {\n",
        "        std::cerr << curl_easy_strerror(result) << std::endl;\n",
        "    } else {\n",
        "        long status = 0;\n",
        "        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);\n",
        "        std::cout << status << std::endl << response << std::endl;\n",
        "    }\n\n",
    ));
    if !p.form().is_empty() {
        out.push_str("    curl_mime_free(form);\n");
    }
    out.push_str(concat!(
        "    curl_slist_free_all(headers);\n",
        "    curl_easy_cleanup(curl);\n",
        "    curl_global_cleanup();\n",
        "    return result == CURLE_OK ? 0 : 1;\n",
        "}\n",
    ));
    out
}

fn dart_string(text: &str) -> String {
    quoted(text, '\'', Escapes::Dollar)
}

pub(super) fn dart(p: &Prepared) -> String {
    let mut out = String::new();
    if p.text().is_some() {
        out.push_str("import 'dart:convert';\n");
    }
    if p.file().is_some() {
        out.push_str("import 'dart:io';\n");
    }
    if !out.is_empty() {
        out.push('\n');
    }
    out.push_str("import 'package:http/http.dart' as http;\n\nFuture<void> main() async {\n");
    let class = if p.form().is_empty() {
        "Request"
    } else {
        "MultipartRequest"
    };
    out.push_str(&format!(
        "  final request = http.{class}({}, Uri.parse({}));\n",
        dart_string(&p.method),
        dart_string(&p.url)
    ));
    let headers = p.merged_headers();
    if !headers.is_empty() {
        out.push_str("  request.headers.addAll({\n");
        for h in &headers {
            out.push_str(&format!(
                "    {}: {},\n",
                dart_string(&h.name),
                dart_string(&h.value)
            ));
        }
        out.push_str("  });\n");
    }
    match &p.body {
        Body::None => {}
        Body::Text(text) => out.push_str(&format!(
            "  request.bodyBytes = utf8.encode({});\n",
            dart_string(text)
        )),
        Body::Form(fields) => {
            for field in fields {
                if field.file {
                    out.push_str(&format!(
                        "  request.files.add(await http.MultipartFile.fromPath({}, {}));\n",
                        dart_string(&field.key),
                        dart_string(&field.value)
                    ));
                } else {
                    out.push_str(&format!(
                        "  request.fields[{}] = {};\n",
                        dart_string(&field.key),
                        dart_string(&field.value)
                    ));
                }
            }
        }
        Body::File(path) => out.push_str(&format!(
            "  request.bodyBytes = await File({}).readAsBytes();\n",
            dart_string(path)
        )),
    }
    let timeout = match p.timeout_ms {
        Some(ms) => format!(".timeout(const Duration(milliseconds: {ms}))"),
        None => String::new(),
    };
    out.push_str(&format!(
        "\n  final streamed = await request.send(){timeout};\n"
    ));
    out.push_str(concat!(
        "  final response = await http.Response.fromStream(streamed);\n",
        "  print(response.statusCode);\n",
        "  print(response.body);\n",
        "}\n",
    ));
    out
}
