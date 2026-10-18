import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:starsync/src/state/settings_schema.dart';

void main() {
  group('settings schema', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('starsync-schema');
      Hive.init(dir.path);
    });
    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test('a box without a version is at 1, runs the steps and gets stamped', () async {
      final box = await Hive.openBox('settings');
      expect(await migrateSettings(box), hasLength(settingsSchemaVersion - 1));
      expect(box.get(settingsSchemaKey), settingsSchemaVersion);
      expect(await migrateSettings(box), isEmpty);
    });

    test('2: the idle switch gives way to auto sit-out, on', () async {
      for (final old in [true, false]) {
        final box = await Hive.openBox('settings');
        await box.put('idleSitsOut', old);
        await migrateSettings(box);
        expect(box.containsKey('idleSitsOut'), isFalse);
        expect(box.get('autoSitOut'), isTrue);
        await box.deleteFromDisk();
      }
      final kept = await Hive.openBox('settings');
      await kept.putAll({'idleSitsOut': true, 'autoSitOut': false});
      await migrateSettings(kept);
      expect(kept.get('autoSitOut'), isFalse, reason: 'a choice already made stays');
    });

    test('3: the video volume is kept; a stored value that is not a number goes', () async {
      final box = await Hive.openBox('settings');
      await box.putAll({settingsSchemaKey: 2, 'playerVolume': 'loud'});
      await migrateSettings(box);
      expect(box.containsKey('playerVolume'), isFalse);
      await box.putAll({settingsSchemaKey: 2, 'playerVolume': 40.0});
      await migrateSettings(box);
      expect(box.get('playerVolume'), 40.0);
    });

    test('steps run in order, only past the stored version', () async {
      final box = await Hive.openBox('settings');
      await box.put(settingsSchemaKey, 1);
      await box.put('old', 'x');
      final order = <int>[];
      final steps = [
        SettingsMigration(3, 'c', (b) async {
          order.add(3);
          await b.put('c', b.get('new'));
        }),
        SettingsMigration(2, 'rename old to new', (b) async {
          order.add(2);
          await b.put('new', b.get('old'));
          await b.delete('old');
        }),
        SettingsMigration(4, 'not yet', (b) async => order.add(4)),
      ];
      final ran = await migrateSettings(box, steps: steps, current: 3);
      expect(order, [2, 3]);
      expect(ran, ['settings schema 2: rename old to new', 'settings schema 3: c']);
      expect(box.get('c'), 'x');
      expect(box.get(settingsSchemaKey), 3);
      expect(await migrateSettings(box, steps: steps, current: 3), isEmpty);
    });

    test('a box from a newer build is left as it is', () async {
      final box = await Hive.openBox('settings');
      await box.put(settingsSchemaKey, 9);
      expect(await migrateSettings(box), hasLength(1));
      expect(box.get(settingsSchemaKey), 9);
    });
  });
}
