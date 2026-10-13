import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/transfer/import_actions.dart';
import 'package:reqorb/protocols/grpc_view.dart';
import 'package:reqorb/har/har_analysis.dart';
import 'package:reqorb/request/key_value_editor.dart';
import 'package:reqorb/response/response_view.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/request/tests_editor.dart';
import 'package:reqorb/workspace/workspace_store.dart';

void main() {
  test('reads key and value lines', () {
    expect(parseKeyValueLine('Accept: application/json'), (
      'Accept',
      'application/json',
    ));
    expect(parseKeyValueLine('  X-Empty:  '), ('X-Empty', ''));
    expect(parseKeyValueLine(''), isNull);
    // A name on its own is a row whose value has not been typed yet.
    expect(parseKeyValueLine('no separator'), ('no separator', ''));
  });

  test('lists a URL\'s query as params', () {
    expect(
      paramsTextFromUrl('https://api.test/items?page=2&q=a%20b#top'),
      // Shown as written in the URL, so editing one never recodes the other.
      'page:2\nq:a%20b',
    );
    expect(paramsTextFromUrl('https://api.test/items'), '');
  });

  test('keeps the lines that hold something', () {
    expect(linesOf('status == 200\n\n  time < 5  \n'), [
      'status == 200',
      'time < 5',
    ]);
    expect(linesOf('  \n'), isEmpty);
  });

  test('names an import after its file', () {
    expect(nameHintFor('orders.postman_collection.json'), 'orders');
    expect(nameHintFor('dev.postman_environment.json'), 'dev');
    expect(nameHintFor('session.har'), 'session');
    expect(nameHintFor('README'), 'README');
  });

  test('formats sizes and durations', () {
    expect(formatSize(512), '512 B');
    expect(formatSize(1536), '1.5 KB');
    expect(formatSize(3 * 1024 * 1024), '3.0 MB');
    expect(formatDuration(340), '340 ms');
    expect(formatDuration(1250), '1.25 s');
  });

  test('splits the messages of a gRPC client stream', () {
    expect(grpcMessages('{"a":1}\n---\n{"b":2}\n'), ['{"a":1}', '{"b":2}']);
    expect(grpcMessages('{"a":1}'), ['{"a":1}']);
    expect(grpcMessages('  \n'), isEmpty);
  });

  test('captured variables win and the newest replaces the oldest', () {
    final store = WorkspaceStore('unused.json');
    var changes = 0;
    store.addListener(() => changes++);
    Variable variable(String key, String value) =>
        Variable(key: key, value: value, enabled: true);

    store.capture([variable('token', 'one'), variable('id', '7')]);
    store.capture([variable('token', 'two')]);
    store.capture(const []);
    expect(changes, 2);
    expect(
      [for (final v in store.variablesFor(null)) '${v.key}=${v.value}'],
      ['token=two', 'id=7'],
    );

    store.clearSession();
    expect(store.captured, isEmpty);
    expect(store.variablesFor(null), isEmpty);
  });
}
