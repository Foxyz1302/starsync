import 'dart:io' show FileStat;

import '../../files/scanner.dart' show FolderScan;

/// The user's folders and files: picking them, listing videos, looking a
/// path up. Paths for now; a platform without them (Android's tree URIs)
/// brings its own implementation.
abstract interface class FolderAccess {
  /// The system folder dialog; null when cancelled.
  Future<String?> pickFolder({required String dialogTitle});

  /// The system file dialog limited to [extensions]; the picked paths
  /// (empty when cancelled).
  Future<List<String>> pickFiles({required String dialogTitle, required List<String> extensions});

  /// The videos under [dir] (see [FolderScan]); never throws.
  Future<FolderScan> scan(String dir);

  /// Whether the folder [dir] exists.
  bool folderExists(String dir);

  /// Size and dates of [path]; throws when it is gone.
  Future<FileStat> stat(String path);

  /// Shows the folder [dir] in the file manager; false when nothing
  /// opened it.
  Future<bool> reveal(String dir);

  /// Where screenshots are saved (Pictures / Starsync); it may not
  /// exist yet.
  Future<String> screenshotFolder();
}
