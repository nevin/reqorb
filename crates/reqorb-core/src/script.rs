//! Scripts: JavaScript that runs before a request is sent, to prepare it,
//! and after its response arrives, to test it and keep values from it.
//!
//! A script sees the request, the response and the variables, and nothing
//! else: it has no files, no network and no clock to wait on. What it sees
//! and what it decides cross as JSON, and the objects it works with are
//! written in JavaScript themselves (`script_prelude.js`).

use std::future::Future;
use std::task::Poll;
use std::time::{Duration, Instant};

use boa_engine::{Context, JsError, JsValue, Script, Source};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::checks::TestResult;
use crate::{Error, Header, Request, Response, Variable};

const PRELUDE: &str = include_str!("script_prelude.js");

/// How far a script may run before it is taken to be stuck. The loop limit
/// applies to each loop on its own, so loops inside loops are caught by
/// the time limit instead.
const LOOP_LIMIT: u64 = 5_000_000;
const RECURSION_LIMIT: usize = 400;
const TIME_LIMIT: Duration = Duration::from_secs(10);
/// How many instructions run between looks at the clock.
const BUDGET: u32 = 50_000;

/// Why evaluation stopped short.
enum Stopped {
    Failed(JsError),
    /// The time ran out, part way through, which leaves the engine in no
    /// state to be asked anything more.
    OutOfTime,
}

/// Evaluates `code`, giving up at `deadline`.
fn evaluate(context: &mut Context, code: &str, deadline: Instant) -> Result<JsValue, Stopped> {
    let script = Script::parse(Source::from_bytes(code), None, context).map_err(Stopped::Failed)?;
    let mut running = std::pin::pin!(script.evaluate_async_with_budget(context, BUDGET));
    // The engine pauses after each budget of instructions and is ready to
    // go on at once, so it needs no waking, only asking again.
    let mut asking = std::task::Context::from_waker(std::task::Waker::noop());
    loop {
        if let Poll::Ready(result) = running.as_mut().poll(&mut asking) {
            return result.map_err(Stopped::Failed);
        }
        if Instant::now() >= deadline {
            return Err(Stopped::OutOfTime);
        }
    }
}

fn out_of_time(limit: Duration) -> String {
    format!(
        "it ran for longer than {} seconds and was stopped",
        limit.as_secs_f32()
    )
}

/// What a script decided.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Outcome {
    /// Variables the script set, in the order it set them.
    pub set: Vec<Variable>,
    /// Variables the script removed.
    pub unset: Vec<String>,
    /// How each `test(…)` came out.
    pub tests: Vec<TestResult>,
    /// What the script printed.
    pub console: Vec<String>,
}

#[derive(Deserialize)]
struct Finished {
    request: Changed,
    out: Out,
}

#[derive(Deserialize)]
struct Changed {
    method: String,
    url: String,
    headers: Vec<Header>,
    body: Option<String>,
}

#[derive(Deserialize)]
struct Out {
    set: serde_json::Map<String, Value>,
    unset: Vec<String>,
    tests: Vec<Test>,
    console: Vec<String>,
}

#[derive(Deserialize)]
struct Test {
    name: String,
    passed: bool,
    detail: String,
}

/// What went wrong in a script, as the engine puts it but without the
/// engine's own trail, and with the line it happened on.
fn problem(error: &boa_engine::JsError) -> String {
    let text = error.to_string();
    let first = text.lines().next().unwrap_or("").trim();
    // `Error: boom (unknown at :3:7)` and `… at line 3, col 7 (native)`.
    let (message, line) = match first.rsplit_once(" (unknown at :") {
        Some((message, place)) => (message, place.split(':').next()),
        None => match first.rsplit_once(" at line ") {
            Some((message, place)) => (message, place.split(',').next()),
            None => (first, None),
        },
    };
    let message = message.strip_prefix("Error: ").unwrap_or(message);
    match line.and_then(|line| line.trim().parse::<u32>().ok()) {
        Some(line) => format!("{message} (line {line})"),
        None => message.to_string(),
    }
}

