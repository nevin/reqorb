import 'package:flutter/material.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/workspace/workspace_store.dart';

/// Dropdown value meaning "no environment"; real names are never empty.
const _noEnvironment = '';

/// Chooses the environment whose variables requests are sent with.
class EnvironmentPicker extends StatelessWidget {
  const EnvironmentPicker({
    super.key,
    required this.store,
    required this.onManage,
  });

  final WorkspaceStore store;

  /// Opens the page where environments are created and edited.
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = store.activeEnvironment;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.layers_outlined,
              size: 16,
              // Coloured while an environment is supplying variables.
              color: active == null ? scheme.outline : scheme.primary,
            ),
            const SizedBox(width: 6),
            DropdownButton<String>(
              key: const Key('environment'),
              value: active ?? _noEnvironment,
              isDense: true,
              style: theme.textTheme.bodyMedium,
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(
                  value: _noEnvironment,
                  child: Text('No environment'),
                ),
                for (final e in store.environments)
                  DropdownMenuItem(value: e.name, child: Text(e.name)),
              ],
              onChanged: (name) => store.setActiveEnvironment(
                name == _noEnvironment ? null : name,
              ),
            ),
            IconButton(
              key: const Key('manage-environments'),
              tooltip: 'Manage environments',
              iconSize: 18,
              // Kept full size on touch screens, where it is hard to hit.
              visualDensity: isDesktop ? VisualDensity.compact : null,
              icon: const Icon(Icons.tune),
              onPressed: onManage,
            ),
          ],
        ),
      ),
    );
  }
}
