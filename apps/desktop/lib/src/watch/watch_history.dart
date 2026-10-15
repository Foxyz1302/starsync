import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

// The device's watch history (device-owned, one Hive box): what this app
// watched of files and links, by [WatchKey], with the verdict of the
// watched rule (`WatchSession`, D3). Jellyfin keeps its own (reported by
// `JellyfinProgressReporter`); AniList later reads the tracker's records.
// See ARCHITECTURE.md "Watch tracking".

const watchHistoryBoxName = 'watch_history';

/// What a watch is about, independent of the opening: a file by its path
/// on this computer, a link by its URL, a Jellyfin item by its ids, else
/// the media's name and size (someone else's file, a link passed on).
class WatchKey {
  final String value;
  const WatchKey._(this.value);

  factory WatchKey.file(String path) => WatchKey._('file:$path');
  factory WatchKey.link(String url) => WatchKey._('link:$url');
  factory WatchKey.jellyfin(JellyfinRef ref) => WatchKey._('jf:${ref.serverId}/${ref.itemId}');
  factory WatchKey.media(String name, int size) => WatchKey._('media:$name|$size');

  bool get isJellyfin => value.startsWith('jf:');

  /// The key of `state.media` [media]: [ownFile] / [ownLink] when this app
  /// put it up from there, else its Jellyfin ref, its shared link, its
  /// name and size.
  static WatchKey? of(Map<String, Object?>? media, {String? ownFile, String? ownLink}) {
    if (media == null) return null;
    if (ownFile != null) return WatchKey.file(ownFile);
    final jf = media['jellyfin'];
    if (jf is Map) {
      final ref = JellyfinRef.fromJson(Map<String, Object?>.from(jf));
      if (ref.serverId.isNotEmpty && ref.itemId.isNotEmpty) return WatchKey.jellyfin(ref);
    }
    if (ownLink != null) return WatchKey.link(ownLink);
    final url = media['url'];
    if (url is String && (url.startsWith('http://') || url.startsWith('https://'))) return WatchKey.link(url);
    final name = media['name'];
    final size = media['size'];
    return WatchKey.media(name is String ? name : '', size is num ? size.toInt() : 0);
  }

  @override
  bool operator ==(Object other) => other is WatchKey && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// One closed watch: what the tracker hands its sinks (the device history,
/// AniList later).
class WatchRecord {
  final WatchKey key;
  final String title;
  final MediaRef? ref;
  final WatchVerdict verdict;
  /// Seconds the media played while this viewer was In, and its runtime
  /// (0 when unknown).
  final double timeIn;
  final double runtime;
  final DateTime at;
  const WatchRecord({
    required this.key,
    required this.title,
    required this.verdict,
    required this.timeIn,
    required this.runtime,
    required this.at,
    this.ref,
  });

  @override
  String toString() => 'WatchRecord($key, $verdict, ${timeIn.round()} s In of ${runtime.round()} s)';
}

/// What the history holds for a key: watched (played), or where to
/// resume, and when.
class WatchEntry {
  final bool played;
  /// Seconds; 0 when played or none.
  final double resumeAt;
  final String title;
  final MediaRef? ref;
  final DateTime at;
  const WatchEntry({required this.played, this.resumeAt = 0, this.title = '', this.ref, required this.at});

  Map<String, Object?> toJson() => {
        'played': played,
        if (resumeAt > 0) 'resumeAt': resumeAt,
        if (title.isNotEmpty) 'title': title,
        if (ref != null) 'ref': ref!.toJson(),
        'at': at.toUtc().toIso8601String(),
      };

  static WatchEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    if (at == null) return null;
    final resume = j['resumeAt'];
    MediaRef? ref;
    try {
      ref = MediaRef.fromJson(j['ref']);
    } catch (_) {}
    return WatchEntry(
      played: j['played'] == true,
      resumeAt: resume is num && resume.isFinite && resume > 0 ? resume.toDouble() : 0,
      title: j['title'] is String ? j['title'] as String : '',
      ref: ref,
      at: at,
    );
  }
}

/// The device's watch history: [entry] per key, [record] from the
/// tracker. [revision] bumps on every change (pages that show it listen).
class WatchHistory {
  final Map<String, Object?> _memory = {};
  /// False: memory only (tests).
  final bool persist;
  Box? _box;
  Future<void>? _load;
  final revision = signal(0);

  WatchHistory({this.persist = true});

  Future<void> ensureLoaded() => _load ??= () async {
        if (!persist) return;
        try {
          final box = _box = await Hive.openBox(watchHistoryBoxName);
          for (final e in _memory.entries) {
            await box.put(e.key, e.value);
          }
          _memory.clear();
          revision.value++;
        } catch (e, st) {
          debugPrint('open watch history failed: $e\n$st');
        }
      }();

  WatchEntry? entry(WatchKey key) => WatchEntry.fromJson(_box?.get(key.value) ?? _memory[key.value]);

  /// A closed watch: played -> played (the resume point goes); part way
  /// -> its resume point, unless it was played before (it stays played);
  /// a peek changes nothing. Jellyfin items are not kept here.
  void record(WatchRecord r) {
    if (r.key.isJellyfin) return;
    final before = entry(r.key);
    final WatchEntry next;
    switch (r.verdict.outcome) {
      case WatchOutcome.played || WatchOutcome.keepPlayed:
        next = WatchEntry(played: true, title: r.title, ref: r.ref, at: r.at);
      case WatchOutcome.partial:
        next = WatchEntry(
            played: before?.played ?? false,
            resumeAt: (before?.played ?? false) ? 0 : r.verdict.resumeAt ?? 0,
            title: r.title,
            ref: r.ref,
            at: r.at);
      case WatchOutcome.peek:
        return;
    }
    final json = next.toJson();
    final box = _box;
    if (box == null) {
      _memory[r.key.value] = json;
    } else {
      box.put(r.key.value, json).catchError((Object e) => debugPrint('watch history put ${r.key}: $e'));
    }
    revision.value++;
  }

  /// Every entry, newest first.
  List<(WatchKey, WatchEntry)> get entries {
    final raw = <String, Object?>{..._memory, if (_box != null) for (final k in _box!.keys) '$k': _box!.get(k)};
    final out = [
      for (final e in raw.entries)
        if (WatchEntry.fromJson(e.value) case final w?) (WatchKey._(e.key), w),
    ];
    out.sort((a, b) => b.$2.at.compareTo(a.$2.at));
    return out;
  }
}
