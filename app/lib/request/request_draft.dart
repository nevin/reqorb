import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' hide FormField;

import 'package:reqorb/editor/code_controller.dart';
import 'package:reqorb/request/body_editor.dart';
import 'package:reqorb/request/key_value_editor.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/request/tests_editor.dart';

/// The request being edited: everything that is sent or saved, apart from
/// where it is saved and what came back. Notifies on every edit.
///
/// Fields that are not text are plain; call [touch] after changing one.
class RequestDraft extends ChangeNotifier {
  RequestDraft({String url = ''}) {
    this.url.text = url;
    params.text = paramsTextFromUrl(url);
    this.url.addListener(_urlChanged);
    params.addListener(_paramsChanged);
    for (final controller in _edited) {
      controller.addListener(notifyListeners);
    }
  }

  final url = TextEditingController();

  /// Headers as `Name: value` lines.
  final headers = TextEditingController();

  /// The URL's query string as `key:value` lines, for the Params tab.
  final params = TextEditingController();

  /// The raw body, or the message of a WebSocket or gRPC request.
  final body = CodeController();

  /// Url-encoded fields as `key: value` lines.
  final urlEncoded = TextEditingController();

  /// A GraphQL query and its variables, the latter as JSON.
  final graphqlQuery = CodeController();
  final graphqlVariables = CodeController();

  /// Which of the query's operations to run; empty when it has only one.
  String graphqlOperation = '';

  /// Path of the file sent as a binary body.
  final binary = TextEditingController();

  /// Tests and captures, one per line.
  final tests = TextEditingController();
  final captures = TextEditingController();

  /// An HTTP method, or `WS` or `GRPC`.
  String method = 'GET';

  /// Which kind of body the request has; [body] holds the raw text.
  BodyMode bodyMode = BodyMode.none;

  /// Form-data fields, kept in step by the form-data table.
  List<FormField> formData = const [];

  /// How the request authenticates; null for no auth.
  Auth? auth;

  /// Transport options; null for the defaults.
  RequestSettings? settings;

  /// For a gRPC request, the method to call as `package.Service/Method`.
  String? grpcMethod;

  /// The `.proto` file the methods come from; null means reflection.
  String? protoPath;

  /// Bumped whenever a different request is loaded, so that forms holding
  /// their own state rebuild from it instead of keeping what was typed.
  int generation = 0;

  /// The request as it was last saved or loaded; null for one never saved.
  Request? saved;

  /// Guards the two listeners that keep [url] and [params] in step.
  bool _syncing = false;

  /// The controllers whose edits change the request. [params] is left out,
  /// as it only ever changes together with [url].
  late final _edited = [
    url,
    headers,
    body,
    urlEncoded,
    binary,
    graphqlQuery,
    graphqlVariables,
    tests,
    captures,
  ];

  bool get isWs => method == 'WS';
  bool get isGrpc => method == 'GRPC';

  /// Reports an edit to a field that is not a text controller.
  void touch() => notifyListeners();

  /// Typing in the URL bar updates the Params tab.
  void _urlChanged() {
    if (_syncing) return;
    final text = paramsTextFromUrl(url.text);
    // Compared as pairs so that reformatting alone does not disturb the tab.
    if (urlWithParamsText('', text) == urlWithParamsText('', params.text)) {
      return;
    }
    _syncing = true;
    params.text = text;
    _syncing = false;
  }

  /// Editing the Params tab rewrites the URL's query string.
  void _paramsChanged() {
    if (_syncing) return;
    final next = urlWithParamsText(url.text, params.text);
    if (next == url.text) return;
    _syncing = true;
    url.text = next;
    _syncing = false;
  }

