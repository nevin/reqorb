import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reqorb/bridge/engine.dart';
import 'package:reqorb/request/request_page.dart';
import 'package:reqorb/shared/folders.dart';
import 'package:reqorb/shared/theme.dart';
import 'package:reqorb/src/rust/api/core.dart';
import 'package:reqorb/src/rust/frb_generated.dart';
import 'package:reqorb/workspace/workspace_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final directory = await getApplicationSupportDirectory();
  final store = WorkspaceStore('${directory.path}/workspace.json');
  await store.load();
  await store.restoreWorkingDir(folders);
  runApp(ReqorbApp(store: store));
}

class ReqorbApp extends StatelessWidget {
  const ReqorbApp({super.key, required this.store});

  final WorkspaceStore store;

  @override
  Widget build(BuildContext context) {
    // Rebuilt when settings change, so a new theme applies immediately.
    return EngineScope(
      engine: store.engine,
      child: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final settings = store.settings;
          WorkingDir.path = settings.workingDir;
          CodeStyle.fontSize = settings.fontSize.clamp(9, 28).toDouble();
          CodeStyle.indent = switch (settings.indent) {
            Indent.twoSpaces => '  ',
            Indent.fourSpaces => '    ',
            Indent.tab => '\t',
          };
          return MaterialApp(
            title: 'reqorb',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light),
            darkTheme: buildTheme(Brightness.dark),
            themeMode: switch (store.settings.theme) {
              AppTheme.system => ThemeMode.system,
              AppTheme.light => ThemeMode.light,
              AppTheme.dark => ThemeMode.dark,
            },
            home: RequestPage(store: store),
          );
        },
      ),
    );
  }
}
