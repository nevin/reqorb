import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/shared/folders.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// Shown on the About tab. Kept in step with `pubspec.yaml`.
const appVersion = '0.1.0';

/// App-wide preferences. Changes apply and are saved as they are made.
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
  WorkspaceStore get _store => widget.store;
  Settings get _settings => _store.settings;

  // Number and text fields keep their own text, so that typing is not
  // disturbed by the setting being saved on every keystroke.
  late final _timeout = TextEditingController(text: '${_settings.timeoutSecs}');
  late final _maxSize = TextEditingController(
    text: '${_settings.maxResponseMb}',
  );
  late final _fontSize = TextEditingController(text: '${_settings.fontSize}');
  late final _proxyUrl = TextEditingController(text: _settings.proxyUrl);
  late final _history = TextEditingController(
    text: '${_settings.historyLimit}',
  );

  @override
  void dispose() {
    for (final controller in [
      _timeout,
      _maxSize,
      _fontSize,
      _proxyUrl,
      _history,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _update(Settings Function(Settings current) change) =>
      _store.updateSettings(change(_settings));

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 720),
        child: DefaultTabController(
          length: 5,
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
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(key: Key('settings-general'), text: 'General'),
                  Tab(key: Key('settings-themes'), text: 'Themes'),
                  Tab(key: Key('settings-proxy'), text: 'Proxy'),
                  Tab(key: Key('settings-shortcuts'), text: 'Shortcuts'),
                  Tab(key: Key('settings-about'), text: 'About'),
                ],
              ),
              Expanded(
                // Rebuilt on every change so the selections stay current.
                child: ListenableBuilder(
                  listenable: _store,
                  builder: (context, _) => TabBarView(
                    children: [
                      _general(context),
                      _themes(),
                      _proxy(context),
                      _shortcuts(context),
                      _about(context),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- general

  Widget _general(BuildContext context) {
    final s = _settings;
    final directory = _workingDirectory(context);
    final request = _Section('Request', [
      _Row(
        label: 'HTTP version',
        help: switch (s.httpMode) {
          HttpMode.auto => 'Uses HTTP/2 when the server offers it.',
          HttpMode.http1 => 'Every request uses HTTP/1.1.',
          HttpMode.http2 =>
            'Every request uses HTTP/2, and fails if the server only '
                'supports HTTP/1.1.',
        },
        control: DropdownButton<HttpMode>(
          key: const Key('settings-http'),
          value: s.httpMode,
          isDense: true,
          items: const [
            DropdownMenuItem(value: HttpMode.auto, child: Text('Auto')),
            DropdownMenuItem(value: HttpMode.http1, child: Text('HTTP/1')),
            DropdownMenuItem(value: HttpMode.http2, child: Text('HTTP/2')),
          ],
          onChanged: (mode) => _update((c) => c.copyWith(httpMode: mode)),
        ),
      ),
      _Row(
        label: 'Request timeout in seconds',
        help: s.timeoutSecs == 0
            ? 'How long to wait for a response. 0 waits as long as the '
                  'server takes.'
            : 'Requests are abandoned after ${s.timeoutSecs} seconds.',
        control: _number(
          const Key('settings-timeout'),
          _timeout,
          (value) => _update((c) => c.copyWith(timeoutSecs: value)),
        ),
      ),
      _Row(
        label: 'Max response size in MB',
        help: s.maxResponseMb == 0
            ? 'The largest response to download. 0 downloads a response of '
                  'any size.'
            : 'A response over ${s.maxResponseMb} MB is abandoned.',
        control: _number(
          const Key('settings-max-size'),
          _maxSize,
          (value) => _update((c) => c.copyWith(maxResponseMb: value)),
        ),
      ),
      _Row(
        label: 'SSL certificate verification',
        help: 'Refuse a server whose certificate cannot be verified.',
        control: _switch(
          const Key('settings-verify-ssl'),
          s.verifySsl,
          (on) => _update((c) => c.copyWith(verifySsl: on)),
        ),
      ),
      _Row(
        label: 'Always ask before discarding unsaved changes',
        help: 'When off, opening another request drops the edits to this one.',
        control: _switch(
          const Key('settings-confirm-discard'),
          s.confirmDiscard,
          (on) => _update((c) => c.copyWith(confirmDiscard: on)),
        ),
      ),
    ]);
    final security = _security(context);
    final history = _Section('History', [
      _Row(
        label: 'Requests kept in history',
        help: s.historyLimit == 0
            ? 'Nothing is kept: requests are forgotten when reqorb closes.'
            : 'The last ${s.historyLimit} requests and their responses are '
                  'kept between launches. 0 keeps none.',
        control: _number(
          const Key('settings-history-limit'),
          _history,
          (value) => _update((c) => c.copyWith(historyLimit: value)),
        ),
      ),
    ]);
    final headers = _Section('Headers', [
      _Row(
        label: 'Send no-cache header',
        help: 'Adds Cache-Control: no-cache to requests that do not set it.',
        control: _switch(
          const Key('settings-no-cache'),
          s.sendNoCache,
          (on) => _update((c) => c.copyWith(sendNoCache: on)),
        ),
      ),
      _Row(
        label: 'Automatically follow redirects',
        help: 'When off, a redirect is shown as the response.',
        control: _switch(
          const Key('settings-follow-redirects'),
          s.followRedirects,
          (on) => _update((c) => c.copyWith(followRedirects: on)),
        ),
      ),
    ]);
    final interface = _Section('User interface', [
      _Row(
        label: 'Layout',
        help: switch (s.layout) {
          Layout.auto =>
            'The response is beside the request in a wide window and '
                'below it in a narrow one.',
          Layout.sideBySide => 'The response is always beside the request.',
          Layout.stacked => 'The response is always below the request.',
        },
        control: DropdownButton<Layout>(
          key: const Key('settings-layout'),
          value: s.layout,
          isDense: true,
          items: const [
            DropdownMenuItem(value: Layout.auto, child: Text('Auto')),
            DropdownMenuItem(
              value: Layout.sideBySide,
              child: Text('Side by side'),
            ),
            DropdownMenuItem(value: Layout.stacked, child: Text('Stacked')),
          ],
          onChanged: (layout) => _update((c) => c.copyWith(layout: layout)),
        ),
      ),
    ]);
    final editor = _Section(
      'Editor',
      [
        _Row(
          label: 'Font size (px)',
          help: 'For URLs, headers, bodies and responses. From 9 to 28.',
          control: _number(
            const Key('settings-font-size'),
            _fontSize,
            // Kept in range as it is typed, so a stray digit cannot make
            // the app unreadable.
            (value) => _update((c) => c.copyWith(fontSize: value.clamp(9, 28))),
            digits: 2,
          ),
        ),
        _Row(
          label: 'Indentation',
          help: 'What formatted JSON is indented with.',
          control: DropdownButton<Indent>(
            key: const Key('settings-indent'),
            value: s.indent,
            isDense: true,
            items: const [
              DropdownMenuItem(
                value: Indent.twoSpaces,
                child: Text('2 spaces'),
              ),
              DropdownMenuItem(
                value: Indent.fourSpaces,
                child: Text('4 spaces'),
              ),
              DropdownMenuItem(value: Indent.tab, child: Text('Tab')),
            ],
            onChanged: (indent) => _update((c) => c.copyWith(indent: indent)),
          ),
        ),
      ],
      action: TextButton(
        key: const Key('settings-editor-reset'),
        onPressed: () {
          _fontSize.text = '13';
          _update((c) => c.copyWith(fontSize: 13, indent: Indent.twoSpaces));
        },
        child: const Text('Reset'),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Two columns when there is room, as there is on a desktop.
        final wide = constraints.maxWidth >= 720;
        final left = [request, security, history];
        final right = [headers, interface, editor];
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              directory,
              const Divider(height: 24),
              const SizedBox(height: 8),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Column(children: left)),
                    const SizedBox(width: 40),
                    Expanded(child: Column(children: right)),
                  ],
                )
              else ...[
                ...left,
                ...right,
              ],
            ],
          ),
        );
      },
    );
  }

  // --------------------------------------------------------------- security

  /// Whether saved credentials are encrypted, and what stands in the way
  /// when they are not.
  Widget _security(BuildContext context) {
    final theme = Theme.of(context);
    final warning = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.error,
    );
    final on = _settings.protectSecrets;
    final locked = _store.lockedSecrets;
    return _Section('Security', [
      _Row(
        label: 'Encrypt saved credentials',
        help: on
            ? 'Passwords, tokens, cookies and secret variables are encrypted '
                  'in the workspace file. The key is kept in the system '
                  'keychain, so the file alone gives nothing away.'
            : 'Passwords, tokens and cookies are saved in the workspace '
                  'file as plain text.',
        control: _switch(
          const Key('settings-protect-secrets'),
          on,
          (on) => _update((c) => c.copyWith(protectSecrets: on)),
        ),
      ),
      if (on && _store.unprotected != null)
        Text(
          'Not encrypted: ${_store.unprotected}. Credentials are being '
          'saved as plain text.',
          key: const Key('settings-secrets-unprotected'),
          style: warning,
        ),
      if (locked > 0)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '$locked saved ${locked == 1 ? 'credential is' : 'credentials are'}'
            ' locked: ${_store.keyProblem ?? 'the key could not be read'}. '
            'This happens when the workspace file comes from another '
            'machine. Nothing is lost, but each must be entered again '
            'before a request can use it.',
            key: const Key('settings-secrets-locked'),
            style: warning,
          ),
        ),
    ]);
  }

  // ------------------------------------------------------ working directory

  /// The folder [_access] was worked out for; null to work it out again.
  String? _checkedDir;
  DirAccess? _access;

  /// Asks for a folder, which is also how the system is asked for permission
  /// to use it, and keeps that permission for the next launch.
  Future<void> _chooseWorkingDir() async {
    final current = _settings.workingDir;
    final path = await folders.choose(initial: current);
    if (path == null) return;
    final grant = await folders.grant(path);
    // Checked afresh even if it is the same folder: access may be new.
    _checkedDir = null;
    _update((c) => c.copyWith(workingDir: path, workingDirGrant: grant));
  }

  Widget _workingDirectory(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = _settings;
    final path = s.workingDir;
    final chosen = path.isNotEmpty;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final warning = methodColor('POST', scheme.brightness);
    // Trying a folder out writes to it, so it is done once per folder and
    // not on every rebuild.
    if (path != _checkedDir) {
      _checkedDir = path;
      _access = chosen ? Engine.of(context).checkDirectory(path: path) : null;
    }
    final access = _access;

    // What the folder allows, and what to do when that is not enough.
    final (
      IconData icon,
      Color color,
      String status,
      String? fix,
    ) = switch (access) {
      null => (
        Icons.folder_off_outlined,
        scheme.onSurfaceVariant,
        'No folder chosen: requests read files from wherever their '
            'paths point.',
        null,
      ),
      DirAccess(exists: true, readable: true, writable: true) => (
        Icons.check_circle_outline,
        statusColor(200, scheme),
        'reqorb can read and write this folder.',
        null,
      ),
      DirAccess(exists: true, readable: true) => (
        Icons.info_outline,
        warning,
        'reqorb can read this folder but not write to it. That is '
            'enough to send files from it.',
        null,
      ),
      // A sandboxed app cannot tell a folder it may not open from one
      // that is gone; choosing it again settles both.
      _ => (
        Icons.warning_amber_outlined,
        scheme.error,
        'reqorb cannot open this folder: it was moved or deleted, or '
            'permission to use it has lapsed.',
        'Give access',
      ),
    };

    return _Section('Working directory', [
      Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 10),
        child: Text(
          'Keep the files your requests send in one folder. File paths are '
          'looked up in it, so a shared collection works on any machine '
          'that has the folder.',
          style: muted,
        ),
      ),
      Row(
        children: [
          Expanded(
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Location'),
              child: Text(
                chosen ? path : 'No folder chosen',
                key: const Key('settings-working-dir'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: chosen
                    ? mono
                    : mono.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonal(
            key: const Key('settings-working-dir-choose'),
            onPressed: _chooseWorkingDir,
            child: const Text('Choose'),
          ),
          if (chosen)
            IconButton(
              key: const Key('settings-working-dir-clear'),
              tooltip: 'Stop using a working directory',
              icon: const Icon(Icons.close),
              onPressed: () => _update(
                (c) => c.copyWith(workingDir: '', workingDirGrant: ''),
              ),
            ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                status,
                key: const Key('settings-working-dir-status'),
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (fix != null)
              TextButton(
                key: const Key('settings-working-dir-grant'),
                onPressed: _chooseWorkingDir,
                child: Text(fix),
              ),
          ],
        ),
      ),
      _Row(
        label: 'Allow reading files outside working directory',
        help: chosen
            ? 'When off, a request that names a file outside the folder is '
                  'not sent.'
            : 'Choose a working directory to limit which files requests '
                  'can read.',
        control: _switch(
          const Key('settings-allow-outside'),
          // Without a working directory there is nothing to be outside of.
          !chosen || s.allowOutsideWorkingDir,
          chosen
              ? (on) => _update((c) => c.copyWith(allowOutsideWorkingDir: on))
              : null,
        ),
      ),
      if (chosen && s.allowOutsideWorkingDir)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_outlined, size: 16, color: warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'With this on, a collection imported from someone else can '
                'send any file on this device that reqorb can read.',
                key: const Key('settings-allow-outside-warning'),
                style: muted,
              ),
            ),
          ],
        ),
    ]);
  }

  Widget _switch(Key key, bool value, ValueChanged<bool>? onChanged) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Switch(key: key, value: value, onChanged: onChanged),
      SizedBox(width: 32, child: Text(value ? 'ON' : 'OFF')),
    ],
  );

  Widget _number(
    Key key,
    TextEditingController controller,
    ValueChanged<int> onChanged, {
    int digits = 5,
  }) => SizedBox(
    width: 84,
    child: TextField(
      key: key,
      controller: controller,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.end,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(digits),
      ],
      onChanged: (text) => onChanged(int.tryParse(text) ?? 0),
    ),
  );

  // ----------------------------------------------------------------- themes

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
            selected: {_settings.theme},
            onSelectionChanged: (choice) =>
                _update((c) => c.copyWith(theme: choice.single)),
          ),
          const SizedBox(height: 12),
          const Text('System follows the light or dark mode of this device.'),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ proxy

  Widget _proxy(BuildContext context) {
    final s = _settings;
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('HTTP requests are sent'),
          const SizedBox(height: 12),
          SegmentedButton<ProxyMode>(
            key: const Key('settings-proxy-mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: ProxyMode.system,
                label: Text('Through the system proxy'),
              ),
              ButtonSegment(value: ProxyMode.none, label: Text('Directly')),
              ButtonSegment(
                value: ProxyMode.custom,
                label: Text('Through this proxy'),
              ),
            ],
            selected: {s.proxy},
            onSelectionChanged: (choice) =>
                _update((c) => c.copyWith(proxy: choice.single)),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 420,
            child: TextField(
              key: const Key('settings-proxy-url'),
              controller: _proxyUrl,
              enabled: s.proxy == ProxyMode.custom,
              autocorrect: false,
              keyboardType: TextInputType.url,
              style: mono,
              decoration: const InputDecoration(
                labelText: 'Proxy address',
                hintText: 'http://127.0.0.1:8080',
              ),
              onChanged: (text) =>
                  _update((c) => c.copyWith(proxyUrl: text.trim())),
            ),
          ),
          const SizedBox(height: 12),
          Text(switch (s.proxy) {
            ProxyMode.system =>
              'Uses the proxy this device or the HTTP_PROXY and '
                  'HTTPS_PROXY environment variables are set up with, if '
                  'any.',
            ProxyMode.none =>
              'Connects straight to each server, whatever the system '
                  'says.',
            ProxyMode.custom when s.proxyUrl.isEmpty =>
              'Enter an address; until then the system proxy is used.',
            ProxyMode.custom =>
              'An http://, https:// or socks5:// address. A user and '
                  'password can go in it: http://user:pass@host:8080.',
          }, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text(
            'WebSocket and gRPC connections do not use a proxy.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- shortcuts

  Widget _shortcuts(BuildContext context) {
    final theme = Theme.of(context);
    final key = shortcutModifier;
    final enter = key == '⌘' ? '↵' : 'Enter';
    final actions = [
      ('Send, connect or call', '$key$enter'),
      ('Stop a send or a call', '$key.'),
      ('Put back what was just deleted', '${key}Z'),
      ('Save the request', '${key}S'),
      ('New request', '${key}N'),
      ('Close request', '${key}W'),
      ('Go to the address', '${key}L'),
      ('Show or hide the sidebar', '${key}B'),
      ('Find anything: requests, environments, actions', '${key}K'),
      ('Go to the first eight tabs', '${key}1 – ${key}8'),
      ('Go to the last tab', '${key}9'),
      ('Next tab', 'Ctrl Tab'),
      ('Previous tab', 'Ctrl ⇧ Tab'),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (action, keys) in actions)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  SizedBox(width: 280, child: Text(action)),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      child: Text(keys, style: mono.copyWith(fontSize: 12)),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text(
            'Double-click a request\'s name to rename it. Escape leaves it '
            'as it was.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ about

  Widget _about(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('reqorb', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Version $appVersion', key: const Key('settings-version')),
          const SizedBox(height: 16),
          const Text(
            'A native API client for HTTP, WebSocket and gRPC, built on a '
            'Rust engine.',
          ),
          const SizedBox(height: 16),
          Text('Your workspace is kept in', style: muted),
          const SizedBox(height: 4),
          SelectableText(_store.path, style: mono.copyWith(fontSize: 12)),
          const SizedBox(height: 16),
          Text(
            'reqorb sends nothing about how it is used. MIT licensed.',
            style: muted,
          ),
        ],
      ),
    );
  }
}

/// A titled group of settings.
class _Section extends StatelessWidget {
  const _Section(this.title, this.rows, {this.action});

  final String title;
  final List<Widget> rows;

  /// Sits beside the title, such as a Reset button.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              if (action != null) ...[const SizedBox(width: 4), action!],
            ],
          ),
          const SizedBox(height: 4),
          ...rows,
        ],
      ),
    );
  }
}

/// One setting: what it is and what it does on the left, its control on the
/// right.
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.help, required this.control});

  final String label;
  final String help;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                const SizedBox(height: 2),
                Text(
                  help,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          control,
        ],
      ),
    );
  }
}
