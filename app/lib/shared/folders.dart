import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:macos_secure_bookmarks/macos_secure_bookmarks.dart';

/// Choosing folders, and keeping the platform's permission to use them.
///
/// A sandboxed app may only open what the user has picked, and only until
/// it quits. Picking a folder is how permission is asked for; a grant is
/// what lets the app open the folder again after a restart.
abstract class Folders {
  /// Asks the user for a folder, starting at [initial]; null when cancelled.
  /// [title] says what the folder is wanted for.
  Future<String?> choose({String? initial, String? title});

  /// A grant for [path], which must have just been chosen. Empty where the
  /// platform needs none, or offers none.
  Future<String> grant(String path);

  /// Takes a grant up again after a restart. Returns the folder it is for,
  /// which may have been moved, or null when the grant no longer works.
  Future<String?> restore(String grant);
}

/// The system's folder picker, with security-scoped bookmarks on macOS.
class SystemFolders implements Folders {
  const SystemFolders();

  bool get _bookmarks =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<String?> choose({String? initial, String? title}) =>
      FilePicker.getDirectoryPath(
        dialogTitle: title ?? 'Choose the working directory',
        initialDirectory: (initial == null || initial.isEmpty) ? null : initial,
      );

  @override
  Future<String> grant(String path) async {
    if (!_bookmarks) return '';
    try {
      return await SecureBookmarks().bookmark(Directory(path));
    } catch (_) {
      // Without a grant the folder still works until the app quits.
      return '';
    }
  }

  @override
  Future<String?> restore(String grant) async {
    if (!_bookmarks || grant.isEmpty) return null;
    try {
      final bookmarks = SecureBookmarks();
      final folder = await bookmarks.resolveBookmark(grant, isDirectory: true);
      final started = await bookmarks.startAccessingSecurityScopedResource(
        folder,
      );
      return started ? folder.path : null;
    } catch (_) {
      return null;
    }
  }
}

/// How folders are chosen; tests replace this so that no system dialog opens.
Folders folders = const SystemFolders();

/// The working directory as chosen in Settings; empty when there is none.
/// Set once per build of the app, like the code style.
abstract final class WorkingDir {
  static String path = '';

  /// [file] as it should be kept in a request: relative when it is inside
  /// the working directory, so that the request works wherever that folder
  /// is, and unchanged otherwise.
  static String relative(String file) {
    final root = path.endsWith('/') || path.endsWith(r'\')
        ? path.substring(0, path.length - 1)
        : path;
    if (root.isEmpty || file.length <= root.length + 1) return file;
    final separator = file[root.length];
    if (file.startsWith(root) && (separator == '/' || separator == r'\')) {
      return file.substring(root.length + 1);
    }
    return file;
  }
}
