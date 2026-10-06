import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart';

import 'accounts.dart';

// Per-viewer audio/subtitle carry-over: the last choice is kept per series
// (and as a global fallback) and matched against the next Jellyfin item's
// tracks with core's `matchTrack`. Local only; nothing goes on the wire.

const trackPrefsBoxName = 'track_prefs';
const _keyGlobal = 'global';

/// One mpv track as media_kit lists it ([id] is mpv's `aid` / `sid`).
class MpvTrack {
  final int id;
  final JellyfinStreamType type;
  final String? language;
  final String? title;
  final String? codec;
  final int? channels;
  final bool isDefault;
  const MpvTrack({
    required this.id,
    required this.type,
    this.language,
    this.title,
    this.codec,
    this.channels,
    this.isDefault = false,
  });

  /// As a stream for [matchTrack]; its index is the mpv id.
  JellyfinMediaStream get asStream => JellyfinMediaStream(
      index: id,
      type: type,
      language: language,
      title: title,
      codec: codec,
      channels: channels,
      isDefault: isDefault);

  /// Menu text: "English (eac3 2ch)", "Track 2".
  String get label {
    final name = title ?? language ?? 'Track $id';
    final extra = [?codec, if (channels != null) '${channels}ch'].join(' ');
    final lang = title != null && language != null ? ' [$language]' : '';
    return extra.isEmpty ? '$name$lang' : '$name$lang ($extra)';
  }
}

/// A viewer's audio/subtitle choice as traits (indices shift between
/// files). [subtitlesOff] wins over [subtitle].
class TrackChoice {
  final TrackPreference? audio;
  final TrackPreference? subtitle;
  final bool subtitlesOff;
  const TrackChoice({this.audio, this.subtitle, this.subtitlesOff = false});

  Map<String, Object?> toJson() => {
        'audio': ?_prefToJson(audio),
        'subtitle': ?_prefToJson(subtitle),
        'subtitlesOff': subtitlesOff,
      };

  static TrackChoice? fromJson(Object? j) {
    if (j is! Map) return null;
    return TrackChoice(
      audio: _prefFromJson(j['audio'], JellyfinStreamType.audio),
      subtitle: _prefFromJson(j['subtitle'], JellyfinStreamType.subtitle),
      subtitlesOff: j['subtitlesOff'] == true,
    );
  }

  /// The choice behind mpv's [aid] / [sid] (null = none / off): traits from
  /// the Jellyfin [source] when this viewer has it (title, channels,
  /// forced/HI flags), else from mpv's [tracks].
  factory TrackChoice.of({
    required int? aid,
    required int? sid,
    JellyfinMediaSource? source,
    List<MpvTrack> tracks = const [],
  }) {
    TrackPreference? pref(JellyfinStreamType type, int? id) {
      if (id == null) return null;
      if (source != null) {
        final index = source.jellyfinIndexForMpvTrack(type, id);
        final s = index == null ? null : source.streamAt(index);
        if (s != null) return TrackPreference.fromStream(s);
      }
      final t = tracks.where((t) => t.type == type && t.id == id).firstOrNull;
      return t == null ? null : TrackPreference.fromStream(t.asStream);
    }

    return TrackChoice(
      audio: pref(JellyfinStreamType.audio, aid),
      subtitle: pref(JellyfinStreamType.subtitle, sid),
      subtitlesOff: sid == null,
    );
  }
}

Map<String, Object?>? _prefToJson(TrackPreference? p) => p == null
    ? null
    : {
        'language': ?p.language,
        'title': ?p.title,
        'codec': ?p.codec,
        'channels': ?p.channels,
        if (p.isForced) 'forced': true,
        if (p.isHearingImpaired) 'hi': true,
      };

TrackPreference? _prefFromJson(Object? j, JellyfinStreamType type) {
  if (j is! Map) return null;
  String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
  return TrackPreference(
    type: type,
    language: s(j['language']),
    title: s(j['title']),
    codec: s(j['codec']),
    channels: j['channels'] is int ? j['channels'] as int : null,
    isForced: j['forced'] == true,
    isHearingImpaired: j['hi'] == true,
  );
}

/// mpv tracks to select for [choice] on a new item. Matches against the
/// Jellyfin [source]'s streams when this viewer has them (mapped to mpv ids
/// with [JellyfinMediaSource.mpvTrackId]), else against mpv's [tracks].
/// Null fields keep the player's default; [subtitlesOff] turns them off.
({int? aid, int? sid, bool subtitlesOff}) chooseTracks(TrackChoice choice,
    {JellyfinMediaSource? source, List<MpvTrack> tracks = const []}) {
  int? pick(TrackPreference? pref) {
    if (pref == null) return null;
    if (source != null) {
      final s = matchTrack(pref, source.mediaStreams);
      return s == null ? null : source.mpvTrackId(s.index);
    }
    return matchTrack(pref, [for (final t in tracks) t.asStream])?.index;
  }

  return (
    aid: pick(choice.audio),
    sid: choice.subtitlesOff ? null : pick(choice.subtitle),
    subtitlesOff: choice.subtitlesOff,
  );
}

/// The last choice per series and overall, in their own Hive box.
class TrackPrefs {
  TrackPrefs({JellyfinStore? store}) : _store = store ?? HiveJellyfinStore(boxName: trackPrefsBoxName);
  final JellyfinStore _store;
  Future<void>? _open;

  Future<void> _ready() => _open ??= _store.open().catchError((Object e) {
        debugPrint('open track prefs failed: $e');
      });

  /// The series' choice, else the global one.
  Future<TrackChoice?> load({String? seriesId}) async {
    await _ready();
    try {
      Object? read(String key) {
        final v = _store.get(key);
        return v is String ? jsonDecode(v) : null;
      }

      return (seriesId == null ? null : TrackChoice.fromJson(read('series:$seriesId'))) ??
          TrackChoice.fromJson(read(_keyGlobal));
    } catch (e) {
      debugPrint('read track prefs failed: $e');
      return null;
    }
  }

  /// Saves [choice] as the global one and, with [seriesId], the series'.
  Future<void> save(TrackChoice choice, {String? seriesId}) async {
    await _ready();
    try {
      final v = jsonEncode(choice.toJson());
      await _store.put(_keyGlobal, v);
      if (seriesId != null) await _store.put('series:$seriesId', v);
    } catch (e) {
      debugPrint('save track prefs failed: $e');
    }
  }
}
