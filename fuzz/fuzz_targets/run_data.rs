//! A data file for a collection run, as CSV and as JSON.
#![no_main]

use libfuzzer_sys::fuzz_target;
use reqorb_core::parse_run_data;

fuzz_target!(|text: &str| {
    let _ = parse_run_data("rows.csv", text);
    let _ = parse_run_data("rows.json", text);
});
