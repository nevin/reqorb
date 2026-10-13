/// The command palette: one box that finds a saved request, an open tab,
/// an environment or an action by a few letters of its name.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/shared/theme.dart';

/// Something the palette can do.
class PaletteItem {
  const PaletteItem({
    required this.title,
    required this.kind,
    required this.run,
    this.detail = '',
    this.method,
    this.icon,
    this.shortcut,
  });

  final String title;

  /// Where it lives or what it does, shown smaller beside the title and
  /// searched along with it.
  final String detail;

  /// What sort of thing it is: `Request`, `Tab`, `Environment`, `Action`.
  final String kind;

  /// The method of a request, shown in its colour in place of an icon.
  final String? method;
  final IconData? icon;

  /// The key that does the same without the palette, such as `S`.
  final String? shortcut;
  final VoidCallback run;
}

/// How well [text] answers [query]: null when it does not, and otherwise
/// higher for a closer match. Every letter of the query must appear in
/// order; letters that start a word or follow one another count for more.
int? paletteScore(String query, String text) {
  final q = query.toLowerCase().replaceAll(' ', '');
  if (q.isEmpty) return 0;
  final t = text.toLowerCase();
  var score = 0;
  var at = 0;
  var last = -2;
  for (var i = 0; i < q.length; i++) {
    final found = t.indexOf(q[i], at);
    if (found < 0) return null;
    final starts = found == 0 || !_isWord(t.codeUnitAt(found - 1));
    score += 1 + (starts ? 6 : 0) + (found == last + 1 ? 4 : 0);
    // Letters far apart are a weaker sign that this was meant.
    score -= found - at > 8 ? 2 : 0;
    last = found;
    at = found + 1;
  }
  if (t.startsWith(q)) score += 20;
  return score;
}

bool _isWord(int unit) =>
    (unit >= 0x30 && unit <= 0x39) || (unit >= 0x61 && unit <= 0x7a);

/// The [items] that answer [query], best first. With nothing typed they
/// are all there, in the order given.
List<PaletteItem> paletteMatches(String query, List<PaletteItem> items) {
  if (query.trim().isEmpty) return items;
  final scored = <(int, int, PaletteItem)>[];
  for (final (i, item) in items.indexed) {
    final title = paletteScore(query, item.title);
    final detail = paletteScore(query, '${item.title} ${item.detail}');
    // A match in the name is worth more than one helped by the detail.
    final score = title != null ? title + 10 : detail;
    if (score != null) scored.add((score, i, item));
  }
  scored.sort((a, b) => a.$1 != b.$1 ? b.$1 - a.$1 : a.$2 - b.$2);
  return [for (final (_, _, item) in scored) item];
}

/// Shows the palette and does what is chosen from it.
Future<void> showCommandPalette(
  BuildContext context,
  List<PaletteItem> items,
) async {
  final chosen = await showDialog<PaletteItem>(
    context: context,
    barrierColor: Colors.black26,
    builder: (_) => CommandPalette(items: items),
  );
  // After the dialog has gone, so that what runs can open one of its own.
  chosen?.run();
}

class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.items});

  final List<PaletteItem> items;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  late List<PaletteItem> _found = widget.items;
  int _at = 0;

  static const _rowHeight = 44.0;

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _search(String query) => setState(() {
    _found = paletteMatches(query, widget.items);
    _at = 0;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  });

  void _move(int by) {
    if (_found.isEmpty) return;
    setState(() => _at = (_at + by) % _found.length);
    if (!_scroll.hasClients) return;
    // Keeps the chosen row in view as the arrows walk the list.
    final top = _at * _rowHeight;
    final view = _scroll.position;
    if (top < view.pixels) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > view.pixels + view.viewportDimension) {
      _scroll.jumpTo(top + _rowHeight - view.viewportDimension);
    }
  }

  void _choose([int? index]) {
    final at = index ?? _at;
    if (at < _found.length) Navigator.of(context).pop(_found[at]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: EdgeInsets.fromLTRB(24, size.height * 0.12, 24, 24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 620,
          maxHeight: (size.height * 0.6).clamp(200.0, 520.0),
        ),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
            const SingleActivator(LogicalKeyboardKey.enter): _choose,
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('palette-input'),
                controller: _query,
                autofocus: true,
                onChanged: _search,
                onSubmitted: (_) => _choose(),
                decoration: const InputDecoration(
                  hintText: 'Find a request, an environment or an action',
                  prefixIcon: Icon(Icons.search, size: 20),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              const Divider(height: 1),
              if (_found.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Nothing matches',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    controller: _scroll,
                    shrinkWrap: true,
                    itemExtent: _rowHeight,
                    itemCount: _found.length,
                    itemBuilder: (context, i) => _row(context, i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int i) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = _found[i];
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return InkWell(
      key: Key('palette-item-$i'),
      onTap: () => _choose(i),
      child: Container(
        color: i == _at ? scheme.primary.withValues(alpha: 0.12) : null,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: item.method == null
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Icon(
                        item.icon ?? Icons.bolt_outlined,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    )
                  : Text(
                      item.method!,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: methodColor(item.method!, theme.brightness),
                      ),
                    ),
            ),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(item.title, maxLines: 1, overflow: .ellipsis),
                  ),
                  if (item.detail.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        item.detail,
                        maxLines: 1,
                        overflow: .ellipsis,
                        style: small,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (item.shortcut case final shortcut?)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Text('$shortcutModifier$shortcut', style: small),
              ),
            Text(item.kind, style: small),
          ],
        ),
      ),
    );
  }
}
