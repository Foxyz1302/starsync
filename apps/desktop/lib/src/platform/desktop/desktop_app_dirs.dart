import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../data_migration.dart';
import '../ports/app_dirs.dart';

/// The desktop's [AppDirsPort]: the app support folder from path_provider
/// (Linux `$XDG_DATA_HOME/dev.foxyz.starsync`, Windows
/// `%APPDATA%\foxyz\Starsync`); on the first start it copies the data of
/// the old names in ([migrateLegacyData]). Needs Flutter's binding.
class DesktopAppDirs implements AppDirsPort {
  const DesktopAppDirs();

  @override
  Future<AppDirs> resolve() async {
    final support = (await getApplicationSupportDirectory()).path;
    final base = AppDirs.fromEnv(support: support, env: const {});
    List<String> migrated;
    try {
      String? documents;
      try {
        // Where Hive.initFlutter() kept the boxes up to 1.2.x.
        documents = (await getApplicationDocumentsDirectory()).path;
      } catch (_) {}
      migrated = await migrateLegacyData(
          support: support, hive: base.hive, oldSupport: legacySupportDirs(support), documents: documents);
    } catch (e) {
      migrated = ['migration failed: $e'];
    }
    final dirs = AppDirs.fromEnv(support: support, env: Platform.environment, migrated: migrated);
    await Directory(dirs.hive).create(recursive: true);
    return dirs;
  }
}
