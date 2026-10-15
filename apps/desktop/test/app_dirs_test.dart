import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/files/folder_store.dart' show filesBoxName;
import 'package:starsync/src/jellyfin/accounts.dart' show jellyfinBoxName;
import 'package:starsync/src/jellyfin/track_prefs.dart' show trackPrefsBoxName;
import 'package:starsync/src/platform/data_migration.dart';
import 'package:starsync/src/platform/ports/app_dirs.dart';
import 'package:starsync/src/state/connect_prefs.dart' show connectFormBoxName;
import 'package:starsync/src/state/settings.dart' show settingsBoxName;

void main() {
  final sep = Platform.pathSeparator;
  const support = '/s';

  group('AppDirs', () {
    test('no profile: Hive and logs in the support folder', () {
      final d = AppDirs.fromEnv(support: support, env: const {});
      expect(d.profile, isNull);
      expect(d.hive, '$support${sep}hive');
      expect(d.logs, '$support${sep}logs');
    });

    test('a profile gets its own Hive and logs folders', () {
      final d = AppDirs.fromEnv(support: support, env: const {profileEnv: 'b'});
      expect(d.profile, 'b');
      expect(d.hive, '$support${sep}profiles${sep}b${sep}hive');
      expect(d.logs, '$support${sep}profiles${sep}b${sep}logs');
      expect(d.support, support, reason: 'yt-dlp and shaders stay shared');
    });

    test('an unusable name is ignored and reported', () {
      for (final bad in ['../x', 'a b', 'x' * 33, 'é']) {
        final env = {profileEnv: bad};
        expect(AppDirs.fromEnv(support: support, env: env).profile, isNull, reason: bad);
        expect(AppDirs.invalidProfile(env), bad);
      }
      expect(AppDirs.invalidProfile(const {profileEnv: ''}), isNull, reason: 'empty is just unset');
      expect(AppDirs.invalidProfile(const {profileEnv: 'ok_1-2'}), isNull);
    });
  });

  test('the migrated boxes are the ones the app opens', () {
    expect(appHiveBoxes.toSet(),
        {settingsBoxName, connectFormBoxName, filesBoxName, jellyfinBoxName, trackPrefsBoxName});
  });

  test('old support folders next to the new one', () {
    expect(legacySupportDirs('/home/u/.local/share/dev.foxyz.starsync', windows: false), [
      '/home/u/.local/share/moe.senkochan.watch_together',
      '/home/u/.local/share/watch_together',
    ]);
    expect(legacySupportDirs(r'C:\Users\u\AppData\Roaming\foxyz\Starsync', windows: true),
        [r'C:\Users\u\AppData\Roaming\com.example\watch_together']);
  });

  group('migration from before the rename', () {
    late Directory home;
    late String share, oldSupport, support, docs, hive;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('starsync-mig');
      share = '${home.path}/.local/share';
      oldSupport = '$share/moe.senkochan.watch_together';
      support = '$share/dev.foxyz.starsync';
      docs = '${home.path}/Documents';
      hive = '$support/hive';
      // The old support folder as 1.2.x left it.
      await Directory('$oldSupport/yt-dlp').create(recursive: true);
      await File('$oldSupport/yt-dlp/cookies.txt').writeAsString('# Netscape cookies');
      await File('$oldSupport/yt-dlp/yt-dlp').writeAsString('bin');
      await Directory('$oldSupport/logs').create();
      await File('$oldSupport/logs/app-2026-01-01.log').writeAsString('log');
      await Directory('$oldSupport/shaders').create();
      await File('$oldSupport/shaders/a.glsl').writeAsString('shader');
      await Directory('$oldSupport/profiles/b/hive').create(recursive: true);
      await File('$oldSupport/profiles/b/hive/settings.hive').writeAsString('b-settings');
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', '$oldSupport/yt-dlp/cookies.txt']);
        await Process.run('chmod', ['755', '$oldSupport/yt-dlp/yt-dlp']);
        await Link('$oldSupport/yt-dlp/current').create('yt-dlp');
      }
      // The documents folder: this app's boxes and another app's.
      await Directory(docs).create(recursive: true);
      for (final n in ['settings', 'jellyfin', 'files', 'track_prefs', 'connect_form', 'app', 'credentials']) {
        await File('$docs/$n.hive').writeAsString('$n-data');
        await File('$docs/$n.lock').writeAsString('');
      }
      // path_provider creates the new folder before the app looks.
      await Directory(support).create(recursive: true);
    });

    tearDown(() => home.delete(recursive: true));

    Future<List<String>> migrate() => migrateLegacyData(
        support: support, hive: hive, oldSupport: legacySupportDirs(support, windows: false), documents: docs);

    test('copies the support folder and only this app\'s boxes, once', () async {
      final lines = await migrate();
      expect(lines, hasLength(2));
      expect(lines.first, contains(oldSupport));
      expect(lines.last, contains('5 Hive boxes'));
      expect(lines.join(), isNot(contains('Netscape')), reason: 'paths and counts, never contents');

      expect(await File('$support/yt-dlp/cookies.txt').readAsString(), '# Netscape cookies');
      expect(await File('$support/logs/app-2026-01-01.log').readAsString(), 'log');
      expect(await File('$support/shaders/a.glsl').readAsString(), 'shader');
      expect(await File('$support/profiles/b/hive/settings.hive').readAsString(), 'b-settings',
          reason: 'profiles come along with the support folder');
      if (!Platform.isWindows) {
        expect(File('$support/yt-dlp/cookies.txt').statSync().mode & 0x1ff, 0x180, reason: '0600 kept');
        expect(File('$support/yt-dlp/yt-dlp').statSync().mode & 0x40, isNonZero, reason: 'exec bit kept');
        expect(await Link('$support/yt-dlp/current').target(), 'yt-dlp');
      }
      for (final n in appHiveBoxes) {
        expect(await File('$hive/$n.hive').readAsString(), '$n-data');
        expect(File('$hive/$n.lock').existsSync(), isTrue);
      }
      expect(File('$hive/app.hive').existsSync(), isFalse);
      expect(File('$hive/credentials.hive').existsSync(), isFalse);
      // Copied, not moved: 1.2.x keeps working.
      expect(File('$docs/settings.hive').existsSync(), isTrue);
      expect(File('$oldSupport/yt-dlp/cookies.txt').existsSync(), isTrue);

      final marker = jsonDecode(File('$support/$migrationMarker').readAsStringSync()) as Map;
      expect(marker['migratedFrom'], oldSupport);
      expect(marker['hiveFrom'], docs);
      expect(marker['files'], greaterThan(0));

      // Once: a later change on the old side is not copied again.
      await File('$docs/settings.hive').writeAsString('changed by 1.2.x');
      await File('$hive/settings.hive').delete();
      expect(await migrate(), isEmpty);
      expect(File('$hive/settings.hive').existsSync(), isFalse);
    });

    test('never overwrites what the new folder already has', () async {
      await Directory(hive).create(recursive: true);
      await File('$hive/settings.hive').writeAsString('new');
      await Directory('$support/yt-dlp').create();
      await File('$support/yt-dlp/cookies.txt').writeAsString('new cookies');
      await migrate();
      expect(await File('$hive/settings.hive').readAsString(), 'new');
      expect(await File('$support/yt-dlp/cookies.txt').readAsString(), 'new cookies');
      expect(await File('$hive/jellyfin.hive').readAsString(), 'jellyfin-data');
    });

    test('a fresh install finds nothing and still marks it done', () async {
      await Directory(oldSupport).delete(recursive: true);
      await Directory(docs).delete(recursive: true);
      expect(await migrate(), ['migration: no data from before the rename']);
      final marker = jsonDecode(File('$support/$migrationMarker').readAsStringSync()) as Map;
      expect(marker['migratedFrom'], isNull);
      expect(marker['hiveFrom'], isNull);
    });
  });
}
