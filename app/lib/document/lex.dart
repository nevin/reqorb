/// Where a document's strings, comments and tags are, for pairing brackets
/// and colouring part of it: the Rust engine's scan
/// (`crates/reqorb-core/src/document/lex.rs`) for [MemoryDocument], held
/// to the same results by the conformance tests.
library;

import 'dart:typed_data';

import 'package:reqorb/src/rust/api/document.dart' show DocQuoting;

/// How far either way brackets are paired, and how far back is read to
/// know what a place is inside.
const lexReach = 64 * 1024;

enum _In {
  code,
  lineComment,
  blockComment,
  string,
  template,
  scriptString,
  blockString,
  xmlComment,
  cdata,
  tag,
  attribute,
}

const _brackets = {0x7B, 0x7D, 0x5B, 0x5D, 0x28, 0x29}; // {}[]()
const _newline = 0x0A, _backslash = 0x5C, _dquote = 0x22, _squote = 0x27;

class _Scan {
  _Scan(this.bytes, this.quoting);

  final Uint8List bytes;
  final DocQuoting quoting;
  _In inside = _In.code;

  /// The quote that closes the string or attribute value it is in.
  int quote = 0;

  bool _at(int i, String s) {
    if (i + s.length > bytes.length) return false;
    for (var k = 0; k < s.length; k++) {
      if (bytes[i + k] != s.codeUnitAt(k)) return false;
    }
    return true;
  }

  /// Goes through all of [bytes], calling [bracket] with every bracket in
  /// code.
  void run([void Function(int at, int byte)? bracket]) {
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      switch (inside) {
        case _In.code || _In.tag:
          if (_brackets.contains(b)) {
            bracket?.call(i, b);
            i++;
          } else {
            i += _opens(i);
          }
        case _In.lineComment:
          if (b == _newline) inside = _In.code;
          i++;
        case _In.blockComment:
          if (_at(i, '*/')) {
            inside = _In.code;
            i += 2;
          } else {
            i++;
          }
        case _In.string:
          if (b == _backslash &&
              i + 1 < bytes.length &&
              bytes[i + 1] != _newline) {
            i += 2;
            continue;
          }
          // A string left open ends with its line.
          if (b == quote || b == _newline) inside = _In.code;
          i++;
        case _In.template:
          if (b == _backslash && quoting == DocQuoting.javaScript) {
            i += 2;
            continue;
          }
          if (b == 0x60) inside = _In.code;
          i++;
        case _In.scriptString:
          if (b == _backslash) {
            i += 2;
            continue;
          }
          if (b == _squote) inside = _In.code;
          i++;
        case _In.blockString:
          if (_at(i, '"""')) {
            inside = _In.code;
            i += 3;
          } else {
            i++;
          }
        case _In.xmlComment:
          if (_at(i, '-->')) {
            inside = _In.code;
            i += 3;
          } else {
            i++;
          }
        case _In.cdata:
          if (_at(i, ']]>')) {
            inside = _In.code;
            i += 3;
          } else {
            i++;
          }
        case _In.attribute:
          if (b == quote) inside = _In.tag;
          i++;
      }
    }
  }

  /// Takes in what starts at [i] in code or a tag; how many bytes it takes.
  int _opens(int i) {
    final b = bytes[i];
    if (inside == _In.tag) {
      if (b == _dquote || b == _squote) {
        inside = _In.attribute;
        quote = b;
      } else if (b == 0x3E) {
        inside = _In.code;
      } else if (b == 0x3C) {
        // Another tag opened before this one closed.
        inside = _In.code;
        return _opens(i);
      }
      return 1;
    }
    switch (quoting) {
      case DocQuoting.json:
        if (b == _dquote) _string(b);
        return 1;
      case DocQuoting.javaScript || DocQuoting.source:
        if (_at(i, '//')) {
          inside = _In.lineComment;
          return 2;
        }
        if (_at(i, '/*')) {
          inside = _In.blockComment;
          return 2;
        }
        if (b == _dquote || b == _squote) _string(b);
        if (b == 0x60) inside = _In.template;
        return 1;
      case DocQuoting.script:
        if (b == 0x23) inside = _In.lineComment;
        if (b == _dquote) _string(b);
        // How a shell writes a quote outside quotes.
        if (b == _backslash &&
            i + 1 < bytes.length &&
            bytes[i + 1] == _squote) {
          return 2;
        }
        if (b == _squote) inside = _In.scriptString;
        return 1;
      case DocQuoting.graphql:
        if (_at(i, '"""')) {
          inside = _In.blockString;
          return 3;
        }
        if (b == 0x23) inside = _In.lineComment;
        if (b == _dquote) _string(b);
        return 1;
      case DocQuoting.xml:
        if (_at(i, '<!--')) {
          inside = _In.xmlComment;
          return 4;
        }
        if (_at(i, '<![CDATA[')) {
          inside = _In.cdata;
          return 9;
        }
        if (b == 0x3C && _startsTag(i + 1)) inside = _In.tag;
        return 1;
    }
  }

  void _string(int q) {
    inside = _In.string;
    quote = q;
  }

  bool _startsTag(int i) {
    if (i < bytes.length && '/?!'.codeUnits.contains(bytes[i])) i++;
    if (i >= bytes.length) return false;
    final c = bytes[i];
    return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;
  }

  /// What, put before the text after [bytes], has it coloured as it would
  /// be with them before it.
  String get opener => switch (inside) {
    _In.code => '',
    _In.lineComment =>
      quoting == DocQuoting.script || quoting == DocQuoting.graphql
          ? '#'
          : '//',
    _In.blockComment => '/*',
    _In.string => quote == _squote ? "'" : '"',
    _In.template => '`',
    _In.scriptString => "'",
    _In.blockString => '"""',
    _In.xmlComment => '<!--',
    _In.cdata => '<![CDATA[',
    _In.tag => '<a ',
    _In.attribute => quote == _squote ? "<a b='" : '<a b="',
  };
}

