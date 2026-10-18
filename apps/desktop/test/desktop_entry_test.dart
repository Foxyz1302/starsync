import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/platform/desktop_entry.dart';

void main() {
  test('writes the Starsync entry, removes only the old id\'s files', () async {
    final tmp = await Directory.systemTemp.createTemp('starsync-entry');
    try {
      final root = '${tmp.path}/install';
      await Directory('$root/lib').create(recursive: true);
      await Directory('$root/data/flutter_assets/assets/icon').create(recursive: true);
      await File('$root/data/flutter_assets/assets/icon/icon_48.png').writeAsString('png');
      final share = '${tmp.path}/share';
      final apps = Directory('$share/applications')..createSync(recursive: true);
      final oldEntry = File('${apps.path}/$legacyAppId.desktop')..writeAsStringSync('old');
      final other = File('${apps.path}/other.app.desktop')..writeAsStringSync('keep');
      final oldIcon = File('$share/icons/hicolor/48x48/apps/$legacyAppId.png')
        ..createSync(recursive: true);
      final otherIcon = File('$share/icons/hicolor/48x48/apps/other.png')..createSync();

      final registered = <String>[];
      await installDesktopEntry(
          executable: '$root/starsync',
          dataHome: share,
          force: true,
          registerScheme: (file, dir) async => registered.add('$file in $dir'));

      expect(oldEntry.existsSync(), isFalse);
      expect(oldIcon.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      expect(otherIcon.existsSync(), isTrue);
      final entry = File('${apps.path}/dev.foxyz.starsync.desktop').readAsStringSync();
            expect(entry, contains('StartupWMClass=dev.foxyz.starsync'));
      expect(entry, contains('Icon=dev.foxyz.starsync'));
      // starsync:// links: the entry takes them and becomes their default.
      expect(entry, contains('Exec="$root/starsync" %u'));
      expect(entry, contains('MimeType=x-scheme-handler/starsync;'));
      expect(entry, contains('StartupNotify=true'));
      expect(registered, ['dev.foxyz.starsync.desktop in ${apps.path}']);
      expect(File('$share/icons/hicolor/48x48/apps/dev.foxyz.starsync.png').existsSync(), isTrue);
    } finally {
      await tmp.delete(recursive: true);
    }
  }, skip: Platform.isLinux ? null : 'Linux launcher entry');
}
