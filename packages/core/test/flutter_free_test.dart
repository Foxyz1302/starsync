import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('core has zero flutter imports', () async {
    final libDir = Directory('lib');
    final offenders = <String>[];
    await for (final entity in libDir.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final content = await entity.readAsString();
      if (content.contains('package:flutter/') ||
          content.contains('dart:ui') ||
          content.contains('package:signals/signals_flutter')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty, reason: 'Flutter imports in core: $offenders');
  });
}
