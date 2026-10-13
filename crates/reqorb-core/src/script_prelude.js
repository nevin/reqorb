// What a script can see and do. Everything here is plain JavaScript: the
// request and response come in as JSON, and what the script decided goes
// back out the same way. A script can reach nothing else.
(function (input) {
  const out = { set: {}, unset: [], tests: [], console: [] };

  const show = (value) => {
    if (typeof value === 'string') return value;
    try {
      const text = JSON.stringify(value);
      return text === undefined ? String(value) : text;
    } catch (e) {
      return String(value);
    }
  };
  const log = (level) => (...args) => {
    out.console.push(level + args.map(show).join(' '));
  };
  globalThis.console = {
    log: log(''), info: log(''), debug: log(''),
    warn: log('warning: '), error: log('error: '),
  };

  // ---------------------------------------------------------- variables
  const vars = {
    get(name) {
      name = String(name);
      if (Object.prototype.hasOwnProperty.call(out.set, name)) return out.set[name];
      if (out.unset.includes(name)) return undefined;
      return input.variables[name];
    },
    has(name) { return vars.get(name) !== undefined; },
    set(name, value) {
      name = String(name);
      out.set[name] = value == null ? '' : show(value);
      out.unset = out.unset.filter((n) => n !== name);
    },
    unset(name) {
      name = String(name);
      delete out.set[name];
      if (!out.unset.includes(name)) out.unset.push(name);
    },
    replaceIn(text) {
      return String(text).replace(/\{\{\s*([^{}]+?)\s*\}\}/g, (all, name) => {
        const value = vars.get(name);
        return value === undefined ? all : value;
      });
    },
    toObject() {
      const all = Object.assign({}, input.variables, out.set);
      for (const name of out.unset) delete all[name];
      return all;
    },
    clear() {},
  };

  // ------------------------------------------------------------ request
  const sent = input.request;
  const headerAt = (name) =>
    sent.headers.findIndex((h) => h.name.toLowerCase() === String(name).toLowerCase());
  const request = {
    get method() { return sent.method; },
    set method(value) { sent.method = String(value).toUpperCase(); },
    get url() { return sent.url; },
    set url(value) { sent.url = String(value); },
    get body() { return sent.body; },
    set body(value) {
      sent.body = value == null ? null : typeof value === 'string' ? value : JSON.stringify(value);
    },
    get headers() {
      const all = {};
      for (const h of sent.headers) all[h.name] = h.value;
      return all;
    },
    header(name) {
      const at = headerAt(name);
      return at < 0 ? undefined : sent.headers[at].value;
    },
    setHeader(name, value) {
      const at = headerAt(name);
      if (at < 0) sent.headers.push({ name: String(name), value: String(value) });
      else sent.headers[at].value = String(value);
    },
    removeHeader(name) {
      for (let at = headerAt(name); at >= 0; at = headerAt(name)) sent.headers.splice(at, 1);
    },
  };

  // ----------------------------------------------------------- response
  let response = null;
  if (input.response) {
    const got = input.response;
    const headers = {};
    for (const h of got.headers) headers[h.name.toLowerCase()] = h.value;
    let parsed;
    let read = false;
    response = {
      status: got.status,
      statusText: got.statusText,
      time: got.time,
      size: got.size,
      body: got.body,
      headers,
      header(name) { return headers[String(name).toLowerCase()]; },
      text() { return got.body; },
      json() {
        if (!read) {
          try {
            parsed = JSON.parse(got.body);
          } catch (e) {
            throw new Error('the response body is not JSON');
          }
          read = true;
        }
        return parsed;
      },
    };
  }

  // -------------------------------------------------------------- tests
  const reason = (e) => (e && e.message !== undefined ? String(e.message) : String(e));
  function test(name, check) {
    try {
      check();
      out.tests.push({ name: String(name), passed: true, detail: '' });
    } catch (e) {
      out.tests.push({ name: String(name), passed: false, detail: reason(e) });
    }
  }
  function assert(condition, message) {
    if (!condition) throw new Error(message || 'assertion failed');
  }
  const same = (a, b) => {
    if (a === b) return true;
    if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return false;
    const ka = Object.keys(a);
    const kb = Object.keys(b);
    return Array.isArray(a) === Array.isArray(b) && ka.length === kb.length &&
      ka.every((k) => same(a[k], b[k]));
  };
  const holds = (whole, part) => {
    if (typeof whole === 'string') return whole.includes(String(part));
    if (Array.isArray(whole)) return whole.some((item) => same(item, part));
    if (whole && typeof whole === 'object' && part && typeof part === 'object') {
      return Object.keys(part).every((k) => same(whole[k], part[k]));
    }
    return false;
  };
  const kind = (value) =>
    value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
  const size = (value) =>
    value == null ? 0 : typeof value === 'object' && !Array.isArray(value)
      ? Object.keys(value).length : value.length;

  // Reads as Jest does (`expect(x).toBe(1)`) and as Chai does
  // (`expect(x).to.equal(1)`), since scripts are written in both.
  function expect(actual, label) {
    let negate = false;
    let deep = false;
    const chain = {};
    const check = (ok, what) => {
      if (Boolean(ok) === negate) {
        throw new Error(
          (label ? label + ': ' : '') + 'expected ' + show(actual) +
            (negate ? ' not ' : ' ') + what);
      }
      negate = false;
      deep = false;
      return chain;
    };
    for (const word of ['to', 'be', 'been', 'is', 'that', 'which', 'and', 'has', 'have', 'with', 'at', 'of', 'same', 'does']) {
      Object.defineProperty(chain, word, { get: () => chain });
    }
    Object.defineProperty(chain, 'not', { get() { negate = !negate; return chain; } });
    Object.defineProperty(chain, 'deep', { get() { deep = true; return chain; } });
    const state = {
      ok: () => !!actual, true: () => actual === true, false: () => actual === false,
      null: () => actual === null, undefined: () => actual === undefined,
      exist: () => actual != null, empty: () => size(actual) === 0,
    };
    for (const name of Object.keys(state)) {
      Object.defineProperty(chain, name, { get: () => check(state[name](), 'to be ' + name) });
    }
    const method = (names, run) => { for (const name of names) chain[name] = run; };
    method(['equal', 'equals', 'eq', 'toBe'], (want) =>
      check(deep ? same(actual, want) : actual === want, 'to equal ' + show(want)));
    method(['eql', 'eqls', 'toEqual', 'toStrictEqual'], (want) =>
      check(same(actual, want), 'to equal ' + show(want)));
    method(['include', 'includes', 'contain', 'contains', 'toContain', 'string'], (want) =>
      check(holds(actual, want), 'to include ' + show(want)));
    method(['above', 'gt', 'greaterThan', 'toBeGreaterThan'], (n) =>
      check(actual > n, 'to be above ' + n));
    method(['below', 'lt', 'lessThan', 'toBeLessThan'], (n) =>
      check(actual < n, 'to be below ' + n));
    method(['least', 'gte', 'toBeGreaterThanOrEqual'], (n) =>
      check(actual >= n, 'to be at least ' + n));
    method(['most', 'lte', 'toBeLessThanOrEqual'], (n) =>
      check(actual <= n, 'to be at most ' + n));
    method(['within'], (low, high) =>
      check(actual >= low && actual <= high, 'to be within ' + low + ' and ' + high));
    method(['match', 'matches', 'toMatch'], (pattern) =>
      check(new RegExp(pattern).test(String(actual)), 'to match ' + pattern));
    method(['property', 'toHaveProperty'], (name, want) =>
      check(
        actual != null && Object.prototype.hasOwnProperty.call(Object(actual), name) &&
          (want === undefined || same(actual[name], want)),
        'to have property ' + show(name) + (want === undefined ? '' : ' of ' + show(want))));
    method(['lengthOf', 'length', 'toHaveLength'], (n) =>
      check(size(actual) === n, 'to have length ' + n));
    method(['a', 'an'], (type) =>
      check(kind(actual) === String(type).toLowerCase(), 'to be ' + type));
    method(['oneOf'], (list) =>
      check(list.some((item) => same(item, actual)), 'to be one of ' + show(list)));
    method(['keys', 'key'], (...names) =>
      check(names.flat().every((n) => actual != null && n in Object(actual)),
        'to have keys ' + show(names.flat())));
    method(['toBeTruthy'], () => check(!!actual, 'to be truthy'));
    method(['toBeFalsy'], () => check(!actual, 'to be falsy'));
    method(['toBeNull'], () => check(actual === null, 'to be null'));
    method(['toBeDefined'], () => check(actual !== undefined, 'to be defined'));
    method(['toBeUndefined'], () => check(actual === undefined, 'to be undefined'));
    return chain;
  }

  // ------------------------------------------- scripts written for Postman
  const scope = Object.assign({}, vars);
  const unsupported = (what) => () => {
    throw new Error(what + ' is not available in reqorb scripts');
  };
  const pm = {
    variables: scope,
    environment: Object.assign({ name: input.environment || '' }, scope),
    collectionVariables: scope,
    globals: scope,
    iterationData: scope,
    test,
    expect,
    info: {
      requestName: input.name || '',
      eventName: input.response ? 'test' : 'prerequest',
      iteration: 0,
    },
    sendRequest: unsupported('pm.sendRequest'),
    request: {
      get method() { return sent.method; },
      set method(value) { request.method = value; },
      get url() {
        // Read as text, which is what scripts nearly always want of it.
        const url = new String(sent.url);
        url.toString = () => sent.url;
        return url;
      },
      set url(value) { request.url = value; },
      get body() {
        return { mode: 'raw', raw: sent.body || '', toString: () => sent.body || '' };
      },
      set body(value) {
        request.body = value && typeof value === 'object' && 'raw' in value ? value.raw : value;
      },
      headers: {
        get: (name) => request.header(name),
        has: (name) => headerAt(name) >= 0,
        add: (h) => sent.headers.push({ name: String(h.key), value: String(h.value) }),
        upsert: (h) => request.setHeader(h.key, h.value),
        remove: (name) => request.removeHeader(name),
        each: (visit) => sent.headers.forEach((h) => visit({ key: h.name, value: h.value })),
        toObject: () => request.headers,
      },
    },
  };
  if (response) {
    const fail = (message) => { throw new Error(message); };
    const within = (low, high, what) => ({
      get() {
        if (response.status < low || response.status > high) {
          fail('expected the response to be ' + what + ' but got ' + response.status);
        }
        return true;
      },
    });
    pm.response = {
      code: response.status,
      status: response.statusText,
      responseTime: response.time,
      responseSize: response.size,
      text: response.text,
      json: response.json,
      headers: {
        get: (name) => response.header(name),
        has: (name) => response.header(name) !== undefined,
        toObject: () => response.headers,
      },
      to: {
        have: {
          status(want) {
            const got = typeof want === 'number' ? response.status : response.statusText;
            if (got !== want) fail('expected status ' + want + ' but got ' + response.status);
          },
          header(name, want) {
            const got = response.header(name);
            if (got === undefined) fail('expected a ' + name + ' header');
            if (want !== undefined && got !== want) {
              fail('expected ' + name + ' to be ' + want + ' but got ' + got);
            }
          },
          body(want) {
            if (want !== undefined && response.body !== want) fail('expected a different body');
          },
          jsonBody() { response.json(); },
        },
        be: Object.defineProperties({}, {
          ok: within(200, 299, 'successful'),
          success: within(200, 299, 'successful'),
          error: within(400, 599, 'an error'),
          clientError: within(400, 499, 'a client error'),
          serverError: within(500, 599, 'a server error'),
          notFound: within(404, 404, 'not found'),
          unauthorized: within(401, 401, 'unauthorized'),
          forbidden: within(403, 403, 'forbidden'),
          json: { get() { response.json(); return true; } },
        }),
      },
    };
  }

  Object.assign(globalThis, { vars, request, response, test, expect, assert, pm });
  globalThis.__reqorb_finish = () => JSON.stringify({ request: sent, out });
})