  /// Parses one `Name: value` per line; lines without a colon are skipped.
  List<Header> parseHeaders() {
    final parsed = <Header>[];
    for (final line in const LineSplitter().convert(headers.text)) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      parsed.add(
        Header(
          name: line.substring(0, i).trim(),
          value: line.substring(i + 1).trim(),
        ),
      );
    }
    return parsed;
  }

  /// The request as typed, before variables are substituted.
  Request toRequest() {
    if (isWs || isGrpc) {
      // The message being composed is kept as the body, so it is saved too.
      return Request(
        method: method,
        url: url.text.trim(),
        headers: parseHeaders(),
        body: body.text.isEmpty ? null : body.text,
        form: const [],
        auth: auth,
        settings: settings,
        grpcMethod: isGrpc ? grpcMethod : null,
        protoPath: isGrpc ? protoPath : null,
        tests: const [],
        captures: const [],
      );
    }
    final text = switch (bodyMode) {
      BodyMode.raw => body.text,
      BodyMode.binary => binary.text.trim(),
      BodyMode.graphQl =>
        graphqlQuery.text.trim().isEmpty ? '' : graphqlQuery.text,
      _ => '',
    };
    final graphql = bodyMode == BodyMode.graphQl && text.isNotEmpty;
    final form = switch (bodyMode) {
      BodyMode.formData => formData,
      BodyMode.urlEncoded => [
        for (final line in urlEncoded.text.split('\n'))
          if (parseKeyValueLine(line) case (final key, final value))
            FormField(key: key, value: value, file: false),
      ],
      _ => const <FormField>[],
    };
    // A body type with nothing in it is the same as no body.
    final empty = text.isEmpty && form.isEmpty;
    return Request(
      method: method,
      url: url.text.trim(),
      headers: parseHeaders(),
      body: text.isEmpty ? null : text,
      bodyMode: empty ? null : bodyMode,
      form: form,
      graphqlVariables: graphql && graphqlVariables.text.trim().isNotEmpty
          ? graphqlVariables.text
          : null,
      graphqlOperation: graphql && _namesOperation(graphqlOperation)
          ? graphqlOperation
          : null,
      auth: auth,
      settings: settings,
      tests: linesOf(tests.text),
      captures: linesOf(captures.text),
    );
  }

  /// Whether the GraphQL query still holds an operation called [name]; one
  /// that was renamed or removed cannot be asked for.
  bool _namesOperation(String name) =>
      name.isNotEmpty &&
      RegExp('\\b(?:query|mutation|subscription)\\s+${RegExp.escape(name)}\\b')
          .hasMatch(graphqlQuery.text);

  /// Shows [request] in the editor, as a saved request with no edits yet.
  void load(Request request) {
    method = request.method.toUpperCase();
    url.text = request.url;
    headers.text = [for (final h in request.headers) '${h.name}: ${h.value}']
        .join('\n');
    tests.text = request.tests.join('\n');
    captures.text = request.captures.join('\n');
    _loadBody(request);
    auth = request.auth;
    settings = request.settings;
    grpcMethod = request.grpcMethod;
    protoPath = request.protoPath;
    generation++;
    saved = toRequest();
    notifyListeners();
  }

  /// Empties the editor for a request that is not saved anywhere yet.
  void clear() {
    method = 'GET';
    for (final controller in _edited) {
      controller.clear();
    }
    bodyMode = BodyMode.none;
    formData = const [];
    graphqlOperation = '';
    auth = null;
    settings = null;
    grpcMethod = null;
    protoPath = null;
    generation++;
    saved = null;
    notifyListeners();
  }

  /// Records that the request as it stands is what is saved.
  void markSaved() {
    saved = toRequest();
    notifyListeners();
  }

  /// Whether the request differs from its saved copy. A request that was
  /// never saved has nothing to differ from.
  bool get dirty {
    final was = saved;
    if (was == null) return false;
    final now = toRequest();
    return now.method != was.method ||
        now.url != was.url ||
        now.body != was.body ||
        now.bodyMode != was.bodyMode ||
        now.graphqlVariables != was.graphqlVariables ||
        now.graphqlOperation != was.graphqlOperation ||
        now.grpcMethod != was.grpcMethod ||
        now.protoPath != was.protoPath ||
        now.settings != was.settings ||
        now.auth?.kind != was.auth?.kind ||
        !listEquals(now.auth?.params, was.auth?.params) ||
        !listEquals(now.headers, was.headers) ||
        !listEquals(now.form, was.form) ||
        !listEquals(now.tests, was.tests) ||
        !listEquals(now.captures, was.captures);
  }

  /// Shows a request's body in the editor for its type. Text bodies saved
  /// or imported as url-encoded strings open in the url-encoded table.
  void _loadBody(Request request) {
    final text = request.body ?? '';
    final encoded = request.headers.any(
      (h) =>
          h.name.toLowerCase() == 'content-type' &&
          h.value.toLowerCase().contains('x-www-form-urlencoded'),
    );
    var mode =
        request.bodyMode ?? (text.isEmpty ? BodyMode.none : BodyMode.raw);
    var fields = request.form;
    if (mode != BodyMode.formData &&
        fields.isEmpty &&
        encoded &&
        text.isNotEmpty) {
      mode = BodyMode.urlEncoded;
      String decode(String s) {
        try {
          return Uri.decodeQueryComponent(s);
        } catch (_) {
          return s;
        }
      }

      fields = [
        for (final pair in text.split('&'))
          if (pair.isNotEmpty)
            switch (pair.indexOf('=')) {
              < 0 => FormField(key: decode(pair), value: '', file: false),
              final i => FormField(
                key: decode(pair.substring(0, i)),
                value: decode(pair.substring(i + 1)),
                file: false,
              ),
            },
      ];
    }
    bodyMode = mode;
    body.text = mode == BodyMode.raw ? text : '';
    binary.text = mode == BodyMode.binary ? text : '';
    final graphql = mode == BodyMode.graphQl;
    graphqlQuery.text = graphql ? text : '';
    graphqlVariables.text = graphql ? request.graphqlVariables ?? '' : '';
    graphqlOperation = graphql ? request.graphqlOperation ?? '' : '';
    formData = mode == BodyMode.formData ? fields : const [];
    urlEncoded.text = mode == BodyMode.urlEncoded
        ? [for (final f in fields) '${f.key}: ${f.value}'].join('\n')
        : '';
  }

  /// Replaces the GraphQL query with one written from the schema, and
  /// returns a function that puts back what was there.
  VoidCallback useGraphqlDraft(GraphQlDraft draft) {
    final was = (
      graphqlQuery.text,
      graphqlVariables.text,
      graphqlOperation,
      bodyMode,
    );
    void set(String query, String variables, String operation, BodyMode mode) {
      bodyMode = mode;
      graphqlOperation = operation;
      graphqlVariables.text = variables;
      graphqlQuery.text = query;
      notifyListeners();
    }

    // One operation needs no name to pick it out.
    set(draft.query, draft.variables, '', BodyMode.graphQl);
    return () => set(was.$1, was.$2, was.$3, was.$4);
  }

  /// The raw-body type whose Content-Type the headers currently carry.
  String? rawLanguage() {
    for (final header in parseHeaders()) {
      if (header.name.toLowerCase() != 'content-type') continue;
      final value = header.value.toLowerCase();
      for (final entry in rawLanguages.entries) {
        if (value.startsWith(entry.value)) return entry.key;
      }
    }
    return null;
  }

  /// Sets the Content-Type header for a raw body, replacing any existing one.
  void setRawLanguage(String name) {
    headers.text = [
      for (final line in headers.text.split('\n'))
        if (line.trim().isNotEmpty &&
            !line.trim().toLowerCase().startsWith('content-type:'))
          line,
      'Content-Type: ${rawLanguages[name]}',
    ].join('\n');
  }

  @override
  void dispose() {
    for (final controller in [..._edited, params]) {
      controller.dispose();
    }
    super.dispose();
  }
}
