/// Carrying the viewer's audio/subtitle choice from one episode to the
/// next. Pure functions, no I/O.
library;

import 'models.dart';

/// The traits of a chosen track that are compared against the next
/// episode's tracks. Stream indices are not compared: they shift between
/// releases.
class TrackPreference {
  final JellyfinStreamType type;
  final String? language;
  final String? title;
  final String? codec;
  final int? channels;
  final bool isForced;
  final bool isHearingImpaired;
  const TrackPreference({
    required this.type,
    this.language,
    this.title,
    this.codec,
    this.channels,
    this.isForced = false,
    this.isHearingImpaired = false,
  });

  factory TrackPreference.fromStream(JellyfinMediaStream s) => TrackPreference(
        type: s.type,
        language: s.language,
        title: s.title,
        codec: s.codec,
        channels: s.channels,
        isForced: s.isForced,
        isHearingImpaired: s.isHearingImpaired,
      );
}

/// Picks the track in [candidates] that best matches [preference]:
/// 1. same type and same language (required; ISO 639-1/639-2 codes are
///    equated, so "en" = "eng" and "ger" = "deu"; a missing or "und"
///    language only matches another missing/"und" one);
/// 2. most similar title (exact match first, then shared words, so "Full
///    Subtitles" keeps "Full" over "Signs & Songs");
/// 3. same forced / hearing-impaired flags;
/// 4. same codec, then the closest channel count;
/// 5. the stream marked default, then the lowest index.
/// Returns null when no candidate has the language: the caller then keeps
/// the server/player default.
JellyfinMediaStream? matchTrack(TrackPreference preference, List<JellyfinMediaStream> candidates) {
  final lang = normalizeLanguage(preference.language);
  final pool = candidates
      .where((s) => s.type == preference.type && normalizeLanguage(s.language) == lang)
      .toList();
  if (pool.isEmpty) return null;
  final prefTokens = _titleTokens(preference.title);
  final prefTitle = _normTitle(preference.title);

  List<num> score(JellyfinMediaStream s) => [
        _normTitle(s.title) == prefTitle ? 2 : _jaccard(prefTokens, _titleTokens(s.title)),
        s.isForced == preference.isForced ? 1 : 0,
        s.isHearingImpaired == preference.isHearingImpaired ? 1 : 0,
        _eq(s.codec, preference.codec) ? 1 : 0,
        (preference.channels == null || s.channels == null)
            ? 0
            : -(s.channels! - preference.channels!).abs(),
        s.isDefault ? 1 : 0,
        -s.index,
      ];

  JellyfinMediaStream? best;
  List<num>? bestScore;
  for (final s in pool) {
    final sc = score(s);
    if (bestScore == null || _compare(sc, bestScore) > 0) {
      best = s;
      bestScore = sc;
    }
  }
  return best;
}

/// Result of [matchTracks]. Indices are Jellyfin stream indices (also what
/// progress reports carry). [subtitleStreamIndex] is -1 for "subtitles
/// off"; null in either field means no match (use the default).
class TrackSelection {
  final int? audioStreamIndex;
  final int? subtitleStreamIndex;
  const TrackSelection({this.audioStreamIndex, this.subtitleStreamIndex});

  @override
  String toString() => 'TrackSelection(audio: $audioStreamIndex, subtitle: $subtitleStreamIndex)';
}

/// Carries a whole choice over: [audio] and [subtitle] are the tracks
/// picked on the previous episode (null = nothing picked, keep defaults);
/// [subtitlesOff] means the viewer turned subtitles off, which carries over
/// as -1. [streams] are the next episode's streams.
TrackSelection matchTracks({
  JellyfinMediaStream? audio,
  JellyfinMediaStream? subtitle,
  bool subtitlesOff = false,
  required List<JellyfinMediaStream> streams,
}) =>
    TrackSelection(
      audioStreamIndex:
          audio == null ? null : matchTrack(TrackPreference.fromStream(audio), streams)?.index,
      subtitleStreamIndex: subtitlesOff
          ? -1
          : subtitle == null
              ? null
              : matchTrack(TrackPreference.fromStream(subtitle), streams)?.index,
    );

const _iso1To2 = {
  'en': 'eng', 'ja': 'jpn', 'de': 'deu', 'fr': 'fra', 'es': 'spa', 'it': 'ita',
  'pt': 'por', 'ru': 'rus', 'zh': 'zho', 'ko': 'kor', 'ar': 'ara', 'nl': 'nld',
  'pl': 'pol', 'sv': 'swe', 'no': 'nor', 'nb': 'nob', 'da': 'dan', 'fi': 'fin',
  'cs': 'ces', 'sk': 'slk', 'hu': 'hun', 'ro': 'ron', 'el': 'ell', 'tr': 'tur',
  'he': 'heb', 'hi': 'hin', 'th': 'tha', 'vi': 'vie', 'id': 'ind', 'ms': 'msa',
  'uk': 'ukr', 'bg': 'bul', 'hr': 'hrv', 'sr': 'srp', 'fa': 'fas', 'ca': 'cat',
};

// ISO 639-2/B (bibliographic) -> 639-2/T, which Jellyfin mostly reports.
const _bToT = {
  'ger': 'deu', 'fre': 'fra', 'chi': 'zho', 'dut': 'nld', 'cze': 'ces', 'slo': 'slk',
  'gre': 'ell', 'rum': 'ron', 'per': 'fas', 'may': 'msa', 'baq': 'eus', 'arm': 'hye',
  'geo': 'kat', 'ice': 'isl', 'mac': 'mkd', 'alb': 'sqi', 'bur': 'mya', 'wel': 'cym',
  'tib': 'bod',
};

/// Lower-case ISO 639-2/T code, or null for none / "und".
String? normalizeLanguage(String? language) {
  if (language == null) return null;
  var l = language.trim().toLowerCase();
  final dash = l.indexOf(RegExp(r'[-_]'));
  if (dash > 0) l = l.substring(0, dash); // "en-US" -> "en"
  if (l.isEmpty || l == 'und' || l == 'unk' || l == 'mis' || l == 'zxx') return null;
  l = _iso1To2[l] ?? l;
  return _bToT[l] ?? l;
}

const _stopWords = {'and', 'the', 'of', 'a'};

String _normTitle(String? t) => _titleTokens(t).join(' ');

List<String> _titleTokens(String? title) {
  if (title == null) return const [];
  return title
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9À-￿]+'))
      .where((w) => w.isNotEmpty && !_stopWords.contains(w))
      .map((w) => w.length > 3 && w.endsWith('s') ? w.substring(0, w.length - 1) : w)
      .toList();
}

double _jaccard(List<String> a, List<String> b) {
  if (a.isEmpty && b.isEmpty) return 1;
  final sa = a.toSet(), sb = b.toSet();
  final inter = sa.intersection(sb).length;
  return inter / sa.union(sb).length;
}

bool _eq(String? a, String? b) => a != null && b != null && a.toLowerCase() == b.toLowerCase();

int _compare(List<num> a, List<num> b) {
  for (var i = 0; i < a.length; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return 0;
}
