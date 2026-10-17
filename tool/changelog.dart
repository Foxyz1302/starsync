// CHANGELOG.md, read and cut for releases (docs/DEVELOPMENT.md,
// "Changelog"). The file: `## Unreleased`, then `## X.Y.Z` sections newest
// first; each has an optional one-paragraph summary and `### Added` /
// `### Changed` / `### Fixed` lists of `- ` items.
// Usage: dart tool/changelog.dart cut X.Y.Z
//          (tool/release.sh: Unreleased becomes X.Y.Z, a fresh empty
//          Unreleased on top; fails when Unreleased has no items)
//        dart tool/changelog.dart json <X.Y.Z|unreleased>
//          (the manifest's {"notes": "...", "changes": {...}})
//        dart tool/changelog.dart markdown <X.Y.Z|unreleased> [X.Y.Z]
//          (the release page's body; the last argument names the version
//          when it is not the section's own)
// dart: imports only — runs without `pub get` (tool/release_publish.dart
// imports it).
import 'dart:convert';
import 'dart:io';

const unreleased = 'Unreleased';
const kinds = ['Added', 'Changed', 'Fixed'];

/// The empty section [cutRelease] puts on top.
const freshUnreleased = '## $unreleased\n\n### Added\n\n### Changed\n\n### Fixed\n';

class ChangelogSection {
  /// `Unreleased` or a version.
  final String title;
  /// The paragraph under the heading, one line ('' when there is none).
  final String summary;
  /// [kinds] name -> items, in file order.
  final Map<String, List<String>> items;
  const ChangelogSection(this.title, this.summary, this.items);

  List<String> of(String kind) => items[kind] ?? const [];
  bool get isEmpty => kinds.every((k) => of(k).isEmpty);

  /// One line for apps that read only `notes` (1.2.x, 1.3.x): the summary,
  /// else the first items.
  String get notes {
    if (summary.isNotEmpty) return summary;
    final all = [for (final k in kinds) ...of(k)];
    final head = all.take(3).join('; ');
    return all.length > 3 ? '$head; and more' : head;
  }

  Map<String, Object?> toManifest() => {
        'notes': notes,
        'changes': {for (final k in kinds) k.toLowerCase(): of(k)},
      };

  /// The section as written in CHANGELOG.md under [heading].
  String render([String? heading]) {
    final b = StringBuffer('## ${heading ?? title}\n');
    if (summary.isNotEmpty) b.write('\n$summary\n');
    for (final k in kinds) {
      if (of(k).isEmpty) continue;
      b.write('\n### $k\n\n');
      for (final item in of(k)) {
        b.write('- $item\n');
      }
    }
    return b.toString();
  }

  /// The release page's body.
  String releaseBody(String version) {
    final b = StringBuffer('## Starsync $version\n');
    if (summary.isNotEmpty) b.write('\n$summary\n');
    for (final k in kinds) {
      if (of(k).isEmpty) continue;
      b.write('\n### $k\n\n');
      for (final item in of(k)) {
        b.write('- $item\n');
      }
    }
    b.write('\nIn the app: Update and restart in the band at the top, or Settings → Updates → Check now. '
        'New here: download the archive for your system below.\n');
    return b.toString();
  }
}

class Changelog {
  /// Everything before the first `## ` heading.
  final String preamble;
  final List<ChangelogSection> sections;
  const Changelog(this.preamble, this.sections);

  /// [title] `unreleased` (any case) or a version; null when missing.
  ChangelogSection? section(String title) {
    final want = title.toLowerCase();
    for (final s in sections) {
      if (s.title.toLowerCase() == want) return s;
    }
    return null;
  }