fn run(
    script: &str,
    request: &mut Request,
    response: Option<&Response>,
    variables: &[Variable],
    limit: Duration,
) -> Result<Outcome, String> {
    let deadline = Instant::now() + limit;
    // The first of each name is the one in force.
    let mut known = serde_json::Map::new();
    for variable in variables.iter().filter(|v| v.enabled) {
        known
            .entry(variable.key.clone())
            .or_insert_with(|| variable.value.clone().into());
    }
    let input = json!({
        "request": {
            "method": request.method,
            "url": request.url,
            "headers": request.headers,
            "body": request.body,
        },
        "response": response.map(|r| json!({
            "status": r.status,
            "statusText": r.status_text,
            "headers": r.headers,
            "body": r.body,
            "time": r.elapsed_ms,
            "size": r.size_bytes,
        })),
        "variables": known,
    });

    let mut context = Context::default();
    context
        .runtime_limits_mut()
        .set_loop_iteration_limit(LOOP_LIMIT);
    context
        .runtime_limits_mut()
        .set_recursion_limit(RECURSION_LIMIT);
    // The input goes in as a string for the script's side to parse, which
    // keeps anything in it from being read as code.
    let quoted = Value::from(input.to_string()).to_string();
    let setup = format!("{PRELUDE}(JSON.parse({quoted}));");
    match evaluate(&mut context, &setup, deadline) {
        Ok(_) => {}
        Err(Stopped::Failed(e)) => return Err(format!("could not be started: {}", problem(&e))),
        Err(Stopped::OutOfTime) => return Err(out_of_time(limit)),
    }

    // Evaluated on its own, so that its lines are numbered as written.
    let failed = match evaluate(&mut context, script, deadline) {
        Ok(_) => None,
        Err(Stopped::Failed(e)) => Some(e),
        Err(Stopped::OutOfTime) => return Err(out_of_time(limit)),
    };

    // Reading back runs the script's own code too, if it replaced `toJSON`.
    let (finished, unreadable) = match evaluate(&mut context, "__reqorb_finish()", deadline) {
        Ok(value) => (
            value
                .as_string()
                .map(|s| s.to_std_string_escaped())
                .and_then(|text| serde_json::from_str::<Finished>(&text).ok()),
            None,
        ),
        Err(Stopped::Failed(e)) => (None, Some(e)),
        Err(Stopped::OutOfTime) => return Err(out_of_time(limit)),
    };
    let Some(finished) = finished else {
        return Err(match failed.or(unreadable) {
            Some(e) => problem(&e),
            None => "left nothing that could be read back".into(),
        });
    };

    request.method = finished.request.method;
    request.url = finished.request.url;
    request.headers = finished.request.headers;
    request.body = finished.request.body;
    let outcome = Outcome {
        set: finished
            .out
            .set
            .into_iter()
            .map(|(key, value)| {
                let value = match value {
                    Value::String(text) => text,
                    other => other.to_string(),
                };
                Variable::new(&key, &value)
            })
            .collect(),
        unset: finished.out.unset,
        tests: finished
            .out
            .tests
            .into_iter()
            .map(|t| TestResult {
                test: t.name,
                passed: t.passed,
                detail: t.detail,
            })
            .collect(),
        console: finished.out.console,
    };
    match failed {
        // What it printed before it stopped helps to see why it stopped.
        Some(e) => Err(match outcome.console.as_slice() {
            [] => problem(&e),
            printed => format!("{}\nIt had printed:\n{}", problem(&e), printed.join("\n")),
        }),
        None => Ok(outcome),
    }
}

/// Runs the script a request carries for before it is sent. The script may
/// change the request and set variables; one that fails stops the send.
pub(crate) fn before(request: &mut Request, variables: &[Variable]) -> Result<Outcome, Error> {
    let Some(script) = request.pre_script.clone().filter(|s| !s.trim().is_empty()) else {
        return Ok(Outcome::default());
    };
    run(&script, request, None, variables, TIME_LIMIT)
        .map_err(|problem| Error::Script(format!("the pre-request script failed: {problem}")))
}

