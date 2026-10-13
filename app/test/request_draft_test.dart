import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/request/request_draft.dart';
import 'package:reqorb/src/rust/api/core.dart';

Request _request({
  String method = 'POST',
  String url = 'https://api.test/items?page=2',
  List<Header> headers = const [],
  String? body,
  BodyMode? bodyMode,
  List<FormField> form = const [],
  List<String> tests = const [],
  List<String> captures = const [],
}) => Request(
  method: method,
  url: url,
  headers: headers,
  body: body,
  bodyMode: bodyMode,
  form: form,
  tests: tests,
  captures: captures,
);

void main() {
  test('a loaded request comes back out unchanged', () {
    final draft = RequestDraft();
    addTearDown(draft.dispose);
    final request = _request(
      headers: const [Header(name: 'Content-Type', value: 'application/json')],
      body: '{"n":1}',
      bodyMode: BodyMode.raw,
      tests: const ['status == 200'],
      captures: const ['id = body.id'],
    );
    draft.load(request);

    final out = draft.toRequest();
    expect(out.method, 'POST');
    expect(out.url, request.url);
    expect(out.headers, request.headers);
    expect((out.body, out.bodyMode), ('{"n":1}', BodyMode.raw));
    expect(out.tests, ['status == 200']);
    expect(out.captures, ['id = body.id']);
    expect(draft.params.text, 'page:2');
    expect(draft.rawLanguage(), 'JSON');
    expect(draft.dirty, isFalse);
  });

  test('any edit makes the request dirty until it is saved', () {
    final draft = RequestDraft();
    addTearDown(draft.dispose);
    var notified = 0;
    draft.addListener(() => notified++);

    // A request that was never saved has nothing to differ from.
    draft.url.text = 'https://api.test';
    expect(draft.dirty, isFalse);
    expect(notified, greaterThan(0));

    draft.load(_request());
    for (final edit in <void Function()>[
      () => draft.url.text = 'https://api.test/other',
      () => draft.headers.text = 'Accept: text/plain',
      () => draft.method = 'PUT',
      () => draft.tests.text = 'status == 201',
      () => draft.captures.text = 'token = body.token',
      () {
        draft.bodyMode = BodyMode.raw;
        draft.body.text = 'hello';
      },
    ]) {
      draft.load(_request());
      expect(draft.dirty, isFalse);
      edit();
      expect(draft.dirty, isTrue);
      draft.markSaved();
      expect(draft.dirty, isFalse);
    }
  });

  test('the URL and the params table follow each other', () {
    final draft = RequestDraft(url: 'https://api.test/items?page=1');
    addTearDown(draft.dispose);
    expect(draft.params.text, 'page:1');

    draft.url.text = 'https://api.test/items?page=1&limit=5';
    expect(draft.params.text, 'page:1\nlimit:5');

    draft.params.text = 'page:3';
    expect(draft.url.text, 'https://api.test/items?page=3');
    draft.params.text = '';
    expect(draft.url.text, 'https://api.test/items');
  });

  test('a url-encoded text body opens as fields', () {
    final draft = RequestDraft();
    addTearDown(draft.dispose);
    draft.load(
      _request(
        headers: const [
          Header(
            name: 'Content-Type',
            value: 'application/x-www-form-urlencoded',
          ),
        ],
        body: 'user=a%20b&flag',
      ),
    );
    expect(draft.bodyMode, BodyMode.urlEncoded);
    expect(draft.urlEncoded.text, 'user: a b\nflag: ');
    final out = draft.toRequest();
    expect(out.bodyMode, BodyMode.urlEncoded);
    expect(
      [for (final f in out.form) '${f.key}=${f.value}'],
      ['user=a b', 'flag='],
    );
    expect(out.body, isNull);
  });

  test('a body type with nothing in it is no body', () {
    final draft = RequestDraft(url: 'https://api.test');
    addTearDown(draft.dispose);
    draft.bodyMode = BodyMode.formData;
    expect(draft.toRequest().bodyMode, isNull);
    draft.formData = const [FormField(key: 'a', value: '1', file: false)];
    expect(draft.toRequest().bodyMode, BodyMode.formData);
  });

  test('messages are kept for WebSocket and gRPC requests', () {
    final draft = RequestDraft(url: 'localhost:50051');
    addTearDown(draft.dispose);
    draft
      ..method = 'GRPC'
      ..grpcMethod = 'shop.Orders/Get'
      ..body.text = '{"id":1}'
      ..tests.text = 'status == 200';
    final grpc = draft.toRequest();
    expect((grpc.grpcMethod, grpc.body), ('shop.Orders/Get', '{"id":1}'));
    // Tests are for HTTP responses.
    expect(grpc.tests, isEmpty);

    draft.method = 'WS';
    expect(draft.toRequest().grpcMethod, isNull);
  });

  test('clearing starts a new unsaved request', () {
    final draft = RequestDraft();
    addTearDown(draft.dispose);
    draft.load(
      _request(body: 'x', bodyMode: BodyMode.raw, tests: const ['time < 5']),
    );
    final generation = draft.generation;
    draft.clear();
    final out = draft.toRequest();
    expect((out.method, out.url, out.body), ('GET', '', null));
    expect(out.tests, isEmpty);
    expect(draft.params.text, '');
    expect(draft.saved, isNull);
    expect(draft.generation, generation + 1);
  });

  test('choosing a raw type sets one Content-Type header', () {
    final draft = RequestDraft();
    addTearDown(draft.dispose);
    draft.headers.text = 'Accept: */*\nContent-Type: text/plain';
    draft.setRawLanguage('JSON');
    expect(draft.headers.text, 'Accept: */*\nContent-Type: application/json');
    expect(draft.rawLanguage(), 'JSON');
  });
}
