# Script reference

Everything a pre-request or post-response script can use. The README's
[Scripts](../README.md#scripts) section introduces them; this page lists every name. The
API is defined in `crates/reqorb-core/src/script_prelude.js`.

## Where scripts run

- **Pre-request** scripts run before `{{variables}}` are filled in. They may change the
  request and set variables that the request then uses. If one throws, nothing is sent,
  and the error names the line.
- **Post-response** scripts run after the request's one-line tests and captures. They see
  the response and the request as it was sent. Each `test(…)` they run is listed with the
  request's other tests, and a throw outside any test counts as one failed test.
- Both run on [Boa](https://boajs.dev), a JavaScript engine embedded in reqorb, on a
  thread of their own. A script is stopped after **10 seconds** or **512 MB**.
- A script can reach nothing but what this page lists. There is no `require`, `fetch`,
  `setTimeout`, file access or network access.
- Scripts are not run for WebSocket or gRPC requests.
- Scripts from elsewhere (an import, a collection folder) do not run until you allow
  them, because a script can read every variable, credentials included.

## Globals

| Name | Is |
|---|---|
| [`request`](#request) | The request: editable before it is sent, as sent afterwards |
| [`response`](#response) | The response; `null` in a pre-request script |
| [`vars`](#vars) | The variables |
| [`test`](#test-and-assert) | Records a named check |
| [`assert`](#test-and-assert) | Throws unless a condition holds |
| [`expect`](#expect) | Jest-style and Chai-style assertions |
| [`console`](#console) | Output shown with the response |
| [`pm`](#pm-scripts-written-for-postman) | The parts of Postman's API that reqorb supports |

## `request`

| Member | |
|---|---|
| `method` | The method, such as `POST`. Assigning to it upper-cases what you give |
| `url` | The URL, with `{{variables}}` as written in a pre-request script |
| `body` | The body as text, or `null`. Assigning an object stores it as JSON |
| `headers` | An object of header names and values, read-only; use the methods below to change headers |
| `header(name)` | A header's value, by name in any case; `undefined` if absent |
| `setHeader(name, value)` | Sets a header, replacing one of the same name in any case |
| `removeHeader(name)` | Removes every header of that name |

In a post-response script, `request` is the request as it was sent, with variables filled
in. Changing it there has no effect.

## `response`

Only in post-response scripts.

| Member | |
|---|---|
| `status` | The status code, such as `200` |
| `statusText` | The reason phrase, such as `OK` |
| `time` | How long the response took, in milliseconds |
| `size` | The body's size, in bytes |
| `body` | The body as text |
| `headers` | An object of header values, keyed by lower-case name |
| `header(name)` | A header's value, by name in any case; `undefined` if absent |
| `text()` | The body as text |
| `json()` | The body parsed as JSON. Throws "the response body is not JSON" if it is not |

## `vars`

The variables a request can use: those captured earlier in the session, the active
environment's, and the collection's, in that order of priority.

| Member | |
|---|---|
| `get(name)` | The value, or `undefined` |
| `has(name)` | Whether it has a value |
| `set(name, value)` | Sets it. Values are stored as text: objects and arrays as JSON, `null` and `undefined` as `""` |
| `unset(name)` | Hides it from this request only |
| `replaceIn(text)` | `text` with every `{{name}}` that has a value filled in |
| `toObject()` | All the variables as an object |
| `clear()` | Does nothing; there for Postman scripts |

What a script sets is kept like a capture: later requests can use it until the session is
cleared.

## `test` and `assert`

```js
test('is created', () => {
  expect(response.status).toBe(201);
});
assert(response.json().id, 'the order has an id');
```

- `test(name, fn)` runs `fn` and passes unless it throws. The failure message is the
  error's message.
- `assert(condition, message)` throws `message`, or "assertion failed", unless
  `condition` is truthy.

## `expect`

`expect(value)` takes an optional second argument, a label prefixed to the failure
message. The assertions read as Jest does and as Chai does, and may be mixed.

```js
expect(order.items).toHaveLength(2);
expect(order.items).to.have.lengthOf(2);
expect(order.status).to.be.oneOf(['paid', 'shipped']);
expect(order).to.not.have.property('error');
expect(response.time, 'response time').to.be.below(500);
```

### Chain words

`to`, `be`, `been`, `is`, `that`, `which`, `and`, `has`, `have`, `with`, `at`, `of`,
`same` and `does` only make the sentence read; they change nothing. `not` negates the
assertion that follows. `deep` makes the next `equal` compare by value.

### Properties

Used without parentheses, as in `expect(x).to.be.ok`.

| Property | Passes when the value is |
|---|---|
| `ok` | Truthy |
| `true`, `false` | Exactly `true` or `false` |
| `null`, `undefined` | Exactly `null` or `undefined` |
| `exist` | Neither `null` nor `undefined` |
| `empty` | Of size 0: an empty string or array, or an object with no keys |

### Methods

Names on one row are the same assertion.

| Assertion | Passes when the value |
|---|---|
| `toBe(x)`, `equal(x)`, `equals(x)`, `eq(x)` | Is `x` (`===`). After `deep`, equals `x` by value |
| `toEqual(x)`, `toStrictEqual(x)`, `eql(x)`, `eqls(x)` | Equals `x` by value: same keys and same values, all the way down |
| `toContain(x)`, `include(x)`, `includes(x)`, `contain(x)`, `contains(x)`, `string(x)` | A string: contains the text `x`. An array: has an item equal to `x` by value. An object: has every key of `x`, with equal values |
| `toBeGreaterThan(n)`, `above(n)`, `gt(n)`, `greaterThan(n)` | Is `> n` |
| `toBeLessThan(n)`, `below(n)`, `lt(n)`, `lessThan(n)` | Is `< n` |
| `toBeGreaterThanOrEqual(n)`, `least(n)`, `gte(n)` | Is `>= n` |
| `toBeLessThanOrEqual(n)`, `most(n)`, `lte(n)` | Is `<= n` |
| `within(low, high)` | Is between `low` and `high`, inclusive |
| `toMatch(p)`, `match(p)`, `matches(p)` | As text, matches the regular expression `p`, given as a `RegExp` or a string |
| `toHaveProperty(name)`, `property(name)` | Has its own property `name` |
| `toHaveProperty(name, x)`, `property(name, x)` | Has property `name`, equal to `x` by value |
| `toHaveLength(n)`, `lengthOf(n)`, `length(n)` | Has size `n`: a string's or array's length, an object's number of keys |
| `a(type)`, `an(type)` | Is of `type`: `string`, `number`, `boolean`, `object`, `array`, `null`, `undefined` or `function` |
| `oneOf(list)` | Equals, by value, an item of `list` |
| `keys(...names)`, `key(...names)` | Has every one of `names`, given as arguments or as an array |
| `toBeTruthy()` | Is truthy |
| `toBeFalsy()` | Is falsy |
| `toBeNull()` | Is `null` |
| `toBeDefined()` | Is not `undefined` |
| `toBeUndefined()` | Is `undefined` |

A failure reads `expected <value> to equal <x>`, or `expected <value> not …` after `not`,
with the label in front when one was given.

## `console`

`console.log`, `info` and `debug` write a line; `warn` and `error` write one beginning
`warning: ` or `error: `. Strings are written as they are and other values as JSON. The
lines appear under **Console** in the app, and after the response in the CLI and the
runner.

## `pm`: scripts written for Postman

Postman scripts run unchanged when they use these parts of `pm`. Importing a Postman
collection brings its scripts, and exporting to Postman writes them back.

| Postman | In reqorb |
|---|---|
| `pm.test`, `pm.expect` | `test`, `expect` |
| `pm.variables`, `pm.environment`, `pm.collectionVariables`, `pm.globals`, `pm.iterationData` | All the same set: [`vars`](#vars). `pm.environment.name` is `""` |
| `pm.info.eventName` | `prerequest` or `test` |
| `pm.info.iteration` | Always `0` |
| `pm.info.requestName` | Always `""` |
| `pm.request.method`, `pm.request.url` | As `request`. `url` reads as text |
| `pm.request.body` | `{ mode: 'raw', raw: … }`. Assign text, or an object with `raw` |
| `pm.request.headers` | `get(name)`, `has(name)`, `add({ key, value })`, `upsert({ key, value })`, `remove(name)`, `each(fn)`, `toObject()` |
| `pm.response.code`, `.status` | The status code; the reason phrase |
| `pm.response.responseTime`, `.responseSize` | Milliseconds; bytes |
| `pm.response.text()`, `.json()` | As `response` |
| `pm.response.headers` | `get(name)`, `has(name)`, `toObject()` |
| `pm.response.to.have.status(x)` | The status code is `x`, or the reason phrase if `x` is text |
| `pm.response.to.have.header(name, value?)` | The header is there, with `value` if given |
| `pm.response.to.have.body(text)` | The body is exactly `text` |
| `pm.response.to.have.jsonBody()` | The body is JSON |
| `pm.response.to.be.ok`, `.success` | The status is 200–299 |
| `pm.response.to.be.error` | 400–599 |
| `pm.response.to.be.clientError`, `.serverError` | 400–499; 500–599 |
| `pm.response.to.be.notFound`, `.unauthorized`, `.forbidden` | 404; 401; 403 |
| `pm.response.to.be.json` | The body is JSON |

Not supported: `pm.sendRequest`, which throws "pm.sendRequest is not available in reqorb
scripts", along with `require`, `pm.cookies`, `pm.visualizer`, `pm.execution` and
anything not in this table. An import warns when a script uses `pm.sendRequest` or
`require`.