/// Runs the script a request carries for after its response. A script that
/// fails outside any `test(…)` counts as a test that failed.
pub(crate) fn after(request: &Request, response: &Response, variables: &[Variable]) -> Outcome {
    let Some(script) = request
        .post_script
        .as_deref()
        .filter(|s| !s.trim().is_empty())
    else {
        return Outcome::default();
    };
    // The script may read the request, and nothing comes of changing it.
    let mut seen = request.clone();
    match run(script, &mut seen, Some(response), variables, TIME_LIMIT) {
        Ok(outcome) => outcome,
        Err(problem) => failed_after(problem),
    }
}

/// Whether there is a script to run.
pub(crate) fn present(script: Option<&str>) -> bool {
    script.is_some_and(|s| !s.trim().is_empty())
}

/// Does `work`, which runs a script, on a thread of its own: a script may
/// compute for seconds, and the threads that move requests and responses
/// along must not wait for it.
///
/// The script stops itself at the time limit, except inside code that the
/// engine calls back from its own, such as a `map` callback or a `toJSON`,
/// where it cannot be interrupted. Waiting ends a little after the limit
/// all the same, and a script stuck there is left to finish on its own.
pub(crate) async fn apart<T: Send + 'static>(
    limit: Duration,
    work: impl FnOnce() -> T + Send + 'static,
) -> Result<T, String> {
    let (done, finished) = tokio::sync::oneshot::channel();
    std::thread::Builder::new()
        .name("reqorb-script".into())
        // The room the engine needs for scripts that nest deeply.
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            let _ = done.send(std::panic::catch_unwind(std::panic::AssertUnwindSafe(work)));
        })
        .map_err(|e| format!("could not be started: {e}"))?;
    let grace = Duration::from_secs(2).min(limit);
    match tokio::time::timeout(limit + grace, finished).await {
        Ok(Ok(Ok(value))) => Ok(value),
        Ok(Ok(Err(panic))) => std::panic::resume_unwind(panic),
        Ok(Err(_)) => Err("ended without a result".into()),
        Err(_) => Err(out_of_time(limit)),
    }
}

/// The send's view of a script that could not be run to the end.
pub(crate) fn failed_after(problem: String) -> Outcome {
    Outcome {
        tests: vec![TestResult {
            test: "the test script".into(),
            passed: false,
            detail: problem,
        }],
        ..Outcome::default()
    }
}

pub(crate) const fn time_limit() -> Duration {
    TIME_LIMIT
}

#[cfg(test)]
mod tests {
    use super::*;

    fn response(status: u16, body: &str) -> Response {
        Response {
            status,
            status_text: if status == 200 { "OK" } else { "Not Found" }.into(),
            http_version: "HTTP/1.1".into(),
            headers: vec![Header {
                name: "Content-Type".into(),
                value: "application/json".into(),
            }],
            body: body.into(),
            bytes: None,
            size_bytes: body.len() as u64,
            elapsed_ms: 42,
        }
    }

    fn pairs(variables: &[Variable]) -> Vec<(&str, &str)> {
        variables
            .iter()
            .map(|v| (v.key.as_str(), v.value.as_str()))
            .collect()
    }

    #[test]
    fn a_script_that_will_not_end_is_stopped_in_time() {
        let limit = Duration::from_millis(300);
        for script in [
            // Each loop on its own stays under the loop limit.
            "for (let i = 0; i < 4e6; i++) { for (let j = 0; j < 4e6; j++) {} }",
            // And code of its own can run when its results are read back.
            "Object.prototype.toJSON = function () { for (let i = 0; i < 4e6; i++) \
             { for (let j = 0; j < 4e6; j++) {} } };",
        ] {
            let started = Instant::now();
            let mut request = Request::new("GET", "https://api.test");
            let stopped = run(script, &mut request, None, &[], limit).unwrap_err();
            // Stopped by the clock, or by the loop limit within a function.
            assert!(
                stopped.contains("longer than 0.3 seconds") || stopped.contains("loop"),
                "{stopped}"
            );
            // Generous, as the tests run side by side and unoptimised.
            assert!(started.elapsed() < Duration::from_secs(8), "{script}");
        }
    }

