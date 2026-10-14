//! A HAR file, imported as requests and analysed as a report.
#![no_main]

use libfuzzer_sys::fuzz_target;
use reqorb_core::{analyze_har, import_har};

fuzz_target!(|text: &str| {
    let _ = import_har(text, "fuzz", &[]);
    let _ = import_har(text, "fuzz", &[0, 1, 7]);
    let _ = analyze_har(text);
});
