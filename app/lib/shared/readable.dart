import 'dart:convert';

import 'package:reqorb/shared/theme.dart';

/// [text] indented when it is JSON, otherwise as it is.
String readable(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return text;
  try {
    return JsonEncoder.withIndent(CodeStyle.indent).convert(jsonDecode(text));
  } on FormatException {
    return text;
  }
}

/// [bytes] in hexadecimal, sixteen to a line, up to the first [limit].
String hexPreview(List<int> bytes, {int limit = 512}) {
  final lines = <String>[];
  for (var at = 0; at < bytes.length && at < limit; at += 16) {
    final row = bytes.skip(at).take(16);
    lines.add(row.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' '));
  }
  if (bytes.length > limit) lines.add('… ${bytes.length - limit} more bytes');
  return lines.join('\n');
}
