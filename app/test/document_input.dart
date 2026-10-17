/// Typing into a [DocumentView] as the platform's input method does,
/// for widget tests.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the input method was last told.
TextEditingValue told(WidgetTester tester) =>
    TextEditingValue.fromJSON(tester.testTextInput.editingState!);

/// Sends what an input method sends: [text] in place of [start] to
/// [end] of what it was told (the selection, if not given), the caret
/// after it, and [composing] as the text it is still composing.
Future<void> input(
  WidgetTester tester,
  String text, {
  int? start,
  int? end,
  TextRange composing = TextRange.empty,
}) async {
  final value = told(tester);
  final from = start ?? value.selection.start;
  final to = end ?? value.selection.end;
  final client = tester.testTextInput.log
      .lastWhere((call) => call.method == 'TextInput.setClient')
      .arguments[0];
  final delta = {
    'oldText': value.text,
    'deltaText': text,
    'deltaStart': from,
    'deltaEnd': to,
    'selectionBase': from + text.length,
    'selectionExtent': from + text.length,
    'selectionAffinity': 'TextAffinity.downstream',
    'selectionIsDirectional': false,
    'composingBase': composing.start,
    'composingExtent': composing.end,
  };
  // The platform holds what it sent, unless the view tells it otherwise.
  tester.testTextInput.editingState = TextEditingValue(
    text: value.text.replaceRange(from, to, text),
    selection: TextSelection.collapsed(offset: from + text.length),
    composing: composing,
  ).toJSON();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(
      MethodCall('TextInputClient.updateEditingStateWithDeltas', [
        client,
        {
          'deltas': [delta],
        },
      ]),
    ),
    (_) {},
  );
  await tester.pump();
}
