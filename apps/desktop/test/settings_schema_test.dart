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

    test('a box without a version is at 1 and gets stamped', () async {
      final box = await Hive.openBox('settings');
      expect(await migrateSettings(box), isEmpty);
      expect(box.get(settingsSchemaKey), settingsSchemaVersion);
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
