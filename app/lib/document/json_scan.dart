/// JSON in bytes held in Dart, as the Rust engine reads it in a document:
/// the children of one object or array at a time, and the whole written
/// out again indented or minified. For [MemoryDocument], which the widget
/// tests use; the conformance suite holds the two to the same results.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:reqorb/document/text_document.dart';

/// The most bytes of a value or key shown before it is cut short.
const _preview = 120;

class _Reader {
  _Reader(this.bytes, this.at);

  final Uint8List bytes;
  int at;

  int? peek() => at < bytes.length ? bytes[at] : null;

  int? next() => at < bytes.length ? bytes[at++] : null;

  void skipSpace() {
    while (at < bytes.length) {
      final b = bytes[at];
      if (b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D) return;
      at++;
    }
  }

  String fail(String what) {
    var line = 1;
    for (var i = 0; i < at && i < bytes.length; i++) {
      if (bytes[i] == 0x0A) line++;
    }
    return 'not valid JSON at line $line: $what';
  }

  void string(List<int> keep) {
    while (true) {
      final b = next();
      if (b == null) throw fail('a string is not closed');
      if (b == 0x22) return;
      if (b == 0x5C) {
        final escaped = next();
        if (escaped == null) throw fail('a string is not closed');
        if (keep.length < _preview) keep.addAll([0x5C, escaped]);
      } else if (keep.length < _preview) {
        keep.add(b);
      }
    }
  }

  DocJsonKind value(List<int> keep) {
    skipSpace();
    final first = next();
    switch (first) {
      case null:
        throw fail('a value is missing');
      case 0x22:
        string(keep);
        return DocJsonKind.string;
      case 0x7B || 0x5B:
        container();
        return first == 0x7B ? DocJsonKind.object : DocJsonKind.array;
    }
    final DocJsonKind kind;
    if (first == 0x74 || first == 0x66) {
      kind = DocJsonKind.bool;
    } else if (first == 0x6E) {
      kind = DocJsonKind.null_;
    } else if (first == 0x2D || (first >= 0x30 && first <= 0x39)) {
      kind = DocJsonKind.number;
    } else {
      throw fail('a value is not one JSON knows');
    }
    keep.add(first);
    while (true) {
      final b = peek();
      if (b == null || !(_alnum(b) || b == 0x2E || b == 0x2B || b == 0x2D)) {
        break;
      }
      if (keep.length < _preview) keep.add(b);
      at++;
    }
    return kind;
  }

  void container() {
    var depth = 1;
    while (depth > 0) {
      final b = next();
      if (b == null) throw fail('an object or array is not closed');
      if (b == 0x22) {
        string([]);
      } else if (b == 0x7B || b == 0x5B) {
        depth++;
      } else if (b == 0x7D || b == 0x5D) {
        depth--;
      }
    }
  }
}

bool _alnum(int b) =>
    (b >= 0x30 && b <= 0x39) ||
    (b >= 0x41 && b <= 0x5A) ||
    (b >= 0x61 && b <= 0x7A);

String _textOf(List<int> bytes) {
  var end = bytes.length < _preview ? bytes.length : _preview;
  while (end > 0 && end < bytes.length && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}

/// The value at the top of [bytes].
DocJsonNode jsonRootOf(Uint8List bytes) {
  final reader = _Reader(bytes, 0)..skipSpace();
  if (reader.peek() == 0xEF) {
    reader
      ..at += 3
      ..skipSpace();
  }
  final start = reader.at;
  final keep = <int>[];
  final kind = reader.value(keep);
  return DocJsonNode(
    kind: kind,
    preview: _textOf(keep),
    start: start,
    end: reader.at,
  );
}

/// Up to [count] children of the object or array at [at] in [bytes].
DocJsonPage jsonChildrenOf(Uint8List bytes, int at, int? from, int count) {
  final reader = _Reader(bytes, at);
  final open = reader.next();
  if (open != 0x7B && open != 0x5B) {
    throw reader.fail('there is no object or array here');
  }
  final object = open == 0x7B;
  final closer = object ? 0x7D : 0x5D;
  if (from != null) reader.at = from;
  final nodes = <DocJsonNode>[];
  while (true) {
    reader.skipSpace();
    if (reader.peek() == 0x2C) {
      reader
        ..at += 1
        ..skipSpace();
    }
    final b = reader.peek();
    if (b == null) throw reader.fail('an object or array is not closed');
    if (b == closer) return DocJsonPage(nodes: nodes);
    if (nodes.length >= count) {
      return DocJsonPage(nodes: nodes, next: reader.at);
    }
    String? key;
    if (object) {
      if (reader.next() != 0x22) {
        throw reader.fail('a name in an object is not in quotes');
      }
      final name = <int>[];
      reader
        ..string(name)
        ..skipSpace();
      if (reader.next() != 0x3A) {
        throw reader.fail('a name in an object has no `:` after it');
      }
      key = _textOf(name);
    }
    reader.skipSpace();
    final start = reader.at;
    final keep = <int>[];
    final kind = reader.value(keep);
    nodes.add(
      DocJsonNode(
        key: key,
        kind: kind,
        preview: _textOf(keep),
        start: start,
        end: reader.at,
      ),
    );
  }
}

/// All of [bytes], which are JSON, indented by [indent], or minified.
/// Throws a [String] saying where it is not valid.
Uint8List formatJsonBytes(Uint8List bytes, String? indent) {
  final out = BytesBuilder(copy: false);
  final unit = indent == null ? null : utf8.encode(indent);
  final stack = <int>[];
  var inString = false;
  var escaped = false;
  var opened = false;
  var line = 1;
  var seenValue = false;
  var inScalar = false;
  void newline(int depth) {
    if (unit == null) return;
    out.addByte(0x0A);
    for (var i = 0; i < depth; i++) {
      out.add(unit);
    }
  }

  String invalid(String what) => 'not valid JSON at line $line: $what';
  for (final b in bytes) {
    if (b == 0x0A) line++;
    if (inString) {
      out.addByte(b);
      if (escaped) {
        escaped = false;
      } else if (b == 0x5C) {
        escaped = true;
      } else if (b == 0x22) {
        inString = false;
      }
      continue;
    }
    final scalar = inScalar;
    inScalar = false;
    switch (b) {
      case 0x20 || 0x09 || 0x0A || 0x0D:
        break;
      case 0x7D || 0x5D:
        final open = b == 0x7D ? 0x7B : 0x5B;
        if (stack.isEmpty || stack.removeLast() != open) {
          throw invalid('a closing bracket does not match');
        }
        if (!opened) newline(stack.length);
        opened = false;
        out.addByte(b);
      case 0x2C:
        if (stack.isEmpty) {
          throw invalid('a `,` is outside any object or array');
        }
        out.addByte(b);
        newline(stack.length);
      case 0x3A:
        out.add(unit != null ? const [0x3A, 0x20] : const [0x3A]);
      default:
        if (stack.isEmpty && seenValue && !scalar) out.addByte(0x0A);
        if (opened) {
          newline(stack.length);
          opened = false;
        }
        seenValue = true;
        if (b == 0x7B || b == 0x5B) {
          stack.add(b);
          opened = true;
        } else if (b == 0x22) {
          inString = true;
        } else if (_alnum(b) || b == 0x2D || b == 0x2B || b == 0x2E) {
          inScalar = true;
        } else {
          throw invalid('a character that JSON does not use');
        }
        out.addByte(b);
    }
  }
  if (inString) throw invalid('a string is not closed');
  if (stack.isNotEmpty) throw invalid('an object or array is not closed');
  if (unit != null) out.addByte(0x0A);
  return out.takeBytes();
}
