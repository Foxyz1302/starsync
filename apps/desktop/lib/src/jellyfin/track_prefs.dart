import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart';

import 'accounts.dart';

// Per-viewer audio/subtitle carry-over: the last choice is kept per series
// (and as a global fallback) and matched against the next Jellyfin item's
// tracks with core's `matchTrack`. Local only; nothing goes on the wire.

const trackPrefsBoxName = 'track_prefs';
const _keyGlobal = 'global';

/// One audio or subtitle track of the open file as mpv's `track-list`
/// has it ([id] is mpv's `aid` / `sid`; [selected] is mpv's choice).
class MpvTrack {
  final int id;
  final JellyfinStreamType type;
  final String? language;
  final String? title;
  final String? codec;
  final int? channels;
  final bool isDefault;
  final bool isForced;
  final bool isHearingImpaired;
  final bool isExternal;
  final bool selected;
  const MpvTrack({
    required this.id,
    required this.type,
    this.language,
    this.title,
    this.codec,
    this.channels,
    this.isDefault = false,
    this.isForced = false,
    this.isHearingImpaired = false,
    this.isExternal = false,
    this.selected = false,
  });

  /// As a stream for [matchTrack]; its index is the mpv id.
  JellyfinMediaStream get asStream => JellyfinMediaStream(
      index: id,
      type: type,
      language: language,
      title: title,
      codec: codec,
      channels: channels,
      isDefault: isDefault,
      isForced: isForced,
      isHearingImpaired: isHearingImpaired);

  /// Menu text: "Japanese · E-AC3 2.0 · Commentary", "Track 2 · ASS".
  String get label => [
        languageName(language) ?? 'Track $id',
        [?codecName(codec), ?channelLayoutName(channels)].join(' '),
        if (title != null && title != languageName(language)) title!,
        if (isForced) 'Forced',
        if (isHearingImpaired) 'SDH',
      ].where((p) => p.isNotEmpty).join(' · ');

  @override
  bool operator ==(Object other) =>
      other is MpvTrack &&
      other.id == id &&
      other.type == type &&
      other.language == language &&
      other.title == title &&
      other.codec == codec &&
      other.channels == channels &&
      other.isDefault == isDefault &&
      other.isForced == isForced &&
      other.isHearingImpaired == isHearingImpaired &&
      other.isExternal == isExternal &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(id, type, language, title, codec, channels, isDefault, isForced,
      isHearingImpaired, isExternal, selected);

  @override
  String toString() => 'MpvTrack(${type.name} $id ${selected ? '*' : ''}$label)';
}

const _languages = {
  'jpn': 'Japanese', 'ja': 'Japanese', 'eng': 'English', 'en': 'English',
  'ger': 'German', 'deu': 'German', 'de': 'German', 'fre': 'French', 'fra': 'French',
  'fr': 'French', 'spa': 'Spanish', 'es': 'Spanish', 'ita': 'Italian', 'it': 'Italian',
  'por': 'Portuguese', 'pt': 'Portuguese', 'rus': 'Russian', 'ru': 'Russian',
  'chi': 'Chinese', 'zho': 'Chinese', 'zh': 'Chinese', 'kor': 'Korean', 'ko': 'Korean',
  'ara': 'Arabic', 'ar': 'Arabic', 'pol': 'Polish', 'pl': 'Polish', 'dut': 'Dutch',
  'nld': 'Dutch', 'nl': 'Dutch', 'swe': 'Swedish', 'sv': 'Swedish', 'fin': 'Finnish',
  'fi': 'Finnish', 'nor': 'Norwegian', 'no': 'Norwegian', 'dan': 'Danish', 'da': 'Danish',
  'tur': 'Turkish', 'tr': 'Turkish', 'hin': 'Hindi', 'hi': 'Hindi', 'tha': 'Thai',
  'th': 'Thai', 'vie': 'Vietnamese', 'vi': 'Vietnamese', 'ind': 'Indonesian', 'id': 'Indonesian',
  'may': 'Malay', 'msa': 'Malay', 'ms': 'Malay', 'heb': 'Hebrew', 'he': 'Hebrew',
  'gre': 'Greek', 'ell': 'Greek', 'el': 'Greek', 'cze': 'Czech', 'ces': 'Czech', 'cs': 'Czech',
  'hun': 'Hungarian', 'hu': 'Hungarian', 'ukr': 'Ukrainian', 'uk': 'Ukrainian',
  'rum': 'Romanian', 'ron': 'Romanian', 'ro': 'Romanian', 'und': 'Undetermined',
};

/// "jpn" -> "Japanese"; other codes upper-cased, null for none.
String? languageName(String? code) {
  if (code == null || code.isEmpty) return null;
  return _languages[code.toLowerCase()] ?? code.toUpperCase();
}

const _codecs = {
  'eac3': 'E-AC3', 'ac3': 'AC3', 'aac': 'AAC', 'flac': 'FLAC', 'opus': 'Opus',
  'vorbis': 'Vorbis', 'mp3': 'MP3', 'truehd': 'TrueHD', 'dts': 'DTS', 'mlp': 'MLP',
  'alac': 'ALAC', 'ass': 'ASS', 'ssa': 'SSA', 'subrip': 'SRT', 'srt': 'SRT',
  'webvtt': 'VTT', 'mov_text': 'TX3G', 'hdmv_pgs_subtitle': 'PGS', 'pgssub': 'PGS',
  'dvd_subtitle': 'VobSub', 'dvdsub': 'VobSub', 'dvb_subtitle': 'DVB',
};

/// mpv / Jellyfin codec name for menus: "eac3" -> "E-AC3", "subrip" -> "SRT".
String? codecName(String? codec) {
  if (codec == null || codec.isEmpty) return null;
  final c = codec.toLowerCase();
  if (c.startsWith('pcm')) return 'PCM';
  return _codecs[c] ?? codec.toUpperCase();
}

/// Channel count as a layout: 2 -> "2.0", 6 -> "5.1", 8 -> "7.1".
String? channelLayoutName(int? channels) => switch (channels) {
      null || <= 0 => null,
      1 => '1.0',
      2 => '2.0',
      3 => '2.1',
      6 => '5.1',
      7 => '6.1',
      8 => '7.1',
      final n => '${n}ch',
    };

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
