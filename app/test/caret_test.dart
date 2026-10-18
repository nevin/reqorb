import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/document/caret.dart';
import 'package:reqorb/document/memory_document.dart';

void main() {
  test('counts UTF-8 bytes and finds UTF-16 units from them', () {
    const text = 'aé日😀\uD800z';
    expect(utf8Length(text), utf8.encode(text).length);
    expect(utf8Length(text, 1, 3), 5);
    expect(unitsOf(text, 3), 2);
    expect(unitsOf(text, 4), 2, reason: 'inside 日, at its start');
    expect(unitsOf(text, 10), 5);
    expect(unitsOf(text, 99), text.length);
  });

  test('steps over characters, line breaks and bytes that are not UTF-8', () {
    final doc = MemoryDocument.bytes(
      Uint8List.fromList([
        ...utf8.encode('a😀\r\n'),
        0xFF,
        ...utf8.encode('�é'),
      ]),
    );
    final stops = [0];
    while (stops.last < doc.info().len) {
      stops.add(nextChar(doc, stops.last));
    }
    expect(stops, [0, 1, 5, 7, 8, 11, 13]);
    final back = [stops.last];
    while (back.last > 0) {
      back.add(previousChar(doc, back.last));
    }
    expect(back, stops.reversed.toList());
  });

  test('steps over words and what is between them', () {
    final doc = MemoryDocument('let x_1 = "héllo";\nnext');
    expect(nextWord(doc, 0), 3);
    expect(nextWord(doc, 3), 7);
    expect(nextWord(doc, 7), 17);
    expect(nextWord(doc, 17), 24);
    expect(previousWord(doc, 24), 20);
    expect(previousWord(doc, 20), 11);
    expect(previousWord(doc, 4), 0);
  });
}