/// What, put before the text that follows [bytes], has it coloured as it
/// would be with them before it: the opening of the string or comment
/// their end is inside.
String openerAfter(Uint8List bytes, DocQuoting quoting) =>
    (_Scan(bytes, quoting)..run()).opener;

/// The bracket just before [at] in [bytes], or at it, and its partner, the
/// opening one first; none when neither is a bracket in code, or its
/// partner is not in [bytes]. Only brackets of its own kind are counted.
(int, int)? bracketPair(Uint8List bytes, int at, DocQuoting quoting) {
  bool isBracket(int i) =>
      i >= 0 && i < bytes.length && _brackets.contains(bytes[i]);
  if (!isBracket(at - 1) && !isBracket(at)) return null;
  final places = <int>[];
  final kinds = <int>[];
  _Scan(bytes, quoting).run((i, b) {
    places.add(i);
    kinds.add(b);
  });
  for (final i in [at - 1, at]) {
    final k = _indexOf(places, i);
    if (k < 0) continue;
    final own = kinds[k];
    const pairs = {0x7B: 0x7D, 0x5B: 0x5D, 0x28: 0x29};
    final forward = pairs.containsKey(own);
    final other = forward
        ? pairs[own]!
        : pairs.entries.firstWhere((e) => e.value == own).key;
    var depth = 0;
    for (var j = k; j >= 0 && j < places.length; j += forward ? 1 : -1) {
      if (kinds[j] == own) depth++;
      if (kinds[j] == other) depth--;
      if (depth == 0) {
        final a = places[k], b = places[j];
        return a < b ? (a, b) : (b, a);
      }
    }
    return null;
  }
  return null;
}

int _indexOf(List<int> sorted, int value) {
  var low = 0, high = sorted.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    if (sorted[middle] == value) return middle;
    if (sorted[middle] < value) {
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return -1;
}
