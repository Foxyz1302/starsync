import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:signals/signals_flutter.dart';

// Files source state, one Hive box: the folders the user added and the
// local files played last. Same shape as AppSettings: signals start empty,
// take the stored values once [FolderStore.ensureLoaded] finishes, and
// mutators write through.

const filesBoxName = 'files';

const _keyFolders = 'folders';
const _keyRecent = 'recent';

/// Recent files kept, most recent first.
const maxRecentFiles = 30;

class FolderStore {
  static final FolderStore instance = FolderStore();

  /// Watched folders, in the order they were added.
  final folders = signal<List<String>>(const []);
  /// Local files played, most recent first, no duplicates.
  final recent = signal<List<String>>(const []);

  Future<void>? _load;
  Box? _box;

  Future<void> ensureLoaded() => _load ??= _loadNow();

  Future<void> _loadNow() async {
    try {
      final box = _box = await Hive.openBox(filesBoxName);
      final f = box.get(_keyFolders);
      if (f is List) folders.value = List.unmodifiable(f.whereType<String>());
      final r = box.get(_keyRecent);
      if (r is List) {
        recent.value = List.unmodifiable(
            r.whereType<String>().toSet().take(maxRecentFiles));
      }
    } catch (e, st) {
      debugPrint('load files store failed: $e\n$st');
    }
  }

  /// False when [dir] is already watched.
  bool addFolder(String dir) {
    if (folders.value.contains(dir)) return false;
    _setFolders([...folders.value, dir]);
    return true;
  }

  void removeFolder(String dir) =>
      _setFolders([...folders.value.where((d) => d != dir)]);

  /// Moves [path] to the top of [recent].
  void addRecent(String path) => _setRecent(
      [path, ...recent.value.where((p) => p != path)].take(maxRecentFiles));

  void removeRecent(String path) =>
      _setRecent(recent.value.where((p) => p != path));

  void clearRecent() => _setRecent(const []);

  void _setFolders(List<String> list) {
    folders.value = List.unmodifiable(list);
    _put(_keyFolders, [...list]);
  }

  void _setRecent(Iterable<String> list) {
    recent.value = List.unmodifiable(list);
    _put(_keyRecent, [...recent.value]);
  }

  Future<void> _put(String key, Object value) async {
    try {
      final box = _box ??
          (Hive.isBoxOpen(filesBoxName) ? Hive.box(filesBoxName) : null);
      await box?.put(key, value);
    } catch (e, st) {
      debugPrint('save files store $key failed: $e\n$st');
    }
  }
}