    #[tokio::test]
    async fn waiting_ends_even_where_the_engine_cannot_stop_the_script() {
        // Each callback stays inside the loop limit, and the engine cannot
        // look at the clock inside `map`.
        let script = "[...Array(1e6)].map(() => { for (let i = 0; i < 4e6; i++) {} })";
        let started = Instant::now();
        let limit = Duration::from_millis(200);
        let outcome = apart(limit, move || {
            run(
                script,
                &mut Request::new("GET", "https://api.test"),
                None,
                &[],
                limit,
            )
        })
        .await;
        assert_eq!(outcome.unwrap_err(), out_of_time(limit));
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn a_pre_request_script_prepares_the_request() {
        let mut request = Request::new("get", "{{base}}/orders");
        request.add_header("Accept", "text/plain");
        request.pre_script = Some(
            r#"
            const stamp = vars.get('stamp') + '-' + [1, 2, 3].reduce((a, b) => a + b);
            vars.set('signature', stamp);
            vars.set('count', 3);
            vars.unset('stale');
            request.method = 'post';
            request.url = request.url + '?page=' + vars.get('count');
            request.setHeader('accept', 'application/json');
            request.setHeader('X-Signature', '{{signature}}');
            request.removeHeader('X-Gone');
            request.body = { ok: true, who: vars.replaceIn('{{user}} of {{nowhere}}') };
            console.log('signed', { stamp }, 7);
            "#
            .into(),
        );
        let variables = [
            Variable::new("stamp", "s1"),
            Variable::new("stamp", "shadowed"),
            Variable::new("user", "ada"),
        ];
        let outcome = before(&mut request, &variables).unwrap();
        assert_eq!(request.method, "POST");
        assert_eq!(request.url, "{{base}}/orders?page=3");
        assert_eq!(
            request
                .headers
                .iter()
                .map(|h| (h.name.as_str(), h.value.as_str()))
                .collect::<Vec<_>>(),
            [
                ("Accept", "application/json"),
                ("X-Signature", "{{signature}}")
            ]
        );
        assert_eq!(
            request.body.as_deref(),
            Some(r#"{"ok":true,"who":"ada of {{nowhere}}"}"#)
        );
        assert_eq!(pairs(&outcome.set), [("signature", "s1-6"), ("count", "3")]);
        assert_eq!(outcome.unset, ["stale"]);
        assert_eq!(outcome.console, [r#"signed {"stamp":"s1-6"} 7"#]);
    }

    #[test]
    fn a_test_script_judges_the_response_and_keeps_values() {
        let mut request = Request::new("GET", "https://api.test/me");
        request.post_script = Some(
            r#"
            const body = response.json();
            test('is fine', () => {
                expect(response.status).toBe(200);
                expect(response.header('content-type')).toContain('json');
                expect(body.tags).toEqual(['a', 'b']);
                expect(body).toHaveProperty('id', 7);
                expect(response.time).toBeLessThan(100);
            });
            test('is wrong', () => expect(body.id, 'the id').toBe(8));
            test('throws', () => { throw new Error('gave up'); });
            test('asserts', () => assert(body.id > 10, 'too small'));
            test('reads the request', () => expect(request.url).toMatch(/me$/));
            vars.set('id', body.id);
            "#
            .into(),
        );
        let outcome = after(
            &request,
            &response(200, r#"{"id": 7, "tags": ["a", "b"]}"#),
            &[],
        );
        let results: Vec<(&str, bool, &str)> = outcome
            .tests
            .iter()
            .map(|t| (t.test.as_str(), t.passed, t.detail.as_str()))
            .collect();
        assert_eq!(
            results,
            [
                ("is fine", true, ""),
                ("is wrong", false, "the id: expected 7 to equal 8"),
                ("throws", false, "gave up"),
                ("asserts", false, "too small"),
                ("reads the request", true, ""),
            ]
        );
        assert_eq!(pairs(&outcome.set), [("id", "7")]);
    }

    #[test]
    fn scripts_written_for_postman_run_as_they_are() {
        let mut request = Request::new("POST", "https://api.test/login");
        request.pre_script = Some(
            r#"
            pm.environment.set("when", "now");
            pm.request.headers.upsert({ key: "X-When", value: pm.variables.get("when") });
            pm.request.headers.add({ key: "X-Url", value: pm.request.url.toString() });
            if (pm.info.eventName !== "prerequest") throw new Error("wrong event");
            "#
            .into(),
        );
        request.post_script = Some(
            r#"
            pm.test("Status code is 200", function () {
                pm.response.to.have.status(200);
                pm.response.to.be.ok;
                pm.response.to.have.header("Content-Type");
            });
            pm.test("has a token", function () {
                var data = pm.response.json();
                pm.expect(data.token).to.be.a("string").and.to.have.lengthOf(3);
                pm.expect(data.roles).to.include("admin");
                pm.expect(data.count).to.be.above(1).and.below(5);
                pm.expect(data).to.have.property("token");
                pm.expect(data.missing).to.be.undefined;
                pm.expect(data.count).to.not.equal(9);
                pm.expect(data.nested).to.deep.equal({ a: [1] });
                pm.expect(pm.response.responseTime).to.be.below(1000);
                pm.collectionVariables.set("token", data.token);
            });
            pm.test("fails as Chai would", function () {
                pm.expect(pm.response.code).to.eql(201);
            });
            pm.test("cannot call out", function () { pm.sendRequest("x", function () {}); });
            "#
            .into(),
        );
        let outcome = before(&mut request, &[]).unwrap();
        assert_eq!(pairs(&outcome.set), [("when", "now")]);
        assert_eq!(request.headers[0].value, "now");
        assert_eq!(request.headers[1].value, "https://api.test/login");

        let body = r#"{"token": "abc", "roles": ["admin"], "count": 3, "nested": {"a": [1]}}"#;
        let outcome = after(&request, &response(200, body), &[]);
        let results: Vec<(bool, &str)> = outcome
            .tests
            .iter()
            .map(|t| (t.passed, t.detail.as_str()))
            .collect();
        assert_eq!(
            results,
            [
                (true, ""),
                (true, ""),
                (false, "expected 200 to equal 201"),
                (false, "pm.sendRequest is not available in reqorb scripts"),
            ]
        );
        assert_eq!(pairs(&outcome.set), [("token", "abc")]);
    }

    #[test]
    fn a_script_that_fails_says_where_and_does_not_hang() {
        let mut request = Request::new("GET", "https://api.test");
        let mut fails = |script: &str| {
            request.pre_script = Some(script.into());
            before(&mut request, &[]).unwrap_err().to_string()
        };
        assert_eq!(
            fails("const a = 1;\nconsole.log('got to', a);\nnothing.here = 2;"),
            "the pre-request script failed: ReferenceError: nothing is not defined (line 3)\n\
             It had printed:\ngot to 1"
        );
        assert!(fails("let = ;").contains("unexpected token"));
        assert!(fails("while (true) {}").contains("pre-request script failed"));
        assert!(fails("const f = () => f(); f();").contains("pre-request script failed"));
        // No way out of the box.
        assert!(fails("require('fs')").contains("require is not defined"));
        assert!(fails("fetch('http://x')").contains("fetch is not defined"));

        // After the response, a failure is a failed test, not a failed send.
        request.post_script = Some("test('ran', () => {});\nresponse.json().x.y;".into());
        let outcome = after(&request, &response(404, "nope"), &[]);
        assert_eq!(outcome.tests.len(), 1);
        assert_eq!(outcome.tests[0].test, "the test script");
        assert!(
            outcome.tests[0]
                .detail
                .contains("the response body is not JSON")
        );
    }

    #[test]
    fn nothing_in_the_request_is_read_as_code() {
        let mut request = Request::new("GET", "https://api.test/\"); vars.set('x', 1); (\"");
        request.body = Some("</script>\u{2028}`${vars.set('y', 2)}`\\".into());
        request.pre_script = Some("vars.set('seen', request.body.length);".into());
        let outcome = before(&mut request, &[]).unwrap();
        assert_eq!(pairs(&outcome.set), [("seen", "32")]);
    }
}
