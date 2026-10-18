import 'package:flutter_test/flutter_test.dart';
import 'package:reqorb/document/memory_document.dart';

import 'document_conformance.dart';

void main() {
  group('MemoryDocument', () {
    documentConformance(
      (text) async => MemoryDocument(text),
      MemoryDocument.open,
    );
  });
}
