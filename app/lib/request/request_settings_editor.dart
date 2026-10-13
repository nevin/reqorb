import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reqorb/src/rust/api/core.dart';

/// The request's Settings tab: how this one request is carried out.
/// Give the widget a new [key] to load a different request's settings.
class RequestSettingsEditor extends StatefulWidget {
  const RequestSettingsEditor({
    super.key,
    required this.settings,
    required this.appHttpMode,
    required this.onChanged,
  });

  final RequestSettings? settings;

  /// The app-wide HTTP version, shown as what "Default" currently means.
  final HttpMode appHttpMode;

  /// Called with null when every option is back at its default.
  final ValueChanged<RequestSettings?> onChanged;

  @override
  State<RequestSettingsEditor> createState() => _RequestSettingsEditorState();
}

String _httpLabel(HttpMode mode) => switch (mode) {
  HttpMode.auto => 'Auto',
  HttpMode.http1 => 'HTTP/1.x',
  HttpMode.http2 => 'HTTP/2',
};

class _RequestSettingsEditorState extends State<RequestSettingsEditor> {
  static final _defaults = defaultRequestSettings();

  late RequestSettings _s = widget.settings ?? _defaults;
  late final _maxRedirects = TextEditingController(
    text: _s.maxRedirects.toString(),
  );

  @override
  void dispose() {
    _maxRedirects.dispose();
    super.dispose();
  }

  void _set({
    HttpMode? Function()? httpMode,
    bool? verifySsl,
    bool? followRedirects,
    bool? followOriginalMethod,
    bool? followAuthHeader,
    bool? removeReferer,
    bool? strictHttpParser,
    bool? disableCookieJar,
    int? maxRedirects,
    DisabledTls? disabledTls,
  }) {
    setState(() {
      _s = RequestSettings(
        httpMode: httpMode != null ? httpMode() : _s.httpMode,
        verifySsl: verifySsl ?? _s.verifySsl,
        followRedirects: followRedirects ?? _s.followRedirects,
        followOriginalMethod: followOriginalMethod ?? _s.followOriginalMethod,
        followAuthHeader: followAuthHeader ?? _s.followAuthHeader,
        removeReferer: removeReferer ?? _s.removeReferer,
        strictHttpParser: strictHttpParser ?? _s.strictHttpParser,
        disableCookieJar: disableCookieJar ?? _s.disableCookieJar,
        maxRedirects: maxRedirects ?? _s.maxRedirects,
        disabledTls: disabledTls ?? _s.disabledTls,
      );
    });
    widget.onChanged(_s == _defaults ? null : _s);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        children: [
          _row(
            'HTTP version',
            'The HTTP version used to send this request.',
            DropdownButton<HttpMode?>(
              key: const Key('rs-http'),
              value: _s.httpMode,
              isDense: true,
              items: [
                DropdownMenuItem(
                  child: Text('Default (${_httpLabel(widget.appHttpMode)})'),
                ),
                for (final mode in HttpMode.values)
                  DropdownMenuItem(value: mode, child: Text(_httpLabel(mode))),
              ],
              onChanged: (mode) => _set(httpMode: () => mode),
            ),
          ),
          _toggle(
            'rs-verify-ssl',
            'Enable SSL certificate verification',
            'Refuse to send when the server\'s certificate cannot be verified.',
            _s.verifySsl,
            (on) => _set(verifySsl: on),
          ),
          _toggle(
            'rs-follow-redirects',
            'Automatically follow redirects',
            'Follow HTTP 3xx responses as redirects.',
            _s.followRedirects,
            (on) => _set(followRedirects: on),
          ),
          _toggle(
            'rs-original-method',
            'Follow original HTTP method',
            'Redirect with the original method and body instead of '
                'switching to GET.',
            _s.followOriginalMethod,
            (on) => _set(followOriginalMethod: on),
          ),
          _toggle(
            'rs-follow-auth',
            'Follow Authorization header',
            'Keep the Authorization header when a redirect goes to a '
                'different host.',
            _s.followAuthHeader,
            (on) => _set(followAuthHeader: on),
          ),
          _toggle(
            'rs-remove-referer',
            'Remove referer header on redirect',
            'Do not add a Referer header when a redirect happens.',
            _s.removeReferer,
            (on) => _set(removeReferer: on),
          ),
          _toggle(
            'rs-strict-parser',
            'Enable strict HTTP parser',
            'Reject responses with invalid HTTP headers.',
            _s.strictHttpParser,
            (on) => _set(strictHttpParser: on),
          ),
          _toggle(
            'rs-disable-cookies',
            'Disable cookie jar',
            'Do not send cookies from the jar with this request, or store '
                'the ones it receives.',
            _s.disableCookieJar,
            (on) => _set(disableCookieJar: on),
          ),
          _row(
            'Maximum number of redirects',
            'How many redirects to follow before giving up.',
            SizedBox(
              width: 72,
              child: TextField(
                key: const Key('rs-max-redirects'),
                controller: _maxRedirects,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.end,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (text) =>
                    _set(maxRedirects: int.tryParse(text) ?? 0),
              ),
            ),
          ),
          _row(
            'TLS protocol disabled during handshake',
            'Refuse one TLS version. Only TLS 1.2 and 1.3 are ever used.',
            DropdownButton<DisabledTls>(
              key: const Key('rs-disabled-tls'),
              value: _s.disabledTls,
              isDense: true,
              items: const [
                DropdownMenuItem(value: DisabledTls.none, child: Text('None')),
                DropdownMenuItem(
                  value: DisabledTls.tls12,
                  child: Text('TLS 1.2'),
                ),
                DropdownMenuItem(
                  value: DisabledTls.tls13,
                  child: Text('TLS 1.3'),
                ),
              ],
              onChanged: (value) => _set(disabledTls: value),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggle(
    String key,
    String title,
    String description,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return _row(
      title,
      description,
      Switch(key: Key(key), value: value, onChanged: onChanged),
    );
  }

  Widget _row(String title, String description, Widget control) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          control,
        ],
      ),
    );
  }
}