  static Changelog parse(String text) {
    final lines = const LineSplitter().convert(text);
    final pre = StringBuffer();
    final sections = <ChangelogSection>[];
    String? title;
    var summary = <String>[];
    var items = <String, List<String>>{};
    String? kind;
    void close() {
      if (title != null) sections.add(ChangelogSection(title, summary.join(' ').trim(), items));
    }

    for (final (n, raw) in lines.indexed) {
      final line = raw.trimRight();
      FormatException bad(String why) => FormatException('CHANGELOG.md line ${n + 1}: $why: "$line"');
      if (line.startsWith('## ')) {
        close();
        title = line.substring(3).trim();
        if (title.toLowerCase() == unreleased.toLowerCase()) title = unreleased;
        summary = [];
        items = {};
        kind = null;
      } else if (title == null) {
        pre.writeln(raw);
      } else if (line.startsWith('### ')) {
        final name = line.substring(4).trim();
        kind = kinds.where((k) => k.toLowerCase() == name.toLowerCase()).firstOrNull ??
            (throw bad('a section is ${kinds.join(' / ')}'));
        if (items.containsKey(kind)) throw bad('$kind twice');
        items[kind] = [];
      } else if (RegExp(r'^[-+*] ').hasMatch(line)) {
        if (kind == null) throw bad('an item needs ${kinds.join(' / ')} above it');
        items[kind]!.add(line.substring(2).trim());
      } else if (line.isEmpty) {
        continue;
      } else if (kind != null && raw.startsWith('  ') && items[kind]!.isNotEmpty) {
        final list = items[kind]!;
        list[list.length - 1] = '${list.last} ${line.trim()}';
      } else if (kind == null) {
        summary.add(line.trim());
      } else {
        throw bad('expected a "- " item');
      }
    }
    close();
    return Changelog(pre.toString(), sections);
  }

  /// [version] takes Unreleased's items; a fresh, empty Unreleased goes on
  /// top. Throws when Unreleased is missing or empty or [version] is there.
  String cutRelease(String version) {
    final next = section(unreleased);
    if (next == null) throw StateError('CHANGELOG.md has no "## $unreleased" section');
    if (next.isEmpty) {
      throw StateError('CHANGELOG.md: "## $unreleased" has no items — '
          'add what changed for people before cutting $version');
    }
    if (section(version) != null) throw StateError('CHANGELOG.md already has "## $version"');
    final b = StringBuffer(preamble.trimRight())..write('\n\n$freshUnreleased');
    for (final s in sections) {
      b.write('\n${s.title == unreleased ? s.render(version) : s.render()}');
    }
    return b.toString();
  }
}

Future<void> main(List<String> args) async {
  final markdown = args.length == 3 && args[0] == 'markdown';
  if ((args.length != 2 && !markdown) || !const ['cut', 'json', 'markdown'].contains(args[0])) {
    _die('usage: dart tool/changelog.dart cut X.Y.Z\n'
        '       dart tool/changelog.dart json <X.Y.Z|unreleased>\n'
        '       dart tool/changelog.dart markdown <X.Y.Z|unreleased> [X.Y.Z]');
  }
  final root = File.fromUri(Platform.script).parent.parent.path;
  final file = File('$root/CHANGELOG.md');
  if (!file.existsSync()) _die('missing ${file.path}');
  final Changelog log;
  try {
    log = Changelog.parse(file.readAsStringSync());
  } on FormatException catch (e) {
    _die(e.message);
  }
  final [cmd, which, ...rest] = args;
  switch (cmd) {
    case 'cut':
      if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(which)) _die('version must look like 1.3.3, got $which');
      try {
        file.writeAsStringSync(log.cutRelease(which));
      } on StateError catch (e) {
        _die(e.message);
      }
      stdout.writeln('CHANGELOG.md: $unreleased is now $which');
    case 'json':
      stdout.writeln(jsonEncode((log.section(which) ?? _die('CHANGELOG.md has no "## $which"')).toManifest()));
    case 'markdown':
      final s = log.section(which) ?? _die('CHANGELOG.md has no "## $which"');
      stdout.write(s.releaseBody(rest.firstOrNull ?? which));
  }
}

Never _die(String msg) {
  stderr.writeln('error: $msg');
  exit(1);
}
