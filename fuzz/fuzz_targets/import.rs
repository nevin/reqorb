//! Any text given to Import: Postman, OpenAPI, HAR, Bruno, curl, .env or
//! reqorb's own. Whatever it makes of the text is exported again, in every
//! format and as curl, as a user could then do.
#![no_main]

use libfuzzer_sys::fuzz_target;
use reqorb_core::{ExportFormat, export_collection, export_environment, import, to_curl};

fuzz_target!(|text: &str| {
    let Ok(result) = import(text, "fuzz") else {
        return;
    };
    for collection in &result.collections {
        for format in [
            ExportFormat::Reqorb,
            ExportFormat::Postman,
            ExportFormat::Bruno,
            ExportFormat::Curl,
        ] {
            let _ = export_collection(collection, format);
        }
        for (_, request) in collection.requests() {
            let _ = to_curl(request);
        }
    }
    for environment in &result.environments {
        for format in [
            ExportFormat::Reqorb,
            ExportFormat::Postman,
            ExportFormat::Dotenv,
        ] {
            let _ = export_environment(environment, format);
        }
    }
});
