/// Short messages shown at the bottom of the window.
library;

import 'package:flutter/material.dart';

void showMessage(BuildContext context, String message) =>
    notify(ScaffoldMessenger.of(context), message);

/// Reports something that was just removed and offers to put it back.
void showUndo(BuildContext context, String message, VoidCallback undo) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: 'Undo', onPressed: undo),
      ),
    );
}

// Async actions look the messenger up before their first await, so they can
// still report after the widget that started them is gone.
void notify(ScaffoldMessengerState messenger, String message) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
