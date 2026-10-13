import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide FormField;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reqorb/transfer/export_actions.dart';
import 'package:reqorb/main.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/src/rust/frb_generated.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// What the test server saw on its most recent request.
class Seen {
  String? method;
  String? path;
  String? body;
  HttpHeaders? headers;
}

/// Swagger 2.0 with no host, so the API is assumed to live where it was served.
final _swagger = jsonEncode({
  'swagger': '2.0',
  'info': {'title': 'Orders API'},
  'basePath': '/api',
  'securityDefinitions': {
    'token': {'type': 'apiKey', 'in': 'header', 'name': 'X-Token'},
  },
  'security': [
    {'token': []},
  ],
  'paths': {
    '/orders/{orderId}': {
      'put': {
        'tags': ['orders'],
        'summary': 'Replace order',
        'consumes': ['application/json'],
        'parameters': [
          {
            'name': 'orderId',
            'in': 'path',
            'required': true,
            'type': 'integer',
            'x-example': 42,
          },
          {
            'name': 'dryRun',
            'in': 'query',
            'required': true,
            'type': 'boolean',
            'default': true,
          },
          {
            'name': 'body',
            'in': 'body',
            'schema': {r'$ref': '#/definitions/Order'},
          },
        ],
        'responses': {
          '200': {'description': 'ok'},
        },
      },
    },
    '/upload': {
      'post': {
        'consumes': ['multipart/form-data'],
        'parameters': [
          {'name': 'file', 'in': 'formData', 'type': 'file'},
        ],
        'responses': {
          '200': {'description': 'ok'},
        },
      },
    },
  },
  'definitions': {
    'Order': {
      'type': 'object',
      'properties': {
        'sku': {'type': 'string', 'example': 'A-1'},
        'quantity': {'type': 'integer'},
      },
    },
  },
});

