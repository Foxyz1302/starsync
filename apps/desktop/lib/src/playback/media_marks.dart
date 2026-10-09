import 'dart:convert';

import 'package:sync_relay_core/core.dart' show JellyfinMediaSegment, JellyfinSegmentType, JellyfinStreamType;

import '../jellyfin/track_prefs.dart' show MpvTrack;

// Chapters, segments and tracks of the open media as plain values, plus
// the skip rules built on them (OP / ED / the 1:30 fallback, chapter
// steps). No Flutter, no player: `PlaybackController` feeds its signals
// through these and any controls UI reads them.

/// One mpv chapter. [end] is the next chapter's start, or the duration for
/// the last one ([start] while the duration is unknown).
class MediaChapter {
  final int index;
  final String title;
  final Duration start;
  final Duration end;
  const MediaChapter({required this.index, required this.title, required this.start, required this.end});

  @override
  bool operator ==(Object other) =>
      other is MediaChapter &&
      other.index == index &&
      other.title == title &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(index, title, start, end);

  @override
  String toString() => 'MediaChapter($index "$title" $start-$end)';
}

/// A marked range of the item from Jellyfin (MediaSegments): intro,
/// outro, recap, preview or commercial.
class MediaSegment {
  final JellyfinSegmentType kind;
  final Duration start;
  final Duration end;
  const MediaSegment({required this.kind, required this.start, required this.end});

  factory MediaSegment.fromJellyfin(JellyfinMediaSegment s) =>
      MediaSegment(kind: s.type, start: s.start, end: s.end);

  @override
  String toString() => 'MediaSegment(${kind.name} $start-$end)';
}

/// Where a skip range came from.
enum SkipSource { segment, chapter }

/// An opening or ending: skipping it seeks to [end].
class SkipRange {
  final Duration start;
  final Duration end;
  final SkipSource source;
  /// The chapter title when [source] is a chapter.
  final String? title;
  const SkipRange(this.start, this.end, this.source, {this.title});

  @override
  bool operator ==(Object other) =>
      other is SkipRange &&
      other.start == start &&
      other.end == end &&
      other.source == source &&
      other.title == title;

  @override
  int get hashCode => Object.hash(start, end, source, title);

  @override
  String toString() => 'SkipRange(${source.name} $start-$end${title == null ? '' : ' "$title"'})';
}

Duration _secs(num s) => Duration(microseconds: (s * 1e6).round());

