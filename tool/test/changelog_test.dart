import 'dart:io';

import 'package:test/test.dart';

import '../changelog.dart';

const _sample = '''# Changelog

Intro text.

## Unreleased

Summary of the next one,
over two lines.

### Added

- Danmaku style notifications
+ Bilibili style chat box
  that wraps

### Fixed

- Optimized relay

## 1.0.0

### Fixed

- Various bug fixes
''';

void main() {
  test('parses sections, summaries, items and wrapped items', () {
    final log = Changelog.parse(_sample);
    expect(log.sections.map((s) => s.title), ['Unreleased', '1.0.0']);
    final next = log.section('unreleased')!;
    expect(next.summary, 'Summary of the next one, over two lines.');
    expect(next.of('Added'), ['Danmaku style notifications', 'Bilibili style chat box that wraps']);
    expect(next.of('Changed'), isEmpty);
    expect(next.of('Fixed'), ['Optimized relay']);
    expect(next.toManifest(), {
      'notes': 'Summary of the next one, over two lines.',
      'changes': {
        'added': ['Danmaku style notifications', 'Bilibili style chat box that wraps'],
        'changed': <String>[],
        'fixed': ['Optimized relay'],
      },
    });
    // No summary: the first items.
    expect(log.section('1.0.0')!.notes, 'Various bug fixes');
  });

  test('cut: Unreleased becomes the version, a fresh empty one on top', () {
    final cut = Changelog.parse(_sample).cutRelease('1.1.0');
    final log = Changelog.parse(cut);
    expect(log.sections.map((s) => s.title), ['Unreleased', '1.1.0', '1.0.0']);
    expect(log.section('Unreleased')!.isEmpty, isTrue);
    expect(log.section('1.1.0')!.of('Added'), hasLength(2));
    expect(log.preamble, contains('Intro text.'));
    expect(cut, contains(freshUnreleased));
    // Nothing new: no release.
    expect(() => log.cutRelease('1.2.0'), throwsStateError);
    expect(() => Changelog.parse(_sample).cutRelease('1.0.0'), throwsStateError);
  });

  test('rejects unknown kinds and stray text', () {
    expect(() => Changelog.parse('## 1.0.0\n\n### Removed\n\n- x\n'), throwsFormatException);
    expect(() => Changelog.parse('## 1.0.0\n\n- no kind\n'), throwsFormatException);
    expect(() => Changelog.parse('## 1.0.0\n\n### Fixed\n\nprose\n'), throwsFormatException);
  });

  test('release body: heading, summary, lists', () {
    final body = Changelog.parse(_sample).section('unreleased')!.releaseBody('1.1.0');
    expect(body, startsWith('## Starsync 1.1.0\n\nSummary of the next one'));
    expect(body, contains('### Added\n\n- Danmaku style notifications\n'));
    expect(body, isNot(contains('### Changed')));
  });

  test("the repo's CHANGELOG.md parses and has an Unreleased section", () {
    final log = Changelog.parse(File('../CHANGELOG.md').readAsStringSync());
    expect(log.sections.first.title, unreleased);
    expect(log.section('1.3.0')!.of('Added'), isNotEmpty);
  });
}
