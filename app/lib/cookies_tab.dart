import 'package:flutter/material.dart';

import 'src/rust/api/core.dart';
import 'workspace_store.dart';

/// The Cookies tab: what servers have set, plus cookies added by hand.
/// The jar is shared by every request, so all domains are listed.
class CookiesTab extends StatefulWidget {
  const CookiesTab({super.key, required this.store, required this.currentUrl});

  final WorkspaceStore store;

  /// The URL in the editor, used to suggest a domain for a new cookie.
  final String Function() currentUrl;

  @override
  State<CookiesTab> createState() => _CookiesTabState();
}

const _mono = TextStyle(fontFamily: 'Menlo', fontSize: 13);

class _CookiesTabState extends State<CookiesTab> {
  final _domain = TextEditingController();
  final _path = TextEditingController(text: '/');
  final _name = TextEditingController();
  final _value = TextEditingController();
  bool _secure = false;
  bool _adding = false;
  String? _problem;

  WorkspaceStore get _store => widget.store;

  @override
  void dispose() {
    _domain.dispose();
    _path.dispose();
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  void _add() {
    // Accept a pasted URL or a leading dot, and keep just the host.
    var domain = _domain.text.trim().toLowerCase();
    domain = domain.replaceFirst(RegExp(r'^[a-z]+://'), '');
    domain = domain.split('/').first.split(':').first;
    domain = domain.replaceFirst(RegExp(r'^\.'), '');
    final name = _name.text.trim();
    final path = _path.text.trim();
    if (domain.isEmpty || name.isEmpty) {
      setState(() => _problem = 'A cookie needs a domain and a name.');
      return;
    }
    _store.putCookie(
      Cookie(
        name: name,
        value: _value.text.trim(),
        domain: domain,
        path: path.startsWith('/') ? path : '/',
        secure: _secure,
        httpOnly: false,
        // Typed by hand, so it should also reach subdomains.
        hostOnly: false,
      ),
    );
    setState(() {
      _name.clear();
      _value.clear();
      _problem = null;
      _adding = false;
    });
  }

  /// Opens or closes the form, suggesting the current request's host.
  void _toggleForm() {
    setState(() {
      _adding = !_adding;
      _problem = null;
      if (_adding && _domain.text.trim().isEmpty) {
        _domain.text = Uri.tryParse(widget.currentUrl().trim())?.host ?? '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final cookies = _store.cookies;
        final domains = {for (final c in cookies) c.domain}.toList()..sort();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      cookies.isEmpty
                          ? 'No cookies stored'
                          : '${cookies.length} stored, sent to matching URLs',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (cookies.isNotEmpty)
                    TextButton(
                      key: const Key('cookies-clear'),
                      onPressed: _store.clearCookies,
                      child: const Text('Clear all'),
                    ),
                  TextButton.icon(
                    key: const Key('cookies-add'),
                    onPressed: _toggleForm,
                    icon: Icon(_adding ? Icons.expand_less : Icons.add),
                    label: const Text('Add cookie'),
                  ),
                ],
              ),
            ),
            Expanded(
              // One scroll area for the form and the list, so the form
              // never squeezes the list out of a short pane.
              child: ListView(
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  if (_adding) _form(theme),
                  if (cookies.isEmpty && !_adding)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Cookies that servers set are kept here and sent '
                        'back on later requests. You can also add your own.',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  for (final domain in domains) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                      child: Text(domain, style: theme.textTheme.titleSmall),
                    ),
                    for (final cookie in cookies)
                      if (cookie.domain == domain) _row(cookie),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _row(Cookie cookie) {
    final details = [
      cookie.path,
      if (cookie.expires case final at?) 'expires ${_date(at)}' else 'session',
      if (cookie.secure) 'Secure',
      if (cookie.httpOnly) 'HttpOnly',
      if (!cookie.hostOnly) 'subdomains',
    ].join(' · ');
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 12, right: 4),
      title: SelectableText(
        '${cookie.name}=${cookie.value}',
        maxLines: 1,
        style: _mono,
      ),
      subtitle: Text(details),
      trailing: IconButton(
        tooltip: 'Delete cookie',
        iconSize: 18,
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _store.removeCookie(cookie),
      ),
    );
  }

  static String _date(int unixSeconds) {
    final at = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }

  Widget _form(ThemeData theme) {
    InputDecoration field(String label, String hint) => InputDecoration(
      border: const OutlineInputBorder(),
      isDense: true,
      labelText: label,
      hintText: hint,
    );
    TextField input(
      String key,
      TextEditingController controller,
      String label,
      String hint,
    ) => TextField(
      key: Key(key),
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      smartQuotesType: SmartQuotesType.disabled,
      smartDashesType: SmartDashesType.disabled,
      style: _mono,
      decoration: field(label, hint),
      onSubmitted: (_) => _add(),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: input(
                  'cookie-domain',
                  _domain,
                  'Domain',
                  'api.example.com',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: input('cookie-path', _path, 'Path', '/'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: input('cookie-name', _name, 'Name', 'session'),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: input('cookie-value', _value, 'Value', 'abc123'),
              ),
            ],
          ),
          // On its own line so it cannot crowd the row below in a narrow pane.
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _problem!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Checkbox(
                key: const Key('cookie-secure'),
                value: _secure,
                onChanged: (value) => setState(() => _secure = value ?? false),
              ),
              const Text('Secure (HTTPS only)'),
              const Spacer(),
              FilledButton(
                key: const Key('cookie-save'),
                onPressed: _add,
                child: const Text('Add'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
