// restructure: rewrite in step R (Rename): Hive moves into the support
// folder for the normal app too.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/platform/app_dirs.dart';

void main() {
  final sep = Platform.pathSeparator;
  const support = '/s';

  test('no profile: today\'s layout', () {
    final d = AppDirs.fromEnv(support: support, env: const {});
    expect(d.profile, isNull);
    expect(d.hive, isNull, reason: "Hive's default folder");
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
}
