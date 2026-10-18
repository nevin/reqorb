import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:reqorb/document/text_document.dart';
import 'package:reqorb/shared/theme.dart';

/// Bytes shown on each row.
const _width = 16;

/// Rows fetched from the document at once.
const _block = 256;

/// A document's bytes in hexadecimal, sixteen to a row, with where each
/// row starts and its bytes as characters beside them. Only the rows in
/// view are read, so it is as quick for a gigabyte as for a kilobyte.
///
/// Keyed `<name>`; each row `<name>-row-<n>`.
class HexView extends StatefulWidget {
  const HexView({super.key, required this.document, this.name = 'hex'});

  final TextDocument document;
  final String name;

  @override
  State<HexView> createState() => _HexViewState();
}

class _HexViewState extends State<HexView> {
  final _scroll = ScrollController();
  final _blocks = <int, List<int>>{};
  int _version = -1;

  @override
  void didUpdateWidget(HexView old) {
    super.didUpdateWidget(old);
    if (old.document != widget.document) _blocks.clear();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double get _rowHeight => (CodeStyle.fontSize * 1.4).ceilToDouble();

  /// The bytes of row [row], fetched a block of rows at a time.
  List<int> _bytesOf(int row, int len) {
    if (_blocks.length > 64) _blocks.clear();
    final block = row ~/ _block;
    final bytes = _blocks[block] ??= widget.document.bytes(
      block * _block * _width,
      math.min(len, (block + 1) * _block * _width),
    );
    final from = (row - block * _block) * _width;
    return bytes.sublist(
      math.min(from, bytes.length),
      math.min(from + _width, bytes.length),
    );
  }

  static String _hex(int n, int digits) =>
      n.toRadixString(16).padLeft(digits, '0');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = widget.document.info();
    if (info.version != _version) {
      _blocks.clear();
      _version = info.version;
    }
    final len = info.len;
    final rows = (len + _width - 1) ~/ _width;
    // Enough digits for the last offset, and at least eight.
    final digits = math.max(8, _hex(math.max(0, len - 1), 1).length);
    final faint = mono.copyWith(
      color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
    );
    final plain = mono.copyWith(color: scheme.onSurface);
    final charWidth = (TextPainter(
      text: TextSpan(text: '0', style: mono),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout()).width;
    if (len == 0) {
      return Center(
        child: Text('Empty', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: 24 + (digits + 2 + _width * 3 + 2 + _width) * charWidth + 24,
          child: ListView.builder(
            key: Key(widget.name),
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            itemExtent: _rowHeight,
            itemCount: rows,
            itemBuilder: (context, row) {
              final bytes = _bytesOf(row, len);
              final hex = StringBuffer();
              final chars = StringBuffer();
              for (var i = 0; i < _width; i++) {
                if (i == _width ~/ 2) hex.write(' ');
                if (i < bytes.length) {
                  final b = bytes[i];
                  hex.write('${_hex(b, 2)} ');
                  chars.writeCharCode(b >= 0x20 && b < 0x7F ? b : 0x2E);
                } else {
                  hex.write('   ');
                }
              }
              return Text.rich(
                key: ValueKey('${widget.name}-row-$row'),
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${_hex(row * _width, digits)}  ',
                      style: faint,
                    ),
                    TextSpan(text: '$hex ', style: plain),
                    TextSpan(text: chars.toString(), style: faint),
                  ],
                ),
                maxLines: 1,
                softWrap: false,
              );
            },
          ),
        ),
      ),
    );
  }
}
