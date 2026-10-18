import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app's own `.instance` singletons and how often `lib` reaches for
/// each. Systems get their dependencies through the composition root
/// (`AppGraph`, widgets through `AppScope`); this list may only shrink.
/// Lower a number when a use goes; never raise one or add a class.
const baseline = {
  'AppSettings': 47,
  'JellyfinAccounts': 10,
  'UpdateController': 8,
  'Profile': 8,
  'FolderStore': 6,
  'AppYtDlp': 2,
  'RecentLinks': 3,
};

void main() {
  test('no new .instance singletons, and no more uses of the old ones', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    final sources = [for (final f in files) f.readAsStringSync()];
    // The app's own classes (framework singletons like
    // `WidgetsBinding.instance` are not counted).
    final classes = {
      for (final s in sources)
        for (final m in RegExp(r'^(?:abstract |final |base )*class (\w+)', multiLine: true).allMatches(s)) m.group(1)!,
    };
    final counts = <String, int>{};
    for (final s in sources) {
      for (final m in RegExp(r'\b([A-Z]\w*)\.instance\b').allMatches(s)) {
        final name = m.group(1)!;
        if (classes.contains(name)) counts[name] = (counts[name] ?? 0) + 1;
      }
    }
    final grown = {
      for (final e in counts.entries)
        if (e.value > (baseline[e.key] ?? 0)) e.key: '${e.value} (baseline ${baseline[e.key] ?? 'none'})',
    };
    expect(grown, isEmpty,
        reason: 'pass the system in through AppGraph / AppScope instead of a new `.instance` use or singleton');
  });
}