/// A one-pixel PNG, which is not valid text.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  late HttpServer server;
  late Seen seen;
  late Directory tmp;
  late WorkspaceStore store;

  // Real sockets and bridge calls need real async, which testWidgets fakes.
  Future<void> start(WidgetTester tester) async {
    seen = Seen();
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('reqorb_test');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        // A WebSocket that greets, then answers each message in capitals.
        if (request.uri.path == '/ws') {
          final socket = await WebSocketTransformer.upgrade(request);
          socket.add('welcome ${request.headers.value('x-room')}');
          socket.listen((message) => socket.add('$message'.toUpperCase()));
          return;
        }
        // The server also publishes a Swagger document describing itself.
        final swagger = request.uri.path == '/docs/swagger.json';
        if (!swagger) {
          seen
            ..method = request.method
            ..path = request.uri.toString()
            ..headers = request.headers
            ..body = await utf8.decodeStream(request);
        }
        // An endpoint that has moved.
        if (request.uri.path == '/old') {
          request.response
            ..statusCode = 302
            ..headers.set('location', '/new?from=old');
          await request.response.close();
          return;
        }
        // A binary body: the smallest PNG there is.
        if (request.uri.path == '/logo.png') {
          request.response
            ..headers.contentType = ContentType('image', 'png')
            ..add(_png);
          await request.response.close();
          return;
        }
        // Signing in sets a session cookie, as a real API might.
        if (request.uri.path == '/login') {
          request.response.headers.add(
            'set-cookie',
            'sid=abc123; Path=/; HttpOnly',
          );
        }
        request.response
          ..statusCode = swagger ? 200 : 201
          ..headers.contentType = ContentType.json
          ..write(swagger ? _swagger : '{"ok":true}');
        await request.response.close();
      });
    });
    store = WorkspaceStore('${tmp.path}/workspace.json');
    addTearDown(() async {
      await server.close(force: true);
      await tmp.delete(recursive: true);
    });
  }

  /// Shows the app and waits for its window to finish appearing, since
  /// frames arrive unevenly while macOS is still bringing the window up.
  Future<void> launch(WidgetTester tester) async {
    // Typed text goes through the test's own text input rather than the
    // real macOS one, which only works while the window has keyboard focus.
    tester.testTextInput.register();
    addTearDown(tester.testTextInput.unregister);
    await tester.pumpWidget(ReqorbApp(store: store));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();
  }

  /// Pumps real frames until [done] holds, for animations that
  /// `pumpAndSettle` can return from early when the window is in the background.
  Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 50 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  /// Types into a text field. Unlike `enterText`, this waits until the
  /// field really has focus, because while the window is in the background
  /// the focus change can lag and the text would land in the previous field.
  Future<void> type(WidgetTester tester, Finder field, String text) async {
    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
      matchRoot: true,
    );
    // Rows in a short pane may be scrolled out of view.
    await tester.ensureVisible(field);
    await tester.pump();
    await tester.showKeyboard(field);
    for (
      var i = 0;
      i < 40 && !tester.widget<EditableText>(editable).focusNode.hasFocus;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    tester.testTextInput.enterText(text);
    await tester.pump();
  }

  /// Types into the Headers tab's text view, switching to it if needed.
  Future<void> typeHeaders(WidgetTester tester, String text) async {
    await tester.tap(find.byKey(const Key('headers-tab')));
    await tester.pumpAndSettle();
    if (find.byKey(const Key('headers')).evaluate().isEmpty) {
      await tester.tap(find.byKey(const Key('headers-bulk-toggle')));
      await tester.pumpAndSettle();
    }
    await type(tester, find.byKey(const Key('headers')), text);
  }

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(finder, findsWidgets);
  }

  testWidgets('sends a request through the Rust core and shows the response', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);

    // The sidebar collapses to give the editor the full width, and returns.
    final sidebar = find.byKey(const Key('sidebar'));
    final editorWidth = tester.getSize(find.byKey(const Key('url'))).width;
    expect(tester.getSize(sidebar).width, 281);
    expect(find.byKey(const Key('show-sidebar')), findsNothing);
    await tester.tap(find.byKey(const Key('hide-sidebar')));
    await pumpUntil(tester, () => tester.getSize(sidebar).width == 0);
    expect(tester.getSize(sidebar).width, 0);
    expect(
      tester.getSize(find.byKey(const Key('url'))).width,
      greaterThan(editorWidth + 200),
    );
    await tester.tap(find.byKey(const Key('show-sidebar')));
    await pumpUntil(tester, () => tester.getSize(sidebar).width == 281);
    expect(tester.getSize(sidebar).width, 281);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('POST').last);
    await tester.pumpAndSettle();
    await type(
      tester,
      find.byKey(const Key('url')),
      'http://127.0.0.1:${server.port}/things',
    );
    await typeHeaders(tester, 'X-Test: yes');
    await tester.tap(find.text('Body').first);
    await tester.pumpAndSettle();
    expect(find.text('This request does not have a body'), findsOneWidget);
    await tester.tap(find.byKey(const Key('body-mode-raw')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('body')), 'hello');
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));

    expect(find.text('201 Created'), findsOneWidget);
    expect(find.textContaining('"ok": true'), findsOneWidget);
    expect(seen.method, 'POST');
    expect(seen.headers!.value('x-test'), 'yes');
    expect(seen.body, 'hello');
  });

  testWidgets('imports a pasted curl command and saves a new request', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);

    await tester.tap(find.byKey(const Key('import-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-paste')));
    await tester.pumpAndSettle();
    await type(
      tester,
      find.byKey(const Key('paste')),
      "curl -X PATCH http://127.0.0.1:${server.port}/items/7 "
      "-H 'X-From: curl' --json '{\"n\":1}'",
    );
    await tester.tap(find.byKey(const Key('dialog-confirm')));
    // Importing asks what to call the new collection.
    await waitFor(tester, find.byKey(const Key('collection-name')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('collection-name')), 'Scratch');
    await tester.tap(find.byKey(const Key('dialog-confirm')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Scratch'), findsOneWidget);
    expect(find.text('PATCH /items/7'), findsOneWidget);

    await tester.tap(find.byTooltip('Collection actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rename-collection')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('collection-name')), 'Items');
    await tester.tap(find.byKey(const Key('dialog-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Scratch'), findsNothing);
    expect(store.collections.single.name, 'Items');

    await tester.tap(find.byKey(const Key('new-collection')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('collection-name')), 'Empty');
    await tester.tap(find.byKey(const Key('dialog-confirm')));
    await tester.pumpAndSettle();
    expect(store.collections.map((c) => c.name), ['Items', 'Empty']);
    store.removeCollection(1);
    await tester.pumpAndSettle();

    await tester.tap(find.text('PATCH /items/7'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    expect(seen.method, 'PATCH');
    expect(seen.headers!.value('x-from'), 'curl');
    expect(seen.headers!.contentType?.mimeType, 'application/json');
    expect(seen.body, '{"n":1}');

    // A request typed from scratch is saved through the dialog.
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    expect(store.collections.single.items.length, 1);

    // Deleting the open request detaches the editor, so Save asks where to put it.
    await tester.tap(find.byTooltip('Request actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-request')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    // The menu's closing animation can still be absorbing taps when frames
    // arrive late, so the tap is repeated if the dialog did not open.
    if (find.byKey(const Key('save-name')).evaluate().isEmpty) {
      await tester.tap(find.byKey(const Key('save')));
      await tester.pumpAndSettle();
    }
    await type(tester, find.byKey(const Key('save-name')), 'Patch item');
    await tester.tap(find.byKey(const Key('save-destination')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Items').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Patch item'), findsWidgets);
    expect(store.collections.single.items.single.request!.method, 'PATCH');
    await tester.runAsync(store.flush);
  });

  testWidgets('saves, reopens and updates a request outside any collection', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);

    // A new request starts blank and saves on its own by default.
    await tester.tap(find.byKey(const Key('new-request')));
    await tester.pumpAndSettle();
    expect(find.text('https://httpbin.org/get'), findsNothing);
    final url = 'http://127.0.0.1:${server.port}';
    await type(tester, find.byKey(const Key('url')), '$url/solo');
    await typeHeaders(tester, 'X-Solo: 1');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('save-name')), 'Solo ping');
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();
    expect(store.collections, isEmpty);
    expect(store.requests.single.name, 'Solo ping');
    expect(find.text('Solo ping'), findsWidgets);

    // Saving again updates it in place rather than asking where to put it.
    await type(tester, find.byKey(const Key('url')), '$url/solo/v2');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('save-name')), findsNothing);
    expect(store.requests.single.request!.url, '$url/solo/v2');

    // It survives a restart and can be reopened and sent.
    late Workspace reloaded;
    await tester.runAsync(() async {
      await store.flush();
      reloaded = await loadWorkspace(path: store.path);
    });
    expect(reloaded.requests.single.request!.headers.single.name, 'X-Solo');

    await tester.tap(find.byKey(const Key('new-request')));
    await tester.pumpAndSettle();
    expect(find.text('$url/solo/v2'), findsNothing);
    await tester.tap(find.text('Solo ping'));
    await tester.pumpAndSettle();
    expect(find.text('$url/solo/v2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    expect(seen.path, '/solo/v2');
    expect(seen.headers!.value('x-solo'), '1');

    await tester.tap(find.byTooltip('Request actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-request')));
    await tester.pumpAndSettle();
    expect(store.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.runAsync(store.flush);
  });

  testWidgets('edits query parameters and headers as a table or in bulk', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);
    final base = 'http://127.0.0.1:${server.port}/search';
    String urlText() =>
        tester.widget<TextField>(find.byKey(const Key('url'))).controller!.text;
    String cell(String key) =>
        tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

    // The Params tab opens first and mirrors the URL's query string.
    await type(tester, find.byKey(const Key('url')), '$base?q=tea&page=2#top');
    await tester.pumpAndSettle();
    expect(cell('params-key-0'), 'q');
    expect(cell('params-value-0'), 'tea');
    expect(cell('params-key-1'), 'page');
    expect(cell('params-value-1'), '2');

    // Editing a row, adding one and removing one all rewrite the URL.
    await type(tester, find.byKey(const Key('params-value-0')), 'green tea');
    await tester.pumpAndSettle();
    expect(urlText(), '$base?q=green tea&page=2#top');
    await type(tester, find.byKey(const Key('params-key-2')), 'sort');
    await type(tester, find.byKey(const Key('params-value-2')), '{{order}}');
    await tester.pumpAndSettle();
    expect(urlText(), '$base?q=green tea&page=2&sort={{order}}#top');
    expect(find.byKey(const Key('params-key-3')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('params-remove-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('params-remove-1')));
    await tester.pumpAndSettle();
    expect(urlText(), '$base?q=green tea&sort={{order}}#top');

    // Bulk Edit shows the same parameters as text, and edits flow back.
    await tester.tap(find.byKey(const Key('params-bulk-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Key-Value Edit'), findsOneWidget);
    expect(cell('params'), 'q:green tea\nsort:{{order}}');
    await type(
      tester,
      find.byKey(const Key('params')),
      'q:green tea\nlimit:5\nflag',
    );
    await tester.pumpAndSettle();
    expect(urlText(), '$base?q=green tea&limit=5&flag#top');
    await tester.tap(find.byKey(const Key('params-bulk-toggle')));
    await tester.pumpAndSettle();
    expect(cell('params-key-1'), 'limit');
    expect(cell('params-key-2'), 'flag');
    expect(cell('params-value-2'), '');

    // Headers use the same table.
    await tester.tap(find.byKey(const Key('headers-tab')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('headers-key-0')), 'X-One');
    await type(tester, find.byKey(const Key('headers-value-0')), '1');
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('headers-key-1')), 'X-Two');
    await type(tester, find.byKey(const Key('headers-value-1')), 'a: b');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('headers-bulk-toggle')));
    await tester.pumpAndSettle();
    expect(cell('headers'), 'X-One: 1\nX-Two: a: b');

    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    expect(seen.path, '/search?q=green%20tea&limit=5&flag');
    expect(seen.headers!.value('x-one'), '1');
    expect(seen.headers!.value('x-two'), 'a: b');

    // A saved request brings its parameters back into the table.
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-request')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('params-tab')));
    await tester.pumpAndSettle();
    expect(cell('params-key-0'), '');
    await tester.tap(find.text('GET /search'));
    await tester.pumpAndSettle();
    expect(cell('params-key-1'), 'limit');
    expect(cell('params-value-1'), '5');
    expect(tester.takeException(), isNull);
    await tester.runAsync(store.flush);
  });

  testWidgets('settings switch the theme and control how requests are sent', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);
    Brightness brightness() =>
        Theme.of(tester.element(find.byKey(const Key('url')))).brightness;
    final url = 'http://127.0.0.1:${server.port}/ping';
    await type(tester, find.byKey(const Key('url')), url);

    // The entry sits below the sidebar's list, outside its scroll area.
    final entry = find.byKey(const Key('settings'));
    expect(
      find.ancestor(of: entry, matching: find.byType(Scrollable)),
      findsNothing,
    );
    // It ends at the bottom of the window, or above the home indicator on iPad.
    final ratio = tester.view.devicePixelRatio;
    final bottom =
        (tester.view.physicalSize.height - tester.view.padding.bottom) / ratio;
    expect(tester.getBottomLeft(entry).dy, closeTo(bottom, 1));

    await tester.tap(entry);
    await tester.pumpAndSettle();
    for (final label in const [
      'Themes',
      'General',
      'System',
      'Dark',
      'Light',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);

    await tester.tap(find.byKey(const Key('settings-general')));
    await tester.pumpAndSettle();
    for (final label in const ['Auto', 'HTTP/1', 'HTTP/2']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.textContaining('0 uses the default'), findsOneWidget);
    await type(tester, find.byKey(const Key('settings-timeout')), '7');
    await tester.tap(find.text('HTTP/2'));
    await tester.pumpAndSettle();
    expect(find.textContaining('abandoned after 7 seconds'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-close')));
    await tester.pumpAndSettle();

    // Everything is saved with the workspace.
    late Workspace reloaded;
    await tester.runAsync(() async {
      await store.flush();
      reloaded = await loadWorkspace(path: store.path);
    });
    expect(reloaded.settings.theme, AppTheme.light);
    expect(reloaded.settings.httpMode, HttpMode.http2);
    expect(reloaded.settings.timeoutSecs, 7);

    // The test server only speaks HTTP/1.1, so forcing HTTP/2 fails clearly.
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('error')));
    expect(find.textContaining('HTTP/2 is forced in settings'), findsOneWidget);

    store.updateSettings(
      const Settings(
        theme: AppTheme.light,
        httpMode: HttpMode.http1,
        timeoutSecs: 7,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    expect(find.text('HTTP/1.1'), findsOneWidget);
    expect(seen.path, '/ping');
    expect(tester.takeException(), isNull);
    await tester.runAsync(store.flush);
  });

  testWidgets('keeps cookies from responses and sends them with added ones', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);
    final base = 'http://127.0.0.1:${server.port}';
    Future<void> send(String path) async {
      seen.path = null;
      await type(tester, find.byKey(const Key('url')), '$base$path');
      await tester.tap(find.byKey(const Key('send')));
      for (var i = 0; i < 50 && seen.path != path; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(seen.path, path);
      await tester.pumpAndSettle();
    }

    // Cookies is a tab of the request editor, after Auth.
    for (final label in const ['Params', 'Headers', 'Auth', 'Cookies']) {
      expect(find.widgetWithText(Tab, label), findsOneWidget);
    }
    expect(find.byKey(const Key('cookies')), findsNothing);
    await tester.tap(find.byKey(const Key('cookies-tab')));
    await tester.pumpAndSettle();
    expect(find.text('No cookies stored'), findsOneWidget);

    // The server sets a cookie, and the next request carries it back.
    await send('/login');
    expect(seen.headers!.value('cookie'), isNull);
    expect(store.cookies.single.name, 'sid');
    await send('/orders');
    expect(seen.headers!.value('cookie'), 'sid=abc123');

    // It shows in the tab, where another can be added by hand.
    expect(find.text('127.0.0.1'), findsOneWidget);
    expect(find.text('sid=abc123'), findsOneWidget);
    expect(find.textContaining('session · HttpOnly'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cookies-add')));
    await tester.pumpAndSettle();
    // The domain is suggested from the URL in the editor.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('cookie-domain')))
          .controller!
          .text,
      '127.0.0.1',
    );
    await tester.ensureVisible(find.byKey(const Key('cookie-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cookie-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('needs a domain and a name'), findsOneWidget);
    await type(tester, find.byKey(const Key('cookie-name')), 'theme');
    await type(tester, find.byKey(const Key('cookie-value')), 'dark');
    await tester.ensureVisible(find.byKey(const Key('cookie-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cookie-save')));
    await tester.pumpAndSettle();
    expect(find.text('theme=dark'), findsOneWidget);
    expect(store.cookies.last.domain, '127.0.0.1');
    await send('/orders');
    expect(seen.headers!.value('cookie'), 'sid=abc123; theme=dark');

    // The jar is saved with the workspace.
    late Workspace reloaded;
    await tester.runAsync(() async {
      await store.flush();
      reloaded = await loadWorkspace(path: store.path);
    });
    expect(reloaded.cookies.map((c) => c.name), ['sid', 'theme']);

    // Deleting one stops it being sent; clearing empties the jar.
    await tester.tap(find.byTooltip('Delete cookie').first);
    await tester.pumpAndSettle();
    expect(find.text('sid=abc123'), findsNothing);
    await send('/orders');
    expect(seen.headers!.value('cookie'), 'theme=dark');
    await tester.tap(find.byKey(const Key('cookies-clear')));
    await tester.pumpAndSettle();
    expect(store.cookies, isEmpty);
    expect(find.text('No cookies stored'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(store.flush);
  });

  testWidgets('per-request settings control redirects and are saved', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);
    final base = 'http://127.0.0.1:${server.port}';
    Future<void> sendAndWait() async {
      seen.path = null;
      await tester.tap(find.byKey(const Key('send')));
      for (var i = 0; i < 50 && seen.path == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      await waitFor(tester, find.byKey(const Key('status')));
      await tester.pumpAndSettle();
    }

    Future<void> flip(String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('POST').last);
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('url')), '$base/old');

    // By default the redirect is followed, and the POST becomes a GET.
    await sendAndWait();
    expect(seen.path, '/new?from=old');
    expect(seen.method, 'GET');
    expect(seen.headers!.value('referer'), '$base/old');

    await tester.tap(find.byKey(const Key('request-settings-tab')));
    await tester.pumpAndSettle();
    for (final title in const [
      'HTTP version',
      'Enable SSL certificate verification',
      'Automatically follow redirects',
      'Follow original HTTP method',
      'Follow Authorization header',
      'Remove referer header on redirect',
      'Enable strict HTTP parser',
      'Disable cookie jar',
      'Maximum number of redirects',
    ]) {
      expect(find.text(title, skipOffstage: false), findsOneWidget);
    }
    expect(find.text('Default (Auto)'), findsOneWidget);

    // Keeping the method and dropping the Referer.
    await flip('rs-original-method');
    await flip('rs-remove-referer');
    await sendAndWait();
    expect(seen.path, '/new?from=old');
    expect(seen.method, 'POST');
    expect(seen.headers!.value('referer'), isNull);

    // Not following shows the redirect response itself.
    await flip('rs-follow-redirects');
    seen.path = null;
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.text('302 Found'));
    expect(seen.path, '/old', reason: 'the redirect target was not requested');

    // Settings are saved with the request and restored when it is reopened.
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('save-name')), 'Moved');
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();
    final saved = store.requests.single.request!.settings!;
    expect(saved.followRedirects, isFalse);
    expect(saved.followOriginalMethod, isTrue);
    expect(saved.removeReferer, isTrue);
    expect(saved.verifySsl, isTrue);
    expect(saved.maxRedirects, 10);

    await tester.tap(find.byKey(const Key('new-request')));
    await tester.pumpAndSettle();
    Switch toggle(String key) =>
        tester.widget<Switch>(find.byKey(Key(key), skipOffstage: false));
    await tester.tap(find.byKey(const Key('request-settings-tab')));
    await tester.pumpAndSettle();
    expect(toggle('rs-follow-redirects').value, isTrue);
    await tester.tap(find.text('Moved'));
    await tester.pumpAndSettle();
    expect(toggle('rs-follow-redirects').value, isFalse);
    expect(toggle('rs-original-method').value, isTrue);

    // Putting everything back to the defaults stores no settings at all.
    await flip('rs-follow-redirects');
    await flip('rs-original-method');
    await flip('rs-remove-referer');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(store.requests.single.request!.settings, isNull);
    expect(tester.takeException(), isNull);
    await tester.runAsync(store.flush);
  });

  testWidgets('sends each body type', (tester) async {
    await start(tester);
    await launch(tester);
    final upload = File('${tmp.path}/note.txt')
      ..writeAsStringSync('from a file');
    Future<void> sendAndWait() async {
      seen.body = null;
      await tester.tap(find.byKey(const Key('send')));
      for (var i = 0; i < 50 && seen.body == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      await waitFor(tester, find.byKey(const Key('status')));
      await tester.pumpAndSettle();
    }

    Future<void> mode(String name) async {
      await tester.ensureVisible(find.byKey(Key('body-mode-$name')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('body-mode-$name')));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('POST').last);
    await tester.pumpAndSettle();
    await type(
      tester,
      find.byKey(const Key('url')),
      'http://127.0.0.1:${server.port}/upload',
    );
    await tester.tap(find.text('Body').first);
    await tester.pumpAndSettle();
    for (final name in const [
      'none',
      'form-data',
      'x-www-form-urlencoded',
      'raw',
      'binary',
    ]) {
      expect(find.byKey(Key('body-mode-$name')), findsOneWidget);
    }

    // none
    await sendAndWait();
    expect(seen.body, '');
    expect(seen.headers!.contentType, isNull);

    // raw, with the type picker setting the Content-Type header
    await mode('raw');
    await type(tester, find.byKey(const Key('body')), '{"a": 1}');
    await tester.tap(find.byKey(const Key('body-raw-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JSON').last);
    await tester.pumpAndSettle();
    await sendAndWait();
    expect(seen.body, '{"a": 1}');
    expect(seen.headers!.contentType!.mimeType, 'application/json');

    // x-www-form-urlencoded, as a table; the JSON header no longer applies
    await tester.tap(find.byKey(const Key('headers-tab')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('headers-remove-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('headers-remove-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Body').first);
    await tester.pumpAndSettle();
    await mode('x-www-form-urlencoded');
    await type(tester, find.byKey(const Key('urlencoded-key-0')), 'name');
    await type(tester, find.byKey(const Key('urlencoded-value-0')), 'a b&c');
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('urlencoded-key-1')), 'n');
    await type(tester, find.byKey(const Key('urlencoded-value-1')), '2');
    await sendAndWait();
    expect(seen.body, 'name=a+b%26c&n=2');
    expect(
      seen.headers!.contentType!.mimeType,
      'application/x-www-form-urlencoded',
    );

    // form-data, with a text field and a file
    await mode('form-data');
    await type(tester, find.byKey(const Key('form-key-0')), 'title');
    await type(tester, find.byKey(const Key('form-value-0')), 'Hello');
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('form-key-1')), 'doc');
    await tester.ensureVisible(find.byKey(const Key('form-type-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('form-type-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File').last);
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('form-value-1')), upload.path);
    await sendAndWait();
    expect(seen.headers!.contentType!.mimeType, 'multipart/form-data');
    expect(seen.body, contains('name="title"\r\n\r\nHello'));
    expect(seen.body, contains('name="doc"; filename="note.txt"'));
    expect(seen.body, contains('from a file'));

    // binary sends the file itself
    await mode('binary');
    await type(tester, find.byKey(const Key('body-binary')), upload.path);
    await sendAndWait();
    expect(seen.body, 'from a file');
    expect(seen.headers!.contentType!.mimeType, 'application/octet-stream');

    // Each type keeps what was entered, and the chosen one is saved.
    await mode('raw');
    expect(find.text('{"a": 1}'), findsOneWidget);
    await mode('form-data');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('save-name')), 'Upload');
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();
    final saved = store.requests.single.request!;
    expect(saved.bodyMode, BodyMode.formData);
    expect(saved.form.map((f) => '${f.key}:${f.file}'), [
      'title:false',
      'doc:true',
    ]);

    await tester.tap(find.byKey(const Key('new-request')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Body').first);
    await tester.pumpAndSettle();
    expect(find.text('This request does not have a body'), findsOneWidget);
    await tester.tap(find.text('Upload'));
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text(upload.path), findsOneWidget);

    // A missing file is reported instead of sending an empty upload.
    await type(tester, find.byKey(const Key('form-value-1')), '/no/such.bin');
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('error')));
    expect(find.textContaining('cannot read `/no/such.bin`'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(store.flush);
  });

  testWidgets('applies, saves and restores authorization', (tester) async {
    await start(tester);
    store.merge(
      await tester.runAsync(
        () => importText(text: 'pw=s3cret', nameHint: 'Local'),
      ) as ImportResult,
    );
    store.setActiveEnvironment('Local');
    await launch(tester);

    final url = 'http://127.0.0.1:${server.port}/secure';
    await type(tester, find.byKey(const Key('url')), url);
    await typeHeaders(tester, 'Authorization: x');
    await tester.tap(find.byKey(const Key('auth-tab')));
    await tester.pumpAndSettle();

    // Every type from Postman's picker, in the same order.
    expect(authChoices().map((c) => c.label), [
      'No Auth',
      'API Key',
      'Bearer Token',
      'JWT Bearer',
      'Basic Auth',
      'Digest Auth',
      'OAuth 1.0',
      'OAuth 2.0',
      'Hawk Authentication',
      'AWS Signature',
      'NTLM Authentication',
      'Akamai EdgeGrid',
    ]);
    await tester.tap(find.byKey(const Key('auth-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Basic Auth').last);
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('auth-username')), 'alice');
    await type(tester, find.byKey(const Key('auth-password')), '{{pw}}');
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    // base64("alice:s3cret"); the typed Authorization header is replaced.
    expect(seen.headers!['authorization'], ['Basic YWxpY2U6czNjcmV0']);

    // Auth is saved with the request and comes back when it is reopened.
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('save-name')), 'Secure');
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();
    late Workspace reloaded;
    await tester.runAsync(() async {
      await store.flush();
      reloaded = await loadWorkspace(path: store.path);
    });
    final saved = reloaded.requests.single.request!.auth!;
    expect(saved.kind, AuthKind.basic);
    expect(
      {for (final p in saved.params) p.key: p.value},
      {'username': 'alice', 'password': '{{pw}}'},
    );

    await tester.tap(find.byKey(const Key('new-request')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auth-tab')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auth-username')), findsNothing);
    await tester.tap(find.text('Secure'));
    await tester.pumpAndSettle();
    expect(find.text('alice'), findsOneWidget);

    // Switching type swaps the form; an API key can go in the query string.
    await tester.tap(find.byKey(const Key('auth-kind')));
    await tester.pumpAndSettle();
    // In a short window the menu opens scrolled to the current type.
    await tester.ensureVisible(find.text('API Key').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('API Key').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auth-username')), findsNothing);
    await type(tester, find.byKey(const Key('auth-key')), 'api_key');
    await type(tester, find.byKey(const Key('auth-value')), 'k 1');
    await tester.ensureVisible(find.byKey(const Key('auth-in')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auth-in')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('query').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    expect(seen.path, '/secure?api_key=k%201');
    expect(seen.headers!['authorization'], ['x']);

    // A type that is missing a required field says which one.
    await tester.ensureVisible(find.byKey(const Key('auth-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auth-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bearer Token').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('error')));
    expect(find.textContaining('needs a value for "Token"'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(store.flush);
  });

  testWidgets('creates an environment in the editor and uses it', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);

    await tester.tap(find.byKey(const Key('manage-environments')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('env-add')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('env-name')), 'Local');
    await type(
      tester,
      find.byKey(const Key('env-variables')),
      'base=http://127.0.0.1:${server.port}\n# off=1\nwho=me',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.environments.single.name, 'Local');
    expect(store.environments.single.variables.length, 3);
    expect(store.environments.single.variables[1].enabled, isFalse);

    await tester.tap(find.byKey(const Key('environment')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local').last);
    await tester.pumpAndSettle();
    await type(
      tester,
      find.byKey(const Key('url')),
      '{{base}}/hi?who={{who}}&off={{off}}',
    );
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    expect(seen.path, '/hi?who=me&off=%7B%7Boff%7D%7D');
    expect(find.text('Unresolved: off'), findsOneWidget);
    await tester.runAsync(store.flush);
  });

  testWidgets('creates a collection from a served swagger.json', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);

    await tester.tap(find.byKey(const Key('import-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-url')));
    await tester.pumpAndSettle();
    await type(
      tester,
      find.byKey(const Key('import-url-field')),
      '127.0.0.1:${server.port}/docs/swagger.json',
    );
    await tester.tap(find.byKey(const Key('dialog-confirm')));
    // The title from the document is offered as the name.
    await waitFor(tester, find.byKey(const Key('collection-name')));
    await tester.pumpAndSettle();
    expect(find.text('Orders API'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dialog-confirm')));
    // The multipart upload cannot be carried over, which is reported.
    await waitFor(tester, find.byKey(const Key('warnings-ok')));
    expect(find.textContaining('multipart'), findsOneWidget);
    await tester.tap(find.byKey(const Key('warnings-ok')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.text('Orders API'), findsOneWidget);
    expect(find.text('orders'), findsOneWidget);
    final collection = store.collections.single;
    expect(collection.variables.first.key, 'baseUrl');
    expect(
      collection.variables.first.value,
      'http://127.0.0.1:${server.port}/api',
    );

    await tester.tap(find.text('Replace order'));
    await tester.pumpAndSettle();
    expect(
      find.text('{{baseUrl}}/orders/{{orderId}}?dryRun=true'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));

    expect(seen.method, 'PUT');
    expect(seen.path, '/api/orders/42?dryRun=true');
    expect(seen.headers!.contentType?.mimeType, 'application/json');
    expect(jsonDecode(seen.body!), {'sku': 'A-1', 'quantity': 0});
    // The API key has no value yet, so it is flagged rather than hidden.
    expect(find.text('Unresolved: token'), findsOneWidget);

    late Map<String, dynamic> bruno;
    await tester.runAsync(() async {
      bruno = jsonDecode(
        await exportCollection(
          collection: store.collections.single,
          format: ExportFormat.bruno,
        ),
      ) as Map<String, dynamic>;
      await store.flush();
    });
    expect(bruno['name'], 'Orders API');
    expect(bruno['items'][0]['type'], 'folder');
    expect(bruno['items'][0]['items'][0]['request']['method'], 'PUT');
  });

  testWidgets('imports a Postman collection and sends it with an environment', (
    tester,
  ) async {
    await start(tester);
    final collection = jsonEncode({
      'info': {'name': 'Shop'},
      'auth': {
        'type': 'bearer',
        'bearer': [
          {'key': 'token', 'value': '{{token}}'},
        ],
      },
      'variable': [
        {'key': 'section', 'value': 'orders'},
      ],
      'item': [
        {
          'name': 'Orders',
          'item': [
            {
              'name': 'Create order',
              'request': {
                'method': 'PUT',
                'url': '{{base}}/{{section}}?debug={{missing}}',
                'body': {'mode': 'raw', 'raw': '{"by":"{{user}}"}'},
              },
            },
          ],
        },
      ],
    });
    final environment =
        'base=http://127.0.0.1:${server.port}\n'
        'token=t0k\n'
        'user=alice\n';
    await tester.runAsync(() async {
      store.merge(await importText(text: collection, nameHint: 'shop'));
      store.merge(await importText(text: environment, nameHint: 'Local'));
    });

    await launch(tester);
    expect(find.text('Shop'), findsOneWidget);

    // Without an environment the URL cannot be resolved.
    await tester.tap(find.text('Create order'));
    await tester.pumpAndSettle();
    expect(find.text('{{base}}/{{section}}?debug={{missing}}'), findsOneWidget);
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('error')));
    expect(find.textContaining('unresolved variable'), findsOneWidget);

    await tester.tap(find.byKey(const Key('environment')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));

    expect(find.text('201 Created'), findsOneWidget);
    expect(find.text('Unresolved: missing'), findsOneWidget);
    expect(seen.method, 'PUT');
    expect(seen.path, '/orders?debug=%7B%7Bmissing%7D%7D');
    expect(seen.headers!.value('authorization'), 'Bearer t0k');
    expect(seen.body, '{"by":"alice"}');

    // Editing and saving updates the collection, and it survives a reload.
    await type(tester, find.byKey(const Key('url')), '{{base}}/edited');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pump();
    late Workspace reloaded;
    late String exported;
    await tester.runAsync(() async {
      await store.flush();
      reloaded = await loadWorkspace(path: store.path);
      exported = await exportCollection(
        collection: reloaded.collections.single,
        format: ExportFormat.curl,
      );
    });
    expect(reloaded.activeEnvironment, 'Local');
    expect(reloaded.environments.single.variables.length, 3);
    expect(exported, contains("'{{base}}/edited'"));
    expect(exported, contains('# Orders/Create order'));
  });
  testWidgets('renames, duplicates, filters and restores saved requests', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);
    final url = 'http://127.0.0.1:${server.port}';

    await type(tester, find.byKey(const Key('url')), '$url/one');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('save-name')), 'First');
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();
    expect(store.requests.single.name, 'First');

    // An edit is flagged until the request is saved again.
    expect(find.byKey(const Key('unsaved')), findsNothing);
    await type(tester, find.byKey(const Key('url')), '$url/one?x=1');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unsaved')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unsaved')), findsNothing);
    expect(store.requests.single.request!.url, '$url/one?x=1');

    final actions = find.byTooltip('Request actions');
    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rename-request')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('request-name')), 'Renamed');
    await tester.tap(find.byKey(const Key('dialog-confirm')));
    await tester.pumpAndSettle();
    expect(store.requests.single.name, 'Renamed');

    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('duplicate-request')));
    await tester.pumpAndSettle();
    expect(store.requests.map((r) => r.name), ['Renamed', 'Renamed copy']);
    expect(actions, findsNWidgets(2));

    // The filter narrows the list to matching requests.
    await type(tester, find.byKey(const Key('sidebar-filter')), 'COPY');
    await tester.pumpAndSettle();
    expect(actions, findsOneWidget);

    // A deleted request can be brought back.
    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-request')));
    await tester.pumpAndSettle();
    expect(store.requests.map((r) => r.name), ['Renamed']);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.requests.map((r) => r.name), ['Renamed', 'Renamed copy']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('edits the title in place and exports the response', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);
    final url = 'http://127.0.0.1:${server.port}/ping';
    await type(tester, find.byKey(const Key('url')), url);

    Future<void> rename(String name) async {
      await type(tester, find.byKey(const Key('title-field')), name);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('title-field')), findsNothing);
    }

    // A long press names a request before it is saved anywhere.
    final title = find.byKey(const Key('title'));
    await tester.longPress(title);
    await tester.pumpAndSettle();
    await rename('Ping');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();
    expect(store.requests.single.name, 'Ping');

    // A double click renames the saved request.
    await tester.tap(title);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(title);
    await tester.pumpAndSettle();
    await rename('Pong');
    expect(store.requests.single.name, 'Pong');

    // The response body can be saved as JSON or as it was received.
    final files = <String, String>{};
    final realSaver = fileSaver;
    fileSaver = ({required fileName, required bytes}) async {
      files[fileName] = utf8.decode(bytes);
      return fileName;
    };
    addTearDown(() => fileSaver = realSaver);

    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    for (final kind in const ['json', 'text']) {
      await tester.tap(find.byKey(const Key('export-response')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('export-$kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-confirm')));
      await tester.pumpAndSettle();
    }
    expect(files, {
      'response.json': '{\n  "ok": true\n}',
      'response.txt': '{"ok":true}',
    });

    // The whole session, here two sends, can be saved as a HAR file.
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    await tester.pumpAndSettle();
    expect(find.text('Session · 2 requests'), findsOneWidget);
    await tester.tap(find.byKey(const Key('export-response')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export-har')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export-confirm')));
    await tester.pumpAndSettle();
    final har = jsonDecode(files['session.har']!) as Map<String, dynamic>;
    final entries = har['log']['entries'] as List;
    expect(har['log']['version'], '1.2');
    expect(entries.length, 2);
    expect(entries.first['request']['url'], url);
    expect(entries.first['response']['status'], 201);
    expect(entries.first['response']['content']['text'], '{"ok":true}');

    // Ticking the box in the export dialog takes credentials out of the file,
    // and the choice is remembered for the next export.
    await type(tester, find.byKey(const Key('url')), '$url?api_key=abc123');
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.text('Session · 3 requests'));
    await tester.pumpAndSettle();
    Future<void> exportHarFile({required bool tick}) async {
      // The message from the previous export would cover the menu.
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .clearSnackBars();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-response')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-har')));
      await tester.pumpAndSettle();
      if (tick) {
        await tester.tap(find.byKey(const Key('export-redact')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('export-confirm')));
      await tester.pumpAndSettle();
    }

    await exportHarFile(tick: false);
    expect(files['session.har'], contains('abc123'));
    await exportHarFile(tick: true);
    expect(files['session.har'], isNot(contains('abc123')));
    expect(files['session.har'], contains('api_key=[REDACTED]'));
    expect(find.text('Exported session.har, redacted'), findsOneWidget);
    files.remove('session.har');
    await exportHarFile(tick: false);
    expect(files['session.har'], isNot(contains('abc123')));
    // Back off, so later exports in this run start from the default.
    await exportHarFile(tick: true);
    expect(files['session.har'], contains('abc123'));

    // The archive imports back as a collection, one request per exchange.
    await tester.tap(find.byKey(const Key('import-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-paste')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('paste')), files['session.har']!);
    await tester.tap(find.byKey(const Key('dialog-confirm')));
    await waitFor(tester, find.byKey(const Key('collection-name')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('collection-name')), 'Replay');
    await tester.tap(find.byKey(const Key('dialog-confirm')));
    await tester.pumpAndSettle();
    final replay = store.collections.single;
    expect(replay.name, 'Replay');
    expect(replay.items.map((i) => i.name), [
      'GET /ping',
      'GET /ping (2)',
      'GET /ping (3)',
    ]);
    expect(replay.items.last.request!.url, '$url?api_key=abc123');
    expect(find.text('GET /ping (3)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('analyses the session and imports it from the report', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);
    final base = 'http://127.0.0.1:${server.port}';
    for (final path in const ['/old', '/ping?api_key=abc123']) {
      await type(tester, find.byKey(const Key('url')), '$base$path');
      await tester.tap(find.byKey(const Key('send')));
      await waitFor(tester, find.byKey(const Key('status')));
      await tester.pumpAndSettle();
    }
    // The redirect and where it led are separate exchanges.
    await waitFor(tester, find.text('Session · 3 requests'));

    await tester.tap(find.byKey(const Key('session')));
    await waitFor(tester, find.byKey(const Key('har-summary')));
    await tester.pumpAndSettle();
    expect(find.text('HAR analysis · Session'), findsOneWidget);
    expect(find.text('1 request has a credential in the URL'), findsOneWidget);
    expect(find.text('1 redirect'), findsOneWidget);

    // A finding narrows the table to the requests it is about.
    await tester.tap(find.text('1 request has a credential in the URL'));
    await tester.pumpAndSettle();
    const narrowed = '1 of 3 · 1 request has a credential in the URL';
    expect(find.text(narrowed), findsOneWidget);
    // The table has scrolled into view with only that request in it.
    expect(find.byKey(const Key('har-entry-2')), findsOneWidget);
    expect(find.byKey(const Key('har-entry-0')), findsNothing);
    expect(find.byKey(const Key('har-entry-1')), findsNothing);
    await tester.tap(find.byTooltip('Show all requests'));
    await tester.pumpAndSettle();
    expect(find.text(narrowed), findsNothing);
    expect(find.byKey(const Key('har-entry-0')), findsOneWidget);

    // Typing narrows the table too, by address, method, status or kind.
    await type(tester, find.byKey(const Key('har-search')), '302');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('har-entry-0')), findsOneWidget);
    expect(find.byKey(const Key('har-entry-1')), findsNothing);

    // A row opens the request in full.
    await tester.tap(find.byKey(const Key('har-entry-0')));
    await tester.pumpAndSettle();
    expect(find.text('$base/old'), findsOneWidget);
    expect(find.textContaining('302'), findsWidgets);
    await tester.tap(find.byKey(const Key('har-detail-response')));
    await tester.pumpAndSettle();
    expect(find.textContaining('/new?from=old'), findsOneWidget);
    await tester.tap(find.byKey(const Key('har-detail-close')));
    await tester.pumpAndSettle();

    // Only the ticked requests are kept as a collection: here the redirect
    // is left out by clearing everything listed.
    expect(find.text('3 of 3 selected to import'), findsOneWidget);
    await tester.tap(find.byKey(const Key('har-select-shown')));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3 selected to import'), findsOneWidget);
    expect(find.text('Import 2 as collection'), findsOneWidget);
    await tester.tap(find.byKey(const Key('har-import')));
    await waitFor(tester, find.byKey(const Key('collection-name')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('collection-name')), 'Recorded');
    await tester.tap(find.byKey(const Key('dialog-confirm')));
    await tester.pumpAndSettle();
    expect(store.collections.single.name, 'Recorded');
    expect(store.collections.single.items.map((i) => i.name), [
      'GET /new',
      'GET /ping',
    ]);
    expect(tester.takeException(), isNull);
  });
  testWidgets('tests a response and passes captured values on', (tester) async {
    await start(tester);
    await launch(tester);
    final base = 'http://127.0.0.1:${server.port}';
    await type(tester, find.byKey(const Key('url')), '$base/login');
    await tester.tap(find.byKey(const Key('tests-tab')));
    await tester.pumpAndSettle();
    await type(
      tester,
      find.byKey(const Key('tests')),
      'status == 201\nbody.ok == true\nstatus == 200',
    );
    await type(
      tester,
      find.byKey(const Key('captures')),
      'flag = body.ok\nsid = header set-cookie\nnope = body.zzz',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    await tester.pumpAndSettle();
    // Two of the three tests pass; the tab says so and lists each one.
    expect(find.text('Tests (2/3)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('test-results-tab')));
    await tester.pumpAndSettle();
    expect(find.textContaining('was 201'), findsOneWidget);
    expect(find.textContaining('flag = true'), findsOneWidget);
    expect(find.textContaining('nope: body.zzz was not found'), findsOneWidget);
    expect(
      {for (final v in store.captured) v.key: v.value},
      {'flag': 'true', 'sid': 'sid=abc123; Path=/; HttpOnly'},
    );

    // Tests and captures are saved with the request.
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('save-name')), 'Login');
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();
    final saved = store.requests.single.request!;
    expect(saved.tests, ['status == 201', 'body.ok == true', 'status == 200']);
    expect(saved.captures.first, 'flag = body.ok');

    // A later request can use what was captured.
    await tester.tap(find.byKey(const Key('new-request')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('url')), '$base/ping?ok={{flag}}');
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    await tester.pumpAndSettle();
    expect(seen.path, '/ping?ok=true');
    expect(find.byKey(const Key('test-results-tab')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('shows a binary response and records what was sent', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);
    final saved = <String, Uint8List>{};
    final realSaver = fileSaver;
    fileSaver = ({required fileName, required bytes}) async {
      saved[fileName] = bytes;
      return fileName;
    };
    addTearDown(() => fileSaver = realSaver);

    final url = 'http://127.0.0.1:${server.port}/logo.png';
    await type(tester, find.byKey(const Key('url')), url);
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('status')));
    await tester.pumpAndSettle();
    // The image is shown and saved byte for byte, not mangled into text.
    expect(find.text('image/png · ${_png.length} B'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.byKey(const Key('binary-save')));
    await tester.pumpAndSettle();
    expect(saved['response.png'], _png);

    // The session records the headers the client added, and the body.
    final har =
        jsonDecode(exportHar(exchanges: store.session)) as Map<String, dynamic>;
    final entry = har['log']['entries'][0] as Map<String, dynamic>;
    final sent = {
      for (final h in entry['request']['headers'] as List)
        h['name'] as String: h['value'] as String,
    };
    expect(sent['host'], '127.0.0.1:${server.port}');
    expect(sent['user-agent'], startsWith('reqorb/'));
    expect(sent['accept'], '*/*');
    expect(seen.headers!.value('user-agent'), sent['user-agent']);
    expect(entry['response']['content']['encoding'], 'base64');
    expect(entry['response']['content']['text'], base64Encode(_png));
    expect(tester.takeException(), isNull);
  });
  testWidgets('guards unsaved edits and undoes removals', (tester) async {
    await start(tester);
    await launch(tester);
    final url = 'http://127.0.0.1:${server.port}';
    final newRequest = find.byKey(const Key('new-request'));

    // Sending with no URL says why nothing happened.
    await type(tester, find.byKey(const Key('url')), '');
    await tester.tap(find.byKey(const Key('send')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a URL to send the request'), findsOneWidget);

    await type(tester, find.byKey(const Key('url')), '$url/a');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('save-name')), 'A');
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();

    // Leaving an edited request asks first; cancelling stays put.
    await type(tester, find.byKey(const Key('url')), '$url/b');
    await tester.tap(newRequest);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('$url/b'), findsOneWidget);

    await tester.tap(newRequest);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discard-changes')));
    await tester.pumpAndSettle();
    expect(store.requests.single.request!.url, '$url/a');
    expect(find.text('$url/b'), findsNothing);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('url')), '$url/c');
    await tester.tap(newRequest);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-changes')));
    await tester.pumpAndSettle();
    expect(store.requests.single.request!.url, '$url/c');

    // An environment can be put to use, deleted, and brought back in use.
    await tester.tap(find.byKey(const Key('manage-environments')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('env-add')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('env-name')), 'One');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('env-item-0')), findsOneWidget);
    await tester.tap(find.byKey(const Key('env-use')));
    await tester.pumpAndSettle();
    expect(store.activeEnvironment, 'One');
    await tester.tap(find.byTooltip('Environment actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('env-delete')));
    await tester.pumpAndSettle();
    expect(store.environments, isEmpty);
    expect(store.activeEnvironment, isNull);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.environments.single.name, 'One');
    expect(store.activeEnvironment, 'One');
    expect(tester.takeException(), isNull);
  });
  testWidgets('connects to a WebSocket and exchanges messages', (tester) async {
    await start(tester);
    await launch(tester);

    await tester.tap(find.byKey(const Key('method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WS').last);
    await tester.pumpAndSettle();
    await type(
      tester,
      find.byKey(const Key('url')),
      'ws://127.0.0.1:${server.port}/ws',
    );
    await typeHeaders(tester, 'X-Room: lobby');

    // The handshake carries the headers, and the greeting arrives.
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.text('Connected'));
    await waitFor(tester, find.text('welcome lobby'));

    await tester.tap(find.byKey(const Key('body-tab')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('ws-message')), 'hello');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ws-send')));
    await waitFor(tester, find.text('HELLO'));
    expect(find.text('3 messages'), findsOneWidget);

    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.text('Disconnected'));
    expect(find.text('Connect'), findsOneWidget);

    // Saved like any request, with the message being composed.
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();
    final saved = store.requests.single.request!;
    expect((saved.method, saved.body), ('WS', 'hello'));
    expect(tester.takeException(), isNull);
  });
  testWidgets('switches to gRPC and explains an unreachable server', (
    tester,
  ) async {
    await start(tester);
    await launch(tester);

    await tester.tap(find.byKey(const Key('method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GRPC').last);
    await tester.pumpAndSettle();
    expect(find.text('Invoke'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Message'), findsOneWidget);

    // Nothing listens on port 1, so loading the methods fails with a reason.
    await type(tester, find.byKey(const Key('url')), '127.0.0.1:1');
    await tester.tap(find.byKey(const Key('send')));
    await waitFor(tester, find.byKey(const Key('grpc-error')));
    expect(find.textContaining('cannot reach 127.0.0.1:1'), findsOneWidget);

    // The address and message are saved as a gRPC request.
    await tester.tap(find.byKey(const Key('body-tab')));
    await tester.pumpAndSettle();
    await type(tester, find.byKey(const Key('grpc-message')), '{"a": 1}');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-confirm')));
    await tester.pumpAndSettle();
    final saved = store.requests.single.request!;
    expect(
      (saved.method, saved.url, saved.body),
      ('GRPC', '127.0.0.1:1', '{"a": 1}'),
    );
    expect(tester.takeException(), isNull);
  });
}
