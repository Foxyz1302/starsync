import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';
import 'package:sync_relay_core/core.dart' show createLogger;

import 'anilist.dart';
import 'animeflow.dart';
import 'schedule_model.dart';

// The last schedule the Schedule tab showed, kept on disk per account and
// source, so the tab opens on it at once while it loads anew
// (ARCHITECTURE "Desktop UI", Schedule). It keeps the merged result the
// page drew, nothing of the clients' own caches (AniList's pages,
// AnimeFlow's ETags), which stay theirs.

final _log = createLogger('schedule');

/// A schedule kept from an earlier load, and when it was loaded.
typedef KeptSchedule = ({ScheduleSnapshot snapshot, DateTime savedAt});

/// Kept data this old, or from another day, is marked as old while the
/// fresh one loads.
const keptScheduleFreshFor = Duration(hours: 1);

/// [savedAt] is old by [now]: past [keptScheduleFreshFor], or another
/// local day.
bool keptScheduleIsOld(DateTime savedAt, DateTime now) {
  final a = savedAt.toLocal(), b = now.toLocal();
  return now.difference(savedAt) > keptScheduleFreshFor || a.year != b.year || a.month != b.month || a.day != b.day;
}

/// Which schedule is whose: the AnimeFlow address and the Jellyfin
/// account its token comes from (none: AniList alone).
String scheduleKeyFor(String animeFlowBase, {String? serverId, String? userId}) =>
    '$animeFlowBase|${serverId ?? '-'}|${userId ?? '-'}';

/// Reads and writes kept schedules, one file per key in [dir] (the app's
/// cache folder by default; none: nothing is kept on disk).
class ScheduleStore {
  ScheduleStore({Future<Directory?> Function()? dir}) : _dir = dir ?? _cacheDir;

  final Future<Directory?> Function() _dir;

  /// The format of the files; another one is not read.
  static const version = 1;

  static Future<Directory?> _cacheDir() async {
    try {
      return await getApplicationCacheDirectory();
    } catch (_) {
      return null;
    }
  }

  Future<File?> _file(String key) async {
    final dir = await _dir();
    return dir == null ? null : File('${dir.path}/schedule-kept-${_hash(key)}.json');
  }

  /// The schedule kept for [key]; null when none (or unreadable).
  Future<KeptSchedule?> read(String key) async {
    try {
      final f = await _file(key);
      if (f == null || !await f.exists()) return null;
      final text = await f.readAsString();
      return await Isolate.run(() => keptFromJson(jsonDecode(text), key), debugName: 'schedule read');
    } catch (e) {
      _log.warning('kept schedule unreadable: $e');
      return null;
    }
  }

  /// Keeps [snapshot] for [key], loaded at [savedAt].
  Future<void> write(String key, ScheduleSnapshot snapshot, DateTime savedAt) async {
    try {
      final f = await _file(key);
      if (f == null) return;
      final text = await Isolate.run(() => jsonEncode(keptToJson(snapshot, savedAt, key)), debugName: 'schedule write');
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      _log.warning('schedule not kept: $e');
    }
  }
}

/// FNV-1a, 64 bit, as hex: a file name from a key.
String _hash(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in utf8.encode(s)) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xffffffffffffffff;
  }
  return h.toUnsigned(64).toRadixString(16);
}

/// [snapshot] (loaded at [savedAt], for [key]) as JSON.
Map<String, Object?> keptToJson(ScheduleSnapshot snapshot, DateTime savedAt, String key) => {
      'version': ScheduleStore.version,
      'key': key,
      'savedAt': savedAt.millisecondsSinceEpoch,
      'from': snapshot.from.millisecondsSinceEpoch,
      'to': snapshot.to.millisecondsSinceEpoch,
      'aniListStaleSince': snapshot.aniListStaleSince?.millisecondsSinceEpoch,
      'animeFlowError': snapshot.animeFlowError,
      if (snapshot.me case final me?)
        'me': {'user_id': me.userId, 'name': me.name, 'scopes': [for (final s in me.scopes) s.name]},
      'entries': [for (final e in snapshot.entries) _entryToJson(e)],
    };

/// [keptToJson] read back; null for another [key] or format.
KeptSchedule? keptFromJson(Object? j, String key) {
  if (j is! Map || j['version'] != ScheduleStore.version || j['key'] != key) return null;
  DateTime? time(Object? v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
  final savedAt = time(j['savedAt']), from = time(j['from']), to = time(j['to']);
  final rows = j['entries'];
  if (savedAt == null || from == null || to == null || rows is! List) return null;
  final me = j['me'];
  return (
    snapshot: ScheduleSnapshot(
      from: from,
      to: to,
      entries: [for (final r in rows) ?_entryFromJson(r)],
      aniListStaleSince: time(j['aniListStaleSince']),
      animeFlowError: j['animeFlowError'] is String ? j['animeFlowError'] as String : null,
      me: me is Map ? AnimeFlowMe.fromJson(me) : null,
    ),
    savedAt: savedAt,
  );
}

Map<String, Object?> _entryToJson(ScheduleEntry e) => {
      'airing': e.airing.toJson(),
      'status': e.status.name,
      'progress': ?e.progress,
      'reason': ?e.reason,
      'lastSearchedAt': ?e.lastSearchedAt?.millisecondsSinceEpoch,
      if (e.tracked) 'tracked': true,
      'seriesId': ?e.seriesId,
      'season': ?e.season,
      'jellyfinEpisode': ?e.jellyfinEpisode,
      'jellyfinSeriesId': ?e.jellyfinSeriesId,
      if (e.watch case final w?) 'watch': {'played': w.played, 'progress': w.progress},
    };

ScheduleEntry? _entryFromJson(Object? j) {
  if (j is! Map) return null;
  final airing = Airing.fromJson(j['airing']);
  final status = ScheduleStatus.values.where((s) => s.name == j['status']).firstOrNull;
  if (airing == null || status == null) return null;
  int? integer(Object? v) => v is int ? v : null;
  final searched = integer(j['lastSearchedAt']);
  final w = j['watch'];
  return ScheduleEntry(
    airing: airing,
    status: status,
    progress: (j['progress'] as num?)?.toDouble(),
    reason: j['reason'] is String ? j['reason'] as String : null,
    lastSearchedAt: searched == null ? null : DateTime.fromMillisecondsSinceEpoch(searched, isUtc: true),
    tracked: j['tracked'] == true,
    seriesId: integer(j['seriesId']),
    season: integer(j['season']),
    jellyfinEpisode: integer(j['jellyfinEpisode']),
    jellyfinSeriesId: j['jellyfinSeriesId'] is String ? j['jellyfinSeriesId'] as String : null,
    watch: w is Map
        ? EpisodeWatch(played: w['played'] == true, progress: (w['progress'] as num?)?.toDouble() ?? 0)
        : null,
  );
}
