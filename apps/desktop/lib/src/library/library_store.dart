import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

// Where the library's matches live (device-owned, one Hive box): AniList
// entries seen, automatic matches, the user's pins and episode offsets.
// Plain JSON-ish values under string keys; reads are synchronous once
// loaded, writes go through.

const libraryBoxName = 'library';

abstract interface class LibraryStore {
  /// Loads the stored values (once).
  Future<void> ensureLoaded();
  Object? get(String key);
  void put(String key, Object value);
  void delete(String key);

  /// Every key starting with [prefix].
  Iterable<String> keys(String prefix);
}

/// For tests and as the fallback when Hive is not available.
class MemoryLibraryStore implements LibraryStore {
  final Map<String, Object> values;
  MemoryLibraryStore([Map<String, Object>? values]) : values = values ?? {};

  @override
  Future<void> ensureLoaded() async {}
  @override
  Object? get(String key) => values[key];
  @override
  void put(String key, Object value) => values[key] = value;
  @override
  void delete(String key) => values.remove(key);
  @override
  Iterable<String> keys(String prefix) => values.keys.where((k) => k.startsWith(prefix)).toList();
}

/// The `library` box; until it opens (or when it cannot) it acts as an
/// empty memory store, so matching still works for the run.
class HiveLibraryStore implements LibraryStore {
  Box? _box;
  final _memory = MemoryLibraryStore();
  Future<void>? _load;

  @override
  Future<void> ensureLoaded() => _load ??= () async {
        try {
          final box = _box = await Hive.openBox(libraryBoxName);
          // Writes made before the box opened.
          for (final e in _memory.values.entries) {
            await box.put(e.key, e.value);
          }
          _memory.values.clear();
        } catch (e, st) {
          debugPrint('open library store failed: $e\n$st');
        }
      }();

  @override
  Object? get(String key) => _box?.get(key) ?? _memory.get(key);

  @override
  void put(String key, Object value) {
    final box = _box;
    if (box == null) return _memory.put(key, value);
    box.put(key, value).catchError((Object e) => debugPrint('library store put $key: $e'));
  }

  @override
  void delete(String key) {
    _memory.delete(key);
    _box?.delete(key).catchError((Object e) => debugPrint('library store delete $key: $e'));
  }

  @override
  Iterable<String> keys(String prefix) => [
        ...?_box?.keys.whereType<String>().where((k) => k.startsWith(prefix)),
        ..._memory.keys(prefix),
      ];
}
