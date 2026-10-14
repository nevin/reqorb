/// Short messages shown at the bottom of the window.
library;

import 'package:flutter/material.dart';

void showMessage(BuildContext context, String message) =>
    notify(ScaffoldMessenger.of(context), message);

/// The way back from the last removal, while its message is showing.
VoidCallback? _undo;

/// Reports something that was just removed and offers to put it back, with
/// the button or with ⌘Z, for as long as the message shows.
void showUndo(BuildContext context, String message, VoidCallback undo) {
  void once() {
    if (_undo != once) return;
    _undo = null;
    undo();
  }

  _undo = once;
  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  final shown = messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      // With an action it stays until dismissed or replaced.
      action: SnackBarAction(label: 'Undo', onPressed: once),
    ),
  );
  shown.closed.whenComplete(() {
    if (_undo == once) _undo = null;
  });
}

/// Puts back what was last removed, if its message is still showing.
/// Returns whether there was anything to put back.
bool undoLast() {
  final undo = _undo;
  undo?.call();
  return undo != null;
}

// Async actions look the messenger up before their first await, so they can
// still report after the widget that started them is gone.
void notify(ScaffoldMessengerState messenger, String message) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
