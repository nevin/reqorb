//! A GraphQL query as typed, and a server's answer to one.
#![no_main]

use libfuzzer_sys::fuzz_target;
use reqorb_core::{graphql_errors, graphql_format, graphql_inspect};

fuzz_target!(|text: &str| {
    let _ = graphql_inspect(text);
    let _ = graphql_format(text);
    let _ = graphql_errors(text);
});