/// mpv `chapter-list` as JSON (`[{"title": "OP", "time": 30.0}, ...]`).
/// Ends come from the next start, the last from [duration].
List<MediaChapter> parseChapterList(String json, Duration duration) {
  final Object? raw;
  try {
    raw = jsonDecode(json);
  } on FormatException {
    return const [];
  }
  if (raw is! List) return const [];
  final starts = <(String, Duration)>[
    for (final c in raw)
      if (c is Map && c['time'] is num && (c['time'] as num).isFinite)
        ((c['title'] is String ? c['title'] as String : '').trim(), _secs(c['time'] as num)),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return chaptersFromStarts(starts, duration);
}

/// Chapters from (title, start) pairs in start order.
List<MediaChapter> chaptersFromStarts(List<(String, Duration)> starts, Duration duration) => [
      for (var i = 0; i < starts.length; i++)
        MediaChapter(
          index: i,
          title: starts[i].$1,
          start: starts[i].$2,
          end: i + 1 < starts.length
              ? starts[i + 1].$2
              : (duration > starts[i].$2 ? duration : starts[i].$2),
        ),
    ];

/// mpv `track-list` as JSON: the audio and subtitle tracks (video and
/// unknown types left out), with mpv's selection.
List<MpvTrack> parseTrackList(String json) {
  final Object? raw;
  try {
    raw = jsonDecode(json);
  } on FormatException {
    return const [];
  }
  if (raw is! List) return const [];
  String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
  return [
    for (final t in raw)
      if (t is Map && t['id'] is int && (t['type'] == 'audio' || t['type'] == 'sub'))
        MpvTrack(
          id: t['id'] as int,
          type: t['type'] == 'audio' ? JellyfinStreamType.audio : JellyfinStreamType.subtitle,
          language: s(t['lang']),
          title: s(t['title']),
          codec: s(t['codec']),
          channels: (t['demux-channel-count'] ?? t['audio-channels']) is int
              ? (t['demux-channel-count'] ?? t['audio-channels']) as int
              : null,
          isDefault: t['default'] == true,
          isForced: t['forced'] == true,
          isHearingImpaired: t['hearing-impaired'] == true,
          isExternal: t['external'] == true,
          selected: t['selected'] == true,
        ),
  ];
}

final _openingTitle = RegExp(r'\b(op|opening|intro)\d*\b', caseSensitive: false);
final _endingTitle = RegExp(r'\b(ed|ending|credits|outro)\d*\b', caseSensitive: false);

/// "OP", "OP1", "Opening", "Intro" (whole words, any case).
bool isOpeningTitle(String title) => _openingTitle.hasMatch(title);

/// "ED", "ED2", "Ending", "Credits", "Outro" (whole words, any case).
bool isEndingTitle(String title) => _endingTitle.hasMatch(title);

SkipRange? _range(List<MediaSegment> segments, List<MediaChapter> chapters,
    JellyfinSegmentType kind, bool Function(String) titleMatches) {
  for (final s in segments) {
    if (s.kind == kind && s.end > s.start) return SkipRange(s.start, s.end, SkipSource.segment);
  }
  for (final c in chapters) {
    if (c.end > c.start && titleMatches(c.title)) {
      return SkipRange(c.start, c.end, SkipSource.chapter, title: c.title);
    }
  }
  return null;
}

/// The opening: the first Jellyfin Intro segment, else the first chapter
/// titled like an opening ([isOpeningTitle]).
SkipRange? openingRange(List<MediaSegment> segments, List<MediaChapter> chapters) =>
    _range(segments, chapters, JellyfinSegmentType.intro, isOpeningTitle);

/// The ending: the first Jellyfin Outro segment, else the first chapter
/// titled like an ending ([isEndingTitle]).
SkipRange? endingRange(List<MediaSegment> segments, List<MediaChapter> chapters) =>
    _range(segments, chapters, JellyfinSegmentType.outro, isEndingTitle);

/// Index of the chapter playing at [position], or null (before the first
/// chapter, or none).
int? chapterIndexAt(List<MediaChapter> chapters, Duration position) {
  int? at;
  for (final c in chapters) {
    if (c.start <= position) at = c.index;
  }
  return at;
}

/// mpv's `chapter-seek-threshold`: going back within this much of a
/// chapter's start goes to the chapter before it.
const chapterBackThreshold = Duration(seconds: 5);

/// Target of a chapter step ([delta] +1 = PgDn, -1 = PgUp), as mpv: back
/// goes to the current chapter's start, or the previous one within
/// [chapterBackThreshold] of it; forward to the next chapter's start.
/// Null when there is nowhere to go.
Duration? chapterStepTarget(List<MediaChapter> chapters, Duration position, int delta) {
  if (chapters.isEmpty || delta == 0) return null;
  final at = chapterIndexAt(chapters, position);
  if (delta > 0) {
    final next = (at ?? -1) + delta;
    return next < chapters.length ? chapters[next].start : null;
  }
  if (at == null) return null;
  var target = at + delta + 1;
  if (position - chapters[at].start < chapterBackThreshold) target--;
  return target >= 0 ? chapters[target].start : Duration.zero;
}

/// What the skip pill offers.
enum SkipKind {
  /// "Skip OP": to the opening's end.
  opening,
  /// "Skip ED": to the ending's end, nothing further.
  ending,
  /// "Skip 1:30": no opening known, +[fallbackSkip] from where it plays.
  fixed,
}

class SkipOffer {
  final SkipKind kind;
  /// Seek target (for [SkipKind.fixed] as of the position it was computed
  /// at; the press itself skips relative to the moment it lands).
  final Duration target;
  const SkipOffer(this.kind, this.target);

  @override
  bool operator ==(Object other) => other is SkipOffer && other.kind == kind && other.target == target;

  @override
  int get hashCode => Object.hash(kind, target);

  @override
  String toString() => 'SkipOffer(${kind.name} -> $target)';
}

/// The fixed skip (pill without an opening, Shift+Right, the controls'
/// "1:30" button).
const fallbackSkip = Duration(seconds: 90);
/// The fallback pill needs media longer than this (an episode, not a clip).
const fallbackMinDuration = Duration(minutes: 20);
/// ... and shows during this first part only.
const fallbackWindow = Duration(minutes: 6);
/// No pill in the last second of a range: the skip would do nothing.
const _skipTail = Duration(seconds: 1);

/// The skip pill at [position]: inside the opening "Skip OP" (to its end),
/// inside the ending "Skip ED" (to its end only: what follows, preview or
/// more episode, is the viewer's call). Without any opening info on media
/// longer than [fallbackMinDuration] and without chapters ([chaptered]: a
/// chaptered file without an OP chapter has none on purpose), "Skip 1:30"
/// during the first [fallbackWindow]. Null otherwise.
SkipOffer? skipOfferAt({
  required Duration position,
  required Duration duration,
  required SkipRange? opening,
  required SkipRange? ending,
  bool chaptered = false,
}) {
  bool inside(SkipRange r) => position >= r.start && position < r.end - _skipTail;
  if (opening != null && inside(opening)) return SkipOffer(SkipKind.opening, opening.end);
  if (ending != null && inside(ending)) return SkipOffer(SkipKind.ending, ending.end);
  if (opening == null && !chaptered && duration > fallbackMinDuration && position < fallbackWindow) {
    final to = position + fallbackSkip;
    return SkipOffer(SkipKind.fixed, to < duration ? to : duration);
  }
  return null;
}

/// "1:05", "1:02:03".
String formatClock(Duration d) {
  final neg = d.isNegative;
  final t = d.abs();
  String two(int n) => n.toString().padLeft(2, '0');
  final h = t.inHours, m = t.inMinutes % 60, s = t.inSeconds % 60;
  final body = h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  return neg ? '-$body' : body;
}
