import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// App-wide preferences, in a Themes section and a General section.
/// Changes apply and are saved as they are made.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.store});

  final WorkspaceStore store;

  static Future<void> show(BuildContext context, WorkspaceStore store) {
    return showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(store: store),
    );
  }

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final _timeout = TextEditingController(
    text: widget.store.settings.timeoutSecs.toString(),
  );

  WorkspaceStore get _store => widget.store;

  @override
  void dispose() {
    _timeout.dispose();
    super.dispose();
  }

  void _update({AppTheme? theme, HttpMode? httpMode, int? timeoutSecs}) {
    final current = _store.settings;
    _store.updateSettings(
      Settings(
        theme: theme ?? current.theme,
        httpMode: httpMode ?? current.httpMode,
        timeoutSecs: timeoutSecs ?? current.timeoutSecs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
        child: DefaultTabController(
          length: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Settings',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      key: const Key('settings-close'),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(key: Key('settings-themes'), text: 'Themes'),
                  Tab(key: Key('settings-general'), text: 'General'),
                ],
              ),
              Expanded(
                // Rebuilt on every change so the selections stay current.
                child: ListenableBuilder(
                  listenable: _store,
                  builder: (context, _) =>
                      TabBarView(children: [_themes(), _general(context)]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _themes() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Appearance'),
          const SizedBox(height: 12),
          SegmentedButton<AppTheme>(
            key: const Key('settings-theme'),
            segments: const [
              ButtonSegment(
                value: AppTheme.system,
                icon: Icon(Icons.brightness_auto_outlined),
                label: Text('System'),
              ),
              ButtonSegment(
                value: AppTheme.dark,
                icon: Icon(Icons.dark_mode_outlined),
                label: Text('Dark'),
              ),
              ButtonSegment(
                value: AppTheme.light,
                icon: Icon(Icons.light_mode_outlined),
                label: Text('Light'),
              ),
            ],
            selected: {_store.settings.theme},
            onSelectionChanged: (choice) => _update(theme: choice.single),
          ),
          const SizedBox(height: 12),
          const Text('System follows the light or dark mode of this device.'),
        ],
      ),
    );
  }

  Widget _general(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('HTTP version'),
          const SizedBox(height: 12),
          SegmentedButton<HttpMode>(
            key: const Key('settings-http'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: HttpMode.auto, label: Text('Auto')),
              ButtonSegment(value: HttpMode.http1, label: Text('HTTP/1')),
              ButtonSegment(value: HttpMode.http2, label: Text('HTTP/2')),
            ],
            selected: {_store.settings.httpMode},
            onSelectionChanged: (choice) => _update(httpMode: choice.single),
          ),
          const SizedBox(height: 8),
          Text(switch (_store.settings.httpMode) {
            HttpMode.auto => 'Uses HTTP/2 when the server offers it.',
            HttpMode.http1 => 'Every request uses HTTP/1.1.',
            HttpMode.http2 =>
              'Every request uses HTTP/2, and fails if the server '
                  'only supports HTTP/1.1.',
          }),
          const SizedBox(height: 24),
          SizedBox(
            width: 260,
            child: TextField(
              key: const Key('settings-timeout'),
              controller: _timeout,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(5),
              ],
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Request timeout',
                suffixText: 'seconds',
              ),
              onChanged: (text) =>
                  _update(timeoutSecs: int.tryParse(text) ?? 0),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _store.settings.timeoutSecs == 0
                ? '0 uses the default: wait as long as the server takes.'
                : 'Requests are abandoned after '
                      '${_store.settings.timeoutSecs} seconds.',
          ),
        ],
      ),
    );
  }
}
